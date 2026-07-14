import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MarkdownBlockParser — découpage du Markdown en blocs d'affichage
//
// `AttributedString(markdown:)` d'Apple gère très bien le Markdown EN LIGNE
// (gras, italique, `code`, liens) mais pas les structures de bloc (fences de
// code, titres, listes) dans un rendu de chat. Ce parseur fait donc le
// découpage en blocs ; le rendu en ligne reste délégué à AttributedString.
// Zéro dépendance externe — remplaçable par swift-markdown-ui si besoin.
// ─────────────────────────────────────────────────────────────────────────────

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bulletList([String])
    case numberedList([String])
    case quote(String)
    case codeBlock(language: String?, code: String)
    case rule
}

enum MarkdownBlockParser {

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quotes: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inFence = false
        var fenceMarker = "```"

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushBullets() {
            if !bullets.isEmpty { blocks.append(.bulletList(bullets)); bullets = [] }
        }
        func flushNumbered() {
            if !numbered.isEmpty { blocks.append(.numberedList(numbered)); numbered = [] }
        }
        func flushQuotes() {
            if !quotes.isEmpty { blocks.append(.quote(quotes.joined(separator: "\n"))); quotes = [] }
        }
        func flushAll() {
            flushParagraph(); flushBullets(); flushNumbered(); flushQuotes()
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if inFence {
                if trimmed.hasPrefix(fenceMarker) {
                    blocks.append(.codeBlock(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                    codeLines = []
                    inFence = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                fenceMarker = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
                inFence = true
                continue
            }

            if trimmed.isEmpty { flushAll(); continue }

            if let (level, text) = headingItem(trimmed) {
                flushAll()
                blocks.append(.heading(level: level, text: text))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph(); flushBullets(); flushNumbered()
                quotes.append(String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
                continue
            }

            if let item = bulletItem(trimmed) {
                flushParagraph(); flushNumbered(); flushQuotes()
                bullets.append(item)
                continue
            }

            if let item = numberedItem(trimmed) {
                flushParagraph(); flushBullets(); flushQuotes()
                numbered.append(item)
                continue
            }

            flushBullets(); flushNumbered(); flushQuotes()
            paragraph.append(rawLine)
        }

        // Fence jamais refermée : cas normal PENDANT le streaming — on rend
        // le code partiel plutôt que de le faire disparaître.
        if inFence {
            blocks.append(.codeBlock(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    // MARK: - Reconnaissance des lignes

    private static func headingItem(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }
}
