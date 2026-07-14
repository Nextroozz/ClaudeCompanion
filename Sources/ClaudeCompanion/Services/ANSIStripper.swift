import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// ANSIStripper — nettoyage robuste des codes d'échappement de terminal
//
// Utilisé pour assainir stderr du CLI et tout texte provenant d'un terminal
// avant affichage dans SwiftUI. Couvre l'intégralité des familles ECMA-48 :
//
//   • CSI  — ESC [ … lettre finale     (couleurs SGR, curseur, effacement…)
//   • OSC  — ESC ] … BEL ou ESC \      (titre de fenêtre, hyperliens OSC 8…)
//   • DCS / SOS / PM / APC — ESC P/X/^/_ … ESC \
//   • Échappements Fe simples — ESC suivi d'un seul caractère @–Z \ ] ^ _
//   • Désignation de jeux de caractères — ESC ( B, etc.
//
// Gère aussi les retours chariot \r (barres de progression qui réécrivent la
// ligne) et filtre les caractères de contrôle C0 restants.
// ─────────────────────────────────────────────────────────────────────────────

enum ANSIStripper {

    private static let escapeRegex: NSRegularExpression = {
        let pattern = "\u{1B}(?:"
            + "\\[[0-9:;<=>?]*[ -/]*[@-~]"                    // CSI
            + "|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"     // OSC (terminé par BEL ou ST)
            + "|[PX^_][^\u{1B}]*\u{1B}\\\\"                   // DCS, SOS, PM, APC
            + "|[@-Z\\\\-_]"                                  // Fe simple (ESC + un caractère)
            + "|[=>78c]"                                      // Fp/Fs : DECKPAM/DECKPNM, curseur DEC, RIS
            + "|[()][AB012]"                                  // jeux de caractères G0/G1
            + ")"
        // Le pattern est une constante : un échec de compilation serait un bug
        // de développement, d'où le try! assumé (couvert par les tests).
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Supprime tous les codes d'échappement ANSI et normalise les contrôles.
    static func strip(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        let range = NSRange(input.startIndex..., in: input)
        let withoutEscapes = escapeRegex.stringByReplacingMatches(
            in: input, options: [], range: range, withTemplate: ""
        )
        return resolveControlCharacters(withoutEscapes)
    }

    /// 1. Résout les retours chariot : pour chaque ligne, seul le contenu
    ///    après le dernier `\r` est conservé (c'est ce que verrait l'œil dans
    ///    un vrai terminal après réécriture de la ligne — spinners, % de
    ///    progression…).
    /// 2. Filtre les contrôles C0 restants, en préservant `\n` et `\t`.
    static func resolveControlCharacters(_ input: String) -> String {
        var lines: [Substring] = []
        for line in input.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(line.split(separator: "\r", omittingEmptySubsequences: false).last ?? "")
        }
        let joined = lines.joined(separator: "\n")
        let scalars = joined.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.value >= 0x20
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
