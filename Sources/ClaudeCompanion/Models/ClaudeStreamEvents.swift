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
    /// `{"type":"system","subtype":"init",…}` — début de tour, donne le session_id.
    case initialized(sessionID: String, model: String?)
    /// Début d'un message assistant (via --include-partial-messages).
    case messageStarted(id: String)
    /// Fragment de texte streamé (effet « machine à écrire »).
    case textDelta(String)
    /// Claude invoque un outil (connu dès le content_block_start).
    case toolStarted(id: String, name: String, detail: String?)
    /// Message assistant complet — version faisant autorité, remplace le brouillon.
    case assistantMessage(id: String, segments: [ChatMessage.Segment])
    /// Résultat d'outil reçu (l'exécution est terminée).
    case toolFinished(toolUseID: String, isError: Bool)
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
        let thinking: String?           // thinking_delta
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
            return [.initialized(sessionID: sessionID, model: envelope.model)]

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
                return .toolFinished(toolUseID: toolUseID, isError: block.isError ?? false)
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
                    id: block.id ?? UUID().uuidString,
                    name: block.name ?? "Outil",
                    detail: toolDetail(name: block.name ?? "", input: block.input)
                )]
            case "content_block_delta":
                guard let text = sse.delta?.text, sse.delta?.type == "text_delta" else { return [] }
                return [.textDelta(text)]
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
                case "tool_use":
                    return .tool(ChatMessage.ToolCall(
                        id: block.id ?? UUID().uuidString,
                        name: block.name ?? "Outil",
                        detail: toolDetail(name: block.name ?? "", input: block.input),
                        status: .running
                    ))
                default:
                    return nil // thinking, tool_result, images… non affichés ici
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
}
