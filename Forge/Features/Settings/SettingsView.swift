import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Terminal"
    case workspace = "Workspace"
    case agents = "Agents"
    case shortcuts = "Shortcuts"

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "terminal"
        case .workspace: "folder.badge.gearshape"
        case .agents: "cpu"
        case .shortcuts: "keyboard"
        }
    }
}

struct SettingsView: View {
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        HSplitView {
            // Sidebar
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsSidebarRow(
                        section: section,
                        isSelected: selectedSection == section,
                        onSelect: { selectedSection = section }
                    )
                }
                Spacer()
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 220)
            .padding(.top, 12)
            .padding(.horizontal, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedSection {
                    case .general:
                        GeneralSettingsContent()
                    case .appearance:
                        AppearanceSettingsContent()
                    case .workspace:
                        WorkspaceSettingsContent()
                    case .agents:
                        CodingAgentsSettingsContent()
                    case .shortcuts:
                        ShortcutsSettingsContent()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 420)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}

// MARK: - Sidebar Row

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .white : .secondary)
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.8))
                    : nil
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Setting Row Helper

private struct SettingRow<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            content
                .frame(minWidth: 160, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }
}

private struct SettingDivider: View {
    var body: some View {
        Divider()
            .background(Color.white.opacity(0.06))
    }
}

// MARK: - General

private struct GeneralSettingsContent: View {
    @ObservedObject private var appearanceStore = TerminalAppearanceStore.shared
    @State private var showResetConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General")
                .font(.system(size: 20, weight: .bold))
                .padding(.bottom, 20)

            SettingRow(title: "Theme", description: "App-wide color theme.") {
                Picker("", selection: $appearanceStore.config.theme) {
                    ForEach(TerminalTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            SettingDivider()

            SettingRow(title: "Clone directory", description: "Where workspace clones are stored.") {
                HStack(spacing: 6) {
                    Text(abbreviate(ForgeStore.shared.clonesDir.path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button("Open") {
                        NSWorkspace.shared.open(ForgeStore.shared.clonesDir)
                    }
                    .controlSize(.small)
                }
            }

            SettingDivider()

            SettingRow(title: "Data directory", description: "Where Forge stores configuration and state.") {
                HStack(spacing: 6) {
                    Text(abbreviate(dataDir))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button("Open") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: dataDir))
                    }
                    .controlSize(.small)
                }
            }

            SettingDivider()

            SettingRow(title: "Reset settings", description: "Reset all settings to their defaults.") {
                Button("Reset", role: .destructive) {
                    showResetConfirm = true
                }
                .controlSize(.small)
                .alert("Reset all settings?", isPresented: $showResetConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Reset") {
                        TerminalAppearanceStore.shared.config = TerminalAppearanceConfig()
                    }
                } message: {
                    Text("This will delete all Forge settings. Projects and workspaces will not be affected.")
                }
            }

            SettingDivider()

            SettingRow(title: "Version", description: "Current Forge version.") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var dataDir: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".forge").path
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Appearance

private struct AppearanceSettingsContent: View {
    @ObservedObject private var store = TerminalAppearanceStore.shared
    @State private var restoreScrollback: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Terminal")
                .font(.system(size: 20, weight: .bold))
                .padding(.bottom, 20)

            SettingRow(title: "Font", description: "Font family used in terminal sessions.") {
                Picker("", selection: $store.config.font) {
                    ForEach(TerminalFont.allCases, id: \.self) { font in
                        Text(font.displayName).tag(font)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            SettingDivider()

            SettingRow(title: "Font size", description: "Size in points.") {
                HStack(spacing: 8) {
                    Button(action: { if store.config.fontSize > 10 { store.config.fontSize -= 1 } }) {
                        Image(systemName: "minus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("\(Int(store.config.fontSize)) pt")
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 44)

                    Button(action: { if store.config.fontSize < 28 { store.config.fontSize += 1 } }) {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            SettingDivider()

            SettingRow(title: "Line height", description: "Spacing between lines.") {
                HStack(spacing: 8) {
                    Button(action: { if store.config.lineHeightMultiple > 1.0 { store.config.lineHeightMultiple -= 0.1 } }) {
                        Image(systemName: "minus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text(String(format: "%.1f", store.config.lineHeightMultiple))
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 44)

                    Button(action: { if store.config.lineHeightMultiple < 2.0 { store.config.lineHeightMultiple += 0.1 } }) {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            SettingDivider()

            SettingRow(title: "Diff font size", description: "Font size used in the review viewer.") {
                HStack(spacing: 8) {
                    Button(action: { if store.config.diffFontSize > 10 { store.config.diffFontSize -= 1 } }) {
                        Image(systemName: "minus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("\(Int(store.config.diffFontSize)) pt")
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 44)

                    Button(action: { if store.config.diffFontSize < 28 { store.config.diffFontSize += 1 } }) {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            SettingDivider()

            SettingRow(title: "Cursor style", description: "Cursor shape.") {
                Picker("", selection: $store.config.cursorStyle) {
                    ForEach(CursorStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            SettingDivider()

            SettingRow(title: "Cursor blink", description: "Animate the cursor.") {
                Toggle("", isOn: $store.config.cursorBlink)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            SettingDivider()

            SettingRow(title: "Scrollback lines", description: "Maximum lines retained in history.") {
                HStack(spacing: 8) {
                    Button(action: {
                        store.config.scrollbackLines = max(1000, store.config.scrollbackLines - 10000)
                    }) {
                        Image(systemName: "minus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text(formatNumber(store.config.scrollbackLines))
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 52)

                    Button(action: {
                        store.config.scrollbackLines = min(100_000, store.config.scrollbackLines + 10000)
                    }) {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            SettingDivider()

            SettingRow(title: "Restore scrollback", description: "Restore terminal output when reopening a session.") {
                Toggle("", isOn: $restoreScrollback)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: restoreScrollback) { newValue in
                        ForgeStore.shared.updateStateFields { $0.restoreScrollback = newValue }
                    }
            }
        }
        .onAppear {
            restoreScrollback = ForgeStore.shared.loadStateFields().restoreScrollback
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 { return "\(n / 1000)K" }
        return "\(n)"
    }
}

// MARK: - Workspace

private struct WorkspaceSettingsContent: View {
    @State private var workspaceSummariesEnabled: Bool = true
    @State private var summarizerCommand: String = SummaryCommand.defaultCommand
    @State private var debounceTask: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Workspace")
                .font(.system(size: 20, weight: .bold))
                .padding(.bottom, 20)

            SettingRow(title: "Summaries", description: "Summarize workspace activity in the sidebar when agents finish tasks.") {
                Toggle("", isOn: $workspaceSummariesEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: workspaceSummariesEnabled) { newValue in
                        ForgeStore.shared.updateStateFields { $0.workspaceSummariesEnabled = newValue }
                    }
            }

            if workspaceSummariesEnabled {
                SettingDivider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Command")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("", text: $summarizerCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: summarizerCommand) { newValue in
                            debounceTask?.cancel()
                            let task = DispatchWorkItem {
                                ForgeStore.shared.updateStateFields { $0.summarizerCommand = newValue }
                            }
                            debounceTask = task
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
                        }
                    Text("The command receives terminal context via stdin.")
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }
                .padding(.vertical, 10)
            }
        }
        .onAppear {
            let state = ForgeStore.shared.loadStateFields()
            workspaceSummariesEnabled = state.workspaceSummariesEnabled
            summarizerCommand = state.summarizerCommand
        }
    }
}

// MARK: - Agents

private struct CodingAgentsSettingsContent: View {
    @ObservedObject private var store = AgentStore.shared
    @State private var selectedAgentID: UUID?

    private var selectedAgent: AgentConfig? {
        guard let id = selectedAgentID else { return nil }
        return store.agents.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agents")
                .font(.system(size: 20, weight: .bold))
                .padding(.bottom, 20)

            // Agent list
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.agents) { agent in
                    AgentRow(
                        agent: agent,
                        isSelected: selectedAgentID == agent.id,
                        onSelect: { selectedAgentID = agent.id }
                    )
                }
            }
            .padding(.bottom, 8)

            HStack(spacing: 8) {
                Button(action: addAgent) {
                    Label("Add Agent", systemImage: "plus")
                }
                .controlSize(.small)

                Button(action: { store.detectAvailability() }) {
                    Label("Check Availability", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)

                Spacer()

                if selectedAgentID != nil {
                    Button("Remove", role: .destructive) { removeSelectedAgent() }
                        .controlSize(.small)
                }
            }

            // Editor for selected agent
            if let agent = selectedAgent {
                SettingDivider()
                    .padding(.vertical, 8)

                AgentEditorInline(agent: agent) { updated in
                    store.updateAgent(updated)
                }
                .id(agent.id)
            }
        }
        .onAppear {
            if selectedAgentID == nil {
                selectedAgentID = store.agents.first?.id
            }
        }
    }

    private func addAgent() {
        let agent = AgentConfig(name: "New Agent", command: "")
        store.addAgent(agent)
        selectedAgentID = agent.id
    }

    private func removeSelectedAgent() {
        guard let id = selectedAgentID else { return }
        store.deleteAgent(id: id)
        selectedAgentID = store.agents.first?.id
    }
}

private struct AgentRow: View {
    let agent: AgentConfig
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(agent.isInstalled ? Color.green : Color(nsColor: NSColor(white: 0.35, alpha: 1.0)))
                    .frame(width: 7, height: 7)

                AgentIconView(agent: agent)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white : .secondary)
                    .frame(width: 16)

                Text(agent.name)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .white : .primary)

                Spacer()

                Text(agent.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.1))
                    : nil
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AgentEditorInline: View {
    @State private var name: String
    @State private var command: String
    @State private var argsText: String
    @State private var envText: String
    @State private var reviewCommand: String

    private let agentID: UUID
    private let onSave: (AgentConfig) -> Void

    init(agent: AgentConfig, onSave: @escaping (AgentConfig) -> Void) {
        agentID = agent.id
        self.onSave = onSave
        _name = State(initialValue: agent.name)
        _command = State(initialValue: agent.command)
        _argsText = State(initialValue: agent.args.joined(separator: " "))
        _envText = State(initialValue: agent.environmentVars
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n"))
        _reviewCommand = State(initialValue: agent.reviewCommand ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                TextField("Agent name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Command").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                TextField("e.g. claude", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Arguments").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                TextField("e.g. --dangerously-skip-permissions", text: $argsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Environment (KEY=VALUE, one per line)").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                TextEditor(text: $envText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 50)
                    .padding(4)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(4)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Review Command").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Text("Use $REVIEW_FILE as a placeholder for the file path.")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                TextField("e.g. claude $REVIEW_FILE", text: $reviewCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            HStack {
                Spacer()
                Button(action: { save() }) {
                    Text("Save")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func save() {
        let args = argsText.split(separator: " ").map(String.init)
        var envVars: [String: String] = [:]
        for line in envText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIdx])
            let value = String(trimmed[trimmed.index(after: eqIdx)...])
            if !key.isEmpty { envVars[key] = value }
        }
        let rc = reviewCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(AgentConfig(id: agentID, name: name, command: command, args: args, environmentVars: envVars, reviewCommand: rc.isEmpty ? nil : rc))
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsContent: View {
    private let sections: [(String, [(String, String)])] = [
        ("Tabs", [
            ("New Tab", "\u{2318}T"),
            ("Close Tab", "\u{2318}W"),
            ("Tab 1–9", "\u{2318}1–9"),
            ("Previous Tab", "\u{2318}\u{21E7}["),
            ("Next Tab", "\u{2318}\u{21E7}]")
        ]),
        ("Panes", [
            ("Split Vertically", "\u{2318}D"),
            ("Split Horizontally", "\u{2318}\u{21E7}D"),
            ("Close Pane", "\u{2318}\u{2325}W"),
            ("Next Pane", "\u{2318}]"),
            ("Previous Pane", "\u{2318}[")
        ]),
        ("View", [
            ("Toggle Sidebar", "\u{2318}0"),
            ("Toggle Inspector", "\u{2318}\u{2325}0")
        ]),
        ("Other", [
            ("Open Project", "\u{2318}\u{21E7}O"),
            ("Settings", "\u{2318},")
        ])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Shortcuts")
                .font(.system(size: 20, weight: .bold))
                .padding(.bottom, 20)

            ForEach(sections, id: \.0) { section in
                Text(section.0)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, section.0 == sections.first?.0 ? 0 : 16)
                    .padding(.bottom, 8)

                ForEach(section.1, id: \.0) { shortcut in
                    HStack {
                        Text(shortcut.0)
                            .font(.system(size: 13))
                        Spacer()
                        Text(shortcut.1)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(4)
                    }
                    .padding(.vertical, 6)

                    if shortcut.0 != section.1.last?.0 {
                        SettingDivider()
                    }
                }
            }
        }
    }
}
