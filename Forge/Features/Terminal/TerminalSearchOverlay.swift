import AppKit
import SwiftUI

/// Floating search bar pinned to the top-right of a terminal pane.
/// Drives Ghostty's search via binding actions and reflects total/selected match
/// counts that Ghostty publishes back through `TerminalSearchState`.
struct TerminalSearchOverlay: View {
    let termView: GhosttyTerminalView
    @Bindable var state: TerminalSearchState

    @State private var isFieldFocused: Bool = false
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 4) {
            SearchField(
                text: $state.needle,
                isFocused: isFieldFocused,
                onSubmit: { isShifted in
                    flushPendingSearch()
                    navigate(isShifted ? .previous : .next)
                },
                onEscape: { close() }
            )
            .frame(width: 200)
            .padding(.leading, 8)
            .padding(.trailing, 56)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.08))
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .trailing) { matchLabel }

            iconButton(systemName: "chevron.up", help: "Previous match (Shift+Return)") {
                flushPendingSearch()
                navigate(.previous)
            }
            iconButton(systemName: "chevron.down", help: "Next match (Return)") {
                flushPendingSearch()
                navigate(.next)
            }
            iconButton(systemName: "xmark", help: "Close (Esc)") { close() }
        }
        .padding(8)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .padding(8)
        .onAppear {
            scheduleEmit(state.needle)
            focusField()
        }
        .onChange(of: state.needle) { _, newValue in
            scheduleEmit(newValue)
        }
        .onChange(of: state.focusToken) { _, _ in
            focusField()
        }
        .onDisappear {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    @ViewBuilder
    private var matchLabel: some View {
        if let total = state.total {
            let label = if let selected = state.selected {
                "\(selected + 1)/\(total)"
            } else {
                "0/\(total)"
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
        }
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private enum Direction {
        case next, previous
        var binding: String {
            self == .next ? "navigate_search:next" : "navigate_search:previous"
        }
    }

    private func navigate(_ direction: Direction) {
        termView.performBindingAction(direction.binding)
    }

    private func close() {
        debounceTask?.cancel()
        debounceTask = nil
        termView.performBindingAction("end_search")
        // Ghostty will emit END_SEARCH which resets state, but reset locally too in
        // case the action was a no-op (e.g. needle was empty).
        state.reset()
        termView.window?.makeFirstResponder(termView)
    }

    private func scheduleEmit(_ needle: String) {
        debounceTask?.cancel()
        // Empty or long-enough needles emit immediately; short ones debounce so we
        // don't churn Ghostty's matcher while the user is mid-word.
        if needle.isEmpty || needle.count >= 3 {
            emit(needle)
            return
        }
        let captured = needle
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            emit(captured)
        }
    }

    private func emit(_ needle: String) {
        termView.performBindingAction("search:\(needle)")
    }

    private func flushPendingSearch() {
        guard let task = debounceTask else { return }
        task.cancel()
        debounceTask = nil
        emit(state.needle)
    }

    private func focusField() {
        // Defer one tick so the NSViewRepresentable has mounted.
        isFieldFocused = false
        Task { @MainActor in
            await Task.yield()
            isFieldFocused = true
        }
    }
}

// MARK: - Search Field

/// NSTextField wrapper that traps Return / Shift+Return / Escape and forwards them
/// to the overlay so the search field behaves like the macOS Find bar.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Bool
    var onSubmit: (Bool) -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.onSubmit = onSubmit
        field.onEscape = onEscape
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Find"
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return field
    }

    func updateNSView(_ nsView: Field, context _: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onSubmit = onSubmit
        nsView.onEscape = onEscape
        if isFocused, nsView.window?.firstResponder !== nsView.currentEditor() {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }
    }

    final class Field: NSTextField {
        var onSubmit: ((Bool) -> Void)?
        var onEscape: (() -> Void)?

        override func cancelOperation(_: Any?) {
            onEscape?()
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76: // Return, numeric Enter
                onSubmit?(event.modifierFlags.contains(.shift))
            case 53: // Escape
                onEscape?()
            default:
                super.keyDown(with: event)
            }
        }
    }
}
