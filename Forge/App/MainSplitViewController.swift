import AppKit
import Combine
import SwiftUI

class MainSplitViewController: NSSplitViewController {
    private let sidebarVC = SidebarViewController()
    private let terminalContainerVC = TerminalContainerViewController()
    private let inspectorVC = InspectorViewController()
    private let welcomeVC = NSHostingController(rootView: WelcomeView())

    private var cancellables = Set<AnyCancellable>()
    private var isShowingWelcome = true

    override func viewDidLoad() {
        super.viewDidLoad()

        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        // Set autosaveName to restore saved positions (if any exist)
        splitView.autosaveName = "ForgeSplitView"

        // Left sidebar — resizable, collapsible
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        addSplitViewItem(sidebarItem)

        // Start with welcome or project content depending on active project
        if ProjectStore.shared.activeProjectID != nil {
            addProjectItems()
            isShowingWelcome = false
        } else {
            addWelcomeItem()
            isShowingWelcome = true
        }

        observeActiveProject()
    }

    private func addWelcomeItem() {
        let welcomeItem = NSSplitViewItem(viewController: welcomeVC)
        welcomeItem.minimumThickness = 200
        welcomeItem.holdingPriority = .defaultLow
        addSplitViewItem(welcomeItem)
    }

    private func addProjectItems() {
        // Center terminal area — expands to fill available space
        let centerItem = NSSplitViewItem(viewController: terminalContainerVC)
        centerItem.minimumThickness = 200
        centerItem.holdingPriority = .defaultLow
        addSplitViewItem(centerItem)

        // Right inspector — resizable, collapsible
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 500
        addSplitViewItem(inspectorItem)
    }

    private func observeActiveProject() {
        ProjectStore.shared.$activeProjectID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] projectID in
                self?.updateLayout(hasProject: projectID != nil)
            }
            .store(in: &cancellables)
    }

    private func updateLayout(hasProject: Bool) {
        if hasProject, isShowingWelcome {
            // Remove welcome, add terminal + inspector
            while splitViewItems.count > 1 {
                removeSplitViewItem(splitViewItems.last!)
            }
            addProjectItems()
            isShowingWelcome = false

            // Set default divider positions if no autosaved state
            if !hasSavedDividerPositions {
                DispatchQueue.main.async { [weak self] in
                    guard let self, splitView.bounds.width > 0 else { return }
                    splitView.setPosition(260, ofDividerAt: 0)
                    splitView.setPosition(splitView.bounds.width - 320, ofDividerAt: 1)
                }
            }
        } else if !hasProject, !isShowingWelcome {
            // Remove terminal + inspector, add welcome
            while splitViewItems.count > 1 {
                removeSplitViewItem(splitViewItems.last!)
            }
            addWelcomeItem()
            isShowingWelcome = true
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Only set default divider positions if no autosaved state exists
        guard !isShowingWelcome else { return }
        guard !hasSavedDividerPositions else { return }
        let totalWidth = splitView.bounds.width
        guard totalWidth > 0 else { return }
        splitView.setPosition(260, ofDividerAt: 0)
        splitView.setPosition(totalWidth - 280, ofDividerAt: 1)
    }

    private var hasSavedDividerPositions: Bool {
        UserDefaults.standard.object(forKey: "NSSplitView Subview Frames ForgeSplitView") != nil
    }

    // MARK: - Divider Hit Area

    override func splitView(_: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect _: NSRect, ofDividerAt _: Int) -> NSRect {
        // Widen hit area so thin dividers are easy to grab
        var rect = proposedEffectiveRect
        rect.origin.x -= 6
        rect.size.width += 12
        return rect
    }

    // MARK: - Sidebar Toggle Actions

    @objc func toggleLeftSidebar(_: Any?) {
        guard splitViewItems.count > 0 else { return }
        let item = splitViewItems[0]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            item.animator().isCollapsed = !item.isCollapsed
        }
    }

    @objc func toggleRightSidebar(_: Any?) {
        guard splitViewItems.count > 2 else { return }
        let item = splitViewItems[2]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            item.animator().isCollapsed = !item.isCollapsed
        }
    }
}
