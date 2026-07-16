import SwiftUI

/// Détail d'un skill : aperçu du SKILL.md AVANT installation (on lit ce qu'on
/// s'apprête à laisser Claude suivre), alerte sur les scripts embarqués, choix
/// du périmètre, puis install/désinstall.
struct SkillDetailView: View {
    let skill: Skill
    @ObservedObject var model: SkillsViewModel

    @State private var manifest: String?
    @State private var files: [SkillInstaller.SkillFile] = []
    @State private var isLoading = true
    @State private var scope: Skill.InstalledScope = .project

    private var scripts: [SkillInstaller.SkillFile] { files.filter(\.isScript) }
    private var isBusy: Bool { model.busySkill == skill.name }

    /// Installable à distance = officiel ou communautaire (pas un skill local).
    private var isRemotelyInstallable: Bool {
        switch skill.origin {
        case .official, .community: return true
        case .local:                return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heading
                actions
                if !scripts.isEmpty { scriptWarning }
                Divider()
                preview
            }
            .padding(16)
        }
        .navigationTitle(skill.name)
        .task { await loadDetail() }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 10) {
            SkillBadge(skill: skill)
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name).font(.title3.weight(.semibold))
                Text(skill.description)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if skill.isInstalled {
            HStack(spacing: 8) {
                Label("Installé — \(skill.installed?.label ?? "")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                if skill.isRemovable {
                    Button(role: .destructive) {
                        Task { await model.uninstall(skill) }
                    } label: {
                        if isBusy { ProgressView().controlSize(.small) } else { Text("Désinstaller") }
                    }
                    .disabled(isBusy)
                } else {
                    Text("Géré par un plugin").font(.caption).foregroundStyle(.tertiary)
                }
            }
        } else if isRemotelyInstallable {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Installer dans", selection: $scope) {
                    Text("Ce projet").tag(Skill.InstalledScope.project)
                    Text("Global (tous les projets)").tag(Skill.InstalledScope.user)
                }
                .pickerStyle(.segmented)

                Button {
                    Task { await model.install(skill, scope: scope) }
                } label: {
                    HStack {
                        if isBusy { ProgressView().controlSize(.small) }
                        Text(isBusy ? "Installation…" : "Installer ce skill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
    }

    /// Un skill peut embarquer des scripts que Claude exécutera : on prévient
    /// AVANT, et on les liste. C'est le cœur de la posture sécurité.
    private var scriptWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(scripts.count) script(s) exécutable(s)", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text("Ce skill contient du code que Claude pourra lancer. N'installez que des sources de confiance.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(scripts, id: \.relativePath) { file in
                Text("• \(file.relativePath)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var preview: some View {
        Text("Aperçu du SKILL.md").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        if isLoading {
            HStack { ProgressView().controlSize(.small); Text("Chargement…").foregroundStyle(.secondary) }
        } else if let manifest, let body = bodyWithoutFrontmatter(manifest) {
            MarkdownView(markdown: body)
        } else if skill.isInstalled {
            Text("Aperçu distant indisponible — le skill est installé localement.")
                .font(.callout).foregroundStyle(.tertiary)
        } else {
            Text("Aperçu indisponible (GitHub injoignable ?).")
                .font(.callout).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Chargement

    private func loadDetail() async {
        switch skill.origin {
        case .official, .community:
            // Aperçu distant à la révision exacte (SKILL.md + repérage scripts).
            async let manifestTask = SkillInstaller.manifest(for: skill)
            async let filesTask = SkillInstaller.files(for: skill)
            manifest = await manifestTask
            files = await filesTask ?? []
        case .local:
            // Skill purement local : on le lit sur disque.
            if let scope = skill.installed {
                let dir = SkillInstaller.destinationRoot(scope: scope, projectDirectory: model.projectDirectoryForPreview)
                    .appendingPathComponent(skill.name)
                manifest = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8)
            }
        }
        isLoading = false
    }

    /// Retire le frontmatter pour n'afficher que le corps lisible.
    private func bodyWithoutFrontmatter(_ content: String) -> String? {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n"),
              let close = normalized.range(of: "\n---", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex)
        else { return content }
        return String(normalized[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
