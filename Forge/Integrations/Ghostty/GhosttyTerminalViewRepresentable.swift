import SwiftUI

/// NSViewRepresentable wrapper for GhosttyTerminalView, used inside BonsplitView.
struct GhosttyTerminalViewRepresentable: NSViewRepresentable {
    let sessionID: UUID

    func makeNSView(context _: Context) -> NSView {
        guard let session = TerminalSessionManager.shared.session(for: sessionID) else {
            return NSView()
        }
        let termView = TerminalCache.shared.terminalView(for: session)
        termView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        termView.removeFromSuperview()
        container.addSubview(termView)

        NSLayoutConstraint.activate([
            termView.topAnchor.constraint(equalTo: container.topAnchor),
            termView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            termView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            termView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    func updateNSView(_: NSView, context _: Context) {}
}

/// Wraps the terminal view with a floating close button overlay on hover.
struct PaneContentView: View {
    let sessionID: UUID
    let paneId: PaneID
    let manager: BonsplitPaneManager
    let onClose: () -> Void

    @State private var isHovering = false

    private var showCloseButton: Bool {
        manager.paneCount > 1
    }

    private var termView: GhosttyTerminalView? {
        guard let session = TerminalSessionManager.shared.session(for: sessionID) else { return nil }
        return TerminalCache.shared.terminalView(for: session)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GhosttyTerminalViewRepresentable(sessionID: sessionID)

            if let termView, termView.searchState.isVisible {
                TerminalSearchOverlay(termView: termView, state: termView.searchState)
                    .transition(.opacity.animation(.easeInOut(duration: 0.12)))
            }

            if showCloseButton, isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .padding(6)
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

/// Top-level SwiftUI wrapper that owns the BonsplitView and observes the controller.
/// Avoids AnyView erasure so @Observable changes propagate correctly.
struct BonsplitContentWrapper: View {
    let manager: BonsplitPaneManager
    let onCloseSession: (UUID) -> Void

    var body: some View {
        BonsplitView(controller: manager.controller) { tab, paneId in
            if let sessionID = manager.sessionID(for: tab.id) {
                PaneContentView(
                    sessionID: sessionID,
                    paneId: paneId,
                    manager: manager,
                    onClose: { onCloseSession(sessionID) }
                )
            }
        } emptyPane: { _ in
            Color.black
        }
    }
}
