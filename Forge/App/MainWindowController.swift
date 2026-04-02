import AppKit
import Combine
import SwiftUI

class MainWindowController: NSWindowController, NSWindowDelegate {
    private var projectNameLabel: NSTextField?
    private var workspaceStack: NSStackView?
    private var workspaceIcon: NSImageView?
    private var workspaceNameLabel: NSTextField?
    private var fromLabel: NSTextField?
    private var separator: NSTextField?
    private var openButton: NSButton?
    private var cancellables = Set<AnyCancellable>()
    private var branchPopover: NSPopover?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.init(window: window)

        window.minSize = NSSize(width: 800, height: 500)
        window.collectionBehavior = [.fullScreenPrimary]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Forge"

        let theme = TerminalAppearanceStore.shared.config.theme
        window.appearance = theme.nsAppearance
        window.isOpaque = false
        window.backgroundColor = theme.windowBackground
        window.setFrameAutosaveName("ForgeMainWindow")

        let splitVC = MainSplitViewController()
        window.contentViewController = splitVC

        setupToolbar(for: window)
        observeStore()

        window.delegate = self
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.center()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_: NSWindow) -> Bool {
        StatusBarController.shared.hideWindow()
        return false
    }

    private func observeStore() {
        let store = ProjectStore.shared

        store.$activeProjectID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateBreadcrumb()
            }
            .store(in: &cancellables)

        store.$activeWorkspaceID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateBreadcrumb()
            }
            .store(in: &cancellables)

        // Observe theme changes and update window chrome
        TerminalAppearanceStore.shared.$config
            .map(\.theme)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                self?.applyTheme(theme)
            }
            .store(in: &cancellables)
    }

    private func applyTheme(_ theme: TerminalTheme) {
        guard let window else { return }
        window.appearance = theme.nsAppearance
        window.backgroundColor = theme.windowBackground
    }

    private func updateBreadcrumb() {
        let store = ProjectStore.shared
        let project = store.activeProject
        projectNameLabel?.stringValue = project?.name ?? "Forge"

        let hasProject = project != nil

        if let workspace = store.activeWorkspace {
            separator?.isHidden = false
            workspaceStack?.isHidden = false
            workspaceNameLabel?.stringValue = workspace.name
            fromLabel?.stringValue = "from \(workspace.parentBranch)"
        } else {
            separator?.isHidden = true
            workspaceStack?.isHidden = true
        }

        openButton?.superview?.isHidden = !hasProject
    }

    private func setupToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unified
        window.toolbar = toolbar
    }

    // MARK: - Breadcrumb

    private func makeBreadcrumb() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY

        // Project name
        let nameLabel = NSTextField(labelWithString: ProjectStore.shared.activeProject?.name ?? "Forge")
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        projectNameLabel = nameLabel

        // Separator: /
        let sep = NSTextField(labelWithString: "/")
        sep.font = .systemFont(ofSize: 12, weight: .regular)
        sep.textColor = .tertiaryLabelColor
        sep.isHidden = true
        separator = sep

        // Workspace info stack: icon + name + "from branch"
        let wsStack = NSStackView()
        wsStack.orientation = .horizontal
        wsStack.spacing = 4
        wsStack.alignment = .centerY
        wsStack.isHidden = true
        workspaceStack = wsStack

        // Branch icon
        let icon = NSImageView()
        if let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Workspace") {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            icon.image = img.withSymbolConfiguration(config)
        }
        icon.contentTintColor = .labelColor
        workspaceIcon = icon

        // Workspace name
        let wsName = NSTextField(labelWithString: "")
        wsName.font = .systemFont(ofSize: 12, weight: .semibold)
        wsName.textColor = .labelColor
        wsName.lineBreakMode = .byTruncatingTail
        wsName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceNameLabel = wsName

        // "from main"
        let from = NSTextField(labelWithString: "")
        from.font = .systemFont(ofSize: 12, weight: .regular)
        from.textColor = .tertiaryLabelColor
        from.lineBreakMode = .byTruncatingTail
        fromLabel = from

        wsStack.addArrangedSubview(icon)
        wsStack.addArrangedSubview(wsName)
        wsStack.addArrangedSubview(from)

        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(sep)
        stack.addArrangedSubview(wsStack)

        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 500)
        ])

        // Set initial state
        updateBreadcrumb()

        return stack
    }

    // MARK: - Branch Popover

    @objc private func showBranchPicker(_ sender: NSButton) {
        if let existing = branchPopover, existing.isShown {
            existing.close()
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = TerminalAppearanceStore.shared.config.theme.nsAppearance

        let pickerView = BranchPickerView {
            popover.close()
        }
        popover.contentViewController = NSHostingController(rootView: pickerView)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        branchPopover = popover
    }

    // MARK: - Open Dropdown

    private func makeOpenButton() -> NSView {
        let button = NSButton(title: "Open", target: self, action: #selector(showOpenMenu(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .secondaryLabelColor

        let attachment = NSTextAttachment()
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
            attachment.image = chevron.withSymbolConfiguration(config)
        }
        let title = NSMutableAttributedString(string: "Open ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        title.append(NSAttributedString(attachment: attachment))
        button.attributedTitle = title

        openButton = button

        let pill = NSView(frame: NSRect(x: 0, y: 0, width: 70, height: 24))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        pill.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        pill.layer?.borderWidth = 0.5
        pill.layer?.borderColor = NSColor.separatorColor.cgColor

        button.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(button)

        NSLayoutConstraint.activate([
            pill.widthAnchor.constraint(equalToConstant: 70),
            pill.heightAnchor.constraint(equalToConstant: 24),
            button.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])

        return pill
    }

    @objc private func showOpenMenu(_ sender: NSButton) {
        let menu = NSMenu()

        let finderItem = NSMenuItem(title: "Finder", action: #selector(openInFinder), keyEquivalent: "")
        finderItem.target = self
        menu.addItem(finderItem)

        let editors = ProjectStore.shared.availableEditors
        if !editors.isEmpty {
            menu.addItem(.separator())
            for editor in editors {
                let item = NSMenuItem(title: editor.name, action: #selector(openInEditorAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = editor.command
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let copyItem = NSMenuItem(title: "Copy Path", action: #selector(copyProjectPath), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func openInFinder() {
        guard let path = ProjectStore.shared.effectivePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openInEditorAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String,
              let path = ProjectStore.shared.effectivePath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command, path]
        try? process.run()
    }

    @objc private func copyProjectPath() {
        guard let path = ProjectStore.shared.effectivePath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {
    static let breadcrumbID = NSToolbarItem.Identifier("breadcrumb")
    static let openID = NSToolbarItem.Identifier("open")
    static let flexibleSpaceID = NSToolbarItem.Identifier.flexibleSpace

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.flexibleSpaceID,
            Self.breadcrumbID,
            Self.flexibleSpaceID,
            Self.openID
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.breadcrumbID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = makeBreadcrumb()
            item.label = ""
            return item

        case Self.openID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = makeOpenButton()
            item.label = "Open"
            return item

        default:
            return nil
        }
    }
}
