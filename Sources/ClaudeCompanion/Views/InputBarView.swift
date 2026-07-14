import SwiftUI

/// Barre de saisie : capsule de verre, champ multi-lignes extensible,
/// bouton envoyer qui devient stop pendant le streaming.
struct InputBarView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Demandez à Claude…  (⏎ envoyer · ⌥⏎ ligne)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit(send)

            Button(action: viewModel.isStreaming ? viewModel.cancel : send) {
                Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(
                        viewModel.isStreaming
                            ? AnyShapeStyle(Color.red.opacity(0.85))
                            : (trimmedDraft.isEmpty
                                ? AnyShapeStyle(Color.secondary.opacity(0.5))
                                : AnyShapeStyle(Color.accentColor))
                    )
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isStreaming && trimmedDraft.isEmpty)
            .help(viewModel.isStreaming ? "Interrompre la génération" : "Envoyer (⏎)")
            .animation(.easeInOut(duration: 0.15), value: viewModel.isStreaming)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 23))
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .onAppear { isFocused = true }
    }

    private func send() {
        let text = trimmedDraft
        guard !text.isEmpty, !viewModel.isStreaming else { return }
        draft = ""
        viewModel.send(text)
    }
}
