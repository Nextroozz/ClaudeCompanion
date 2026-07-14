# 🤖 ClaudeCompanion for macOS

> Une interface macOS 100 % native, fluide et élégante pour l'outil en ligne de commande Claude Code d'Anthropic.

ClaudeCompanion est un "wrapper" SwiftUI qui encapsule la puissance de la CLI `claude` dans une application native intégrant les codes visuels de macOS, dont un superbe effet "Liquid Glass". Fini le terminal austère, profitez de l'IA d'Anthropic directement dans une interface pensée par et pour les développeurs Mac.

## 💻 L'allié parfait pour CodeEdit

ClaudeCompanion a été spécifiquement pensé pour combler le manque actuel d'intégration IA au sein de **CodeEdit**. 

Positionnez simplement la fenêtre translucide de ClaudeCompanion à côté de votre espace de travail CodeEdit. Grâce à son design natif et son effet *Liquid Glass*, l'application se fond naturellement dans votre environnement de développement, offrant une expérience "VS Code-like" fluide et visuellement parfaite, tout en gardant vos projets locaux à portée de terminal.

## ✨ Fonctionnalités

* **100 % Natif :** Développé entièrement en Swift et SwiftUI pour des performances optimales sans la lourdeur d'Electron.
* **Design "Liquid Glass" :** Une interface translucide qui s'intègre parfaitement à votre environnement de travail grâce à des composants visuels sur-mesure (`Glass.swift`).
* **Rendu Markdown & Code :** Affichage riche des réponses de l'IA avec une coloration syntaxique intégrée (`SyntaxHighlighter.swift`) et une gestion propre des blocs de code (`CodeBlockView.swift`).
* **Nettoyage ANSI en temps réel :** Le moteur interne filtre instantanément les codes de formatage de la CLI (`ANSIStripper.swift`) pour garantir un rendu textuel impeccable dans l'interface.
* **Historique des sessions :** Ne perdez jamais le fil grâce à la sauvegarde et à la reprise de vos conversations (`SessionHistoryService.swift`).
* **Suivi de la consommation :** Gardez un œil sur les tokens utilisés via un panneau de statistiques dédié (`UsageView.swift`).

## 📸 Captures d'écran

https://github.com/user-attachments/assets/7d33ab3f-36fe-458d-9b08-d8e306ba12ba

## 🏗️ Architecture Technique

Le projet a été conçu de manière modulaire en suivant le motif MVVM (Model-View-ViewModel) :
* **Views :** Composants UI réutilisables et réactifs (`ChatView`, `HeaderBarView`, `MessageBubbleView`).
* **ViewModels :** Gestion de la logique de présentation et d'état (`ChatViewModel`).
* **Services :** Cœur asynchrone de l'application gérant l'exécution de la ligne de commande en arrière-plan (`ClaudeCLIService`), le parsing des données (`MarkdownBlockParser`) et la télémétrie (`UsageService`).
* **Models :** Structure robuste des données échangées (`ChatMessage`, `ClaudeStreamEvents`).

## 🚀 Prérequis

1. macOS 13.0 ou supérieur.
2. Xcode 15+ (pour compiler le projet).
3. L'outil officiel **Claude Code** d'Anthropic installé globalement sur votre système via Node.js :
   ```bash
   npm install -g @anthropic-ai/claude-code
   claude auth
   ```

## 🛠️ Installation & Lancement

1. Clonez ce dépôt : 
   ```bash
   git clone https://github.com/votre-nom/ClaudeCompanion.git
   ```
2. Ouvrez le fichier `Package.swift` ou le dossier du projet dans Xcode.
3. Laissez Swift Package Manager résoudre les éventuelles dépendances.
4. Compilez et exécutez le projet (`Cmd + R`).

## 🧪 Tests Unitaires

La fiabilité de l'application est primordiale. Le projet inclut une suite de tests unitaires (située dans `Tests/ClaudeCompanionTests/`) pour valider les éléments critiques :
* Vérification du parsing des réponses de la CLI (`ParsingTests.swift`).
* Validation du calcul de l'utilisation des tokens (`UsageServiceTests.swift`).

Exécutez les tests directement depuis Xcode avec le raccourci `Cmd + U`.

## 🤝 Contribuer

Les contributions sont les bienvenues ! Que ce soit pour améliorer l'intégration avec d'autres IDE (comme CodeEdit), optimiser le parsing, ou ajouter de nouvelles thématiques visuelles, n'hésitez pas à ouvrir une *Issue* ou à soumettre une *Pull Request*.

## 📄 Licence

Ce projet est distribué sous la licence MIT. Voir le fichier `LICENSE` pour plus de détails.
