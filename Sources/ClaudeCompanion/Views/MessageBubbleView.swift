import SwiftUI

/// Rendu d'un message : bulle teintée à droite pour l'utilisateur, colonne
/// pleine largeur pour Claude (texte Markdown + puces d'outils + métadonnées).
struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantColumn
        }
    }

    // MARK: - Utilisateur

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachmentNames.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(message.attachmentNames, id: \.self) { name in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                    .font(.caption2)
                                Text(name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 140)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .liquidGlass(in: Capsule())
                        }
                    }
                }
                Text(userText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 17), tint: .accentColor)
            }
        }
    }

    private var userText: String {
        message.segments.compactMap { segment in
            if case .text(let text) = segment { return text }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - Assistant

    private var assistantColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text("Claude")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if message.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.leading, 2)
                }
            }

            ForEach(Array(message.segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .text(let markdown):
                    MarkdownView(markdown: markdown)
                case .thinking(let text):
                    ThinkingView(text: text,
                                 isLive: message.isStreaming && index == message.segments.count - 1)
                case .tool(let call):
                    ToolChipView(call: call)
                }
            }

            // Rien ici pendant l'attente. L'ancien placeholder « Claude
            // réfléchit… » était figé et faisait croire à une app plantée ;
            // le Pong y a aussi été essayé, mais la bulle n'est vide que le
            // temps de la réflexion — 0,3 s sur une question simple, invisible.
            // Attente et progression vivent donc dans ActivityIndicatorView,
            // affiché tant que Claude travaille. Le spinner de l'en-tête suffit
            // à marquer la bulle en cours.

            if let meta = message.meta {
                metaLine(meta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metaLine(_ meta: TurnMeta) -> some View {
        var parts: [String] = []
        if let ms = meta.durationMS {
            parts.append(String(format: "%.1f s", Double(ms) / 1000))
        }
        if let cost = meta.costUSD {
            parts.append(String(format: "%.4f $", cost))
        }
        if let turns = meta.numTurns, turns > 1 {
            parts.append("\(turns) tours")
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

/// Réflexion interne du modèle : affichée en direct (dernières lignes, texte
/// discret) pendant le streaming, puis repliée en une puce dépliable.
struct ThinkingView: View {
    let text: String
    /// true tant que la réflexion défile — on montre alors la fin du texte.
    let isLive: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(isLive ? "Réflexion…" : "Réflexion")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                    if isLive {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.quaternary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)
            .help("Réflexion interne du modèle — cliquer pour tout afficher")

            if isLive && !isExpanded {
                Text(Self.tail(of: text, lines: 3))
                    .font(.caption.italic())
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isExpanded {
                ScrollView {
                    Text(text)
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(9)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    /// Dernières lignes non vides — fait défiler la réflexion comme un journal.
    static func tail(of text: String, lines: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines)
            .joined(separator: "\n")
    }
}

/// Puce représentant un appel d'outil (Read, Bash…) avec son statut.
/// Cliquable : se déplie en inspecteur montrant l'entrée complète (commande
/// Bash colorée en shell, sinon JSON indenté) et la sortie du tool_result.
/// Pendant l'exécution, l'inspecteur s'ouvre tout seul et suit en direct ce
/// que Claude écrit (commande, contenu de fichier…), comme l'extension VS Code.
struct ToolChipView: View {
    let call: ChatMessage.ToolCall
    @State private var isExpanded = false

    /// Suivi en direct : l'outil tourne encore et son entrée se remplit.
    private var isLive: Bool {
        call.status == .running && call.inputDisplay != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                chipLabel
            }
            .buttonStyle(.plain)
            .help("Cliquer pour voir l'entrée et la sortie de l'outil")

            if isExpanded {
                inspector
            } else if isLive {
                livePreview
            }
        }
    }

    /// Aperçu temps réel : la fin de ce que Claude est en train d'écrire,
    /// colorée, comme un terminal qui défile.
    private var livePreview: some View {
        Text(SyntaxHighlighter.highlight(
            ThinkingView.tail(of: call.inputDisplay ?? "", lines: 10),
            language: call.inputLanguage
        ))
        .font(.system(size: 11.5, design: .monospaced))
        .lineSpacing(1.5)
        .lineLimit(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
    }

    private var chipLabel: some View {
        HStack(spacing: 7) {
            statusIcon
            Text(call.name)
                .font(.caption.weight(.semibold))
            if let detail = call.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .liquidGlass(in: Capsule())
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let input = call.inputDisplay {
                inspectorSection(title: "Entrée",
                                 text: input,
                                 language: call.inputLanguage,
                                 icon: "arrow.right.circle")
            }
            if let output = call.output {
                inspectorSection(title: call.status == .error ? "Sortie (erreur)" : "Sortie",
                                 text: output,
                                 language: nil,
                                 icon: call.status == .error ? "exclamationmark.circle" : "arrow.left.circle")
            }
            if call.inputDisplay == nil && call.output == nil {
                Text(call.status == .running
                     ? "En cours d'exécution…"
                     : "Aucun détail disponible pour cet appel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func inspectorSection(title: String, text: String, language: String?, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Group {
                    if let language {
                        Text(SyntaxHighlighter.highlight(text, language: language))
                    } else {
                        Text(text) // sortie brute (logs) : pas de coloration parasite
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(1.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch call.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .done:
            Image(systemName: toolSymbol)
                .font(.caption)
                .foregroundStyle(Color.green.opacity(0.9))
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.red.opacity(0.9))
        }
    }

    private var toolSymbol: String {
        switch call.name {
        case "Read":                 return "doc.text"
        case "Write", "Edit":        return "pencil"
        case "Bash":                 return "terminal"
        case "Grep", "Glob":         return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent":        return "person.2"
        case "TodoWrite":            return "checklist"
        default:                     return "hammer"
        }
    }
}
