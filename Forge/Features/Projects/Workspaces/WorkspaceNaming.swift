import Foundation

enum WorkspaceNaming {
    /// Complete Gen 1 Pokémon (151)
    private static let pokemon = [
        "bulbasaur", "ivysaur", "venusaur", "charmander", "charmeleon", "charizard",
        "squirtle", "wartortle", "blastoise", "caterpie", "metapod", "butterfree",
        "weedle", "kakuna", "beedrill", "pidgey", "pidgeotto", "pidgeot",
        "rattata", "raticate", "spearow", "fearow", "ekans", "arbok",
        "pikachu", "raichu", "sandshrew", "sandslash", "nidoran-f", "nidorina",
        "nidoqueen", "nidoran-m", "nidorino", "nidoking", "clefairy", "clefable",
        "vulpix", "ninetales", "jigglypuff", "wigglytuff", "zubat", "golbat",
        "oddish", "gloom", "vileplume", "paras", "parasect", "venonat",
        "venomoth", "diglett", "dugtrio", "meowth", "persian", "psyduck",
        "golduck", "mankey", "primeape", "growlithe", "arcanine", "poliwag",
        "poliwhirl", "poliwrath", "abra", "kadabra", "alakazam", "machop",
        "machoke", "machamp", "bellsprout", "weepinbell", "victreebel", "tentacool",
        "tentacruel", "geodude", "graveler", "golem", "ponyta", "rapidash",
        "slowpoke", "slowbro", "magnemite", "magneton", "farfetchd", "doduo",
        "dodrio", "seel", "dewgong", "grimer", "muk", "shellder",
        "cloyster", "gastly", "haunter", "gengar", "onix", "drowzee",
        "hypno", "krabby", "kingler", "voltorb", "electrode", "exeggcute",
        "exeggutor", "cubone", "marowak", "hitmonlee", "hitmonchan", "lickitung",
        "koffing", "weezing", "rhyhorn", "rhydon", "chansey", "tangela",
        "kangaskhan", "horsea", "seadra", "goldeen", "seaking", "staryu",
        "starmie", "mr-mime", "scyther", "jynx", "electabuzz", "magmar",
        "pinsir", "tauros", "magikarp", "gyarados", "lapras", "ditto",
        "eevee", "vaporeon", "jolteon", "flareon", "porygon", "omanyte",
        "omastar", "kabuto", "kabutops", "aerodactyl", "snorlax", "articuno",
        "zapdos", "moltres", "dratini", "dragonair", "dragonite", "mewtwo", "mew"
    ]

    static func generateUnique(existing: [String]) -> String {
        for _ in 0 ..< 100 {
            let id = UUID()
            let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
            let idx = (Int(bytes[0]) << 8 | Int(bytes[1])) % pokemon.count
            let name = pokemon[idx]
            if !existing.contains(name) {
                return name
            }
        }
        return "workspace-\(UUID().uuidString.prefix(8))"
    }
}
