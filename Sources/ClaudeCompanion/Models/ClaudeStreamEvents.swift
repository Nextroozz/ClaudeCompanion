import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Décodage du flux `claude -p --output-format stream-json`
//
// Le CLI émet une ligne JSON par événement (JSONL). Les mêmes structures
// servent aussi à lire les fichiers d'historique ~/.claude/projects/*.jsonl,
// dont le schéma des messages est identique (enveloppe légèrement différente).
//
// Stratégie : des DTO « tolérants » (tout optionnel, clés inconnues ignorées)
// puis une projection vers un petit enum métier `ClaudeEvent` consommé par le
// ViewModel. Si Anthropic ajoute des champs, rien ne casse.
// ─────────────────────────────────────────────────────────────────────────────

/// Événement de haut niveau consommé par le ViewModel.
enum ClaudeEvent: Sendable, Equatable {
    /// `{"type":"system","subtype":"init",…}` — début de tour : session_id,
    /// modèle et liste des commandes slash disponibles (plugins compris).
    case initialized(sessionID: String, model: String?, slashCommands: [String])
    /// Début d'un message assistant (via --include-partial-messages).
    case messageStarted(id: String)
    /// Fragment de texte streamé (effet « machine à écrire »).
    case textDelta(String)
    /// Fragment de réflexion streamé (bloc thinking).
    ///
    /// ATTENTION : les modèles actuels (Sonnet 5, Opus 4.8, Fable 5) ne
    /// transmettent PAS le texte de leur réflexion — le champ `thinking` du
    /// flux est vide, le contenu réel étant chiffré dans `signature`. Cet
    /// événement n'est donc émis que par les modèles qui exposent leur
    /// réflexion en clair (Sonnet 4.6 et antérieurs). Voir thinkingProgress.
    case thinkingDelta(String)
    /// Progression de la réflexion, en tokens estimés depuis le dernier delta
    /// (INCRÉMENTAL, pas cumulé). Seul signal disponible quand le texte de la
    /// réflexion est chiffré : la somme approche le compte réel à ~10 % près
    /// (mesuré : 900 estimés pour 954 réels, 300 pour 338).
    case thinkingProgress(estimatedTokens: Int)
    /// Claude invoque un outil (connu dès le content_block_start).
    /// `index` = position du bloc dans le message — corrèle les deltas d'input.
    case toolStarted(index: Int, id: String, name: String, detail: String?)
    /// Fragment de l'input JSON d'un outil en cours de constitution — permet
    /// d'afficher EN DIRECT ce que Claude écrit (commande Bash, contenu Write…).
    case toolInputDelta(index: Int, partialJSON: String)
    /// Fin d'un bloc de contenu (l'input d'outil est alors complet).
    case blockFinished(index: Int)
    /// Fin du message assistant en cours (message_stop).
    case messageStopped
    /// Ligne « assistant » du flux : émise UNE FOIS PAR BLOC terminé (même id
    /// de message répété) — sert de version faisant autorité pour ce bloc.
    case assistantMessage(id: String, segments: [ChatMessage.Segment])
    /// Résultat d'outil reçu (l'exécution est terminée), avec sa sortie texte.
    case toolFinished(toolUseID: String, isError: Bool, output: String?)
    /// `{"type":"result",…}` — fin du tour : coût, durée, session_id (peut changer !).
    case completed(sessionID: String?, meta: TurnMeta, isError: Bool, errorText: String?)
}

// MARK: - DTO tolérants

/// Enveloppe d'une ligne du flux stream-json OU d'une ligne d'historique JSONL.
struct StreamEnvelope: Decodable {
    let type: String
    let subtype: String?
    let sessionId: String?          // stream-json: "session_id" / JSONL: "sessionId" — les deux aboutissent ici
    let message: APIMessageDTO?
    let event: RawSSEEventDTO?      // présent pour type == "stream_event"
    let result: String?
    let totalCostUsd: Double?
    let durationMs: Int?
    let numTurns: Int?
    let isError: Bool?
    let model: String?
    let cwd: String?
    let summary: String?            // lignes {"type":"summary"} des JSONL
    let isMeta: Bool?               // lignes techniques de l'historique
    let isSidechain: Bool?          // trafic des sous-agents
    let timestamp: String?
    let uuid: String?
    let slashCommands: [String]?    // init : commandes « / » disponibles
}

/// Un message au format API Anthropic (imbriqué dans l'enveloppe).
struct APIMessageDTO: Decodable {
    let id: String?
    let role: String?
    let model: String?
    let content: MessageContentDTO?
}

/// `content` peut être une simple chaîne (message utilisateur tapé)
/// ou un tableau de blocs (texte, tool_use, tool_result…).
enum MessageContentDTO: Decodable {
    case text(String)
    case blocks([ContentBlockDTO])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else {
            self = .blocks(try container.decode([ContentBlockDTO].self))
        }
    }
}

struct ContentBlockDTO: Decodable {
    let type: String
    let text: String?          // type == "text"
    let thinking: String?      // type == "thinking" (ignoré à l'affichage)
    let id: String?            // type == "tool_use"
    let name: String?          // type == "tool_use"
    let input: JSONValue?      // type == "tool_use" — schéma libre selon l'outil
    let toolUseId: String?     // type == "tool_result"
    let isError: Bool?         // type == "tool_result"
    let content: JSONValue?    // type == "tool_result" — chaîne OU tableau de blocs
}

/// Événement SSE brut ré-encapsulé (`--include-partial-messages`).
struct RawSSEEventDTO: Decodable {
    let type: String                    // message_start, content_block_start, content_block_delta…
    let index: Int?
    let message: APIMessageDTO?         // message_start
    let contentBlock: ContentBlockDTO?  // content_block_start
    let delta: DeltaDTO?                // content_block_delta

    struct DeltaDTO: Decodable {
        let type: String?
        let text: String?               // text_delta
        let thinking: String?           // thinking_delta — vide si chiffré
        let estimatedTokens: Int?       // thinking_delta : tokens de ce fragment
        let partialJson: String?        // input_json_delta (inputs d'outils)
    }
}

/// Valeur JSON générique — sert à lire les `input` d'outils sans schéma fixe.
enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Valeur JSON non reconnue")
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    /// Rendu JSON indenté et déterministe (clés triées) — pour l'inspecteur
    /// d'appels d'outils dans l'UI.
    var prettyPrinted: String { render(indent: 0) }

    private func render(indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            return value.rounded() == value && abs(value) < 1e15
                ? String(Int(value)) : String(value)
        case .string(let value): return "\"\(value)\""
        case .array(let items):
            if items.isEmpty { return "[]" }
            let body = items.map { inner + $0.render(indent: indent + 1) }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        case .object(let dict):
            if dict.isEmpty { return "{}" }
            let body = dict.keys.sorted()
                .map { "\(inner)\"\($0)\": \(dict[$0]!.render(indent: indent + 1))" }
                .joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        }
    }
}

// MARK: - Décodeur

enum ClaudeEventDecoder {

    /// Décodeur partagé. `convertFromSnakeCase` couvre à la fois le flux
    /// stream-json (snake_case) et les JSONL d'historique (camelCase inchangé).
    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Transforme une ligne JSONL en zéro, un ou plusieurs événements métier.
    /// Une ligne inconnue ou malformée est ignorée silencieusement (robustesse).
    static func decode(line: String) -> [ClaudeEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let envelope = try? jsonDecoder.decode(StreamEnvelope.self, from: data) else {
            return []
        }
        return events(from: envelope)
    }

    static func events(from envelope: StreamEnvelope) -> [ClaudeEvent] {
        switch envelope.type {

        case "system":
            guard envelope.subtype == "init", let sessionID = envelope.sessionId else { return [] }
            return [.initialized(sessionID: sessionID,
                                 model: envelope.model,
                                 slashCommands: envelope.slashCommands ?? [])]

        case "assistant":
            guard let message = envelope.message else { return [] }
            let segments = mapSegments(message.content)
            guard !segments.isEmpty else { return [] }
            return [.assistantMessage(id: message.id ?? UUID().uuidString, segments: segments)]

        case "user":
            // En cours de stream, les lignes "user" transportent les tool_result.
            guard let message = envelope.message, case .blocks(let blocks)? = message.content else { return [] }
            return blocks.compactMap { block in
                guard block.type == "tool_result", let toolUseID = block.toolUseId else { return nil }
                return .toolFinished(toolUseID: toolUseID,
                                     isError: block.isError ?? false,
                                     output: toolResultText(block.content))
            }

        case "stream_event":
            guard let sse = envelope.event else { return [] }
            switch sse.type {
            case "message_start":
                guard let id = sse.message?.id else { return [] }
                return [.messageStarted(id: id)]
            case "content_block_start":
                guard let block = sse.contentBlock, block.type == "tool_use" else { return [] }
                return [.toolStarted(
                    index: sse.index ?? 0,
                    id: block.id ?? UUID().uuidString,
                    name: block.name ?? "Outil",
                    detail: toolDetail(name: block.name ?? "", input: block.input)
                )]
            case "content_block_delta":
                switch sse.delta?.type {
                case "text_delta":
                    guard let text = sse.delta?.text else { return [] }
                    return [.textDelta(text)]
                case "thinking_delta":
                    // Deux signaux indépendants dans le MÊME delta : le texte
                    // (absent si le modèle chiffre sa réflexion) et le nombre
                    // de tokens (toujours là). On émet ce qu'on a.
                    var events: [ClaudeEvent] = []
                    if let thinking = sse.delta?.thinking, !thinking.isEmpty {
                        events.append(.thinkingDelta(thinking))
                    }
                    if let tokens = sse.delta?.estimatedTokens, tokens > 0 {
                        events.append(.thinkingProgress(estimatedTokens: tokens))
                    }
                    return events
                case "input_json_delta":
                    guard let partial = sse.delta?.partialJson, !partial.isEmpty else { return [] }
                    return [.toolInputDelta(index: sse.index ?? 0, partialJSON: partial)]
                default:
                    return []
                }
            case "content_block_stop":
                return [.blockFinished(index: sse.index ?? 0)]
            case "message_stop":
                return [.messageStopped]
            default:
                return []
            }

        case "result":
            let isError = envelope.isError ?? (envelope.subtype != "success")
            let meta = TurnMeta(costUSD: envelope.totalCostUsd,
                                durationMS: envelope.durationMs,
                                numTurns: envelope.numTurns)
            let errorText: String? = isError
                ? (envelope.result ?? "Le CLI a signalé une erreur (\(envelope.subtype ?? "inconnue"))")
                : nil
            return [.completed(sessionID: envelope.sessionId, meta: meta, isError: isError, errorText: errorText)]

        default:
            return []
        }
    }

    /// Projette les blocs de contenu API vers nos segments d'affichage.
    static func mapSegments(_ content: MessageContentDTO?) -> [ChatMessage.Segment] {
        switch content {
        case .text(let string):
            return string.isEmpty ? [] : [.text(string)]
        case .blocks(let blocks):
            return blocks.compactMap { block in
                switch block.type {
                case "text":
                    guard let text = block.text, !text.isEmpty else { return nil }
                    return .text(text)
                case "thinking":
                    guard let thinking = block.thinking,
                          !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return .thinking(thinking)
                case "tool_use":
                    let name = block.name ?? "Outil"
                    let display = toolInputDisplay(name: name, input: block.input)
                    return .tool(ChatMessage.ToolCall(
                        id: block.id ?? UUID().uuidString,
                        name: name,
                        detail: toolDetail(name: name, input: block.input),
                        inputDisplay: display?.text,
                        inputLanguage: display?.language,
                        status: .running
                    ))
                default:
                    return nil // tool_result, images… non affichés ici
                }
            }
        case nil:
            return []
        }
    }

    /// Petit résumé lisible de l'input d'un outil ("/src/App.swift", "npm test"…).
    static func toolDetail(name: String, input: JSONValue?) -> String? {
        guard let input else { return nil }
        let preferredKeys: [String: [String]] = [
            "Read": ["file_path"], "Write": ["file_path"], "Edit": ["file_path"],
            "NotebookEdit": ["notebook_path"],
            "Bash": ["command"],
            "Grep": ["pattern"], "Glob": ["pattern"],
            "WebFetch": ["url"], "WebSearch": ["query"],
            "Task": ["description"], "Agent": ["description"],
        ]
        for key in preferredKeys[name] ?? [] {
            if let value = input[key]?.stringValue { return truncated(value) }
        }
        // Repli : première valeur chaîne de l'objet (clés triées pour être déterministe).
        if case .object(let dict) = input {
            for key in dict.keys.sorted() {
                if let value = dict[key]?.stringValue, !value.isEmpty { return truncated(value) }
            }
        }
        return nil
    }

    private static func truncated(_ string: String, limit: Int = 80) -> String {
        let oneLine = string.replacingOccurrences(of: "\n", with: " ⏎ ")
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }

    /// Entrée complète d'un outil pour l'inspecteur : une commande Bash est
    /// montrée telle quelle (colorée en shell), le code écrit par Write/Edit
    /// tel quel (coloré selon l'extension du fichier), tout le reste en JSON.
    static func toolInputDisplay(name: String, input: JSONValue?) -> (text: String, language: String)? {
        guard let input else { return nil }
        if case .object(let dict) = input, dict.isEmpty { return nil }
        switch name {
        case "Bash":
            if let command = input["command"]?.stringValue { return (command, "sh") }
        case "Write":
            if let content = input["content"]?.stringValue, !content.isEmpty {
                return (content, languageForPath(input["file_path"]?.stringValue))
            }
        case "Edit":
            if let newString = input["new_string"]?.stringValue, !newString.isEmpty {
                return (newString, languageForPath(input["file_path"]?.stringValue))
            }
        default:
            break
        }
        return (input.prettyPrinted, "json")
    }

    /// Langage de coloration déduit de l'extension du fichier écrit.
    static func languageForPath(_ path: String?) -> String {
        switch (path as NSString?)?.pathExtension.lowercased() ?? "" {
        case "swift":                       return "swift"
        case "js", "jsx", "mjs", "cjs":     return "js"
        case "ts", "tsx":                   return "ts"
        case "py":                          return "python"
        case "sh", "bash", "zsh":           return "sh"
        case "json":                        return "json"
        case "rs":                          return "rust"
        default:                            return "" // profil générique
        }
    }

    /// Texte d'un tool_result : `content` est soit une chaîne, soit un tableau
    /// de blocs {type:"text",…}. Tronqué pour ne pas gonfler la mémoire de l'UI.
    static func toolResultText(_ value: JSONValue?, limit: Int = 8000) -> String? {
        let text: String?
        switch value {
        case .string(let string):
            text = string
        case .array(let items):
            let parts = items.compactMap { item -> String? in
                if case .object(let dict) = item, case .string(let t)? = dict["text"] { return t }
                return nil
            }
            text = parts.isEmpty ? nil : parts.joined(separator: "\n")
        default:
            text = nil
        }
        guard let text, !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "\n… (tronqué)" : text
    }
}

// MARK: - JSON partiel (streaming des inputs d'outils)

/// Répare un fragment de JSON en cours de streaming (`input_json_delta`) pour
/// pouvoir l'afficher EN DIRECT : ferme les chaînes et crochets ouverts, retire
/// les séparateurs pendants, puis tente un décodage.
///
/// Best-effort assumé : si un fragment ne se répare pas (littéral coupé en
/// plein milieu, nombre incomplet…), on renvoie nil et l'UI garde simplement
/// le dernier état affichable — le delta suivant corrigera.
enum PartialJSON {

    static func parse(_ partial: String) -> JSONValue? {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        if let value = decode(trimmed) { return value } // déjà complet
        return decode(repaired(trimmed))
    }

    /// Complète un JSON tronqué : troncature avant un échappement incomplet,
    /// fermeture de la chaîne ouverte, retrait d'un `,` ou `"clé":` pendant,
    /// fermeture des `}` / `]` manquants.
    static func repaired(_ partial: String) -> String {
        let chars = Array(partial)
        var closers: [Character] = []   // pile des fermetures attendues
        var inString = false
        var safeEnd = chars.count       // point de coupe si échappement incomplet
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if inString {
                if ch == "\\" {
                    // Échappement : `\uXXXX` (6 caractères) ou `\x` (2).
                    let length = (i + 1 < chars.count && chars[i + 1] == "u") ? 6 : 2
                    if i + length > chars.count { safeEnd = i; break }
                    i += length
                    continue
                }
                if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{":  closers.append("}")
                case "[":  closers.append("]")
                case "}", "]":
                    if closers.last == ch { closers.removeLast() }
                default: break
                }
            }
            i += 1
        }

        var result = Array(chars[..<safeEnd])
        if inString {
            result.append("\"")
        } else {
            trimDanglingSeparator(&result)
        }
        result.append(contentsOf: closers.reversed())
        return String(result)
    }

    /// Retire une fin d'objet invalide : `…,` ou `…"clé":` (avec espaces).
    private static func trimDanglingSeparator(_ chars: inout [Character]) {
        func trimWhitespace() {
            while let last = chars.last, last.isWhitespace { chars.removeLast() }
        }
        trimWhitespace()
        if chars.last == "," {
            chars.removeLast()
            return
        }
        guard chars.last == ":" else { return }
        chars.removeLast()
        trimWhitespace()
        guard chars.last == "\"" else { return }
        chars.removeLast()
        // Remonte au guillemet ouvrant de la clé (une clé JSON contient
        // rarement des guillemets échappés ; si c'est le cas, le décodage
        // échouera et l'UI attendra le delta suivant).
        while let last = chars.last, last != "\"" { chars.removeLast() }
        if chars.last == "\"" { chars.removeLast() }
        trimWhitespace()
        if chars.last == "," { chars.removeLast() }
    }

    private static func decode(_ json: String) -> JSONValue? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? ClaudeEventDecoder.jsonDecoder.decode(JSONValue.self, from: data)
    }
}
