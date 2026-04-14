import Foundation

/// Observable per-terminal search state. Mirrors Ghostty's search action callbacks
/// (`SEARCH_TOTAL`, `SEARCH_SELECTED`, `END_SEARCH`) into UI-readable fields and lets
/// the overlay drive `search:<needle>`, `navigate_search:next/previous`, `end_search`
/// binding actions back to the surface.
@MainActor
@Observable
final class TerminalSearchState {
    var isVisible: Bool = false
    var needle: String = ""
    var total: Int?
    var selected: Int?

    /// Bumped each time the user re-triggers Cmd+F so the overlay can refocus its field.
    var focusToken: Int = 0

    func reset() {
        isVisible = false
        needle = ""
        total = nil
        selected = nil
    }
}
