import SwiftUI

struct WelcomeView: View {
    @ObservedObject private var store = TerminalAppearanceStore.shared

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "hammer.fill")
                .font(.system(size: 48))
                .foregroundColor(Color(nsColor: store.config.theme.accent))

            Text("Welcome to Forge")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.primary)

            Text("Select a project to get started")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Text("\u{2318}\u{21E7}O to add a project")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
