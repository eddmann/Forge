import Foundation

enum WorkspaceNaming {
    private static let adjectives = [
        "amber", "azure", "bold", "brave", "bright", "calm", "cedar", "clear", "cobalt", "cool",
        "coral", "crisp", "dawn", "deep", "dusk", "fern", "fleet", "frost", "gentle", "gilt",
        "golden", "grand", "green", "haze", "iron", "ivory", "jade", "keen", "lark", "light",
        "lilac", "lunar", "maple", "mint", "misty", "noble", "olive", "opal", "pale", "pearl",
        "pine", "plain", "plum", "polar", "prime", "quartz", "quiet", "rapid", "reed", "ruby",
        "rustic", "sage", "scarlet", "serene", "silver", "slate", "snow", "solar", "stark", "steel",
        "stone", "storm", "swift", "teal", "terra", "thunder", "tide", "timber", "topaz", "ultra",
        "vale", "velvet", "vivid", "warm", "wild"
    ]

    private static let animals = [
        "badger", "bear", "bison", "bobcat", "crane", "crow", "deer", "dove", "eagle", "elk",
        "falcon", "finch", "fox", "gazelle", "goat", "gopher", "hawk", "heron", "horse", "ibis",
        "jackal", "jay", "kite", "koala", "lark", "lemur", "lion", "lynx", "marten", "moose",
        "mule", "newt", "osprey", "otter", "owl", "panda", "parrot", "pelican", "pike", "puma",
        "quail", "raven", "robin", "salmon", "seal", "shrike", "snake", "sparrow", "stork", "swift",
        "tern", "tiger", "toad", "trout", "viper", "vole", "walrus", "wren", "yak", "zebra"
    ]

    static func generateUnique(existing: [String]) -> String {
        for _ in 0 ..< 100 {
            let id = UUID()
            let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
            let adjIdx = Int(bytes[0]) % adjectives.count
            let animalIdx = Int(bytes[1]) % animals.count
            let name = "\(adjectives[adjIdx])-\(animals[animalIdx])"
            if !existing.contains(name) {
                return name
            }
        }
        return "workspace-\(UUID().uuidString.prefix(8))"
    }
}
