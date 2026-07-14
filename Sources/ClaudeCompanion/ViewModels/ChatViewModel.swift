import Foundation
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// ChatViewModel — orchestration : UI SwiftUI ⇄ processus `claude`
//
// Isolé sur le MainActor : toutes les mutations d'état publié se font sur le
// thread principal. Le travail lourd (processus, parsing, disque) s'exécute
// dans des tâches détachées ; seuls les événements décodés remontent ici.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - État publié

    @Published var messages: [ChatMessage] = []
    @Published var isStreaming = false
    @Published var errorText: String?
    @Published var sessionID: String?
    @Published var modelName: String?
    @Published var sessions: [SessionSummary] = []
    @Published var binaryURL: URL?
    /// Compteur incrémenté à chaque mutation du contenu — déclenche
    /// l'auto-défilement sans imposer Equatable à tout le modèle.
    @Published var revision = 0

    @Published var permissionMode: PermissionMode {
        didSet { UserDefaults.standard.set(permissionMode.rawValue, forKey: Keys.permissionMode) }
    }

    @Published var projectDirectory: URL {
        didSet {
            UserDefaults.standard.set(projectDirectory.path, forKey: Keys.projectDirectory)
            watchSessionsDirectory()
            Task { await refreshSessions() }
        }
    }

    // MARK: - Privé

    private var currentDraftID: String?
    private var streamTask: Task<Void, Never>?
    private var watcher: DirectoryWatcher?

    private enum Keys {
        static let projectDirectory = "projectDirectoryPath"
        static let permissionMode = "permissionMode"
        static let model = "claudeModel" // optionnel : defaults write … claudeModel sonnet
    }

    // MARK: - Cycle de vie

    init() {
        let savedPath = UserDefaults.standard.string(forKey: Keys.projectDirectory)
        let savedURL = savedPath.flatMap { path -> URL? in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue ? URL(fileURLWithPath: path) : nil
        }
        projectDirectory = savedURL ?? FileManager.default.homeDirectoryForCurrentUser
        permissionMode = UserDefaults.standard.string(forKey: Keys.permissionMode)
            .flatMap(PermissionMode.init) ?? .acceptEdits

        watchSessionsDirectory()
        Task { await refreshSessions() }

        // Résolution du binaire hors MainActor (peut interroger un shell).
        Task {
            let url = await Task.detached(priority: .utility) { ClaudeCLIService.locateBinary() }.value
            self.binaryURL = url
            if url == nil {
                self.errorText = """
                Binaire « claude » introuvable. Installez Claude Code, ou indiquez son chemin :
                defaults write com.votre.bundle-id claudeBinaryPath /chemin/vers/claude
                """
            }
        }
    }

    // MARK: - Actions utilisateur

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard let binary = binaryURL else {
            errorText = "Binaire « claude » introuvable — impossible d'envoyer."
            return
        }

        errorText = nil
        messages.append(ChatMessage(id: UUID().uuidString, role: .user, segments: [.text(text)]))
        isStreaming = true
        bump()

        let options = CLIOptions(
            binary: binary,
            projectDirectory: projectDirectory,
            resumeSessionID: sessionID,
            permissionMode: permissionMode.cliValue,
            model: UserDefaults.standard.string(forKey: Keys.model),
            includePartialMessages: true
        )

        streamTask = Task { [weak self] in
            guard let self else { return }
            var failed = false
            do {
                for try await event in ClaudeCLIService.events(prompt: text, options: options) {
                    self.handle(event)
                }
            } catch {
                failed = true
                self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self.finishStreaming(success: !failed)
            await self.refreshSessions()
        }
    }

    /// Interrompt le tour en cours (SIGTERM au processus via l'annulation).
    func cancel() {
        streamTask?.cancel()
    }

    func newSession() {
        cancel()
        messages = []
        sessionID = nil
        currentDraftID = nil
        errorText = nil
        bump()
    }

    func loadSession(_ session: SessionSummary) {
        cancel()
        Task {
            let fileURL = session.fileURL
            let loaded = await Task.detached(priority: .userInitiated) {
                SessionHistoryService.loadMessages(from: fileURL)
            }.value
            self.messages = loaded
            self.sessionID = session.id
            self.currentDraftID = nil
            self.errorText = nil
            self.bump()
        }
    }

    func setProjectDirectory(_ url: URL) {
        // Sous App Sandbox, l'accès obtenu via NSOpenPanel doit être « ouvert » :
        // no-op inoffensif hors sandbox. Pour persister l'accès entre
        // lancements sandboxés, il faudrait un security-scoped bookmark
        // (voir README, section Sandbox).
        _ = url.startAccessingSecurityScopedResource()
        projectDirectory = url
        newSession()
    }

    func refreshSessions() async {
        let directory = projectDirectory
        sessions = await Task.detached(priority: .utility) {
            Array(SessionHistoryService.listSessions(for: directory).prefix(20))
        }.value
    }

    // MARK: - Traitement des événements du CLI

    private func handle(_ event: ClaudeEvent) {
        switch event {

        case .initialized(let sessionID, let model):
            self.sessionID = sessionID
            if let model { modelName = model }

        case .messageStarted(let id):
            startDraft(id: id)

        case .textDelta(let text):
            let index = ensureDraft()
            if let last = messages[index].segments.last, case .text(let existing) = last {
                messages[index].segments[messages[index].segments.count - 1] = .text(existing + text)
            } else {
                messages[index].segments.append(.text(text))
            }

        case .toolStarted(let id, let name, let detail):
            let index = ensureDraft()
            messages[index].segments.append(.tool(.init(id: id, name: name, detail: detail, status: .running)))

        case .assistantMessage(let id, let segments):
            reconcile(id: id, segments: segments)

        case .toolFinished(let toolUseID, let isError):
            updateTool(id: toolUseID) { $0.status = isError ? .error : .done }

        case .completed(let sessionID, let meta, let isError, let errorText):
            if let sessionID { self.sessionID = sessionID } // l'id peut changer après --resume
            if let index = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[index].meta = meta
            }
            if isError, let errorText, !errorText.isEmpty {
                self.errorText = errorText
            }
        }
        bump()
    }

    /// Le message complet fait autorité : il remplace le brouillon streamé
    /// (deltas), en conservant les statuts d'outils déjà résolus.
    private func reconcile(id: String, segments: [ChatMessage.Segment]) {
        var merged = segments
        for (index, segment) in merged.enumerated() {
            if case .tool(var call) = segment,
               let known = findTool(id: call.id), known.status != .running {
                call.status = known.status
                merged[index] = .tool(call)
            }
        }

        if let existing = messages.firstIndex(where: { $0.id == id }) {
            messages[existing].segments = merged
            messages[existing].isStreaming = false
        } else if let draftID = currentDraftID,
                  let draft = messages.firstIndex(where: { $0.id == draftID }) {
            messages[draft] = ChatMessage(id: id, role: .assistant, segments: merged,
                                          meta: messages[draft].meta, isStreaming: false)
        } else {
            messages.append(ChatMessage(id: id, role: .assistant, segments: merged))
        }
        currentDraftID = nil
    }

    private func startDraft(id: String) {
        guard currentDraftID != id else { return }
        currentDraftID = id
        messages.append(ChatMessage(id: id, role: .assistant, segments: [], isStreaming: true))
    }

    private func ensureDraft() -> Int {
        if let id = currentDraftID, let index = messages.firstIndex(where: { $0.id == id }) {
            return index
        }
        // Deltas sans message_start (flux dégradé) : brouillon de secours.
        let id = UUID().uuidString
        currentDraftID = id
        messages.append(ChatMessage(id: id, role: .assistant, segments: [], isStreaming: true))
        return messages.count - 1
    }

    private func finishStreaming(success: Bool) {
        isStreaming = false
        streamTask = nil
        if let draftID = currentDraftID,
           let index = messages.firstIndex(where: { $0.id == draftID }) {
            messages[index].isStreaming = false
        }
        currentDraftID = nil
        // Outils restés « en cours » (tour interrompu ou résultat non émis).
        for messageIndex in messages.indices {
            for segmentIndex in messages[messageIndex].segments.indices {
                if case .tool(var call) = messages[messageIndex].segments[segmentIndex],
                   call.status == .running {
                    call.status = success ? .done : .error
                    messages[messageIndex].segments[segmentIndex] = .tool(call)
                }
            }
        }
        bump()
    }

    private func updateTool(id: String, _ mutate: (inout ChatMessage.ToolCall) -> Void) {
        for messageIndex in messages.indices.reversed() {
            for segmentIndex in messages[messageIndex].segments.indices {
                if case .tool(var call) = messages[messageIndex].segments[segmentIndex], call.id == id {
                    mutate(&call)
                    messages[messageIndex].segments[segmentIndex] = .tool(call)
                    return
                }
            }
        }
    }

    private func findTool(id: String) -> ChatMessage.ToolCall? {
        for message in messages.reversed() {
            for segment in message.segments {
                if case .tool(let call) = segment, call.id == id { return call }
            }
        }
        return nil
    }

    private func watchSessionsDirectory() {
        let sessionsDir = SessionHistoryService.sessionsDirectory(for: projectDirectory)
        let target = FileManager.default.fileExists(atPath: sessionsDir.path)
            ? sessionsDir
            : SessionHistoryService.projectsRoot
        watcher = DirectoryWatcher(url: target) { [weak self] in
            Task { await self?.refreshSessions() }
        }
    }

    private func bump() {
        revision &+= 1
    }
}
