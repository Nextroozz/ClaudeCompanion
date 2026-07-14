import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// SyntaxHighlighter — coloration syntaxique légère, 100 % native
//
// Colorateur par expressions régulières : suffisant et très rapide pour des
// blocs de code de chat. Priorité des passes (la première qui « réclame » une
// plage gagne) : commentaires de bloc → chaînes → commentaires de ligne →
// mots-clés → nombres → types. Ainsi `https://…` dans une chaîne n'est jamais
// pris pour un commentaire `//`.
//
// Pour un rendu de qualité IDE (grammaires complètes), remplacer par
// Splash ou Highlightr via SPM — l'API `highlight(_:language:)` ne bouge pas.
// ─────────────────────────────────────────────────────────────────────────────

enum SyntaxHighlighter {

    /// Palette fixe choisie pour rester lisible sur verre sombre ET clair.
    /// (Définie en RGB pur pour éviter toute dépendance AppKit ici.)
    enum Theme {
        static let plain   = Color(red: 0.92, green: 0.93, blue: 0.96).opacity(0.92)
        static let keyword = Color(red: 1.00, green: 0.48, blue: 0.68)
        static let string  = Color(red: 1.00, green: 0.65, blue: 0.45)
        static let number  = Color(red: 0.85, green: 0.75, blue: 1.00)
        static let comment = Color(red: 0.55, green: 0.60, blue: 0.66)
        static let type    = Color(red: 0.45, green: 0.85, blue: 0.90)
    }

    struct LanguageProfile {
        let lineComments: [String]
        let blockComment: (open: String, close: String)?
        let keywords: Set<String>
        let highlightTypes: Bool
    }

    static func highlight(_ code: String, language: String?) -> AttributedString {
        guard !code.isEmpty else { return AttributedString() }
        let profile = profile(for: language)

        // Collecte des jetons colorés (plages non chevauchantes, premier arrivé servi).
        var claimed: [Range<String.Index>] = []
        var tokens: [(range: Range<String.Index>, color: Color)] = []

        func apply(pattern: String, color: Color, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let fullRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, options: [], range: fullRange) {
                guard let range = Range(match.range, in: code),
                      !claimed.contains(where: { $0.overlaps(range) }) else { continue }
                claimed.append(range)
                tokens.append((range, color))
            }
        }

        if let block = profile.blockComment {
            let open = NSRegularExpression.escapedPattern(for: block.open)
            let close = NSRegularExpression.escapedPattern(for: block.close)
            apply(pattern: "\(open).*?\(close)", color: Theme.comment, options: [.dotMatchesLineSeparators])
        }
        // Chaînes AVANT les commentaires de ligne (protège les URL "https://…").
        apply(pattern: "\"\"\".*?\"\"\"", color: Theme.string, options: [.dotMatchesLineSeparators])
        apply(pattern: "\"(?:[^\"\\\\\\n]|\\\\.)*\"", color: Theme.string)
        apply(pattern: "'(?:[^'\\\\\\n]|\\\\.)*'", color: Theme.string)
        apply(pattern: "`(?:[^`\\\\]|\\\\.)*`", color: Theme.string, options: [.dotMatchesLineSeparators])
        for marker in profile.lineComments {
            apply(pattern: NSRegularExpression.escapedPattern(for: marker) + "[^\\n]*", color: Theme.comment)
        }
        if !profile.keywords.isEmpty {
            let alternation = profile.keywords.sorted().joined(separator: "|")
            apply(pattern: "\\b(?:\(alternation))\\b", color: Theme.keyword)
        }
        apply(pattern: "\\b0[xX][0-9a-fA-F_]+\\b|\\b\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b",
              color: Theme.number)
        if profile.highlightTypes {
            apply(pattern: "\\b[A-Z][A-Za-z0-9_]*\\b", color: Theme.type)
        }

        // Assemblage : on reconstruit la chaîne attribuée segment par segment
        // (déterministe, sans conversion d'index String → AttributedString).
        tokens.sort { $0.range.lowerBound < $1.range.lowerBound }
        var result = AttributedString()
        var cursor = code.startIndex
        for token in tokens {
            if cursor < token.range.lowerBound {
                result += plainChunk(String(code[cursor..<token.range.lowerBound]))
            }
            var colored = AttributedString(String(code[token.range]))
            colored.foregroundColor = token.color
            result += colored
            cursor = token.range.upperBound
        }
        if cursor < code.endIndex {
            result += plainChunk(String(code[cursor...]))
        }
        return result
    }

    private static func plainChunk(_ string: String) -> AttributedString {
        var chunk = AttributedString(string)
        chunk.foregroundColor = Theme.plain
        return chunk
    }

    // MARK: - Profils de langages

    static func profile(for language: String?) -> LanguageProfile {
        switch language?.lowercased() {
        case "swift":
            return LanguageProfile(
                lineComments: ["//"], blockComment: ("/*", "*/"),
                keywords: ["actor", "as", "async", "await", "break", "case", "catch", "class",
                           "continue", "default", "defer", "deinit", "do", "else", "enum",
                           "extension", "false", "fileprivate", "for", "func", "guard", "if",
                           "import", "in", "init", "inout", "internal", "is", "lazy", "let",
                           "mutating", "nil", "open", "override", "private", "protocol", "public",
                           "repeat", "rethrows", "return", "self", "some", "static", "struct",
                           "subscript", "super", "switch", "throw", "throws", "true", "try",
                           "typealias", "var", "weak", "where", "while"],
                highlightTypes: true
            )
        case "js", "jsx", "javascript", "ts", "tsx", "typescript":
            return LanguageProfile(
                lineComments: ["//"], blockComment: ("/*", "*/"),
                keywords: ["abstract", "any", "as", "async", "await", "break", "case", "catch",
                           "class", "const", "continue", "default", "delete", "do", "else",
                           "enum", "export", "extends", "false", "finally", "for", "from",
                           "function", "if", "implements", "import", "in", "instanceof",
                           "interface", "let", "new", "null", "of", "return", "static", "super",
                           "switch", "this", "throw", "true", "try", "type", "typeof",
                           "undefined", "var", "void", "while", "yield"],
                highlightTypes: true
            )
        case "python", "py":
            return LanguageProfile(
                lineComments: ["#"], blockComment: nil,
                keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue",
                           "def", "del", "elif", "else", "except", "False", "finally", "for",
                           "from", "global", "if", "import", "in", "is", "lambda", "None",
                           "nonlocal", "not", "or", "pass", "raise", "return", "True", "try",
                           "while", "with", "yield"],
                highlightTypes: true
            )
        case "sh", "bash", "zsh", "shell", "console":
            return LanguageProfile(
                lineComments: ["#"], blockComment: nil,
                keywords: ["case", "do", "done", "elif", "else", "esac", "exit", "export", "fi",
                           "for", "function", "if", "in", "local", "return", "then", "while"],
                highlightTypes: false
            )
        case "json":
            return LanguageProfile(
                lineComments: [], blockComment: nil,
                keywords: ["true", "false", "null"],
                highlightTypes: false
            )
        case "rust", "rs":
            return LanguageProfile(
                lineComments: ["//"], blockComment: ("/*", "*/"),
                keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn",
                           "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
                           "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
                           "self", "static", "struct", "super", "trait", "true", "type",
                           "unsafe", "use", "where", "while"],
                highlightTypes: true
            )
        default:
            // Profil générique : conventions C + mots-clés fréquents.
            return LanguageProfile(
                lineComments: ["//", "#"], blockComment: ("/*", "*/"),
                keywords: ["break", "case", "class", "const", "continue", "else", "enum",
                           "false", "for", "func", "function", "if", "import", "let", "new",
                           "nil", "null", "return", "static", "struct", "switch", "true",
                           "var", "void", "while"],
                highlightTypes: true
            )
        }
    }
}
