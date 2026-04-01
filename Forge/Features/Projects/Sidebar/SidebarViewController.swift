import AppKit
import SwiftUI

class SidebarViewController: NSViewController {
    override func loadView() {
        // Visual effect view as the root — gives native macOS sidebar vibrancy
        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .inactive
        view = effectView

        // Embed SwiftUI content with clear background
        let hostingVC = NSHostingController(rootView: ProjectListView().ignoresSafeArea())
        hostingVC.sizingOptions = []
        addChild(hostingVC)
        hostingVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingVC.view)

        NSLayoutConstraint.activate([
            hostingVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
