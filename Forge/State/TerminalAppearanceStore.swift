import Combine
import Foundation

class TerminalAppearanceStore: ObservableObject {
    static let shared = TerminalAppearanceStore()

    @Published var config: TerminalAppearanceConfig

    private var saveCancellable: AnyCancellable?

    private init() {
        config = ForgeStore.shared.loadAppearance() ?? TerminalAppearanceConfig()

        saveCancellable = $config
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.save()
            }
    }

    private func save() {
        ForgeStore.shared.saveAppearance(config)
    }
}
