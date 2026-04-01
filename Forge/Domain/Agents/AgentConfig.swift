import Foundation

struct AgentProjectOverride: Codable, Equatable {
    var args: [String]?
    var environmentVars: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case args
        case environmentVars = "env"
    }
}

struct AgentConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var command: String
    var args: [String]
    var environmentVars: [String: String]

    /// Command template for launching with a review file. Use $REVIEW_FILE as placeholder.
    var reviewCommand: String?

    /// Per-project overrides, keyed by project UUID string.
    var overrides: [String: AgentProjectOverride]

    /// Runtime-only: whether the command was found on PATH. Not persisted.
    var isInstalled: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, name, command, args, reviewCommand, overrides
        case environmentVars = "env"
    }

    /// Image name for agent icon. Known agents use bundled images, others get SF Symbols.
    var icon: String {
        switch command {
        case "claude": "AgentIcons/claude-code"
        case "codex": "AgentIcons/codex"
        case "gemini": "AgentIcons/gemini-cli"
        case "amp": "AgentIcons/amp"
        case "cline": "AgentIcons/cline"
        case "pi": "AgentIcons/pi"
        case "opencode": "sf:brain"
        default: "sf:terminal"
        }
    }

    /// Whether the icon is an SF Symbol (prefixed with "sf:") or a bundled image asset.
    var isSFSymbol: Bool {
        icon.hasPrefix("sf:")
    }

    /// The resolved name for use with NSImage/Image — strips "sf:" prefix if present.
    var iconName: String {
        isSFSymbol ? String(icon.dropFirst(3)) : icon
    }

    var fullCommand: String {
        var parts: [String] = []
        for (key, value) in environmentVars.sorted(by: { $0.key < $1.key }) {
            // Single-quote values that contain special shell characters
            if value.contains(" ") || value.contains("{") || value.contains("\"") || value.contains("$") {
                parts.append("\(key)='\(value)'")
            } else {
                parts.append("\(key)=\(value)")
            }
        }
        parts.append(command)
        parts.append(contentsOf: args)
        return parts.joined(separator: " ")
    }

    /// Builds the review launch command, substituting $REVIEW_FILE with the actual path.
    func reviewLaunchCommand(reviewFilePath: String) -> String {
        if let template = reviewCommand, !template.isEmpty {
            return template.replacingOccurrences(of: "$REVIEW_FILE", with: reviewFilePath)
        }
        return fullCommand
    }

    init(id: UUID = UUID(), name: String, command: String, args: [String] = [], environmentVars: [String: String] = [:], reviewCommand: String? = nil, overrides: [String: AgentProjectOverride] = [:]) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.environmentVars = environmentVars
        self.reviewCommand = reviewCommand
        self.overrides = overrides
    }

    /// Returns a copy with per-project overrides merged in.
    func applying(projectID: UUID) -> AgentConfig {
        guard let override = overrides[projectID.uuidString] else { return self }
        var merged = self
        if let overrideArgs = override.args {
            merged.args = overrideArgs
        }
        if let overrideEnv = override.environmentVars {
            merged.environmentVars.merge(overrideEnv) { _, new in new }
        }
        return merged
    }
}

import AppKit
import SwiftUI

extension AgentConfig {
    /// Returns an NSImage for the agent icon (either bundled asset or SF Symbol), sized appropriately.
    func nsImage(size: CGFloat = 16) -> NSImage? {
        if isSFSymbol {
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            return NSImage(systemSymbolName: iconName, accessibilityDescription: name)?
                .withSymbolConfiguration(config)
        } else {
            guard let original = NSImage(named: iconName) else { return nil }
            let target = NSSize(width: size, height: size)
            let resized = NSImage(size: target)
            resized.lockFocus()
            original.draw(in: NSRect(origin: .zero, size: target),
                          from: NSRect(origin: .zero, size: original.size),
                          operation: .copy, fraction: 1.0)
            resized.unlockFocus()
            return resized
        }
    }
}

/// SwiftUI view that renders an agent icon at the given size.
struct AgentIconView: View {
    let agent: AgentConfig
    var size: CGFloat = 14

    var body: some View {
        if agent.isSFSymbol {
            Image(systemName: agent.iconName)
                .font(.system(size: size))
        } else {
            Image(agent.iconName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}
