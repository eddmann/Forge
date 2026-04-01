import SwiftUI

enum AgentInfoCategory {
    case mcps([MCPServerInfo])
    case skills([AgentSkillInfo])
    case plugins([AgentPluginInfo])
    case instructions([AgentInstructions])

    var title: String {
        switch self {
        case .mcps: "MCP Servers"
        case .skills: "Skills"
        case .plugins: "Plugins"
        case .instructions: "Instructions"
        }
    }

    var iconName: String {
        switch self {
        case .mcps: "server.rack"
        case .skills: "command"
        case .plugins: "puzzlepiece"
        case .instructions: "doc.text"
        }
    }
}

/// A file to preview (skill or instruction).
private struct FileDetail: Equatable {
    let name: String
    let filePath: String

    static func == (lhs: FileDetail, rhs: FileDetail) -> Bool {
        lhs.filePath == rhs.filePath
    }
}

struct AgentInfoPopoverView: View {
    let category: AgentInfoCategory
    /// When true and there's exactly one previewable item, jump straight to detail.
    var startInDetail: Bool = false

    @State private var detail: FileDetail?
    @State private var detailContent: String = ""

    private var dimText: Color {
        Color(nsColor: .tertiaryLabelColor)
    }

    var body: some View {
        ZStack {
            // List view — hidden when showing detail
            if detail == nil {
                listView
                    .transition(.move(edge: .leading))
            }

            // Detail view — slides in from right
            if let detail {
                detailView(detail)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: detail)
        .clipped()
        .onAppear {
            if startInDetail {
                autoNavigateToSingleItem()
            }
        }
    }

    // MARK: - List

    private var listView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: category.iconName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text(category.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch category {
                    case let .mcps(servers):
                        ForEach(servers) { server in
                            mcpRow(server)
                        }
                    case let .skills(skills):
                        ForEach(skills) { skill in
                            skillRow(skill)
                        }
                    case let .plugins(plugins):
                        ForEach(plugins) { plugin in
                            pluginRow(plugin)
                        }
                    case let .instructions(instructions):
                        ForEach(Array(instructions.enumerated()), id: \.offset) { _, inst in
                            instructionRow(inst)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 280)
    }

    // MARK: - Detail

    private func detailView(_ file: FileDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with back button
            HStack(spacing: 4) {
                Button {
                    detail = nil
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text(category.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Text(file.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 8)

            ScrollView {
                Text(detailContent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 400)
        }
        .frame(width: 340)
    }

    // MARK: - Navigate

    private func navigateTo(name: String, filePath: String) {
        detailContent = (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? "(unable to read file)"
        detail = FileDetail(name: name, filePath: filePath)
    }

    private func autoNavigateToSingleItem() {
        switch category {
        case let .skills(skills) where skills.count == 1:
            navigateTo(name: skills[0].name, filePath: skills[0].filePath)
        case let .instructions(instructions) where instructions.count == 1:
            navigateTo(name: instructions[0].fileName, filePath: instructions[0].filePath)
        default:
            break
        }
    }

    // MARK: - Rows

    private func mcpRow(_ server: MCPServerInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(server.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Text(server.type.rawValue)
                    .font(.system(size: 10))
                    .foregroundColor(dimText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: .quaternaryLabelColor))
                    .cornerRadius(3)
                scopeBadge(server.scope)
            }
            Text(server.commandOrURL)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(dimText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func skillRow(_ skill: AgentSkillInfo) -> some View {
        Button {
            navigateTo(name: skill.name, filePath: skill.filePath)
        } label: {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    if let desc = skill.description {
                        Text(desc)
                            .font(.system(size: 10))
                            .foregroundColor(dimText)
                            .lineLimit(1)
                    }
                }
                Spacer()
                scopeBadge(skill.scope)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(dimText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pluginRow(_ plugin: AgentPluginInfo) -> some View {
        HStack(spacing: 4) {
            Text(plugin.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
            Spacer()
            if let version = plugin.version {
                Text(version)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(dimText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func instructionRow(_ inst: AgentInstructions) -> some View {
        Button {
            navigateTo(name: inst.fileName, filePath: inst.filePath)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(dimText)
                Text(inst.fileName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(dimText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func scopeBadge(_ scope: CapabilityScope) -> some View {
        Text(scope.rawValue)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(dimText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color(nsColor: .quaternaryLabelColor))
            .cornerRadius(3)
    }
}
