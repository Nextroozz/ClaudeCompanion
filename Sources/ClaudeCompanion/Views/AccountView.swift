import SwiftUI

/// Popover « compte » (icône personne, en haut à gauche) : identité du compte
/// Anthropic connecté au CLI, connexion/déconnexion, coût de la conversation
/// en cours et statistiques d'usage (session/semaine).
struct AccountView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var account: AccountInfo?
    @State private var isBusy = false
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountSection

            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

            conversationSection

            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

            UsageView()
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { refreshAccount() }
    }

    // MARK: - Compte

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: account == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(account == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text(account?.displayName ?? account?.email ?? "Non connecté")
                        .font(.headline)
                        .lineLimit(1)
                    if let account {
                        if account.displayName != nil, let email = account.email {
                            Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let organization = account.organization {
                            Text(organization).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    } else {
                        Text("Connectez le CLI Claude Code pour utiliser l'app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let plan = account?.planHint {
                    Text(plan)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.25), in: Capsule())
                }
            }

            HStack(spacing: 8) {
                if account != nil {
                    Button("Se déconnecter", role: .destructive, action: logout)
                        .disabled(isBusy)
                    Button("Changer de compte…", action: login)
                        .disabled(isBusy)
                } else {
                    Button("Se connecter…", action: login)
                        .disabled(isBusy)
                }
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    refreshAccount()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Actualiser l'état du compte")
            }
            .controlSize(.small)
        }
    }

    // MARK: - Conversation en cours

    private var conversationSection: some View {
        let stats = viewModel.conversationCost
        return HStack(alignment: .firstTextBaseline) {
            Text("Conversation en cours").font(.callout)
            Spacer()
            Text(stats.turns == 0
                 ? "—"
                 : String(format: "%.3f $ · %d tour%@", stats.costUSD, stats.turns, stats.turns > 1 ? "s" : ""))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(stats.turns == 0 ? .secondary : .primary)
        }
    }

    // MARK: - Actions

    private func refreshAccount() {
        account = AccountService.currentAccount()
    }

    private func login() {
        guard let binary = viewModel.binaryURL else {
            feedback = "Binaire « claude » introuvable."
            return
        }
        do {
            try AccountService.openLoginInTerminal(binary: binary)
            feedback = "Connexion ouverte dans le Terminal — terminez-la là-bas, puis cliquez sur ⟳ ici."
        } catch {
            feedback = "Impossible d'ouvrir le Terminal : \(error.localizedDescription)"
        }
    }

    private func logout() {
        guard let binary = viewModel.binaryURL else {
            feedback = "Binaire « claude » introuvable."
            return
        }
        isBusy = true
        feedback = nil
        Task {
            let error = await Task.detached(priority: .userInitiated) {
                AccountService.logout(binary: binary)
            }.value
            account = AccountService.currentAccount()
            feedback = error ?? "Déconnecté."
            isBusy = false
        }
    }
}
