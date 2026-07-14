import AppKit
import SwiftUI
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// Gestion de la fenêtre — HUD flottant + ancrage à CodeEdit
//
// SwiftUI ne donne pas d'accès direct au NSWindow d'un WindowGroup : on le
// « capture » via un NSViewRepresentable invisible (WindowConfigurator), puis
// WindowManager le configure en panneau compagnon :
//   • fond transparent (l'effet verre NSVisualEffectView devient LE fond),
//   • barre de titre fondue dans le contenu,
//   • niveau .floating (reste au-dessus de CodeEdit) débrayable,
//   • déplaçable en attrapant n'importe quel point du fond.
//
// L'ancrage à CodeEdit utilise CGWindowListCopyWindowInfo : lire la POSITION
// des fenêtres d'une autre app (kCGWindowBounds + kCGWindowOwnerName) ne
// requiert AUCUNE permission TCC — seule la lecture des TITRES exigerait
// « Enregistrement de l'écran », et on n'en a pas besoin.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class WindowManager: ObservableObject {

    /// Épinglé = la fenêtre flotte au-dessus des apps normales (dont CodeEdit).
    @Published var isPinned = true {
        didSet { applyLevel() }
    }

    private(set) weak var window: NSWindow?

    /// Nom d'app ciblé pour l'ancrage. Modifiable si vous visez un autre IDE :
    /// defaults write <bundle-id> dockTargetApp "Xcode"
    var dockTargetAppName: String {
        UserDefaults.standard.string(forKey: "dockTargetApp") ?? "CodeEdit"
    }

    func adopt(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window

        // Fond transparent : indispensable pour que le blendingMode
        // .behindWindow de NSVisualEffectView laisse voir le bureau derrière.
        window.isOpaque = false
        window.backgroundColor = .clear

        // Barre de titre fantôme : les feux (fermer/réduire) restent, posés
        // directement sur le verre.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)

        // Ergonomie panneau : déplaçable par le fond.
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 380, height: 460)

        applyLevel()
    }

    /// Épinglé : niveau .floating + présent sur TOUS les Spaces, y compris les
    /// Spaces plein écran (.fullScreenAuxiliary) — le trio nécessaire pour que
    /// le panneau reste visible et utilisable au-dessus de CodeEdit même quand
    /// celui-ci est en plein écran. Détaché : fenêtre normale, ancrée à son Space.
    private func applyLevel() {
        guard let window else { return }
        if isPinned {
            window.level = .floating
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        } else {
            window.level = .normal
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }

    // MARK: - Ancrage à CodeEdit

    /// Colle le panneau au bord droit de la fenêtre CodeEdit au premier plan,
    /// en adoptant sa hauteur. Renvoie false si CodeEdit n'est pas visible.
    @discardableResult
    func dockToCodeEdit() -> Bool {
        guard let window,
              let target = Self.frontmostWindowFrame(ownerName: dockTargetAppName),
              let primaryScreen = NSScreen.screens.first else { return false }

        // CGWindowList fournit des coordonnées « globales » origine EN HAUT à
        // gauche ; AppKit compte depuis le BAS à gauche de l'écran principal.
        let appKitY = primaryScreen.frame.height - target.maxY
        let appKitTarget = NSRect(x: target.minX, y: appKitY, width: target.width, height: target.height)

        let gap: CGFloat = 10
        let width = max(window.frame.width, window.minSize.width)
        let screen = NSScreen.screens.first { $0.frame.intersects(appKitTarget) } ?? primaryScreen

        var x = appKitTarget.maxX + gap
        if x + width > screen.visibleFrame.maxX {
            // Pas de place à droite : on recouvre le bord droit de l'IDE.
            x = min(appKitTarget.maxX - width, screen.visibleFrame.maxX - width)
        }

        let frame = NSRect(x: x, y: appKitTarget.minY, width: width, height: appKitTarget.height)
        window.setFrame(frame, display: true, animate: true)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// Cherche la fenêtre « normale » (layer 0) la plus en avant appartenant
    /// à l'app donnée. La liste CGWindowList est ordonnée avant → arrière.
    nonisolated static func frontmostWindowFrame(ownerName: String) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard (info[kCGWindowOwnerName as String] as? String) == ownerName,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width > 300, rect.height > 200 // ignore palettes et popovers
            else { continue }
            return rect
        }
        return nil
    }
}

/// Vue invisible qui remonte le NSWindow hôte dès qu'il est disponible.
struct WindowConfigurator: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Le window n'existe pas encore pendant makeNSView : on diffère d'un tour.
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
    }
}
