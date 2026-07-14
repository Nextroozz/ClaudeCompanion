import SwiftUI

/// Bloc de code : cartouche sombre semi-transparent posé sur le verre,
/// étiquette de langage, bouton copier, coloration syntaxique native.
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.6)
                Spacer()
                Button(action: copy) {
                    Label(justCopied ? "Copié" : "Copier",
                          systemImage: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(justCopied ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Copier le code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                // Note perf : la coloration est recalculée à chaque rendu.
                // Amplement suffisant pour des blocs de chat ; pour de très
                // gros fichiers, mémoïser sur (code, language).
                Text(SyntaxHighlighter.highlight(code, language: language))
                    .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            justCopied = false
        }
    }
}
