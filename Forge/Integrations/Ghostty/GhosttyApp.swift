import AppKit

/// Singleton managing the Ghostty terminal runtime lifecycle.
class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    /// Coalesce wakeup → tick dispatches. The I/O thread may fire wakeup_cb
    /// thousands of times per second during bulk output. Only one pending tick needed.
    private var _tickScheduled = false
    private let _tickLock = NSLock()

    private var appObservers: [NSObjectProtocol] = []

    /// Path where Forge writes its theme overrides for Ghostty.
    private static let themeConfigPath: String = {
        let dir = NSHomeDirectory() + "/.forge/state"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/ghostty.conf"
    }()

    private init() {
        initializeGhostty()
    }

    // MARK: - Initialization

    private func initializeGhostty() {
        if getenv("NO_COLOR") != nil {
            unsetenv("NO_COLOR")
        }

        // Set GHOSTTY_RESOURCES_DIR so Ghostty can find terminfo, themes, shell integration
        configureGhosttyResources()

        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if result != GHOSTTY_SUCCESS {
            print("[Forge] Failed to initialize ghostty: \(result)")
            return
        }

        guard let primaryConfig = ghostty_config_new() else {
            print("[Forge] Failed to create ghostty config")
            return
        }

        // Load user's ghostty config, then overlay Forge theme
        ghostty_config_load_default_files(primaryConfig)
        ghostty_config_load_recursive_files(primaryConfig)
        writeForgeThemeConfig()
        Self.themeConfigPath.withCString { path in
            ghostty_config_load_file(primaryConfig, path)
        }
        ghostty_config_finalize(primaryConfig)

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false

        runtimeConfig.wakeup_cb = ghosttyWakeupCallback
        runtimeConfig.action_cb = ghosttyActionCallback
        runtimeConfig.read_clipboard_cb = ghosttyReadClipboardCallback
        runtimeConfig.confirm_read_clipboard_cb = ghosttyConfirmReadClipboardCallback
        runtimeConfig.write_clipboard_cb = ghosttyWriteClipboardCallback
        runtimeConfig.close_surface_cb = ghosttyCloseSurfaceCallback

        if let created = ghostty_app_new(&runtimeConfig, primaryConfig) {
            app = created
            config = primaryConfig
        } else {
            ghostty_config_free(primaryConfig)
            guard let fallbackConfig = ghostty_config_new() else {
                print("[Forge] Failed to create ghostty fallback config")
                return
            }
            ghostty_config_finalize(fallbackConfig)
            guard let created = ghostty_app_new(&runtimeConfig, fallbackConfig) else {
                print("[Forge] Failed to create ghostty app")
                ghostty_config_free(fallbackConfig)
                return
            }
            app = created
            config = fallbackConfig
        }

        if let app {
            ghostty_app_set_focus(app, NSApp.isActive)
        }

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })
    }

    // MARK: - Ghostty Resources

    private func configureGhosttyResources() {
        let fileManager = FileManager.default

        guard getenv("GHOSTTY_RESOURCES_DIR") == nil else { return }

        // Check for bundled resources first
        if let bundledURL = Bundle.main.resourceURL?.appendingPathComponent("ghostty"),
           fileManager.fileExists(atPath: bundledURL.path)
        {
            setenv("GHOSTTY_RESOURCES_DIR", bundledURL.path, 1)
        }
        // Fall back to standalone Ghostty.app resources
        else if fileManager.fileExists(atPath: "/Applications/Ghostty.app/Contents/Resources/ghostty") {
            setenv("GHOSTTY_RESOURCES_DIR", "/Applications/Ghostty.app/Contents/Resources/ghostty", 1)
        }

        // Set TERM defaults
        if getenv("TERM") == nil {
            setenv("TERM", "xterm-ghostty", 1)
        }
        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", "ghostty", 1)
        }
    }

    // MARK: - Tick

    func scheduleTick() {
        _tickLock.lock()
        defer { _tickLock.unlock() }
        guard !_tickScheduled else { return }
        _tickScheduled = true
        DispatchQueue.main.async { self.tick() }
    }

    private func tick() {
        _tickLock.lock()
        _tickScheduled = false
        _tickLock.unlock()
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Action Handler

    func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT,
             GHOSTTY_ACTION_GOTO_SPLIT,
             GHOSTTY_ACTION_CLOSE_TAB,
             GHOSTTY_ACTION_CLOSE_WINDOW,
             GHOSTTY_ACTION_NEW_TAB,
             GHOSTTY_ACTION_NEW_WINDOW:
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            if target.tag == GHOSTTY_TARGET_SURFACE {
                let userdata = ghostty_surface_userdata(target.target.surface)
                if let ptr = userdata {
                    let ctx = Unmanaged<GhosttySurfaceContext>.fromOpaque(ptr).takeUnretainedValue()
                    let title = String(cString: action.action.set_title.title)
                    DispatchQueue.main.async {
                        AgentDetector.shared.handleTitleChange(sessionID: ctx.sessionID, title: title)
                    }
                }
            }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // Notifications handled via ForgeSocketServer + forge CLI.
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // Child process exited — close the surface immediately instead of
            // showing "Press any key to close". Must be async to avoid re-entrant
            // close while Ghostty is still dispatching this action callback.
            DispatchQueue.main.async {
                // Trigger close via the surface's callback context
                ghosttyCloseSurfaceCallback(
                    ghostty_surface_userdata(target.target.surface),
                    false
                )
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true
        default:
            return false
        }
    }

    // MARK: - Theme

    /// Write Forge's current theme as a Ghostty config file so it can be loaded
    /// via `ghostty_config_load_file()`.
    func writeForgeThemeConfig() {
        let config = TerminalAppearanceStore.shared.config
        let theme = config.theme
        let ansiColors = theme.ansiColorTuples

        var lines: [String] = []

        // Font
        lines.append("font-family = \(config.font.fontName)")
        lines.append("font-size = \(Int(config.fontSize))")

        // Line height: convert multiplier to percentage adjustment for Ghostty
        let lineHeightPercent = Int((config.lineHeightMultiple - 1.0) * 100)
        if lineHeightPercent != 0 {
            lines.append("adjust-cell-height = \(lineHeightPercent)%")
        }

        // Core colors
        lines.append("background = \(hexString(theme.background))")
        lines.append("foreground = \(hexString(theme.foreground))")
        lines.append("cursor-color = \(hexString(theme.cursor))")
        lines.append("cursor-text = \(hexString(theme.cursorText))")

        // Selection colors
        lines.append("selection-background = \(hexString(theme.selectionBackground))")
        lines.append("selection-foreground = \(hexString(theme.selectionForeground))")

        // Background opacity
        lines.append("background-opacity = \(String(format: "%.2f", config.backgroundOpacity))")

        // Cursor
        lines.append("cursor-style = \(config.cursorStyle.ghosttyValue)")
        lines.append("cursor-style-blink = \(config.cursorBlink)")

        // ANSI palette (0-15)
        for (i, color) in ansiColors.enumerated() {
            lines.append("palette = \(i)=\(String(format: "#%02x%02x%02x", color.r, color.g, color.b))")
        }

        // Split pane styling
        lines.append("unfocused-split-opacity = \(String(format: "%.2f", config.unfocusedSplitOpacity))")

        // Scrollback
        lines.append("scrollback-limit = \(config.scrollbackLines)")

        // Window padding
        lines.append("window-padding-x = \(config.windowPadding)")
        lines.append("window-padding-y = \(config.windowPadding)")

        // UX behavior
        lines.append("mouse-hide-while-typing = \(config.mouseHideWhileTyping)")
        lines.append("copy-on-select = \(config.copyOnSelect ? "clipboard" : "false")")
        lines.append("macos-option-as-alt = \(config.optionAsAlt)")
        lines.append("shell-integration = detect")

        // Forge manages its own window chrome and tab lifecycle
        lines.append("window-decoration = none")
        lines.append("macos-titlebar-style = hidden")
        lines.append("confirm-close-surface = false")
        lines.append("quit-after-last-window-closed = false")

        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(toFile: Self.themeConfigPath, atomically: true, encoding: .utf8)
    }

    func reloadAppearance() {
        guard let app, let oldConfig = config else { return }
        guard let newConfig = ghostty_config_new() else { return }
        ghostty_config_load_default_files(newConfig)
        ghostty_config_load_recursive_files(newConfig)
        writeForgeThemeConfig()
        Self.themeConfigPath.withCString { path in
            ghostty_config_load_file(newConfig, path)
        }
        ghostty_config_finalize(newConfig)
        ghostty_app_update_config(app, newConfig)
        ghostty_config_free(oldConfig)
        config = newConfig
    }

    private func hexString(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x",
                      Int(rgb.redComponent * 255),
                      Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }
}

// MARK: - C-compatible Ghostty Callbacks (must be non-capturing top-level functions)

private func ghosttyWakeupCallback(_: UnsafeMutableRawPointer?) {
    GhosttyApp.shared.scheduleTick()
}

private func ghosttyActionCallback(_: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    GhosttyApp.shared.handleAction(target: target, action: action)
}

private func ghosttyReadClipboardCallback(_ userdata: UnsafeMutableRawPointer?, _: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async {
        let pb = NSPasteboard.general
        let text = pb.string(forType: .string) ?? ""
        guard let userdata else { return }
        let context = Unmanaged<GhosttySurfaceContext>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = context.surface else { return }
        text.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
    }
}

private func ghosttyConfirmReadClipboardCallback(_ userdata: UnsafeMutableRawPointer?, _ content: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?, _: ghostty_clipboard_request_e) {
    guard let content, let userdata else { return }
    let context = Unmanaged<GhosttySurfaceContext>.fromOpaque(userdata).takeUnretainedValue()
    guard let surface = context.surface else { return }
    ghostty_surface_complete_clipboard_request(surface, content, state, true)
}

private func ghosttyWriteClipboardCallback(_: UnsafeMutableRawPointer?, _: ghostty_clipboard_e, _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ len: Int, _: Bool) {
    guard let content, len > 0 else { return }
    let buffer = UnsafeBufferPointer(start: content, count: Int(len))
    var text: String?
    for item in buffer {
        guard let dataPtr = item.data else { continue }
        let value = String(cString: dataPtr)
        if let mimePtr = item.mime {
            let mime = String(cString: mimePtr)
            if mime.hasPrefix("text/plain") {
                text = value
                break
            }
        }
        if text == nil { text = value }
    }
    if let text {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

private func ghosttyCloseSurfaceCallback(_ userdata: UnsafeMutableRawPointer?, _: Bool) {
    guard let userdata else { return }
    let context = Unmanaged<GhosttySurfaceContext>.fromOpaque(userdata).takeUnretainedValue()
    let sessionID = context.sessionID
    DispatchQueue.main.async {
        context.onProcessExit?(sessionID)
    }
}

// MARK: - Surface Callback Context

class GhosttySurfaceContext {
    let sessionID: UUID
    weak var view: GhosttyTerminalView?
    var surface: ghostty_surface_t?
    var onProcessExit: ((UUID) -> Void)?

    init(sessionID: UUID, view: GhosttyTerminalView) {
        self.sessionID = sessionID
        self.view = view
    }
}
