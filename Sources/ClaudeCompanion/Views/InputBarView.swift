import SwiftUI
import UniformTypeIdentifiers

/// Barre de saisie : capsule de verre, champ multi-lignes extensible, bouton
/// trombone pour joindre des fichiers (images, archives, PDF… — tout ce que
/// Claude sait lire avec ses outils), bouton envoyer/stop.
/// Les fichiers peuvent aussi être glissés-déposés n'importe où sur la fenêtre.
struct InputBarView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var draft = ""
    @State private var showsFilePicker = false
    @FocusState private var isFocused: Bool

    // Autocomplétion des commandes « / » : la liste vit dans le ViewModel
    // (captée depuis le CLI). Ici : sélection clavier et annulation (Échap).
    @State private var selectedSuggestion = 0
    @State private var suggestionsDismissed = false

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty {
                suggestionList
            }

            if !viewModel.pendingAttachments.isEmpty {
                attachmentChips
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    showsFilePicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Joindre des fichiers (images, .zip, PDF, code…) — ou glissez-les sur la fenêtre")
                .fileImporter(isPresented: $showsFilePicker,
                              allowedContentTypes: [.item],
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result {
                        viewModel.addAttachments(urls)
                    }
                }

                TextField("Demandez à Claude…  (⏎ envoyer · ⌥⏎ ligne · / commandes)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .onSubmit(send)
                    .onKeyPress(.upArrow) { moveSuggestion(-1) }
                    .onKeyPress(.downArrow) { moveSuggestion(+1) }
                    .onKeyPress(.tab) { acceptSuggestion() }
                    .onKeyPress(.return) { acceptSuggestion() }
                    .onKeyPress(.escape) {
                        guard !suggestions.isEmpty else { return .ignored }
                        suggestionsDismissed = true
                        return .handled
                    }
                    .onChange(of: draft) {
                        selectedSuggestion = 0
                        suggestionsDismissed = false
                    }

                Button(action: viewModel.isStreaming ? viewModel.cancel : send) {
                    Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(
                            viewModel.isStreaming
                                ? AnyShapeStyle(Color.red.opacity(0.85))
                                : (canSend
                                    ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(Color.secondary.opacity(0.5)))
                        )
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.isStreaming && !canSend)
                .help(viewModel.isStreaming ? "Interrompre la génération" : "Envoyer (⏎)")
                .animation(.easeInOut(duration: 0.15), value: viewModel.isStreaming)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 23))
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .onAppear { isFocused = true }
    }

    /// Envoi possible avec du texte, ou avec seulement des pièces jointes.
    private var canSend: Bool {
        !trimmedDraft.isEmpty || !viewModel.pendingAttachments.isEmpty
    }

    // MARK: - Autocomplétion des commandes /

    /// Suggestions affichées : le brouillon est une commande en cours de frappe
    /// (« / » sans espace ni retour à la ligne), filtrée en temps réel.
    private var suggestions: [SlashCommand] {
        guard !suggestionsDismissed,
              draft.hasPrefix("/"),
              !draft.contains(" "), !draft.contains("\n") else { return [] }
        let query = draft.dropFirst().lowercased()
        let matches = viewModel.slashCommands.filter {
            query.isEmpty || $0.name.lowercased().contains(query)
        }
        // Les correspondances par préfixe d'abord, puis alphabétique.
        return Array(matches.sorted { a, b in
            let aPrefix = a.name.lowercased().hasPrefix(query)
            let bPrefix = b.name.lowercased().hasPrefix(query)
            if aPrefix != bPrefix { return aPrefix }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }.prefix(8))
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, command in
                Button {
                    accept(command)
                } label: {
                    HStack(spacing: 8) {
                        Text("/\(command.name)")
                            .font(.callout.weight(.medium).monospaced())
                            .foregroundStyle(index == selectedSuggestion ? Color.accentColor : .primary)
                        Text(command.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        index == selectedSuggestion ? Color.white.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.top, 4)
        }
    }

    private func moveSuggestion(_ delta: Int) -> KeyPress.Result {
        let count = suggestions.count
        guard count > 0 else { return .ignored }
        selectedSuggestion = (selectedSuggestion + delta + count) % count
        return .handled
    }

    private func acceptSuggestion() -> KeyPress.Result {
        let list = suggestions
        guard !list.isEmpty else { return .ignored }
        accept(list[min(selectedSuggestion, list.count - 1)])
        return .handled
    }

    private func accept(_ command: SlashCommand) {
        draft = command.insertionText
        selectedSuggestion = 0
        isFocused = true
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.pendingAttachments, id: \.self) { url in
                    HStack(spacing: 5) {
                        Image(systemName: Self.symbol(for: url))
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 160)
                        Button {
                            viewModel.pendingAttachments.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: Capsule())
                }
            }
        }
    }

    static func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "svg":
            return "photo"
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar":
            return "doc.zipper"
        case "pdf":
            return "doc.richtext"
        case "mp3", "wav", "m4a", "aac":
            return "waveform"
        case "mp4", "mov", "avi":
            return "film"
        default:
            return "doc.text"
        }
    }

    private func send() {
        guard canSend, !viewModel.isStreaming else { return }
        let text = trimmedDraft.isEmpty ? "Examine les fichiers joints." : trimmedDraft
        draft = ""
        viewModel.send(text)
    }
}
