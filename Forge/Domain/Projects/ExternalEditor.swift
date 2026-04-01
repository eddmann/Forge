import Foundation

struct ExternalEditor: Identifiable {
    let id = UUID()
    let name: String
    let command: String
}
