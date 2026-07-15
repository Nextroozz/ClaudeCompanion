import SwiftUI

/// Panneau d'usage : coût et tokens estimés depuis les journaux locaux de
/// Claude Code (~/.claude/projects). Affiché dans un popover de l'en-tête.
///
/// Note honnêteté : les pourcentages exacts des limites du plan (écran /usage
/// du CLI) passent par un endpoint OAuth privé, non exposé localement — on
/// affiche donc une estimation calculée sur la même source que ccusage,
/// clairement étiquetée comme telle.
struct UsageView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var snapshot: UsageSnapshot?
    @State private var scope: UsageScope = .currentProject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Usage (estimation locale)", systemImage: "chart.bar.fill")
                    .font(.headline)
                Spacer()
            }

            Picker("Périmètre", selection: $scope) {
                ForEach(UsageScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let snapshot {
                VStack(alignment: .leading, spacing: 10) {
                    periodRow(title: "Session (5 dernières h)", totals: snapshot.lastFiveHours)
                    periodRow(title: "Aujourd'hui", totals: snapshot.today)
                    periodRow(title: "Semaine (7 jours)", totals: snapshot.lastSevenDays)
                }

                if !snapshot.todayByModel.isEmpty {
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Par modèle (aujourd'hui)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(snapshot.todayByModel) { entry in
                            HStack {
                                Text(ModelNames.short(entry.model))
                                    .font(.caption)
                                Spacer()
                                Text(costText(entry.costUSD))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 24)
            }

            Text("Estimation d'après les journaux locaux (~/.claude/projects), grille tarifaire API publique. Les limites exactes de votre plan ne sont pas exposées localement — utilisez /usage dans le CLI pour les pourcentages officiels.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Composant embarqué (dans AccountView) : le parent fournit padding et largeur.
        // .task(id:) relance le calcul quand le périmètre change.
        .task(id: scope) { await reload() }
    }

    private func periodRow(title: String, totals: UsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout)
                Spacer()
                Text(costText(totals.costUSD))
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            Text(totals.isEmpty
                 ? "Aucune activité"
                 : "\(totals.requests) req · entrée \(tokenText(totals.inputTokens)) · sortie \(tokenText(totals.outputTokens)) · cache \(tokenText(totals.cacheReadTokens)) lus")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        let directory = viewModel.projectDirectory
        let currentScope = scope
        snapshot = await Task.detached(priority: .userInitiated) {
            UsageService.computeSnapshot(scope: currentScope, projectDirectory: directory)
        }.value
    }

    private func costText(_ cost: Double) -> String {
        cost >= 0.995 ? String(format: "%.2f $", cost) : String(format: "%.3f $", cost)
    }

    private func tokenText(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1f M", Double(count) / 1_000_000)
        case 1_000...:     return String(format: "%.0f k", Double(count) / 1_000)
        default:           return "\(count)"
        }
    }
}
