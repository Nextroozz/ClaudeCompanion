# Claude Companion

Panneau compagnon macOS **100 % natif** (SwiftUI + AppKit) pour le CLI
[`claude`](https://claude.com/claude-code) — pensé comme panneau latéral
« façon VS Code » pour l'IDE [CodeEdit](https://www.codeedit.app).

Effet **Liquid Glass** profond sur toute la fenêtre : `NSVisualEffectView`
(`.behindWindow`) comme fond translucide + API `glassEffect` native de
macOS 26 pour les éléments internes (repli `NSVisualEffectView .withinWindow`
sur les macOS antérieurs). Markdown rendu nativement, blocs de code colorés,
streaming token par token. **Zéro dépendance externe.**

---

## Démarrage rapide

```sh
swift run          # lance l'app (mode développement, sans bundle .app)
swift test         # 24 tests : parsing ANSI, Markdown, stream-json, JSONL
```

Prérequis : Xcode 15+ (Xcode 26 recommandé pour le Liquid Glass natif) et
Claude Code installé/connecté (`claude` doit fonctionner dans votre terminal).

---

## Architecture

```
┌────────────────────────────  SwiftUI  ────────────────────────────┐
│  ChatView (verre .behindWindow) → HeaderBar / Messages / InputBar │
│  MarkdownView + CodeBlockView (SyntaxHighlighter natif)           │
└──────────────────────────────┬────────────────────────────────────┘
                               │ @Published (MainActor)
                    ┌──────────┴──────────┐
                    │    ChatViewModel    │  état, brouillon streamé,
                    └──────────┬──────────┘  statut des outils, coût/tour
              ┌────────────────┼─────────────────────┐
              ▼                ▼                     ▼
   ClaudeCLIService   SessionHistoryService     WindowManager
   Process + Pipe     ~/.claude/projects/…      HUD flottant,
   stream-json        liste + rechargement      ancrage CodeEdit
   AsyncThrowingStream  des sessions JSONL      (CGWindowList)
```

### Pourquoi pas de scraping du terminal ?

Le TUI interactif de `claude` réécrit l'écran en continu (codes ANSI,
curseur, re-rendus) : le parser est structurellement fragile. Le CLI expose
précisément pour cela un **mode headless** :

```sh
claude --print --output-format stream-json --verbose --include-partial-messages
```

→ une ligne JSON par événement (`system/init`, deltas de texte, `tool_use`,
`tool_result`, `result` avec coût et durée). C'est l'interface qu'utilisent
les clients graphiques open source (CodMate & co), et celle qu'implémente
`ClaudeCLIService` :

- prompt passé **par stdin** (pas d'échappement shell, longueur illimitée) ;
- lecture asynchrone `FileHandle.bytes.lines` (Swift Concurrency), stderr
  drainé en parallèle pour éviter tout blocage de pipe ;
- annulation coopérative : annuler la tâche ⇒ SIGTERM au processus ;
- PATH enrichi (les apps GUI ne reçoivent pas le PATH du shell) et binaire
  localisé automatiquement (`~/.local/bin`, Homebrew, npm, bun, puis
  `zsh -l -c 'command -v claude'` en dernier recours).

`ANSIStripper` reste dans la boîte à outils : il assainit **stderr** et tout
texte de terminal si vous ajoutez un mode brut (couvre CSI, OSC, DCS/SOS/PM/APC,
échappements simples, jeux de caractères, et résout les `\r` de progression).

### État de session et historique (JSONL)

Claude Code journalise chaque session dans
`~/.claude/projects/<chemin-encodé>/<session-id>.jsonl` (encodage : tout
caractère non alphanumérique du chemin projet → `-`). `SessionHistoryService` :

- liste les sessions du projet courant (titre = ligne `summary` ou premier
  message utilisateur), rafraîchie en direct par un `DispatchSource` ;
- recharge une session complète dans l'UI ;
- la conversation reprend ensuite via `--resume <session-id>` — l'app relit
  toujours le `session_id` renvoyé par `init`/`result`, car un resume en mode
  `--print` peut *forker* vers un nouvel identifiant.

### Permissions des outils (menu bouclier)

En headless, Claude ne peut pas demander « Autoriser ? » dans un terminal.
Le menu propose donc : Standard (outils sensibles refusés), **Accepter les
éditions** (défaut), Plan (lecture seule), Tout autoriser ⚠️.

---

## Créer le bundle .app dans Xcode

1. **File → New → Project… → macOS → App**, nom `ClaudeCompanion`,
   interface SwiftUI. Supprimez `ContentApp/ContentView` générés.
2. Glissez le contenu de `Sources/ClaudeCompanion/` dans la cible.
3. **Signing & Capabilities** :
   - supprimez **App Sandbox** (voir ci-dessous) ;
   - conservez **Hardened Runtime** (notarisation).
   - Le fichier prêt : `Distribution/ClaudeCompanion.entitlements`.
4. Onglet **Info** : reportez les clés de `Distribution/Info.sample.plist`
   (textes TCC pour Bureau/Documents, `LSUIElement` si vous voulez un pur HUD).
5. Cible de déploiement : macOS 14.0 (26.0 pour forcer le Liquid Glass natif).

## App Sandbox — le point important

**Recommandé : sandbox désactivé** (distribution Developer ID notariée, comme
la plupart des outils développeur). Raison structurelle : un processus lancé
par une app sandboxée **hérite du sandbox**. Le CLI `claude` ne pourrait plus
écrire `~/.claude` (sessions, identifiants), ni lire vos projets, ni lancer
ses propres outils — le wrapper deviendrait une coquille vide.

Hors sandbox, macOS protège quand même l'utilisateur : premier accès à
Bureau/Documents/Téléchargements ⇒ dialogue TCC (d'où les textes d'usage dans
`Info.sample.plist`).

Si vous devez livrer sandboxé malgré tout,
`Distribution/ClaudeCompanion-Sandboxed.entitlements` documente la
configuration maximale possible (accès aux dossiers choisis par l'utilisateur
+ bookmarks à persister, réseau client, exception `~/.claude`) et ses limites
— l'exception « temporary-exception » est de toute façon rédhibitoire sur
l'App Store.

---

## Intégration CodeEdit

- **Épingle** (`pin`) : fenêtre en `NSWindow.Level.floating` — le panneau
  reste au-dessus de l'IDE, même quand celui-ci a le focus. Débrayable.
- **Ancrage** (`⌘⇧D`) : `CGWindowListCopyWindowInfo` localise la fenêtre
  CodeEdit au premier plan (aucune permission requise : on lit position et
  propriétaire, pas les titres), puis le panneau se colle à son bord droit en
  adoptant sa hauteur. Autre IDE :
  `defaults write <bundle-id> dockTargetApp "Xcode"`.
- Le dossier de projet sélectionné (📁 en haut à gauche) devient le `cwd` du
  CLI : Claude lit/édite les fichiers que CodeEdit affiche.

Pistes suivantes : suivi continu de la fenêtre (AXObserver), envoi de la
sélection courante de l'éditeur, extension CodeEdit native quand son API de
plugins sera stabilisée.

## Réglages avancés (UserDefaults)

```sh
defaults write <bundle-id> claudeBinaryPath /chemin/vers/claude  # binaire forcé
defaults write <bundle-id> claudeModel sonnet                    # --model
defaults write <bundle-id> dockTargetApp "Xcode"                 # cible d'ancrage
```

(En `swift run`, `<bundle-id>` est `ClaudeCompanion`.)

## Dépannage

| Symptôme | Cause probable | Remède |
|---|---|---|
| « Binaire claude introuvable » | Installation exotique | `claudeBinaryPath` ci-dessus |
| Erreur `unknown option --include-partial-messages` | CLI ancien | `claude update`, ou passez `includePartialMessages: false` dans `ChatViewModel.send` |
| Réponses sans édition de fichiers | Mode permissions Standard | menu bouclier → « Accepter les éditions » |
| Pas de transparence en `swift run` | Réduire la transparence activé | Réglages → Accessibilité → Affichage |
