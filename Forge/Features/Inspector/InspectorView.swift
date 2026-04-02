import SwiftUI

// MARK: - Inspector Tab

enum InspectorTab: String, CaseIterable {
    case working = "Working"
    case workspace = "Workspace"
}

struct InspectorView: View {
    @ObservedObject private var store = ProjectStore.shared
    @State private var commandsExpanded = false
    @State private var commands: [ProjectCommand] = []
    @State private var activeTab: InspectorTab = .working

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar — only show when a workspace is active
            if store.activeWorkspace != nil {
                InspectorTabBar(activeTab: $activeTab)
            }

            // Tab content
            switch activeTab {
            case .working:
                FileStatusList()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .workspace:
                if store.activeWorkspace != nil {
                    WorkspaceDiffList()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FileStatusList()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Commands drawer pinned to bottom
            CommandsDrawer(
                expanded: $commandsExpanded,
                commands: commands,
                onRun: runCommand
            )
        }
        .background(.clear)
        .onAppear {
            discoverCommands()
            Task { @MainActor in
                StatusViewModel.shared.startAutoRefresh()
                WorkspaceDiffViewModel.shared.startAutoRefresh()
            }
        }
        .onDisappear {
            StatusViewModel.shared.stopAutoRefresh()
            WorkspaceDiffViewModel.shared.stopAutoRefresh()
        }
        .onChange(of: store.activeProjectID) { _, _ in
            discoverCommands()
            Task { @MainActor in
                StatusViewModel.shared.refresh()
            }
        }
        .onChange(of: store.activeWorkspaceID) { _, _ in
            discoverCommands()
            activeTab = .working
            Task { @MainActor in
                StatusViewModel.shared.refresh()
                WorkspaceDiffViewModel.shared.refresh()
            }
        }
    }

    private func discoverCommands() {
        guard let project = store.activeProject else {
            commands = []
            return
        }
        let path = store.effectivePath ?? project.path
        commands = discoverProjectCommands(at: path)
    }

    private func runCommand(_ command: ProjectCommand) {
        let dir = command.workingDirectory ?? store.effectivePath ?? NSHomeDirectory()
        TerminalSessionManager.shared.createSession(
            workingDirectory: dir,
            title: command.name,
            launchCommand: command.command,
            projectID: store.activeProjectID,
            workspaceID: store.activeWorkspaceID
        )
    }
}

// MARK: - Inspector Tab Bar

private struct InspectorTabBar: View {
    @Binding var activeTab: InspectorTab
    private let theme = TerminalAppearanceStore.shared.config.theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    tabCell(tab)
                }
            }
            .frame(height: 32)
            .background(Color(nsColor: theme.chromeBackground))

            // Bottom hairline
            Rectangle()
                .fill(Color(nsColor: theme.chromeBorder))
                .frame(height: 0.5)
        }
    }

    private func tabCell(_ tab: InspectorTab) -> some View {
        InspectorTabCell(
            title: tab.rawValue,
            isActive: activeTab == tab,
            theme: theme,
            onSelect: { activeTab = tab }
        )
    }
}

private struct InspectorTabCell: View {
    let title: String
    let isActive: Bool
    let theme: TerminalTheme
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(Color(nsColor: isActive ? theme.chromePrimaryText : theme.chromeSecondaryText))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(cellBackground)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { onSelect() }
    }

    private var cellBackground: Color {
        if isActive {
            Color(nsColor: theme.chromeActiveBackground)
        } else if isHovered {
            Color(nsColor: theme.chromeHoverBackground)
        } else {
            Color(nsColor: theme.chromeBackground)
        }
    }
}

// MARK: - Commands Drawer

private struct CommandsDrawer: View {
    @Binding var expanded: Bool
    let commands: [ProjectCommand]
    let onRun: (ProjectCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Divider above header
            Rectangle()
                .fill(Color(nsColor: NSColor(white: 1.0, alpha: 0.08)))
                .frame(height: 0.5)

            // Header — always visible, click to toggle
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))

                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Text("Commands")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)

                    if !commands.isEmpty {
                        Text("\(commands.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(3)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expandable command list
            if expanded {
                if commands.isEmpty {
                    Text("No commands found")
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(commands) { command in
                                DrawerCommandRow(command: command, onRun: { onRun(command) })
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 280)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Command Row

private struct DrawerCommandRow: View {
    let command: ProjectCommand
    let onRun: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            Text(command.source.label)
                .font(.system(size: 9))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.white.opacity(0.05))
                .cornerRadius(3)

            Button(action: onRun) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: TerminalAppearanceStore.shared.config.theme.accent))
            }
            .buttonStyle(.borderless)
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isHovered ? Color.white.opacity(0.05) : .clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onRun() }
    }
}
