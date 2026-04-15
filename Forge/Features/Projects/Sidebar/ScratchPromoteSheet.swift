import AppKit
import SwiftUI

struct ScratchPromoteSheet: View {
    let scratch: Project
    let workspace: Workspace
    let onCancel: () -> Void
    let onPromote: (URL, String) -> Void

    @State private var parentDir: URL?
    @State private var name: String

    init(
        scratch: Project,
        workspace: Workspace,
        onCancel: @escaping () -> Void,
        onPromote: @escaping (URL, String) -> Void
    ) {
        self.scratch = scratch
        self.workspace = workspace
        self.onCancel = onCancel
        self.onPromote = onPromote
        _name = State(initialValue: scratch.name)
    }

    private var openTabCount: Int {
        TerminalSessionManager.shared.tabs.filter { $0.workspaceID == workspace.id }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Promote Scratch")
                .font(.system(size: 14, weight: .semibold))

            Text("Move this scratch out of `~/.forge/scratch/` and register it as a normal project. A fresh workspace will be created.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Project name")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Parent directory")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                HStack {
                    Text(parentDir?.path ?? "Choose…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(parentDir == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…", action: pickParentDir)
                }
            }

            if openTabCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Promotion will close \(openTabCount) open terminal\(openTabCount == 1 ? "" : "s") for this scratch.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Promote") {
                    guard let parentDir else { return }
                    onPromote(parentDir, name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parentDir == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func pickParentDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK {
            parentDir = panel.url
        }
    }
}
