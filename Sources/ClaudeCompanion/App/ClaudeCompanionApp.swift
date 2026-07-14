import AppKit
import SwiftUI

// ═════════════════════════════════════════════════════════════════════════════
// ClaudeCompanion — point d'entrée
//
// ┌─────────────────────── CONFIGURATION APP SANDBOX ───────────────────────┐
// │                                                                          │
// │ RECOMMANDATION : App Sandbox DÉSACTIVÉ (distribution hors App Store).    │
// │                                                                          │
// │ Pourquoi : cette app lance un binaire tiers (`claude`) via Process. Sous │
// │ sandbox, le processus enfant HÉRITE du sandbox du parent : le CLI ne    │
// │ pourrait plus écrire ~/.claude (sessions, credentials), ni lire vos     │
// │ projets, ni souvent trouver `node`. Un wrapper de CLI développeur n'est  │
// │ tout simplement pas compatible avec le modèle App Store.                 │
// │                                                                          │
// │ Dans Xcode : cible → Signing & Capabilities →                            │
// │   • supprimer la capability « App Sandbox » ;                            │
// │   • garder « Hardened Runtime » (requis pour la notarisation) — aucune   │
// │     entitlement supplémentaire n'est nécessaire pour lancer un Process.  │
// │                                                                          │
// │ Accès disque hors sandbox : macOS (TCC) demandera quand même une         │
// │ confirmation la première fois que l'app (ou le CLI enfant) touche        │
// │ Bureau / Documents / Téléchargements. Ajoutez dans Info.plist des        │
// │ textes d'usage propres : NSDesktopFolderUsageDescription,                │
// │ NSDocumentsFolderUsageDescription, NSDownloadsFolderUsageDescription     │
// │ (voir Distribution/Info.sample.plist).                                   │
// │                                                                          │
// │ Si vous tenez au sandbox (au prix d'un CLI enfant dégradé) :             │
// │   • com.apple.security.app-sandbox = YES                                 │
// │   • com.apple.security.files.user-selected.read-write = YES              │
// │     → l'URL rendue par fileImporter/NSOpenPanel est accessible ;         │
// │       persistez-la entre lancements via un security-scoped bookmark      │
// │       (bookmarkData(options: .withSecurityScope) puis                    │
// │        startAccessingSecurityScopedResource()).                          │
// │   • com.apple.security.network.client = YES (le CLI parle à l'API)       │
// │   • exception temporaire pour ~/.claude :                                │
// │     com.apple.security.temporary-exception.files.home-relative-path.     │
// │     read-write = [ "/.claude/" ] — refusée sur l'App Store.              │
// │   Fichier prêt : Distribution/ClaudeCompanion-Sandboxed.entitlements.    │
// └──────────────────────────────────────────────────────────────────────────┘
// ═════════════════════════════════════════════════════════════════════════════

@main
struct ClaudeCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var windowManager = WindowManager()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(viewModel)
                .environmentObject(windowManager)
                // Le verre est le fond : on force un schéma sombre cohérent
                // avec le material .hudWindow. Supprimez cette ligne pour
                // suivre l'apparence système.
                .preferredColorScheme(.dark)
        }
        // Barre de titre invisible : le contenu (et le verre) occupe TOUTE la
        // fenêtre, les feux flottent par-dessus — look « panneau HUD ».
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 440, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Nouvelle session") {
                    NotificationCenter.default.post(name: .newSessionRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Ancrer à l'IDE") {
                    NotificationCenter.default.post(name: .dockToIDERequested, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Indispensable en `swift run` (exécutable sans bundle .app) : sans
        // cela, pas d'icône Dock ni de focus clavier. Sans effet néfaste
        // une fois l'app empaquetée par Xcode.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true // panneau compagnon : fermer la fenêtre quitte l'app
    }
}
