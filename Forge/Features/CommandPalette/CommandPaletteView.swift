import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CPSearchBar(viewModel: viewModel)
            Divider()
            CPResultsList(
                sections: viewModel.sections,
                selectedItemID: viewModel.selectedItemID,
                onSelect: { item in
                    onClose()
                    viewModel.execute(item)
                }
            )
        }
        .frame(width: 520, height: 380)
        .edgesIgnoringSafeArea(.top)
    }
}

// MARK: - Search Bar

private struct CPSearchBar: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))

            TextField("Search projects, commands, actions\u{2026}", text: $viewModel.query)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onChange(of: viewModel.query) { newValue in
                    viewModel.rebuildSections(for: newValue)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Results List

private struct CPResultsList: View {
    let sections: [CPSection]
    let selectedItemID: String?
    let onSelect: (CPItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if sections.isEmpty {
                        Text("No matches")
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            .padding(12)
                    } else {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                                .padding(.horizontal, 14)
                                .padding(.top, 6)

                            ForEach(section.items) { item in
                                CPResultRow(
                                    item: item,
                                    isSelected: item.id == selectedItemID,
                                    onSelect: { onSelect(item) }
                                )
                                .id(item.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedItemID) { newID in
                guard let id = newID else { return }
                withAnimation(.easeInOut(duration: 0.1)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Result Row

private struct CPResultRow: View {
    let item: CPItem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .primary : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
            }

            Spacer()

            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .padding(.horizontal, 4)
    }
}
