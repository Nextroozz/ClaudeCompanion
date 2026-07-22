import AppKit
import ApplicationServices

// ─────────────────────────────────────────────────────────────────────────────
// AccessibilityBridge — piloter les fenêtres des AUTRES apps
//
// CGWindowList (voir WindowManagement) sait LIRE la position des fenêtres sans
// aucune permission. Mais pour les DÉPLACER ou les REDIMENSIONNER, il n'existe
// qu'une seule voie sur macOS : l'API Accessibilité (AXUIElement), qui exige
// que l'utilisateur coche l'app dans Réglages → Confidentialité → Accessibilité.
//
// Deux conséquences non négociables :
//   • Sans la permission, tout ancrage « qui pousse l'IDE » est impossible :
//     on retombe sur le simple survol. D'où needsAccessibility / requestTrust.
//   • L'App Sandbox interdit purement et simplement l'API Accessibilité. La
//     cible utilise Distribution/ClaudeCompanion.entitlements (non sandboxé) —
//     ne pas y ajouter com.apple.security.app-sandbox sous peine de tout casser.
//
// Repères géométriques : AX et CoreGraphics comptent en Y VERS LE BAS depuis le
// coin haut-gauche de l'écran de référence ; AppKit compte en Y VERS LE HAUT
// depuis son coin bas-gauche. ScreenGeometry fait le pont (conversion
// involutive : la même formule dans les deux sens).
// ─────────────────────────────────────────────────────────────────────────────

enum Accessibility {

    /// L'app est-elle autorisée à piloter les fenêtres des autres apps ?
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Déclenche l'alerte système « ... souhaite contrôler cet ordinateur ».
    /// Le retour est l'état AVANT réponse de l'utilisateur : macOS n'attend pas.
    /// On ne peut donc que re-tester `isTrusted` plus tard (voir DockController).
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Ouvre directement le volet Accessibilité des Réglages Système.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Conversion de repères

enum ScreenGeometry {

    /// L'écran de référence de CoreGraphics/AX est celui dont l'origine AppKit
    /// est (0,0) — pas forcément `NSScreen.main` (qui suit le focus).
    static var referenceFrame: NSRect {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame
            ?? NSScreen.screens.first?.frame
            ?? .zero
    }

    /// AX/CoreGraphics → AppKit. La formule est sa propre inverse.
    static func appKit(from rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: referenceFrame.height - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// AppKit → AX/CoreGraphics. Même formule, d'où le nom symétrique.
    static func ax(from rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: referenceFrame.height - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// L'écran qui contient l'essentiel de `rect` (AppKit), pour maximiser au
    /// bon endroit sur une config multi-écrans.
    static func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            a.frame.intersection(rect).area < b.frame.intersection(rect).area
        }
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// MARK: - Une fenêtre pilotable

/// Poignée sur une fenêtre d'une autre app. Toutes les opérations peuvent
/// échouer (fenêtre fermée, permission retirée, app qui refuse la taille) —
/// d'où les Optional / @discardableResult plutôt que des `try!`.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t

    /// `kAXFullscreenAttribute` n'est pas exposé dans les en-têtes publics,
    /// mais l'attribut existe depuis Lion et tous les IDE le renseignent.
    private static let fullScreenAttribute = "AXFullScreen" as CFString

    /// La fenêtre principale de `app` : on écarte palettes, inspecteurs et
    /// panneaux flottants via le sous-rôle standard + un seuil de taille.
    static func mainWindow(of app: NSRunningApplication) -> AXWindow? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // kAXMainWindow d'abord : c'est celle que l'utilisateur considère comme
        // « la » fenêtre du document. Repli sur la première fenêtre standard.
        if let main = copyElement(appElement, kAXMainWindowAttribute),
           let window = AXWindow(element: main, pid: app.processIdentifier).validated() {
            return window
        }

        guard let list = copyValue(appElement, kAXWindowsAttribute) as? [AXUIElement] else {
            return nil
        }
        return list.lazy
            .map { AXWindow(element: $0, pid: app.processIdentifier) }
            .compactMap { $0.validated() }
            .first
    }

    /// Écarte ce qui n'est pas une vraie fenêtre de document.
    private func validated() -> AXWindow? {
        guard (copyValue(element, kAXSubroleAttribute) as? String) == (kAXStandardWindowSubrole as String),
              let frame = frame, frame.width > 300, frame.height > 200
        else { return nil }
        return self
    }

    /// Frame en coordonnées AppKit (déjà converties).
    var frame: NSRect? {
        guard let posValue = copyValue(element, kAXPositionAttribute),
              let sizeValue = copyValue(element, kAXSizeAttribute),
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return ScreenGeometry.appKit(from: CGRect(origin: origin, size: size))
    }

    /// Applique une frame AppKit et RENVOIE CE QUI A RÉELLEMENT ÉTÉ OBTENU.
    ///
    /// Ce retour est le cœur de l'anti-boucle : une app peut refuser la taille
    /// demandée (taille minimale, incréments). Si l'appelant mémorisait la
    /// valeur DEMANDÉE, l'écart avec le réel serait relu au prochain événement
    /// comme « l'utilisateur a bougé la fenêtre » → re-layout → oscillation.
    /// En mémorisant le réel, la comparaison est stable.
    @discardableResult
    func setFrame(_ rect: NSRect) -> NSRect? {
        var target = ScreenGeometry.ax(from: rect)

        // Ordre taille → position → taille : une fenêtre encore trop large près
        // du bord droit voit sa position écrêtée ; on la rétrécit d'abord, on
        // la place, puis on confirme la taille. Trois appels, zéro tremblement.
        setSize(target.size)
        setPosition(target.origin)
        setSize(target.size)

        // Relecture : la vérité, c'est ce que l'app a accepté.
        guard let actual = frame else { return nil }

        // Si la hauteur a été refusée, le coin haut-gauche AX reste bon mais la
        // conversion AppKit décale le bas : on ne « corrige » rien ici, on
        // remonte le réel tel quel. C'est à la couche layout de s'y adapter.
        target = ScreenGeometry.ax(from: actual)
        return actual
    }

    private func setPosition(_ point: CGPoint) {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)
    }

    private func setSize(_ size: CGSize) {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)
    }

    /// Plein écran NATIF (Space dédié). Aucune fenêtre d'une autre app ne peut
    /// y être tuilée : l'ancrage doit refuser poliment plutôt que d'échouer.
    var isNativeFullScreen: Bool {
        (copyValue(element, Self.fullScreenAttribute as String) as? Bool) ?? false
    }

    /// Tente de SORTIR du plein écran natif (l'attribut est accessible en
    /// écriture sur la plupart des apps) pour pouvoir tuiler la paire.
    @discardableResult
    func exitNativeFullScreen() -> Bool {
        AXUIElementSetAttributeValue(element, Self.fullScreenAttribute,
                                     false as CFBoolean) == .success
    }

    var isMinimized: Bool {
        (copyValue(element, kAXMinimizedAttribute) as? Bool) ?? false
    }

    /// La fenêtre existe-t-elle encore ? (l'app a pu la fermer)
    var isAlive: Bool { frame != nil }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}

// MARK: - Lecture d'attributs (helpers)

private func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return (value as! AXUIElement)
}

// MARK: - Observation des mouvements de l'IDE

/// Écoute les déplacements/redimensionnements d'une fenêtre distante.
///
/// On s'abonne sur l'élément APPLICATION (et non sur la fenêtre) : les
/// notifications de fenêtre remontent au parent, et cet abonnement survit au
/// changement de fenêtre principale (l'utilisateur ouvre un autre projet).
@MainActor
final class AXWindowObserver {

    private var observer: AXObserver?
    private let appElement: AXUIElement
    private let onEvent: (String) -> Void

    /// Les notifications qui nous intéressent. `kAXWindowMoved/Resized` sont
    /// émises EN CONTINU pendant un glisser — d'où un suivi fluide sans polling.
    private static let notifications = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXUIElementDestroyedNotification,
    ]

    init?(pid: pid_t, onEvent: @escaping (String) -> Void) {
        self.appElement = AXUIElementCreateApplication(pid)
        self.onEvent = onEvent

        var observer: AXObserver?
        // Le callback est un pointeur de fonction C : impossible d'y capturer
        // `self`. On passe l'instance en refcon (non retenue — l'observateur ne
        // survit jamais à son propriétaire, voir deinit).
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<AXWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { observer.onEvent(name) }
        }

        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
            return nil
        }
        self.observer = observer

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.notifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(observer),
                           .defaultMode)
    }

    deinit {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                              AXObserverGetRunLoopSource(observer),
                              .defaultMode)
    }
}
