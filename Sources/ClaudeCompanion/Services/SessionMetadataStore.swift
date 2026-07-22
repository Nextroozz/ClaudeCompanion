import Foundation
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// SessionMetadataStore — persistance des décorations de sessions
//
// Un simple dictionnaire id → SessionMetadata, sérialisé en JSON dans le dossier
// Application Support de l'app. Chargé au lancement, réécrit à chaque
// modification. Séparé des .jsonl de Claude Code, qui restent intacts.
//
// @MainActor + ObservableObject : l'UI observe et réagit immédiatement à un
// renommage ou un changement de couleur, sans recharger les sessions.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class SessionMetadataStore: ObservableObject {

    @Published private var byID: [String: SessionMetadata] = [:]

    private let fileURL: URL

    /// `directory` injectable pour les tests ; en production, Application Support.
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("session-metadata.json")
        load()
    }

    // MARK: - Lecture

    func metadata(for id: String) -> SessionMetadata {
        byID[id] ?? SessionMetadata()
    }

    /// Groupes existants, triés — « Sans groupe » n'en est pas un et n'apparaît
    /// pas ici (l'UI le rend à part).
    var groups: [String] {
        Set(byID.values.compactMap(\.group)).sorted()
    }

    // MARK: - Écriture

    func setName(_ name: String?, for id: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.name = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    func setColor(_ color: SessionColor?, for id: String) {
        update(id) { $0.color = color }
    }

    func setGroup(_ group: String?, for id: String) {
        let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.group = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    /// Oublie les décorations d'une session (à sa suppression, par ex.).
    func forget(_ id: String) {
        guard byID[id] != nil else { return }
        byID[id] = nil
        save()
    }

    private func update(_ id: String, _ mutate: (inout SessionMetadata) -> Void) {
        var meta = byID[id] ?? SessionMetadata()
        mutate(&meta)
        // Une entrée redevenue vide est retirée : le JSON ne garde que l'utile.
        if meta.isEmpty { byID[id] = nil } else { byID[id] = meta }
        save()
    }

    // MARK: - Persistance

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: SessionMetadata].self, from: data)
        else { return }
        byID = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(byID) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
