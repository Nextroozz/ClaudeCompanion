# ✨ ClaudeCompanion

**A 100% Native SwiftUI Companion for Claude Code CLI.**

ClaudeCompanion is a lightweight, fully native macOS wrapper that brings a graphical interface to Anthropic's Claude Code CLI. Originally inspired by the need for a native AI integration in editors, it has evolved into a versatile, standalone AI terminal.

Whether you use **CodeEdit, Xcode, VS Code, or no IDE at all**, ClaudeCompanion adapts to your workflow. Snap it next to your editor, or use it as a detached floating assistant for your everyday Mac tasks—do whatever you want with it.

## 🚀 Key Features

### 🖥️ Universal & Standalone
* **IDE Agnostic:** Works seamlessly alongside any IDE.
* **Detached Mode:** Use it entirely on its own as a dedicated, system-wide AI terminal for your Mac.
* **Liquid Glass UI:** Beautiful, deep translucent aesthetic designed to feel like a natural extension of macOS.

### ⚡ 100% Native SwiftUI
* Built entirely with SwiftUI. No Electron, no web views.
* Lightning-fast performance with real-time ANSI stripping and native Markdown rendering.
* Optimized for macOS, ensuring minimal memory footprint and battery impact.

### 🧠 Smart Skills Management (New!)
Supercharge your AI agent effortlessly. You can now manage your `SKILL.md` files directly within ClaudeCompanion:
* **Add Skills Directly:** Browse and install skills without touching the CLI.
* **Official & Community Skills:** Pull directly from official Vercel/Agent skills or any GitHub repository.
* **Intelligent Suggestions:** The app provides smart skill recommendations based on your current project context and stack.

### 🗂️ Advanced Session Management
Keep your workflow organized:
* Manage multiple active sessions at once.
* Group your sessions by project or task.
* Easily rename groups and sessions to find your context instantly.

## 📸 See it in Action

https://youtu.be/zrhYFAH-d3c

## 🛠️ Getting Started

### Prerequisites
* macOS 14.0+ (macOS 15+ recommended for the best visual experience)
* [Claude Code CLI](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview) installed and authenticated
* Xcode 15+ (for building the project)

### Installation
1. Clone the repository:
   ```bash
   git clone https://github.com/Nextroozz/ClaudeCompanion.git
   ```
2. Navigate to the project directory:
   ```bash
   cd ClaudeCompanion
   ```
3. Run the app immediately via Swift package manager:
   ```bash
   swift run
   ```
   *Note: For a fully distributable `.app` bundle, open the `Package.swift` in Xcode, build the macOS App target, and drag it to your Applications folder.*

## 🤝 Contributing

Feedback, bug reports, and pull requests are highly appreciated! Since this is a native macOS app, any ideas on how to further improve the SwiftUI architecture or enhance the "Liquid Glass" rendering are welcome.

## 📄 License

This project is open-source and available under the MIT License.
