import AppKit
import QuartzCore
import UniformTypeIdentifiers

/// NSView subclass hosting a Ghostty terminal surface via CAMetalLayer.
class GhosttyTerminalView: NSView, NSTextInputClient {
    var sessionID: UUID?
    var onProcessExit: ((UUID) -> Void)?

    private var surface: ghostty_surface_t?
    private var surfaceContext: Unmanaged<GhosttySurfaceContext>?
    private var hasStartedProcess = false

    /// Whether a live Ghostty surface exists (for debug/snapshot checks).
    var hasSurface: Bool {
        surface != nil
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        let safeFrame = frameRect.width > 0 && frameRect.height > 0
            ? frameRect
            : CGRect(x: 0, y: 0, width: 600, height: 400)
        super.init(frame: safeFrame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        updateTrackingAreas()
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Layer

    override var wantsUpdateLayer: Bool {
        true
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    // MARK: - Shell Startup

    func startShell(in directory: String, sessionID: UUID? = nil, additionalEnv: [String: String] = [:]) {
        guard !hasStartedProcess else { return }
        hasStartedProcess = true

        var env = ShellEnvironment.buildEnvironment(sessionID: sessionID)
        env["TERM"] = "xterm-ghostty"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ghostty"
        for (key, value) in additionalEnv {
            env[key] = value
        }

        createSurface(command: nil, directory: directory, env: env)
    }

    // MARK: - Scrollback Capture

    /// Read terminal scrollback text from the Ghostty surface.
    /// Tries VT export first (preserves ANSI colors/formatting), falls back to plain text.
    /// Returns up to `lineLimit` lines of text from the terminal history.
    func captureScrollback(lineLimit: Int = 4000) -> String? {
        guard let surface else { return nil }

        // Try VT export first — preserves ANSI colors and escape sequences
        if let vtOutput = captureVTExport(lineLimit: lineLimit) {
            return vtOutput
        }

        // Fallback: plain text via Ghostty API (no colors)
        return capturePlainText(surface: surface, lineLimit: lineLimit)
    }

    /// VT export via Ghostty binding — preserves ANSI colors/formatting.
    /// Ghostty writes terminal history to a temp file, copies path to pasteboard.
    private func captureVTExport(lineLimit: Int) -> String? {
        guard let surface else { return nil }

        let pasteboard = NSPasteboard.general

        // Save pasteboard state so we can restore it
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        } ?? []
        let initialChangeCount = pasteboard.changeCount

        // Trigger VT export
        let action = "write_screen_file:copy,vt"
        let success = action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
        guard success, pasteboard.changeCount != initialChangeCount else { return nil }

        // Read exported file path from pasteboard
        guard let exportedPath = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !exportedPath.isEmpty
        else {
            return nil
        }

        // Restore pasteboard
        pasteboard.clearContents()
        for (type, data) in savedItems {
            pasteboard.setData(data, forType: type)
        }

        // Read and clean up the exported file
        let fileURL = URL(fileURLWithPath: exportedPath)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        guard let data = try? Data(contentsOf: fileURL),
              var output = String(data: data, encoding: .utf8),
              !output.isEmpty
        else {
            return nil
        }

        // Truncate to last `lineLimit` lines
        let lines = output.components(separatedBy: "\n")
        if lines.count > lineLimit {
            output = lines.suffix(lineLimit).joined(separator: "\n")
        }

        return output
    }

    /// Plain text fallback — queries multiple Ghostty point tags, picks the best.
    private func capturePlainText(surface: ghostty_surface_t, lineLimit: Int) -> String? {
        let screen = readSurfaceText(surface, pointTag: GHOSTTY_POINT_SCREEN)
        let history = readSurfaceText(surface, pointTag: GHOSTTY_POINT_SURFACE)
        let active = readSurfaceText(surface, pointTag: GHOSTTY_POINT_ACTIVE)

        var candidates: [String] = []
        if let screen, !screen.isEmpty { candidates.append(screen) }
        if history != nil || active != nil {
            var merged = history ?? ""
            if let active, !active.isEmpty {
                if !merged.isEmpty, !merged.hasSuffix("\n") {
                    merged.append("\n")
                }
                merged.append(active)
            }
            if !merged.isEmpty { candidates.append(merged) }
        }

        guard var output = candidates.max(by: {
            $0.components(separatedBy: "\n").count < $1.components(separatedBy: "\n").count
        }) else { return nil }

        let lines = output.components(separatedBy: "\n")
        if lines.count > lineLimit {
            output = lines.suffix(lineLimit).joined(separator: "\n")
        }

        return output.isEmpty ? nil : output
    }

    private func readSurfaceText(_ surface: ghostty_surface_t, pointTag: ghostty_point_tag_e) -> String? {
        let topLeft = ghostty_point_s(tag: pointTag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let bottomRight = ghostty_point_s(tag: pointTag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        let selection = ghostty_selection_s(top_left: topLeft, bottom_right: bottomRight, rectangle: false)

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return String(bytes: Data(bytes: ptr, count: Int(text.text_len)), encoding: .utf8) ?? ""
    }

    // MARK: - Surface Creation

    private func createSurface(command: String?, directory: String, env: [String: String]) {
        guard let app = GhosttyApp.shared.app else {
            print("[Forge] Ghostty app not initialized")
            return
        }

        guard let sid = sessionID else { return }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )

        // Set up callback context
        let context = GhosttySurfaceContext(sessionID: sid, view: self)
        context.onProcessExit = onProcessExit
        let unmanagedContext = Unmanaged.passRetained(context)
        surfaceConfig.userdata = unmanagedContext.toOpaque()
        surfaceContext?.release()
        surfaceContext = unmanagedContext

        // Scale factor
        let scaleFactor = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        surfaceConfig.scale_factor = scaleFactor
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        surfaceConfig.wait_after_command = false

        // Environment variables
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        for (key, value) in env {
            guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
            envStorage.append((keyPtr, valuePtr))
            envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
        }

        // Create surface with command and working directory kept alive during the call
        let envVarCount = envVars.count

        let doCreate = { (cmdPtr: UnsafePointer<CChar>?) in
            directory.withCString { dirPtr in
                surfaceConfig.command = cmdPtr
                surfaceConfig.working_directory = dirPtr

                if !envVars.isEmpty {
                    envVars.withUnsafeMutableBufferPointer { buffer in
                        surfaceConfig.env_vars = buffer.baseAddress
                        surfaceConfig.env_var_count = envVarCount
                        self.surface = ghostty_surface_new(app, &surfaceConfig)
                    }
                } else {
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            }
        }

        if let command {
            command.withCString { doCreate($0) }
        } else {
            doCreate(nil)
        }

        context.surface = surface

        // Clean up env C strings
        for (key, value) in envStorage {
            free(key)
            free(value)
        }

        // Set initial size
        if let surface, bounds.width > 0, bounds.height > 0 {
            let scale = window?.backingScaleFactor ?? 2.0
            let w = UInt32(bounds.width * scale)
            let h = UInt32(bounds.height * scale)
            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(surface, w, h)

            if let screen = window?.screen {
                ghostty_surface_set_display_id(surface, screen.displayID)
            }

            ghostty_surface_refresh(surface)
        }
    }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        if let screen = window.screen {
            ghostty_surface_set_display_id(surface, screen.displayID)
        }
        updateSurfaceSize()
    }

    override func layout() {
        super.layout()
        updateSurfaceSize()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let w = UInt32(bounds.width * scale)
        let h = UInt32(bounds.height * scale)
        ghostty_surface_set_size(surface, w, h)
    }

    func terminate() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        surfaceContext?.release()
        surfaceContext = nil
    }

    deinit {
        terminate()
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    // MARK: - Copy & Paste

    @objc func copy(_: Any?) {
        guard let surface else { return }
        "copy_to_clipboard".withCString { cString in
            _ = ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    @objc func paste(_: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        sendInput(text)
    }

    // MARK: - Output: Write Directly to Terminal Display

    /// Write text directly to the terminal display without going through the shell.
    /// The text appears as terminal output (not as a typed command).
    /// Supports ANSI escape sequences for colors and formatting.
    func writeOutput(_ text: String) {
        guard let surface else { return }
        let data = Array(text.utf8)
        data.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            ptr.withMemoryRebound(to: CChar.self, capacity: buf.count) { cPtr in
                ghostty_surface_process_output(surface, cPtr, UInt(buf.count))
            }
        }
    }

    // MARK: - Input: Send Text

    func sendInput(_ text: String) {
        guard let surface else { return }
        var bufferedText = ""
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A: // \n — skip if preceded by \r (already sent Return)
                if !previousWasCR {
                    flushTextBuffer(&bufferedText, to: surface)
                    sendKeyEvent(to: surface, keycode: 0x24) // kVK_Return
                }
                previousWasCR = false
            case 0x0D: // \r
                flushTextBuffer(&bufferedText, to: surface)
                sendKeyEvent(to: surface, keycode: 0x24) // kVK_Return
                previousWasCR = true
            case 0x09: // \t
                flushTextBuffer(&bufferedText, to: surface)
                sendKeyEvent(to: surface, keycode: 0x30) // kVK_Tab
                previousWasCR = false
            case 0x1B: // Escape
                flushTextBuffer(&bufferedText, to: surface)
                sendKeyEvent(to: surface, keycode: 0x35) // kVK_Escape
                previousWasCR = false
            default:
                bufferedText.unicodeScalars.append(scalar)
                previousWasCR = false
            }
        }
        flushTextBuffer(&bufferedText, to: surface)
    }

    private func flushTextBuffer(_ buffer: inout String, to surface: ghostty_surface_t) {
        guard !buffer.isEmpty else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 0
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        buffer.withCString { ptr in
            keyEvent.text = ptr
            _ = ghostty_surface_key(surface, keyEvent)
        }
        buffer.removeAll(keepingCapacity: true)
    }

    private func sendKeyEvent(to surface: ghostty_surface_t, keycode: UInt32) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keycode
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
    }

    // MARK: - Keyboard Input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // For Cmd-modified keys, let the main menu handle them first.
        // This ensures Cmd+T (new tab), Cmd+W (close), etc. work even
        // when the terminal is first responder.
        if flags.contains(.command) {
            if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
                return true
            }
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd-modified keys: handle known terminal bindings, drop the rest (menu shortcuts)
        if flags.contains(.command) {
            switch event.keyCode {
            case 123: // Cmd+Left — move to beginning of line (send Ctrl+A)
                sendInput("\u{01}")
                return
            case 124: // Cmd+Right — move to end of line (send Ctrl+E)
                sendInput("\u{05}")
                return
            default:
                break
            }
            if let key = event.charactersIgnoringModifiers {
                switch key {
                case "\u{7F}": // Cmd+Delete — kill line (send Ctrl+U)
                    sendInput("\u{15}")
                    return
                default:
                    break
                }
            }
            return
        }

        // Fast path for Ctrl keys — bypass text interpretation
        if flags.contains(.control), !flags.contains(.command), !flags.contains(.option) {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = unshiftedCodepoint(event)

            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            if text.isEmpty {
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)
            } else {
                text.withCString { ptr in
                    keyEvent.text = ptr
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            }
            return
        }

        // General key event — use interpretKeyEvents for IME/dead key support
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([event])

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = consumedMods(event)
        keyEvent.composing = hasMarkedText()
        keyEvent.unshifted_codepoint = unshiftedCodepoint(event)

        let accumulated = keyTextAccumulator?.joined() ?? ""
        if accumulated.isEmpty {
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        } else {
            accumulated.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false
        keyEvent.text = nil
        keyEvent.unshifted_codepoint = 0
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false
        keyEvent.text = nil
        keyEvent.unshifted_codepoint = 0
        _ = ghostty_surface_key(surface, keyEvent)
    }

    // MARK: - Text Input Protocol

    private var keyTextAccumulator: [String]?
    private var markedText = NSMutableAttributedString()
    private var _markedRange = NSRange(location: NSNotFound, length: 0)
    private var _selectedRange = NSRange(location: 0, length: 0)

    func insertText(_ string: Any, replacementRange _: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let s = string as? NSAttributedString { text = s.string }
        else { return }

        keyTextAccumulator?.append(text)

        // Clear marked text
        markedText = NSMutableAttributedString()
        _markedRange = NSRange(location: NSNotFound, length: 0)

        if let surface {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange _: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let s = string as? NSAttributedString { text = s.string }
        else { return }

        markedText = NSMutableAttributedString(string: text)
        _markedRange = NSRange(location: 0, length: text.count)
        _selectedRange = selectedRange

        if let surface {
            if text.isEmpty {
                ghostty_surface_preedit(surface, nil, 0)
            } else {
                let utf8 = Array(text.utf8)
                utf8.withUnsafeBufferPointer { buffer in
                    ghostty_surface_preedit(surface, buffer.baseAddress, UInt(buffer.count))
                }
            }
        }
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        _markedRange = NSRange(location: NSNotFound, length: 0)
        if let surface {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        _markedRange
    }

    func selectedRange() -> NSRange {
        _selectedRange
    }

    func attributedSubstring(forProposedRange _: NSRange, actualRange _: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let local = NSRect(x: x, y: bounds.height - y - h, width: w, height: h)
        return window?.convertToScreen(convert(local, to: nil)) ?? local
    }

    func characterIndex(for _: NSPoint) -> Int {
        0
    }

    override func doCommand(by _: Selector) {
        // Intentionally empty. The key event is already forwarded to the
        // Ghostty surface via ghostty_surface_key. Swallowing the command
        // here prevents AppKit from calling NSBeep() for unhandled
        // selectors like deleteBackward:.
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else {
            super.rightMouseDown(with: event)
            return
        }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }

        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods |= 0b0000_0001 }
        let momentum = event.momentumPhase
        if momentum == .began { mods |= (1 << 1) }
        else if momentum == .stationary { mods |= (2 << 1) }
        else if momentum == .changed { mods |= (3 << 1) }
        else if momentum == .ended { mods |= (4 << 1) }
        else if momentum == .cancelled { mods |= (5 << 1) }
        else if momentum == .mayBegin { mods |= (6 << 1) }

        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }

        let paths = urls.map { url in
            let path = url.path
            // Shell-escape paths containing spaces or special characters
            if path.rangeOfCharacter(from: .init(charactersIn: " '\"\\$`!#&|;(){}[]<>?*~")) != nil {
                return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            return path
        }

        sendInput(paths.joined(separator: " "))
        return true
    }

    // MARK: - Tracking Areas

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
    }

    // MARK: - Helpers

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if event.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if event.modifierFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if event.modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if event.modifierFlags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func consumedMods(_ event: NSEvent) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if event.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if event.modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func unshiftedCodepoint(_ event: NSEvent) -> UInt32 {
        guard let chars = (event.characters(byApplyingModifiers: [])
            ?? event.charactersIgnoringModifiers
            ?? event.characters),
            let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }
}

// MARK: - NSScreen Display ID

extension NSScreen {
    var displayID: UInt32 {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return 0 }
        return screenNumber.uint32Value
    }
}
