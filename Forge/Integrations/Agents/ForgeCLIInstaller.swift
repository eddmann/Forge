import AppKit

enum ForgeCLIInstaller {
    private static let destinationPath = "/usr/local/bin/forge"

    /// Path to the forge CLI bundled inside the app.
    static var bundledCLIPath: String? {
        Bundle.main.resourceURL?
            .appendingPathComponent("bin/forge").path
    }

    static func isInstalled() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destinationPath) else { return false }
        // Check if it's a symlink pointing to our bundled CLI
        guard let target = try? fm.destinationOfSymbolicLink(atPath: destinationPath),
              let bundled = bundledCLIPath else { return false }
        return target == bundled
    }

    /// Prompt to install if not already present. Call once at app startup.
    static func installIfNeeded() {
        guard !isInstalled(), bundledCLIPath != nil else { return }

        let alert = NSAlert()
        alert.messageText = "Install Forge CLI?"
        alert.informativeText = "Forge can install a command-line tool at /usr/local/bin/forge so agent hooks can communicate with the app.\n\nThis creates a symlink to the CLI bundled inside Forge.app."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        install()
    }

    static func install() {
        guard let source = bundledCLIPath else { return }
        let fm = FileManager.default

        // Ensure /usr/local/bin exists
        let parentDir = (destinationPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parentDir) {
            try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        // Remove existing file/symlink
        if fm.fileExists(atPath: destinationPath) {
            try? fm.removeItem(atPath: destinationPath)
        }

        do {
            try fm.createSymbolicLink(atPath: destinationPath, withDestinationPath: source)
        } catch {
            // If permission denied, try with privilege escalation
            let script = "/bin/mkdir -p \(parentDir) && /bin/ln -sf \(source) \(destinationPath)"
            let appleScript = "do shell script \"\(script)\" with administrator privileges"
            var errorInfo: NSDictionary?
            NSAppleScript(source: appleScript)?.executeAndReturnError(&errorInfo)
        }
    }
}
