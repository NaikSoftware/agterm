import agtermCore
import AppKit
import SwiftUI

/// The two-step workspace setup sheet: a proposal, then a checklist of the projects folder's subfolders.
struct WorkspaceSetupGuide: View {
    let store: AppStore
    let finish: () -> Void

    @State private var picking = false
    @State private var root = ProjectFolderScan.defaultRoot(home: NSHomeDirectory())
    @State private var candidates: [ProjectCandidate] = []
    @State private var checked: Set<String> = []

    private var selectable: [ProjectCandidate] { candidates.filter { !Self.isPinned($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if picking { picker } else { proposal }
        }
        .padding(20)
        .frame(width: 600, height: 400)
    }

    // MARK: - Step 1

    private var proposal: some View {
        Group {
            HStack(alignment: .top, spacing: 20) {
                illustration
                VStack(alignment: .leading, spacing: 10) {
                    Text("One workspace per project").font(.title2.bold())
                    Text("Point agterm at your projects folder. Each project you check gets its own workspace, "
                         + "and every session started in that folder joins it.")
                    Text("That includes sessions a tool opens with:")
                    Text("agtermctl session new --cwd").font(.body.monospaced())
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack {
                Text("Later: File ▸ Set Up Workspaces…").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Skip", action: finish).keyboardShortcut(.cancelAction)
                Button("Choose Projects…") {
                    rescan()
                    picking = true
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var illustration: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([("web-app", ["claude", "dev server"]), ("api-server", ["zsh"]), ("mobile-app", ["claude"])], id: \.0) { name, sessions in
                VStack(alignment: .leading, spacing: 2) {
                    Label(name, systemImage: "square.grid.2x2").fontWeight(.medium)
                    Text("~/Projects/\(name)").font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
                    ForEach(sessions, id: \.self) { Label($0, systemImage: "terminal").padding(.leading, 14) }
                }
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(12)
        .frame(width: 200, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    // MARK: - Step 2

    private var picker: some View {
        Group {
            Text("Choose your projects").font(.title2.bold())
            HStack {
                Text("Projects folder")
                Text(root ?? "")
                    .font(.system(size: 12).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                Button("Choose…", action: chooseRoot)
            }
            checklist
            Text("Git repositories start checked. Hidden folders are not listed.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Back") { picking = false }
                Spacer()
                Button("Cancel", action: finish).keyboardShortcut(.cancelAction)
                Button(checked.isEmpty ? "Create Workspaces"
                       : "Create \(checked.count) Workspace\(checked.count == 1 ? "" : "s")", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(checked.isEmpty)
            }
        }
    }

    private var checklist: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Select all", isOn: Binding(
                    get: { !selectable.isEmpty && checked.count == selectable.count },
                    set: { checked = $0 ? Set(selectable.map(\.path)) : [] }))
                .toggleStyle(.checkbox)
                .disabled(selectable.isEmpty)
                Spacer()
                Text("\(checked.count) of \(selectable.count) selected").foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()
            if candidates.isEmpty {
                VStack(spacing: 4) {
                    Text("No project folders here").font(.headline)
                    Text("Pick the folder that holds your projects, not a project itself.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(candidates, id: \.path) { row($0) }
                    .listStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    private func row(_ candidate: ProjectCandidate) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { checked.contains(candidate.path) },
                set: { if $0 { checked.insert(candidate.path) } else { checked.remove(candidate.path) } })) {
                Label(candidate.name, systemImage: "folder")
            }
            .toggleStyle(.checkbox)
            .disabled(Self.isPinned(candidate))
            Spacer()
            if let note = Self.note(for: candidate) {
                Text(note).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private static func isPinned(_ candidate: ProjectCandidate) -> Bool {
        if case .pinned = candidate.existing { return true }
        return false
    }

    private static func note(for candidate: ProjectCandidate) -> String? {
        switch candidate.existing {
        case .pinned: "Has a workspace"
        case .named(_, let name): "Uses workspace “\(name)”"
        case .none: candidate.isGitRepository ? nil : "Not a git repository"
        }
    }

    private func rescan() {
        candidates = root.map { ProjectFolderScan.candidates(in: $0, workspaces: store.workspaces) } ?? []
        checked = Set(candidates.filter(\.preselected).map(\.path))
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root.map { URL(fileURLWithPath: $0, isDirectory: true) }
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url.path
        rescan()
    }

    private func create() {
        store.importProjects(candidates.filter { checked.contains($0.path) })
        finish()
    }
}
