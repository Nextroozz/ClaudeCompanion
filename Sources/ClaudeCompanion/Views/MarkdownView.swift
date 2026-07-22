import SwiftUI

/// Rendu Markdown d'un segment de texte assistant.
///
/// Découpage en blocs par MarkdownBlockParser ; le Markdown EN LIGNE
/// (gras, italique, `code`, [liens]) de chaque bloc est rendu par
/// `AttributedString(markdown:)` — natif, liens cliquables inclus.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(MarkdownBlockParser.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inline(text))
                .font(.callout)
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Sans ceci, un Text multi-lignes dans un ScrollView voit sa
                // hauteur SOUS-mesurée pendant le streaming : les longues
                // réponses étaient coupées, et seul un rechargement (vues
                // reconstruites) les réparait. fixedSize force la hauteur
                // idéale — celle qui affiche toutes les lignes.
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 4 : 2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

        case .bulletList(let items):
            listView(items) { _ in "•" }

        case .numberedList(let items):
            listView(items) { index in "\(index + 1)." }

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                Text(inline(text))
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)

        case .rule:
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 3)
        }
    }

    private func listView(_ items: [String], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(index))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(inline(item))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Même raison que les paragraphes : une puce longue
                        // s'enroule sur plusieurs lignes et serait tronquée.
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .title2.weight(.bold)
        case 2:  return .title3.weight(.semibold)
        default: return .headline
        }
    }

    /// Markdown en ligne → AttributedString. `inlineOnlyPreservingWhitespace`
    /// garde les retours à la ligne tels quels (comportement attendu en chat).
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
