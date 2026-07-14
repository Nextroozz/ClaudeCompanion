import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Glass — la couche « Liquid Glass » de l'application
//
// Deux étages :
//
// 1. VisualEffectView : le pont NSViewRepresentable vers NSVisualEffectView,
//    demandé explicitement. Avec blendingMode == .behindWindow ET une fenêtre
//    rendue transparente (voir WindowManager.adopt), c'est LE fond de l'app :
//    le bureau et les fenêtres derrière transparaissent, floutés.
//
// 2. liquidGlass(in:tint:) : modificateur pour les éléments internes (barre
//    de saisie, bulles, puces d'outils). Sur macOS 26+, il utilise la vraie
//    API Liquid Glass (.glassEffect) ; sinon il retombe sur un
//    NSVisualEffectView en .withinWindow — même géométrie, même API d'appel.
// ─────────────────────────────────────────────────────────────────────────────

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    /// .active force le flou même quand la fenêtre n'a pas le focus —
    /// exactement ce qu'on attend d'un panneau compagnon posé à côté de l'IDE.
    var state: NSVisualEffectView.State = .active
    var isEmphasized = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
    }
}

extension View {

    /// Applique un effet de verre à un élément, découpé selon `shape`.
    /// macOS 26+ : Liquid Glass natif (réfraction, réaction au contenu).
    /// Avant : NSVisualEffectView .withinWindow + liseré, rendu très proche.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        #if compiler(>=6.2) // SDK macOS 26 requis pour compiler .glassEffect
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            legacyGlass(in: shape, tint: tint)
        }
        #else
        legacyGlass(in: shape, tint: tint)
        #endif
    }

    @ViewBuilder
    private func legacyGlass<S: Shape>(in shape: S, tint: Color?) -> some View {
        self
            .background {
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                    if let tint {
                        tint.opacity(0.22)
                    }
                }
                .clipShape(shape)
            }
            .overlay {
                // Liseré lumineux : simule la capture de lumière sur la tranche.
                shape.stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
    }
}
