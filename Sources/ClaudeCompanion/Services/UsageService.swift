import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// UsageService — estimation locale de la consommation Claude Code
//
// Il n'existe pas d'API publique/locale exposant les limites exactes du plan
// (l'écran /usage du CLI interroge un endpoint OAuth privé). En revanche,
// chaque réponse assistant est journalisée dans ~/.claude/projects/**.jsonl
// avec son `usage` complet (tokens entrée/sortie/cache) et son modèle.
// On agrège donc ces données localement — même approche que l'outil ccusage :
//
//   • déduplication par requestId (les fichiers de sessions « forkées » par
//     --resume dupliquent l'historique ; un même appel API ne compte qu'une fois),
//   • la dernière ligne d'un même message gagne (usage cumulatif final),
//   • coût estimé via la grille tarifaire API publique ci-dessous.
//
// Résultat : aujourd'hui / 5 dernières heures / 7 derniers jours, par modèle.
// C'est une ESTIMATION (l'usage d'un abonnement Pro/Max n'est pas facturé au
// token) — utile pour se situer, affiché comme telle dans l'UI.
// ─────────────────────────────────────────────────────────────────────────────

/// Tarifs par million de tokens (USD) — grille API publique.
struct ModelPricing {
    let input: Double
    let output: Double
    let cacheRead: Double     // ≈ 0,1 × entrée
    let cacheWrite5m: Double  // 1,25 × entrée (TTL 5 min)
    let cacheWrite1h: Double  // 2 × entrée (TTL 1 h)

    init(input: Double, output: Double) {
        self.input = input
        self.output = output
        self.cacheRead = input * 0.1
        self.cacheWrite5m = input * 1.25
        self.cacheWrite1h = input * 2.0
    }
}

enum UsageScope: String, CaseIterable, Identifiable {
    case currentProject, allProjects
    var id: String { rawValue }
    var label: String {
        self == .currentProject ? "Ce projet" : "Tous les projets"
    }
}

/// Un appel API dédupliqué, prêt à être agrégé.
struct UsageEvent {
    let id: String
    let date: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWrite5mTokens: Int
    let cacheWrite1hTokens: Int
    let costUSD: Double
}

struct UsageTotals {
    var costUSD = 0.0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var requests = 0

    var isEmpty: Bool { requests == 0 }

    mutating func add(_ event: UsageEvent) {
        costUSD += event.costUSD
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheReadTokens += event.cacheReadTokens
        cacheWriteTokens += event.cacheWrite5mTokens + event.cacheWrite1hTokens
        requests += 1
    }
}

struct ModelCost: Identifiable {
    let model: String
    let costUSD: Double
    var id: String { model }
}

struct UsageSnapshot {
    let today: UsageTotals
    let lastFiveHours: UsageTotals
    let lastSevenDays: UsageTotals
    let todayByModel: [ModelCost]
}

enum UsageService {

    // MARK: - Grille tarifaire

    /// Correspondance nom de modèle → tarifs. Basée sur la grille publique
    /// (2026) ; le repli par défaut utilise le tarif Opus, volontairement
    /// prudent pour les modèles inconnus/futurs.
    static func pricing(for model: String) -> ModelPricing {
        let name = model.lowercased()
        if name.contains("fable") || name.contains("mythos") {
            return ModelPricing(input: 10, output: 50)
        }
        if name.contains("opus") {
            return ModelPricing(input: 5, output: 25)
        }
        if name.contains("haiku") {
            if name.contains("3-5") { return ModelPricing(input: 0.8, output: 4) }
            if name.contains("-3-") { return ModelPricing(input: 0.25, output: 1.25) }
            return ModelPricing(input: 1, output: 5)
        }
        if name.contains("sonnet") {
            return ModelPricing(input: 3, output: 15)
        }
        return ModelPricing(input: 5, output: 25)
    }

    // MARK: - Calcul du snapshot

    /// ⚠️ Parcourt le disque : à appeler hors du MainActor.
    static func computeSnapshot(scope: UsageScope, projectDirectory: URL, now: Date = Date()) -> UsageSnapshot {
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let files = jsonlFiles(scope: scope, projectDirectory: projectDirectory, modifiedAfter: sevenDaysAgo)

        // Déduplication GLOBALE (entre fichiers) : un resume forke la session
        // en recopiant l'historique — sans cela, tout serait compté en double.
        var events: [String: UsageEvent] = [:]
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                // Pré-filtre rapide avant tout décodage JSON.
                guard line.contains("\"usage\""), line.contains("assistant") else { continue }
                if let event = parseEvent(line: String(line)) {
                    events[event.id] = event // la dernière occurrence gagne
                }
            }
        }
        return snapshot(from: Array(events.values), now: now)
    }

    static func snapshot(from events: [UsageEvent], now: Date) -> UsageSnapshot {
        let startOfDay = Calendar.current.startOfDay(for: now)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 3600)

        var today = UsageTotals()
        var fiveHours = UsageTotals()
        var sevenDays = UsageTotals()
        var byModel: [String: Double] = [:]

        for event in events where event.date <= now {
            if event.date >= sevenDaysAgo { sevenDays.add(event) }
            if event.date >= fiveHoursAgo { fiveHours.add(event) }
            if event.date >= startOfDay {
                today.add(event)
                byModel[event.model, default: 0] += event.costUSD
            }
        }

        let ranking = byModel
            .map { ModelCost(model: $0.key, costUSD: $0.value) }
            .sorted { $0.costUSD > $1.costUSD }
        return UsageSnapshot(today: today,
                             lastFiveHours: fiveHours,
                             lastSevenDays: sevenDays,
                             todayByModel: Array(ranking.prefix(5)))
    }

    // MARK: - Parsing d'une ligne JSONL

    private struct UsageLine: Decodable {
        let type: String?
        let requestId: String?
        let timestamp: String?
        let message: Msg?

        struct Msg: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreationInputTokens: Int?
            /// Objet {"ephemeral_5m_input_tokens": …, "ephemeral_1h_input_tokens": …}.
            /// Décodé en JSONValue : la stratégie convertFromSnakeCase mutile
            /// les clés contenant des chiffres — on balaye donc les clés
            /// nous-mêmes, insensible aux variations de casse.
            let cacheCreation: JSONValue?
        }
    }

    static func parseEvent(line: String) -> UsageEvent? {
        guard let data = line.data(using: .utf8),
              let decoded = try? ClaudeEventDecoder.jsonDecoder.decode(UsageLine.self, from: data),
              decoded.type == "assistant",
              let message = decoded.message,
              let usage = message.usage,
              let date = parseDate(decoded.timestamp)
        else { return nil }

        let model = message.model ?? "inconnu"
        // "<synthetic>" = messages générés localement (erreurs…) : pas un appel API.
        guard !model.hasPrefix("<") else { return nil }

        let input = usage.inputTokens ?? 0
        let output = usage.outputTokens ?? 0
        let cacheRead = usage.cacheReadInputTokens ?? 0
        // Ventilation 5 min / 1 h si disponible ; sinon tout au tarif 5 min
        // (1,25×) — l'hypothèse la plus courante.
        var write5m = 0
        var write1h = 0
        if case .object(let breakdown)? = usage.cacheCreation {
            for (key, value) in breakdown {
                guard case .number(let amount) = value else { continue }
                let normalized = key.lowercased()
                if normalized.contains("5m") { write5m += Int(amount) }
                else if normalized.contains("1h") { write1h += Int(amount) }
            }
        }
        if write5m == 0 && write1h == 0 {
            write5m = usage.cacheCreationInputTokens ?? 0
        }

        let price = pricing(for: model)
        let cost = (Double(input) * price.input
                    + Double(output) * price.output
                    + Double(cacheRead) * price.cacheRead
                    + Double(write5m) * price.cacheWrite5m
                    + Double(write1h) * price.cacheWrite1h) / 1_000_000

        return UsageEvent(
            id: decoded.requestId ?? message.id ?? UUID().uuidString,
            date: date,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWrite5mTokens: write5m,
            cacheWrite1hTokens: write1h,
            costUSD: cost
        )
    }

    // MARK: - Helpers

    private static func jsonlFiles(scope: UsageScope, projectDirectory: URL, modifiedAfter cutoff: Date) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]

        var candidates: [URL] = []
        switch scope {
        case .currentProject:
            let dir = SessionHistoryService.sessionsDirectory(for: projectDirectory)
            candidates = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        case .allProjects:
            if let enumerator = fm.enumerator(at: SessionHistoryService.projectsRoot,
                                              includingPropertiesForKeys: keys,
                                              options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    candidates.append(url)
                }
            }
        }

        // Le mtime d'un fichier de session = date du dernier message ajouté :
        // un fichier plus vieux que la fenêtre ne peut contenir aucun message récent.
        return candidates.filter { url in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return false }
            return modified >= cutoff
        }
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoWithFraction.date(from: string) ?? isoPlain.date(from: string)
    }
}

/// Nom court d'un modèle pour l'affichage : "claude-sonnet-5-20250929" → "sonnet-5".
enum ModelNames {
    static func short(_ raw: String) -> String {
        let trimmed = raw.hasPrefix("claude-") ? String(raw.dropFirst("claude-".count)) : raw
        let parts = trimmed.split(separator: "-").filter { $0.count != 8 || Int($0) == nil }
        return parts.joined(separator: "-")
    }
}
