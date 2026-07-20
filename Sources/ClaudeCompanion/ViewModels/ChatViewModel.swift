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
    /// Fichiers joints en attente d'envoi (trombone ou glisser-déposer).
    @Published var pendingAttachments: [URL] = []
    /// Compteur incrémenté à chaque mutation du contenu — déclenche
    /// l'auto-défilement sans imposer Equatable à tout le modèle.
    @Published var revision = 0

    @Published var permissionMode: PermissionMode {
        didSet { UserDefaults.standard.set(permissionMode.rawValue, forKey: Keys.permissionMode) }
    }

    /// Modèle choisi pour les prochains tours (id complet, ex.
    /// "claude-opus-4-8"). nil = laisser le CLI décider (défaut utilisateur).
    @Published var selectedModel: String? {
        didSet { persist(selectedModel, forKey: Keys.model) }
    }

    /// Niveau d'effort de raisonnement (--effort). nil = défaut du modèle.
    @Published var selectedEffort: String? {
        didSet { persist(selectedEffort, forKey: Keys.effort) }
    }

    /// Modèles proposés dans le sélecteur — rafraîchis depuis l'API Anthropic
    /// (les nouveaux modèles apparaissent automatiquement).
    @Published var availableModels: [ClaudeModel] = ModelCatalogService.fallbackModels

    /// Commandes « / » disponibles (autocomplétion). La liste vient de
    /// l'événement init du CLI (plugins et skills compris) et est persistée.
    @Published var slashCommands: [SlashCommand] = []

    /// Ce que Claude fait en ce moment (« Réfléchit », « Code », « Exécute »…)
    /// — affiché avec animation pendant le streaming.
    @Published var currentActivity: String?

    /// Tokens de réflexion accumulés sur TOUT le tour (pas seulement le message
    /// courant : un tour agentique en enchaîne plusieurs, chacun réfléchissant).
    ///
    /// Les modèles actuels chiffrent le TEXTE de leur réflexion : impossible de
    /// l'afficher au fil de l'eau, il n'est jamais transmis. Ce compteur est le
    /// seul signal vivant pendant une longue réflexion — sans lui, l'interface
    /// reste muette parfois trente secondes.
    @Published private(set) var thinkingTokens = 0

    /// Début du tour, pour le chronomètre. Une Date et non un compteur : la vue
    /// en déduit l'écoulé à chaque tick, sans que le modèle ait à battre la
    /// mesure — même raison que le Pong (voir PongWaitingView).
    @Published private(set) var turnStartedAt: Date?

    /// Verbe d'activité pour la réflexion. Constante partagée : `activityDetail`
    /// s'y compare pour n'afficher le compteur QUE pendant la réflexion.
    static let thinkingVerb = "Réfléchit"
    /// Verbe de rédaction — le seul moment où l'attente n'en est pas une.
    static let writingVerb = "Rédige"

    /// Claude travaille sans rien écrire : réflexion (dont le texte est
    /// chiffré) ou outils en cours. C'est LÀ que l'attente est réelle, et donc
    /// là que le Pong a lieu d'être.
    var isWaiting: Bool {
        currentActivity != nil && currentActivity != Self.writingVerb
    }

    /// Complément affiché à droite du verbe d'activité.
    ///
    /// Le compteur RESTE affiché après la réflexion, tant que le tour dure.
    /// Le restreindre au verbe « Réfléchit » le rendait invisible : sur une
    /// question simple, la réflexion ne dure que 0,3 s. Or ce qu'on veut
    /// savoir, c'est combien Claude a réfléchi pour CE tour — l'information
    /// garde tout son sens pendant qu'il exécute ensuite ses outils.
    var activityDetail: String? {
        guard thinkingTokens > 0 else { return nil }
        return "~\(thinkingTokens) tk"
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

    // Suivi du streaming des inputs d'outils (affichage en direct) :
    // index de bloc → id d'outil, id d'outil → JSON partiel accumulé / nom /
    // horodatage du dernier rafraîchissement UI (throttling).
    private var toolIDForBlockIndex: [Int: String] = [:]
    private var toolInputBuffers: [String: String] = [:]
    private var toolNames: [String: String] = [:]
    private var lastLiveRefresh: [String: Date] = [:]

    private enum Keys {
        static let projectDirectory = "projectDirectoryPath"
        static let permissionMode = "permissionMode"
        static let model = "claudeModel"   // id complet ou alias, passé à --model
        static let effort = "claudeEffort" // low | medium | high | xhigh | max
        static let slashCommands = "slashCommandNames" // liste captée à l'init
    }

    private func persist(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
        selectedModel = UserDefaults.standard.string(forKey: Keys.model)
        selectedEffort = UserDefaults.standard.string(forKey: Keys.effort)

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

        // Catalogue de modèles : cache immédiat, puis rafraîchissement API.
        availableModels = ModelCatalogService.cachedModels()
        Task {
            self.availableModels = await Task.detached(priority: .utility) {
                await ModelCatalogService.refreshedModels()
            }.value
        }

        // Commandes « / » : liste persistée du dernier tour, enrichie des
        // descriptions locales (builtins, plugins).
        rebuildSlashCommands(names: UserDefaults.standard.stringArray(forKey: Keys.slashCommands) ?? [])
    }

    /// Reconstruit la liste des commandes (hors MainActor : lit le disque).
    private func rebuildSlashCommands(names: [String]) {
        let directory = projectDirectory
        Task {
            self.slashCommands = await Task.detached(priority: .utility) {
                SlashCommandService.commands(fromCLINames: names, projectDirectory: directory)
            }.value
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

        // Pièces jointes : le CLI ne reçoit pas de binaire par stdin — on passe
        // les CHEMINS dans le prompt (c'est aussi ce que fait le TUI officiel
        // lors d'un glisser-déposer) : Claude lit les images/PDF/textes avec
        // Read (multimodal) et ouvre les archives avec Bash.
        let attachments = pendingAttachments
        pendingAttachments = []
        var prompt = text
        if !attachments.isEmpty {
            let list = attachments.map { "- \($0.path)" }.joined(separator: "\n")
            prompt += """


            [Pièces jointes fournies par l'utilisateur via l'interface — examine-les \
            avec tes outils (Read pour les images, PDF et textes ; Bash pour les \
            archives .zip/.tar) lorsque c'est pertinent :]
            \(list)
            """
        }

        messages.append(ChatMessage(id: UUID().uuidString,
                                    role: .user,
                                    segments: [.text(text)],
                                    attachmentNames: attachments.map(\.lastPathComponent)))
        isStreaming = true
        bump()

        let options = CLIOptions(
            binary: binary,
            projectDirectory: projectDirectory,
            resumeSessionID: sessionID,
            permissionMode: permissionMode.cliValue,
            model: selectedModel,
            effort: selectedEffort,
            includePartialMessages: true
        )

        currentActivity = "Démarre"
        // Remise à zéro par TOUR : les tokens s'additionnent sur tous les
        // messages du tour, y compris ceux qui suivent un appel d'outil.
        thinkingTokens = 0
        turnStartedAt = Date()

        // Les deltas peuvent arriver par CENTAINES par seconde : traiter (et
        // donc re-rendre SwiftUI) à chaque événement sature le thread principal
        // et l'UI semble figée jusqu'à la fin du tour. On regroupe donc les
        // deltas par fenêtres de ~80 ms ; les événements structurants (début
        // d'outil, résultat, fin de message…) sont appliqués immédiatement.
        streamTask = Task { [weak self] in
            guard let self else { return }
            var failed = false
            do {
                var pending: [ClaudeEvent] = []
                var lastFlush = ContinuousClock.now
                for try await event in ClaudeCLIService.events(prompt: prompt, options: options) {
                    pending.append(event)
                    let isDelta: Bool
                    switch event {
                    case .textDelta, .thinkingDelta, .toolInputDelta: isDelta = true
                    default: isDelta = false
                    }
                    if !isDelta || ContinuousClock.now - lastFlush >= .milliseconds(80) {
                        for queued in pending { self.handle(queued) }
                        pending.removeAll(keepingCapacity: true)
                        lastFlush = ContinuousClock.now
                    }
                }
                for queued in pending { self.handle(queued) }
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

    /// Supprime une session. Si c'est celle affichée, on repart à neuf pour ne
    /// pas rester sur un historique fantôme.
    func deleteSession(_ session: SessionSummary) {
        SessionHistoryService.deleteSession(at: session.fileURL)
        if session.id == sessionID { newSession() }
        Task { await refreshSessions() }
    }

    /// Ajoute des fichiers (sélecteur ou glisser-déposer) au prochain envoi.
    func addAttachments(_ urls: [URL]) {
        for url in urls where !pendingAttachments.contains(url) {
            // Sous App Sandbox, ouvre l'accès obtenu via le sélecteur/drop
            // (no-op inoffensif hors sandbox).
            _ = url.startAccessingSecurityScopedResource()
            pendingAttachments.append(url)
        }
    }

    /// Coût cumulé (estimation, USD) et nombre de tours de la conversation affichée.
    var conversationCost: (costUSD: Double, turns: Int) {
        let metas = messages.compactMap(\.meta)
        return (metas.compactMap(\.costUSD).reduce(0, +), metas.count)
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

        case .initialized(let sessionID, let model, let slashCommandNames):
            self.sessionID = sessionID
            if let model { modelName = model }
            if !slashCommandNames.isEmpty,
               slashCommandNames != UserDefaults.standard.stringArray(forKey: Keys.slashCommands) {
                UserDefaults.standard.set(slashCommandNames, forKey: Keys.slashCommands)
                rebuildSlashCommands(names: slashCommandNames)
            }

        case .messageStarted(let id):
            toolIDForBlockIndex = [:] // les index de blocs repartent de zéro
            startDraft(id: id)

        case .textDelta(let text):
            currentActivity = Self.writingVerb
            let index = ensureDraft()
            if let last = messages[index].segments.last, case .text(let existing) = last {
                messages[index].segments[messages[index].segments.count - 1] = .text(existing + text)
            } else {
                messages[index].segments.append(.text(text))
            }

        case .thinkingProgress(let tokens):
            // Réflexion chiffrée : pas de texte à montrer, mais on prouve que
            // ça avance. Aucun ensureDraft ici — créer une bulle vide pour un
            // contenu qui n'arrivera jamais afficherait une bulle fantôme.
            currentActivity = Self.thinkingVerb
            thinkingTokens += tokens

        case .thinkingDelta(let text):
            currentActivity = Self.thinkingVerb
            let index = ensureDraft()
            if let last = messages[index].segments.last, case .thinking(let existing) = last {
                messages[index].segments[messages[index].segments.count - 1] = .thinking(existing + text)
            } else {
                messages[index].segments.append(.thinking(text))
            }

        case .toolStarted(let blockIndex, let id, let name, let detail):
            currentActivity = Self.activityVerb(forTool: name)
            let index = ensureDraft()
            messages[index].segments.append(.tool(.init(id: id, name: name, detail: detail, status: .running)))
            toolIDForBlockIndex[blockIndex] = id
            toolNames[id] = name
            toolInputBuffers[id] = ""

        case .toolInputDelta(let blockIndex, let partialJSON):
            guard let toolID = toolIDForBlockIndex[blockIndex] else { break }
            toolInputBuffers[toolID, default: ""] += partialJSON
            refreshLiveToolInput(toolID: toolID, throttled: true)

        case .blockFinished(let blockIndex):
            guard let toolID = toolIDForBlockIndex[blockIndex] else { break }
            refreshLiveToolInput(toolID: toolID, throttled: false)

        case .messageStopped:
            if let draftID = currentDraftID,
               let index = messages.firstIndex(where: { $0.id == draftID }) {
                messages[index].isStreaming = false
            }
            currentDraftID = nil
            toolIDForBlockIndex = [:]

        case .assistantMessage(let id, let segments):
            reconcile(id: id, segments: segments)

        case .toolFinished(let toolUseID, let isError, let output):
            currentActivity = "Réfléchit" // en attente de la suite du modèle
            updateTool(id: toolUseID) {
                $0.status = isError ? .error : .done
                if let output { $0.output = output }
            }

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

    /// Verbe d'activité affiché pendant qu'un outil tourne.
    static func activityVerb(forTool name: String) -> String {
        switch name {
        case "Write", "Edit", "NotebookEdit":     return "Code"
        case "Bash":                              return "Exécute"
        case "Read", "Grep", "Glob":              return "Explore"
        case "WebFetch", "WebSearch":             return "Cherche"
        case "Task", "Agent":                     return "Délègue"
        case "TodoWrite", "TaskCreate":           return "Planifie"
        default:                                  return "Travaille"
        }
    }

    /// Affichage en direct de l'input d'un outil : le JSON partiel accumulé est
    /// réparé puis reprojeté (commande Bash, contenu de fichier Write…), comme
    /// le fait l'extension VS Code. Throttlé pour ne pas surcharger l'UI sur
    /// les gros contenus.
    private func refreshLiveToolInput(toolID: String, throttled: Bool) {
        guard let buffer = toolInputBuffers[toolID], !buffer.isEmpty,
              let name = toolNames[toolID] else { return }

        if throttled, buffer.count > 2048,
           let last = lastLiveRefresh[toolID], Date().timeIntervalSince(last) < 0.08 {
            return
        }
        guard let input = PartialJSON.parse(buffer) else { return }
        lastLiveRefresh[toolID] = Date()

        let detail = ClaudeEventDecoder.toolDetail(name: name, input: input)
        let display = ClaudeEventDecoder.toolInputDisplay(name: name, input: input)
        updateTool(id: toolID) { call in
            if let detail { call.detail = detail }
            if let display {
                call.inputDisplay = display.text
                call.inputLanguage = display.language
            }
        }
    }

    /// Réconciliation avec une ligne « assistant » du flux. Ces lignes arrivent
    /// UNE PAR BLOC terminé (même id de message) : on FUSIONNE donc dans le
    /// brouillon streamé au lieu de le remplacer — sinon les segments déjà
    /// affichés disparaîtraient. Les inputs d'outils y sont pris comme version
    /// faisant autorité (le JSON réparé du direct était un best-effort).
    private func reconcile(id: String, segments: [ChatMessage.Segment]) {
        let target: Int
        if let existing = messages.firstIndex(where: { $0.id == id }) {
            target = existing
        } else if let draftID = currentDraftID,
                  let draft = messages.firstIndex(where: { $0.id == draftID }) {
            // Brouillon de secours (flux dégradé) : adopte l'id authentique.
            messages[draft] = ChatMessage(id: id, role: .assistant,
                                          segments: messages[draft].segments,
                                          meta: messages[draft].meta,
                                          isStreaming: messages[draft].isStreaming)
            currentDraftID = id
            target = draft
        } else {
            messages.append(ChatMessage(id: id, role: .assistant, segments: []))
            target = messages.count - 1
        }

        for segment in segments {
            switch segment {
            case .tool(let call):
                if findTool(id: call.id) != nil {
                    updateTool(id: call.id) { known in
                        known.detail = call.detail ?? known.detail
                        if let display = call.inputDisplay {
                            known.inputDisplay = display
                            known.inputLanguage = call.inputLanguage
                        }
                    }
                } else {
                    messages[target].segments.append(.tool(call))
                }
            case .text(let text):
                mergeStreamed(text, into: target, matching: {
                    if case .text(let existing) = $0 { return existing } else { return nil }
                }, wrap: ChatMessage.Segment.text)
            case .thinking(let text):
                mergeStreamed(text, into: target, matching: {
                    if case .thinking(let existing) = $0 { return existing } else { return nil }
                }, wrap: ChatMessage.Segment.thinking)
            }
        }
    }

    /// Fusionne un bloc texte/réflexion faisant autorité avec sa version
    /// streamée : si le dernier segment du même genre en est un préfixe (ou
    /// égal), on le remplace ; sinon (flux dégradé sans deltas) on l'ajoute.
    private func mergeStreamed(_ authoritative: String,
                               into target: Int,
                               matching extract: (ChatMessage.Segment) -> String?,
                               wrap: (String) -> ChatMessage.Segment) {
        for index in messages[target].segments.indices.reversed() {
            guard let existing = extract(messages[target].segments[index]) else { continue }
            if existing == authoritative { return }
            if authoritative.hasPrefix(existing) || existing.hasPrefix(authoritative) {
                messages[target].segments[index] = wrap(authoritative)
                return
            }
            break // dernier segment du genre trouvé mais différent : nouveau bloc
        }
        messages[target].segments.append(wrap(authoritative))
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
        currentActivity = nil
        turnStartedAt = nil // arrête le chronomètre
        toolIDForBlockIndex = [:]
        toolInputBuffers = [:]
        toolNames = [:]
        lastLiveRefresh = [:]
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

// L'accumulation des tokens de réflexion se fait dans `handle`, privé et nourri
// par un flux réel. On expose le seul geste utile aux tests.
extension ChatViewModel {
    func applyThinkingProgressForTesting(tokens: Int) {
        handle(.thinkingProgress(estimatedTokens: tokens))
    }
}
