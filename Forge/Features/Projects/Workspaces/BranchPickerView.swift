import SwiftUI

struct BranchPickerView: View {
    @ObservedObject private var store = ProjectStore.shared
    @State private var searchText: String = ""
    @State private var showNewBranch = false
    @State private var newBranchName: String = ""
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var isOperating = false
    var onDismiss: () -> Void

    private let accentGold = Color(red: 1.0, green: 0.76, blue: 0.28)

    var filteredBranches: [String] {
        let branches = store.allBranches.isEmpty ? [store.currentBranch].filter { !$0.isEmpty } : store.allBranches
        if searchText.isEmpty {
            return branches
        }
        return branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                TextField("Search branches...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .background(Color.white.opacity(0.1))

            if let error = errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(error)
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
                .foregroundColor(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            if let success = successMessage {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text(success)
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
                .foregroundColor(.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            if showNewBranch {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NEW BRANCH")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))

                    HStack(spacing: 6) {
                        TextField("branch-name", text: $newBranchName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { commitNewBranch() }

                        Button("Create") { commitNewBranch() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty || isOperating)

                        Button(action: { showNewBranch = false; errorMessage = nil }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()
                    .background(Color.white.opacity(0.1))
            }

            // Active workspace info
            if let workspace = store.activeWorkspace {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                    Text(workspace.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(workspace.branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.04))

                Divider()
                    .background(Color.white.opacity(0.1))
            }

            Text("BRANCHES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredBranches, id: \.self) { branch in
                        BranchRow(
                            branch: branch,
                            isCurrent: branch == store.currentBranch,
                            accentGold: accentGold
                        ) {
                            selectBranch(branch)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)

            Divider()
                .background(Color.white.opacity(0.1))

            VStack(alignment: .leading, spacing: 0) {
                ActionRow(icon: "plus", label: "New Branch") {
                    showNewBranch = true
                    newBranchName = ""
                    errorMessage = nil
                    successMessage = nil
                }
                ActionRow(icon: "plus.square.on.square", label: "New Workspace") {
                    createWorkspace()
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 320)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func selectBranch(_ branch: String) {
        guard let path = store.effectivePath, !isOperating else { return }
        isOperating = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Git.shared.run(in: path, args: ["checkout", branch])
            DispatchQueue.main.async {
                isOperating = false
                if result.success {
                    store.currentBranch = branch
                    store.requestGitRefresh()
                    onDismiss()
                } else {
                    errorMessage = result.trimmedOutput
                }
            }
        }
    }

    private func commitNewBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isOperating else { return }
        guard let path = store.effectivePath else { return }

        isOperating = true
        errorMessage = nil
        successMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Git.shared.run(in: path, args: ["checkout", "-b", name])
            DispatchQueue.main.async {
                isOperating = false
                if result.success {
                    showNewBranch = false
                    store.currentBranch = name
                    store.requestGitRefresh()
                    successMessage = "Created branch '\(name)'"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        onDismiss()
                    }
                } else {
                    errorMessage = result.trimmedOutput
                }
            }
        }
    }

    private func createWorkspace() {
        guard let project = store.activeProject, !isOperating else { return }
        let parentBranch = store.currentBranch.isEmpty ? project.defaultBranch : store.currentBranch
        isOperating = true
        errorMessage = nil
        successMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let workspace = try WorkspaceCloner.createWorkspace(
                    projectID: project.id,
                    projectName: project.name,
                    projectPath: project.path,
                    parentBranch: parentBranch
                )
                DispatchQueue.main.async {
                    isOperating = false
                    store.addWorkspace(workspace)
                    store.activeWorkspaceID = workspace.id
                    ProjectStore.shared.recordActivity(for: project.id)
                    successMessage = "Created workspace '\(workspace.name)'"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        onDismiss()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isOperating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct BranchRow: View {
    let branch: String
    let isCurrent: Bool
    let accentGold: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(accentGold)
                        .frame(width: 14)
                } else {
                    Color.clear.frame(width: 14, height: 1)
                }

                Text(branch)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundColor(.primary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isCurrent ? Color.white.opacity(0.05) : Color.clear)
    }
}

private struct ActionRow: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
