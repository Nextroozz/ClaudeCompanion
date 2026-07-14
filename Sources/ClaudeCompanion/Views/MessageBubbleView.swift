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
            Text(userText)
                .font(.callout)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 17), tint: .accentColor)
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

            ForEach(Array(message.segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let markdown):
                    MarkdownView(markdown: markdown)
                case .tool(let call):
                    ToolChipView(call: call)
                }
            }

            if message.isStreaming && message.segments.isEmpty {
                Text("Claude réfléchit…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

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

/// Puce compacte représentant un appel d'outil (Read, Bash…) avec son statut.
struct ToolChipView: View {
    let call: ChatMessage.ToolCall

    var body: some View {
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .liquidGlass(in: Capsule())
        .help(call.detail ?? call.name)
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
