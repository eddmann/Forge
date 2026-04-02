import AppKit
import SwiftUI

private class ClickThroughEffectView: NSVisualEffectView {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}

class InspectorViewController: NSViewController {
    override func loadView() {
        let effectView = ClickThroughEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .inactive
        view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let hostingController = NSHostingController(rootView: InspectorView().ignoresSafeArea())
        addChild(hostingController)

        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
}
