import AppKit

class TerminalTabBar: NSView {
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onRenameTab: ((UUID, String) -> Void)?
    var onNewShellTab: (() -> Void)?
    var onNewAgentTab: ((AgentConfig) -> Void)?

    private let stackView = NSStackView()
    private let newTabButton = NSButton()
    private let borderView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private var theme: TerminalTheme {
        TerminalAppearanceStore.shared.config.theme
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = theme.chromeBackground.cgColor

        // Stack view for tabs
        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.distribution = .fillEqually
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        // New tab "+" button
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.bezelStyle = .inline
        newTabButton.isBordered = false
        newTabButton.title = ""
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        newTabButton.imagePosition = .imageOnly
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        addSubview(newTabButton)

        // Bottom hairline
        borderView.translatesAutoresizingMaskIntoConstraints = false
        borderView.wantsLayer = true
        addSubview(borderView)

        refreshTheme()

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            newTabButton.topAnchor.constraint(equalTo: topAnchor),
            newTabButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 36),

            borderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            borderView.bottomAnchor.constraint(equalTo: bottomAnchor),
            borderView.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    func refreshTheme() {
        let t = theme
        layer?.backgroundColor = t.chromeBackground.cgColor
        borderView.layer?.backgroundColor = t.chromeBorder.cgColor
        newTabButton.contentTintColor = t.chromeSecondaryText
    }

    @objc private func newTabClicked() {
        let agents = AgentStore.shared.agents
        guard !agents.isEmpty else {
            onNewShellTab?()
            return
        }

        let menu = NSMenu()

        // Shell item
        let shellItem = NSMenuItem(title: "Shell", action: #selector(shellItemClicked), keyEquivalent: "")
        shellItem.target = self
        shellItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Shell")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        menu.addItem(shellItem)

        menu.addItem(.separator())

        // Agent items
        for agent in agents {
            let item = NSMenuItem(title: agent.name, action: agent.isInstalled ? #selector(agentItemClicked(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = agent.id
            item.image = agent.nsImage(size: 12)
            if !agent.isInstalled {
                item.toolTip = "\(agent.command) not found in PATH"
            }
            menu.addItem(item)
        }

        let buttonFrame = newTabButton.convert(newTabButton.bounds, to: self)
        menu.popUp(positioning: nil, at: NSPoint(x: buttonFrame.minX, y: buttonFrame.minY), in: self)
    }

    @objc private func shellItemClicked() {
        onNewShellTab?()
    }

    @objc private func agentItemClicked(_ sender: NSMenuItem) {
        guard let agentID = sender.representedObject as? UUID,
              let agent = AgentStore.shared.agents.first(where: { $0.id == agentID }) else { return }
        onNewAgentTab?(agent)
    }

    func update(tabs: [TerminalTab], activeID: UUID?, agentStatuses: [UUID: AgentActivity] = [:], notificationCounts: [UUID: Int] = [:]) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (index, tab) in tabs.enumerated() {
            let isActive = tab.id == activeID
            let isLast = index == tabs.count - 1

            let cell = TabCell(
                tab: tab,
                isActive: isActive,
                shortcutIndex: index + 1,
                showRightSeparator: !isLast,
                agentStatus: agentStatuses[tab.id] ?? .idle,
                agentIcons: tab.icon.map { [$0] } ?? [],
                unreadCount: notificationCounts[tab.id] ?? 0
            )
            cell.onSelect = { [weak self] id in
                self?.onSelectTab?(id)
            }
            cell.onClose = { [weak self] id in
                self?.onCloseTab?(id)
            }
            cell.onRename = { [weak self] id, name in
                self?.onRenameTab?(id, name)
            }
            stackView.addArrangedSubview(cell)
        }
    }
}

// MARK: - Tab Cell

private class TabCell: NSView, NSTextFieldDelegate {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onRename: ((UUID, String) -> Void)?

    private let tabID: UUID
    private let isActive: Bool
    private let agentStatus: AgentActivity
    private let theme: TerminalTheme
    private let titleLabel = NSTextField(labelWithString: "")
    private let titleStack = NSStackView()
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let statusDot = NSView()
    // notificationBadge removed — status dot handles all states
    private let separator = NSView()
    private var editField: NSTextField?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(tab: TerminalTab, isActive: Bool, shortcutIndex: Int, showRightSeparator: Bool, agentStatus: AgentActivity = .idle, agentIcons: [String] = [], unreadCount: Int = 0, theme: TerminalTheme = TerminalAppearanceStore.shared.config.theme) {
        tabID = tab.id
        self.isActive = isActive
        self.agentStatus = agentStatus
        self.theme = theme
        super.init(frame: .zero)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        updateBackground()

        // Title label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = tab.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = isActive ? theme.chromePrimaryText : theme.chromeSecondaryText
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Stack: [icon...] [title] — centered together
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.orientation = .horizontal
        titleStack.spacing = 4
        titleStack.alignment = .centerY

        // Add agent icons (one per unique agent in this tab)
        let tintColor = isActive ? theme.chromePrimaryText : theme.chromeSecondaryText
        for symbol in agentIcons {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyDown
            iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            iv.contentTintColor = tintColor
            NSLayoutConstraint.activate([
                iv.widthAnchor.constraint(equalToConstant: 14),
                iv.heightAnchor.constraint(equalToConstant: 14)
            ])
            titleStack.addArrangedSubview(iv)
        }

        titleStack.addArrangedSubview(titleLabel)
        addSubview(titleStack)

        // Shortcut badge on the right (⌘1, ⌘2, etc.) — only for first 9
        if shortcutIndex <= 9 {
            shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
            shortcutLabel.stringValue = "⌘\(shortcutIndex)"
            shortcutLabel.font = .systemFont(ofSize: 10, weight: .regular)
            shortcutLabel.textColor = theme.chromeSecondaryText.withAlphaComponent(0.5)
            shortcutLabel.alignment = .right
            addSubview(shortcutLabel)
        }

        // Status dot — 6pt circle, positioned same as close button
        // Single status dot — last state wins: blue notification > orange waiting > green running
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        addSubview(statusDot)

        // Active agent states take priority over notification badge
        if agentStatus != .idle && agentStatus != .complete {
            configureStatusDot()
        } else if unreadCount > 0 {
            // Solid blue dot for notifications (only when agent is idle/complete)
            statusDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            statusDot.isHidden = false
            statusDot.layer?.removeAllAnimations()
        } else {
            configureStatusDot()
        }

        // Status dot handles all states — no separate notification badge needed

        // Close button — hidden by default, shows on hover
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .semibold))
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = theme.chromeSecondaryText
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)

        // Right-side vertical separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = theme.chromeBorder.cgColor
        separator.isHidden = !showRightSeparator
        addSubview(separator)

        var constraints = [
            titleStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 4),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -30),

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),

            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),

            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            separator.widthAnchor.constraint(equalToConstant: 0.5)
        ]

        if shortcutIndex <= 9 {
            constraints.append(contentsOf: [
                shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        NSLayoutConstraint.activate(constraints)
    }

    private func configureStatusDot() {
        switch agentStatus {
        case .thinking:
            statusDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            statusDot.isHidden = false
            addPulseAnimation()
        case .toolExecuting:
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusDot.isHidden = false
            addPulseAnimation()
        case .waitingForPermission, .waitingForInput:
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusDot.isHidden = false
            statusDot.layer?.removeAllAnimations()
        case .retrying:
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            statusDot.isHidden = false
            addPulseAnimation()
        case .compacting:
            statusDot.layer?.backgroundColor = NSColor.systemPurple.cgColor
            statusDot.isHidden = false
            addPulseAnimation()
        case .idle, .complete:
            statusDot.isHidden = true
            statusDot.layer?.removeAllAnimations()
        }
    }

    private func addPulseAnimation() {
        statusDot.layer?.removeAllAnimations()
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        statusDot.layer?.add(pulse, forKey: "pulse")
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        // If the close button is visible and the click is on it, let the button handle it
        if !closeButton.isHidden, closeButton.frame.insetBy(dx: -4, dy: -4).contains(loc) {
            closeButton.performClick(nil)
            return
        }

        if isActive, event.clickCount == 2 {
            beginEditing()
        } else if !isActive {
            onSelect?(tabID)
        }
    }

    // MARK: - Inline rename

    private func beginEditing() {
        guard editField == nil else { return }

        let field = NSTextField(string: titleLabel.stringValue)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = titleLabel.font
        field.textColor = theme.chromePrimaryText
        field.backgroundColor = theme.chromeActiveBackground
        field.isBordered = false
        field.focusRingType = .none
        field.alignment = .center
        field.delegate = self
        addSubview(field)

        NSLayoutConstraint.activate([
            field.centerXAnchor.constraint(equalTo: centerXAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            field.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28)
        ])

        titleLabel.isHidden = true
        shortcutLabel.isHidden = true
        editField = field
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func commitEditing() {
        guard let field = editField else { return }
        let newTitle = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.removeFromSuperview()
        editField = nil
        titleLabel.isHidden = false
        shortcutLabel.isHidden = false

        if !newTitle.isEmpty, newTitle != titleLabel.stringValue {
            titleLabel.stringValue = newTitle
            onRename?(tabID, newTitle)
        }
    }

    func controlTextDidEndEditing(_: Notification) {
        commitEditing()
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            commitEditing()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            editField?.removeFromSuperview()
            editField = nil
            titleLabel.isHidden = false
            shortcutLabel.isHidden = false
            return true
        }
        return false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
        closeButton.isHidden = false
        statusDot.isHidden = true
        shortcutLabel.isHidden = true
        updateBackground()
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        closeButton.isHidden = true
        // Restore status dot visibility based on agent activity
        statusDot.isHidden = (agentStatus == .idle || agentStatus == .complete)
        shortcutLabel.isHidden = false
        updateBackground()
    }

    private func updateBackground() {
        if isActive {
            layer?.backgroundColor = theme.chromeActiveBackground.cgColor
        } else if isHovered {
            layer?.backgroundColor = theme.chromeHoverBackground.cgColor
        } else {
            layer?.backgroundColor = theme.chromeBackground.cgColor
        }
    }

    @objc private func tabClicked() {
        onSelect?(tabID)
    }

    @objc private func closeClicked() {
        onClose?(tabID)
    }
}
