import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// WorkspaceLayout — PROTOTYPE : le pas de la paire vers N fenêtres
//
// L'ancrage actuel tient sur un invariant à deux : « le compagnon est flush
// contre le bord de l'IDE ». Un workspace, c'est le même invariant généralisé :
// « N fenêtres se partagent une emprise sans trou ni recouvrement ».
//
// Ce fichier ne contient QUE le calcul — pur, testable, sans AppKit vivant.
// Le pilotage (AXWindow.setFrame, suivi AXObserver, anti-écho par relecture)
// est déjà écrit dans WindowManager : y brancher ce layout est mécanique.
//
// ── CE QUI EST IMPOSSIBLE, ET POURQUOI ÇA N'EST PAS GRAVE ───────────────────
// Contenir vraiment les fenêtres d'autres apps DANS une fenêtre à nous
// supposerait de reparenter entre processus : macOS ne l'expose pas, et même
// yabai ne le fait pas (il déplace des fenêtres réelles via des API privées,
// SIP désactivé). Inutile de toute façon : à l'œil, des fenêtres réelles
// tuilées sans interstice donnent le même résultat.
//
// Le plein écran natif reste hors de portée (un Space = une app), MAIS l'écart
// mesuré n'est que de 33 pt — la barre de menus. En masquage automatique,
// `visibleFrame` couvre l'écran entier et la maximisation devient
// indiscernable d'un plein écran. D'où `Workspace.maximize(on:)`, qui vise
// `visibleFrame` et hérite donc gratuitement de ce réglage.
// ─────────────────────────────────────────────────────────────────────────────

/// Une tuile du workspace : une app, et la part d'emprise qu'elle occupe.
struct WorkspaceTile: Equatable, Identifiable {
    /// Identité stable de l'app ciblée. Le pid change à chaque lancement : un
    /// layout sauvegardé doit survivre à un redémarrage de l'IDE, d'où le
    /// bundle identifier.
    let bundleID: String
    /// Poids relatif dans l'axe de partage. Des poids plutôt que des largeurs
    /// absolues : le layout se transpose alors à n'importe quel écran.
    var weight: Double

    var id: String { bundleID }

    init(bundleID: String, weight: Double = 1) {
        self.bundleID = bundleID
        self.weight = max(weight, 0.0001) // un poids nul ferait disparaître la tuile
    }

    /// bundleID sentinelle du compagnon lui-même. Sa fenêtre n'est pas pilotée
    /// par l'API Accessibilité (c'est la nôtre) mais directement via NSWindow :
    /// `WindowManager` teste `isCompanion` pour choisir la bonne voie.
    static let companionBundleID = "app.claudecompanion.self"
    var isCompanion: Bool { bundleID == Self.companionBundleID }
}

/// Un workspace : des tuiles, un axe, une largeur minimale par tuile.
struct Workspace: Equatable {

    enum Axis: String, Codable, CaseIterable {
        /// Côte à côte — la disposition d'un IDE + panneaux.
        case horizontal
        /// Empilées — utile pour un terminal sous l'éditeur.
        case vertical
    }

    var tiles: [WorkspaceTile]
    var axis: Axis = .horizontal

    /// Largeur et hauteur minimales sont deux grandeurs DIFFÉRENTES : 380 pt de
    /// large est le plancher d'un panneau lisible (c'est le minSize du
    /// compagnon), mais 380 pt de haut interdirait d'empiler trois fenêtres sur
    /// un portable — un terminal sous un éditeur vit très bien en 240 pt.
    /// Confondre les deux ne laissait tenir que 2 tuiles verticales sur 949 pt.
    static let minimumWidth: CGFloat = 380
    static let minimumHeight: CGFloat = 240

    /// Le plancher applicable à l'axe de partage courant.
    var minimumExtent: CGFloat {
        axis == .horizontal ? Self.minimumWidth : Self.minimumHeight
    }

    /// Découpe `frame` entre les tuiles, proportionnellement aux poids.
    ///
    /// Deux garanties, vérifiées par les tests :
    ///   • aucun trou ni recouvrement — les tuiles se touchent exactement ;
    ///   • aucune tuile sous `minimumExtent`, quitte à rogner les plus grandes.
    ///
    /// Renvoie [] si l'emprise ne peut loger toutes les tuiles : mieux vaut ne
    /// rien faire que produire un tuilage illisible.
    func frames(in frame: NSRect) -> [NSRect] {
        guard !tiles.isEmpty else { return [] }

        let total = axis == .horizontal ? frame.width : frame.height
        guard total >= minimumExtent * CGFloat(tiles.count) else { return [] }

        var extents = proportionalExtents(total: total)
        enforceMinimum(&extents, total: total)

        // On construit les bords par cumul plutôt que d'additionner les
        // largeurs : les erreurs d'arrondi ne s'accumulent pas, et le dernier
        // bord tombe pile sur celui de l'emprise.
        var result: [NSRect] = []
        var offset: CGFloat = 0
        for extent in extents {
            let start = offset.rounded()
            let end = (offset + extent).rounded()
            result.append(rect(in: frame, from: start, to: end))
            offset += extent
        }
        return result
    }

    private func proportionalExtents(total: CGFloat) -> [CGFloat] {
        let weightSum = tiles.reduce(0) { $0 + $1.weight }
        return tiles.map { CGFloat($0.weight / weightSum) * total }
    }

    /// Remonte les tuiles trop petites au minimum, et facture la différence aux
    /// autres au prorata de ce qu'elles peuvent céder. Itératif : renflouer une
    /// tuile peut en faire passer une autre sous le seuil.
    private func enforceMinimum(_ extents: inout [CGFloat], total: CGFloat) {
        for _ in 0..<extents.count {
            let deficit = extents.reduce(0) { $0 + max(0, minimumExtent - $1) }
            guard deficit > 0.01 else { return }

            let donors = extents.indices.filter { extents[$0] > minimumExtent }
            let surplus = donors.reduce(0) { $0 + (extents[$1] - minimumExtent) }
            guard surplus > 0.01 else {
                // Plus rien à céder : tout le monde au minimum. `frames` a déjà
                // garanti que ça rentre.
                extents = extents.map { _ in minimumExtent }
                return
            }

            for index in extents.indices where extents[index] < minimumExtent {
                extents[index] = minimumExtent
            }
            let take = min(deficit, surplus)
            for index in donors {
                let share = (extents[index] - minimumExtent) / surplus
                extents[index] -= take * share
            }
        }
    }

    private func rect(in frame: NSRect, from start: CGFloat, to end: CGFloat) -> NSRect {
        switch axis {
        case .horizontal:
            return NSRect(x: frame.minX + start, y: frame.minY,
                          width: end - start, height: frame.height)
        case .vertical:
            // AppKit compte vers le HAUT : la première tuile doit coiffer la
            // pile, donc on part du bord supérieur.
            return NSRect(x: frame.minX, y: frame.maxY - end,
                          width: frame.width, height: end - start)
        }
    }

    /// L'emprise d'une maximisation. `visibleFrame` et non `frame` : la barre
    /// de menus recouvrirait le haut d'une fenêtre placée sous elle. Avec le
    /// masquage automatique activé, `visibleFrame` devient l'écran entier et
    /// cette même ligne donne un vrai plein écran — sans rien changer ici.
    static func maximize(on screen: NSScreen) -> NSRect {
        screen.visibleFrame
    }
}

// MARK: - Persistance

/// Un workspace se sauvegarde par projet : « sur ce dépôt, je veux CodeEdit à
/// gauche et le compagnon à droite ». C'est l'intérêt du dispositif face à
/// Stage Manager, qui groupe des apps mais ignore le projet.
extension Workspace: Codable {}
extension WorkspaceTile: Codable {}
