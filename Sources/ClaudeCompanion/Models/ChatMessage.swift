import Foundation

/// Un message affiché dans la conversation.
///
/// Un message assistant n'est pas un simple bloc de texte : pendant un tour
/// « agentique », Claude Code alterne texte et appels d'outils (Read, Bash…).
/// On modélise donc le contenu comme une liste ordonnée de `Segment`,
/// fidèle au flux `stream-json` du CLI.
struct ChatMessage: Identifiable, Sendable {
    enum Role: Sendable {
        case user
        case assistant
    }

    /// Un appel d'outil effectué par Claude (affiché comme une « puce »).
    struct ToolCall: Sendable, Equatable {
        enum Status: Sendable, Equatable {
            case running   // l'outil s'exécute
            case done      // tool_result reçu, succès
            case error     // tool_result reçu, is_error == true
        }

        let id: String        // tool_use_id — sert à corréler le résultat
        let name: String      // "Read", "Bash", "Edit"…
        let detail: String?   // aperçu de l'input (chemin, commande…)
        var status: Status
    }

    enum Segment: Sendable, Equatable {
        case text(String)
        case tool(ToolCall)
    }

    let id: String
    let role: Role
    var segments: [Segment]
    /// Métadonnées du tour (coût, durée) — renseignées par l'événement `result`.
    var meta: TurnMeta?
    /// `true` tant que le message est en cours de génération (spinner UI).
    var isStreaming: Bool = false
}

/// Résumé d'un tour renvoyé par l'événement final `result` du CLI.
struct TurnMeta: Sendable, Equatable {
    let costUSD: Double?
    let durationMS: Int?
    let numTurns: Int?
}

/// Modes de permission du CLI en exécution non interactive.
///
/// Point crucial pour un wrapper : en mode `-p` (headless), Claude ne peut PAS
/// demander confirmation dans un terminal. Sans mode explicite, les outils
/// sensibles (écriture de fichiers, Bash) sont refusés silencieusement.
enum PermissionMode: String, CaseIterable, Identifiable, Sendable {
    case standard          // --permission-mode default  → outils sensibles refusés
    case acceptEdits       // --permission-mode acceptEdits → éditions de fichiers auto-acceptées
    case plan              // --permission-mode plan → lecture seule, Claude planifie
    case bypassPermissions // --permission-mode bypassPermissions → tout autoriser ⚠️

    var id: String { rawValue }

    /// Valeur exacte attendue par `--permission-mode`.
    var cliValue: String {
        self == .standard ? "default" : rawValue
    }

    var label: String {
        switch self {
        case .standard:          return "Standard (outils sensibles refusés)"
        case .acceptEdits:       return "Accepter les éditions"
        case .plan:              return "Plan (lecture seule)"
        case .bypassPermissions: return "Tout autoriser ⚠️"
        }
    }
}
