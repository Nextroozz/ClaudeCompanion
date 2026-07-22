import AppKit
import SwiftUI
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// Gestion de la fenêtre — HUD flottant + ancrage tuilé à n'importe quel IDE
//
// SwiftUI ne donne pas d'accès direct au NSWindow d'un WindowGroup : on le
// « capture » via un NSViewRepresentable invisible (WindowConfigurator), puis
// WindowManager le configure en panneau compagnon (verre, barre de titre
// fondue, niveau flottant débrayable).
//
// ── L'ANCRAGE ────────────────────────────────────────────────────────────────
// Deux modes, selon la permission Accessibilité (voir AccessibilityBridge) :
//
//   • AUTORISÉ (mode tuilé) : l'IDE RÉTRÉCIT pour libérer une bande, le
//     compagnon s'y colle, et les deux restent collés — bouger ou
//     redimensionner l'un déplace l'autre. L'invariant tient en une ligne :
//     « le compagnon est flush contre le bord `side` de l'IDE ». Tout le reste
//     (dock, maximise, suivi) n'est qu'une façon de recalculer cet invariant.
//
//   • REFUSÉ (mode survol) : on ne peut que LIRE la position de l'IDE
//     (CGWindowList, sans permission) et se poser à côté. C'est l'ancien
//     comportement, conservé en repli.
//
// ── ANTI-BOUCLE ──────────────────────────────────────────────────────────────
// On bouge l'IDE → l'IDE émet AXWindowMoved → on croirait que l'utilisateur l'a
// bougé → on re-bouge le compagnon → … Le garde-fou n'est PAS un booléen (les
// notifications AX arrivent de façon asynchrone, bien après la fin de l'appel) :
// on mémorise la frame RÉELLEMENT obtenue (relue après écriture) et on ignore
// tout événement qui la décrit. Voir AXWindow.setFrame.
//
// ── CE QUI EST STRUCTURELLEMENT IMPOSSIBLE ───────────────────────────────────
// Le plein écran NATIF (bouton vert) crée un Space dédié à une seule app :
// aucune fenêtre tierce ne peut y être tuilée — Apple n'expose aucune API de
// Split View. `maximizePair()` remplit donc l'écran utile dans le Space normal
// (barre de menu visible). C'est le maximum atteignable sans désactiver le SIP.
// ─────────────────────────────────────────────────────────────────────────────

enum DockSide: String, CaseIterable {
    case right, left

    var label: String { self == .right ? "À droite de l'IDE" : "À gauche de l'IDE" }
}

@MainActor
final class WindowManager: ObservableObject {

    /// Épinglé = la fenêtre flotte au-dessus des apps normales.
    @Published var isPinned = true {
        didSet { applyLevel() }
    }

    /// L'app à laquelle on est actuellement collé (nil = libre).
    @Published private(set) var dockedApp: NSRunningApplication?

    /// Vrai quand l'ancrage tuilé a été demandé mais que la permission manque.
    @Published var needsAccessibility = false

    /// Dernier échec d'ancrage, à afficher à l'utilisateur.
    @Published var dockError: String?

    var isDocked: Bool { dockedApp != nil }

    private(set) weak var window: NSWindow?

    /// Largeur de la bande réservée au compagnon dans la paire tuilée.
    private var companionWidth: CGFloat {
        get { max(UserDefaults.standard.double(forKey: Keys.companionWidth), 380) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.companionWidth) }
    }

    var dockSide: DockSide {
        get { DockSide(rawValue: UserDefaults.standard.string(forKey: Keys.dockSide) ?? "") ?? .right }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.dockSide)
            objectWillChange.send()
            if isDocked { relayoutFromIDE() }
        }
    }

    /// Nom d'app ciblé par défaut pour l'ancrage rapide (⌘⇧D).
    var dockTargetAppName: String {
        UserDefaults.standard.string(forKey: Keys.dockTargetApp) ?? "CodeEdit"
    }

    private enum Keys {
        static let dockTargetApp = "dockTargetApp"
        static let dockSide = "dockSide"
        static let companionWidth = "companionWidth"
    }

    // MARK: - État de synchronisation

    private var axWindow: AXWindow?
    private var observer: AXWindowObserver?

    /// Frames réellement obtenues au dernier layout appliqué par NOUS.
    /// Un événement qui les décrit est notre propre écho → à ignorer.
    private var settledIDEFrame: NSRect?
    private var settledCompanionFrame: NSRect?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []

    // MARK: - Cycle de vie de la fenêtre

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
        observeOwnWindow(window)
        observeWorkspace()
    }

    /// Épinglé : niveau .floating + présent sur TOUS les Spaces, y compris les
    /// Spaces plein écran (.fullScreenAuxiliary) — le trio nécessaire pour que
    /// le panneau reste visible au-dessus d'un IDE passé en plein écran natif.
    /// Détaché : fenêtre normale, ancrée à son Space.
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

    // MARK: - Apps ancrables

    /// Les apps ancrables, RECALCULÉES sur événement (voir observeWorkspace) :
    /// une simple méthode serait figée au moment où SwiftUI construit le menu,
    /// et un IDE lancé ensuite n'apparaîtrait jamais.
    @Published private(set) var dockableApps: [NSRunningApplication] = []

    /// Les apps ayant au moins une vraie fenêtre. Lecture via CGWindowList :
    /// aucune permission requise, donc la liste est utilisable AVANT même que
    /// l'utilisateur accorde l'Accessibilité.
    private func computeDockableApps() -> [NSRunningApplication] {
        let owners = Set(Self.windowOwnerPIDs())
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .filter { owners.contains($0.processIdentifier) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private nonisolated static func windowOwnerPIDs() -> [pid_t] {
        // PAS de .optionOnScreenOnly : cette option ne voit que le Space
        // COURANT. Un IDE en plein écran (Space dédié), sur un autre bureau ou
        // réduit devenait alors introuvable — mesuré : 1 app détectée contre 24
        // sans l'option. C'était la cause des « bugs quand l'app n'est pas en
        // plein écran » : rien à voir avec le plein écran, tout avec les Spaces.
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width > 300, rect.height > 200, // écarte palettes et popovers
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t
            else { return nil }
            return pid
        }
    }

    // MARK: - Ancrage

    /// Ancrage rapide (⌘⇧D) sur l'app nommée dans les préférences.
    @discardableResult
    func dockToDefaultTarget() -> Bool {
        refreshDockableApps()
        guard let app = dockableApps.first(where: { $0.localizedName == dockTargetAppName }) else {
            dockError = "Fenêtre « \(dockTargetAppName) » introuvable à l'écran. Ouvrez l'IDE puis réessayez (⌘⇧D)."
            return false
        }
        return dock(to: app)
    }

    /// Colle le compagnon à `app`. L'emprise TOTALE de l'IDE est conservée :
    /// l'IDE rétrécit exactement de la largeur du compagnon, qui occupe la bande
    /// libérée. La paire tient donc pile où l'IDE se trouvait — rien ne saute.
    @discardableResult
    func dock(to app: NSRunningApplication) -> Bool {
        dockError = nil

        guard Accessibility.isTrusted else {
            // Sans permission : on ne peut pas pousser l'IDE, seulement se poser
            // à côté. On demande l'autorisation et on fait au mieux en attendant.
            needsAccessibility = true
            Accessibility.requestTrust()
            return overlayDock(to: app)
        }
        needsAccessibility = false

        guard let ide = AXWindow.mainWindow(of: app) else {
            dockError = "Aucune fenêtre exploitable dans « \(app.localizedName ?? "?") »."
            return false
        }

        if ide.isNativeFullScreen {
            // Un Space plein écran n'accepte aucune fenêtre tierce : on tente
            // d'en sortir, sinon on explique plutôt que d'échouer en silence.
            guard ide.exitNativeFullScreen() else {
                dockError = "« \(app.localizedName ?? "?") » est en plein écran natif : macOS y interdit toute fenêtre tierce. Quittez le plein écran (⌃⌘F), puis réancrez — utilisez « Maximiser la paire » pour l'équivalent plein écran."
                return false
            }
            // L'animation de sortie dure ~0,5 s : on laisse la frame se stabiliser.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                _ = self?.dock(to: app)
            }
            return true
        }

        guard let footprint = ide.frame else {
            dockError = "Position de « \(app.localizedName ?? "?") » illisible."
            return false
        }

        axWindow = ide
        dockedApp = app
        isPinned = true

        apply(combined: footprint, ide: ide)
        startObserving(app: app)

        // L'IDE peut vivre sur un AUTRE Space que le nôtre : l'activer nous y
        // emmène, et le compagnon suit grâce à .canJoinAllSpaces (applyLevel).
        // Sans ça, ancrer un IDE d'un autre bureau ne montrait rien à l'écran.
        app.activate()
        return true
    }

    /// Repli sans permission : on se pose à côté sans toucher à l'IDE.
    private func overlayDock(to app: NSRunningApplication) -> Bool {
        guard let window,
              let name = app.localizedName,
              let target = Self.frontmostWindowFrame(ownerName: name) else { return false }

        let ideFrame = ScreenGeometry.appKit(from: target)
        let width = max(window.frame.width, window.minSize.width)
        let screen = ScreenGeometry.screen(containing: ideFrame) ?? NSScreen.main
        var x = dockSide == .right ? ideFrame.maxX : ideFrame.minX - width

        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX), visible.maxX - width)
        }
        window.setFrame(NSRect(x: x, y: ideFrame.minY, width: width, height: ideFrame.height),
                        display: true, animate: true)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func undock() {
        observer = nil
        axWindow = nil
        dockedApp = nil
        settledIDEFrame = nil
        settledCompanionFrame = nil
    }

    /// Étend la paire à tout l'écran utile — l'équivalent le plus proche du
    /// plein écran possible à deux apps (voir l'en-tête du fichier).
    func maximizePair() {
        guard let ide = axWindow, let current = ide.frame else {
            dockError = "Ancrez d'abord le compagnon à un IDE."
            return
        }
        guard let screen = ScreenGeometry.screen(containing: current) ?? NSScreen.main else { return }
        apply(combined: screen.visibleFrame, ide: ide, animate: true)
    }

    // MARK: - Le layout : « le compagnon est flush contre l'IDE »

    /// Plancher du compagnon : DOIT rester aligné sur le `minSize` posé dans
    /// adopt(). Descendre sous cette valeur ferait refuser la taille par AppKit,
    /// et la fenêtre trop large recouvrirait l'IDE au lieu de se coller à lui.
    static let minCompanionWidth: CGFloat = 380
    /// En dessous, un IDE n'affiche plus utilement du code.
    static let minIDEWidth: CGFloat = 400

    /// Largeur de bande retenue pour une emprise donnée, bornée aux deux
    /// plancher ci-dessus. Si l'emprise est trop étroite pour satisfaire les
    /// deux, le compagnon garde son minimum et l'IDE encaisse.
    func companionWidth(within combinedWidth: CGFloat) -> CGFloat {
        let ceiling = max(combinedWidth - Self.minIDEWidth, Self.minCompanionWidth)
        return min(max(companionWidth, Self.minCompanionWidth), ceiling)
    }

    /// Découpe `combined` en deux : l'IDE prend tout sauf une bande du côté
    /// `dockSide`, où va le compagnon.
    func split(_ combined: NSRect) -> (ide: NSRect, companion: NSRect) {
        let width = companionWidth(within: combined.width)
        var ide = combined
        ide.size.width -= width
        if dockSide == .left { ide.origin.x += width }

        let companion = NSRect(
            x: dockSide == .right ? ide.maxX : combined.minX,
            y: combined.minY,
            width: width,
            height: combined.height
        )
        return (ide, companion)
    }

    /// Applique une emprise combinée aux deux fenêtres, puis mémorise les frames
    /// RÉELLES (l'IDE peut refuser une taille) comme référence anti-écho.
    private func apply(combined: NSRect, ide: AXWindow, animate: Bool = false) {
        guard let window else { return }
        let parts = split(combined)
        companionWidth = parts.companion.width

        let actualIDE = ide.setFrame(parts.ide) ?? parts.ide
        // Le compagnon se colle à ce que l'IDE a VRAIMENT accepté : si l'IDE a
        // imposé sa largeur minimale, on reste flush plutôt que de laisser un
        // trou — l'invariant prime sur l'emprise demandée.
        let companion = companionFrame(forIDE: actualIDE, width: parts.companion.width)

        window.setFrame(companion, display: true, animate: animate)
        settledIDEFrame = actualIDE
        settledCompanionFrame = window.frame
    }

    /// L'invariant du mode tuilé, seul et unique : le compagnon est flush
    /// contre le bord `dockSide` de l'IDE, à sa hauteur.
    func companionFrame(forIDE ide: NSRect, width: CGFloat) -> NSRect {
        NSRect(
            x: dockSide == .right ? ide.maxX : ide.minX - width,
            y: ide.minY,
            width: width,
            height: ide.height
        )
    }

    /// Suivi : on conserve la largeur courante du compagnon.
    private func companionFrame(forIDE ide: NSRect) -> NSRect {
        companionFrame(forIDE: ide, width: settledCompanionFrame?.width ?? companionWidth)
    }

    /// Recalcule le compagnon depuis la position courante de l'IDE.
    private func relayoutFromIDE() {
        guard let window, let ide = axWindow, let ideFrame = ide.frame else { return }
        let companion = companionFrame(forIDE: ideFrame)
        window.setFrame(companion, display: true, animate: false)
        settledIDEFrame = ideFrame
        settledCompanionFrame = window.frame
    }

    // MARK: - Suivi de l'IDE

    private func startObserving(app: NSRunningApplication) {
        observer = AXWindowObserver(pid: app.processIdentifier) { [weak self] notification in
            self?.handleIDEEvent(notification)
        }
        if observer == nil {
            dockError = "Impossible d'observer « \(app.localizedName ?? "?") » : l'ancrage ne suivra pas ses déplacements."
        }
    }

    private func handleIDEEvent(_ notification: String) {
        guard let window, let ide = axWindow else { return }

        switch notification {
        case kAXUIElementDestroyedNotification, kAXMainWindowChangedNotification,
             kAXFocusedWindowChangedNotification:
            // La fenêtre suivie a disparu (projet fermé) : on tente de raccrocher
            // la nouvelle fenêtre principale, sinon on se détache proprement.
            if !ide.isAlive {
                guard let app = dockedApp, let replacement = AXWindow.mainWindow(of: app) else {
                    undock()
                    return
                }
                axWindow = replacement
                relayoutFromIDE()
            }
            return

        case kAXWindowMiniaturizedNotification:
            window.orderOut(nil) // l'IDE se réduit : le compagnon disparaît avec
            return

        case kAXWindowDeminiaturizedNotification:
            window.orderFront(nil)
            relayoutFromIDE()
            return

        default:
            break
        }

        guard let ideFrame = ide.frame else { return }
        // Notre propre écho ? On l'ignore, sinon on entre en oscillation.
        if let settled = settledIDEFrame, ideFrame.isNearlyEqual(to: settled) { return }

        // L'utilisateur a bougé/redimensionné l'IDE : le compagnon suit.
        let companion = companionFrame(forIDE: ideFrame)
        window.setFrame(companion, display: true, animate: false)
        settledIDEFrame = ideFrame
        settledCompanionFrame = window.frame
    }

    // MARK: - Suivi de notre propre fenêtre

    private func observeOwnWindow(_ window: NSWindow) {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.companionDidMove() } },

            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.companionDidResize() } },
        ]
    }

    /// Le compagnon a été déplacé à la main → on translate l'IDE du même delta,
    /// pour que la paire se déplace comme un bloc.
    private func companionDidMove() {
        guard let window, let ide = axWindow,
              let previous = settledCompanionFrame,
              let previousIDE = settledIDEFrame else { return }

        let current = window.frame
        if current.isNearlyEqual(to: previous) { return }

        // Un redimensionnement change aussi l'origine (bord gauche/bas tiré) :
        // c'est companionDidResize qui s'en charge, pas nous.
        guard abs(current.width - previous.width) < 1, abs(current.height - previous.height) < 1 else {
            return
        }

        var moved = previousIDE
        moved.origin.x += current.minX - previous.minX
        moved.origin.y += current.minY - previous.minY

        // On ne recale PAS le compagnon derrière : il est sous le curseur de
        // l'utilisateur, le repousser ferait vibrer le glisser.
        settledIDEFrame = ide.setFrame(moved) ?? moved
        settledCompanionFrame = current
    }

    /// Le compagnon a été redimensionné → l'IDE absorbe la différence pour que
    /// les deux restent collés : tirer le bord intérieur agit comme une poignée
    /// de séparation entre les deux « moitiés » de l'app combinée.
    private func companionDidResize() {
        guard let window, let ide = axWindow,
              let previous = settledCompanionFrame,
              let previousIDE = settledIDEFrame else { return }

        let current = window.frame
        if current.isNearlyEqual(to: previous) { return }

        companionWidth = current.width

        var resized = previousIDE
        resized.origin.y = current.minY
        resized.size.height = current.height
        switch dockSide {
        case .right:
            resized.size.width = current.minX - previousIDE.minX
        case .left:
            resized.origin.x = current.maxX
            resized.size.width = previousIDE.maxX - current.maxX
        }

        guard resized.width >= Self.minIDEWidth else { return } // l'IDE serait écrasé
        settledIDEFrame = ide.setFrame(resized) ?? resized
        settledCompanionFrame = current
    }

    // MARK: - Suivi de l'app cible

    private func refreshDockableApps() {
        dockableApps = computeDockableApps()
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        refreshDockableApps()

        // Une app peut mettre une seconde à ouvrir sa fenêtre : didLaunch seul
        // la manquerait. didBecomeActive (NOTRE app) est le filet décisif —
        // c'est exactement l'instant où l'utilisateur revient cliquer le menu.
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshDockableApps() } },

            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshDockableApps() } },
        ]
        workspaceObservers.append(contentsOf: [
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshDockableApps()
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.processIdentifier == self.dockedApp?.processIdentifier
                    else { return }
                    self.undock() // l'IDE a quitté : plus rien à suivre
                }
            },

            center.addObserver(
                forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated { self?.setCompanionVisible(false, ifTargetOf: note) }
            },

            center.addObserver(
                forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated { self?.setCompanionVisible(true, ifTargetOf: note) }
            },
        ])
    }

    /// L'IDE masqué (⌘H) emmène le compagnon avec lui — sinon un panneau
    /// orphelin flotterait devant une app absente.
    private func setCompanionVisible(_ visible: Bool, ifTargetOf note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier == dockedApp?.processIdentifier,
              let window else { return }
        if visible {
            window.orderFront(nil)
            relayoutFromIDE()
        } else {
            window.orderOut(nil)
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Lecture sans permission (repli)

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

extension NSRect {
    /// Tolérance 1 pt : AX et AppKit arrondissent différemment, et un écart
    /// sous-pixel ne doit jamais passer pour un déplacement utilisateur.
    func isNearlyEqual(to other: NSRect) -> Bool {
        abs(minX - other.minX) < 1 && abs(minY - other.minY) < 1
            && abs(width - other.width) < 1 && abs(height - other.height) < 1
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
