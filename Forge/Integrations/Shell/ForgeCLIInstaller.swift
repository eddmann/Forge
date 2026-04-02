import Foundation

enum ForgeCLIInstaller {
    static let symlinkPath = "/usr/local/bin/forge"

    /// Path to the `forge` binary inside the running app bundle.
    static var bundledBinaryPath: String? {
        Bundle.main.resourceURL?
            .appendingPathComponent("bin/forge").path
    }

    /// Ensure `/usr/local/bin/forge` is a symlink pointing to this app's bundled binary.
    static func ensureInstalled() {
        guard let bundledPath = bundledBinaryPath else { return }

        let fm = FileManager.default

        // Check if symlink already points to the right place
        if let destination = try? fm.destinationOfSymbolicLink(atPath: symlinkPath),
           destination == bundledPath
        {
            return
        }

        // Remove whatever is there (stale symlink, regular file, etc.)
        try? fm.removeItem(atPath: symlinkPath)

        // Try unprivileged first (works if user owns /usr/local/bin, e.g. Homebrew)
        do {
            try fm.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: bundledPath)
            return
        } catch {}

        // Escalate via osascript (triggers macOS admin auth dialog)
        let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf \(bundledPath.shellEscaped) \(symlinkPath.shellEscaped)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}

private extension String {
    /// Escape a string for use inside an AppleScript double-quoted string.
    var shellEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
