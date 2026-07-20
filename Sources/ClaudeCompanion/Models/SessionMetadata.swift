import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// SessionMetadata — décorations utilisateur des sessions (nom, couleur, groupe)
//
// Les fichiers de session (.jsonl) appartiennent à Claude Code : on ne les
// modifie PAS. Ces métadonnées vivent donc à part, dans un JSON de l'app, liées
// à la session par son id. Une session sans entrée reste parfaitement valide —
// elle s'affiche avec son titre déduit et sans couleur ni groupe.
// ─────────────────────────────────────────────────────────────────────────────

struct SessionMetadata: Codable, Equatable {
    var name: String?      // renommage manuel ; nil = titre auto (premier message)
    var color: SessionColor?
    var group: String?     // nom de groupe libre ; nil = « Sans groupe »

    var isEmpty: Bool { name == nil && color == nil && group == nil }
}

/// Palette fixe : on stocke un nom de couleur (portable, lisible dans le JSON)
/// plutôt qu'un hex, et l'UI propose exactement ces choix.
enum SessionColor: String, CaseIterable, Codable, Identifiable {
    case red, orange, yellow, green, blue, purple, pink, graphite

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red:      return .red
        case .orange:   return .orange
        case .yellow:   return .yellow
        case .green:    return .green
        case .blue:     return .blue
        case .purple:   return .purple
        case .pink:     return .pink
        case .graphite: return .gray
        }
    }

    var label: String {
        switch self {
        case .red:      return "Rouge"
        case .orange:   return "Orange"
        case .yellow:   return "Jaune"
        case .green:    return "Vert"
        case .blue:     return "Bleu"
        case .purple:   return "Violet"
        case .pink:     return "Rose"
        case .graphite: return "Gris"
        }
    }
}
