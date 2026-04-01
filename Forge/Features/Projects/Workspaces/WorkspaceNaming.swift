import Foundation

enum WorkspaceNaming {
    private static let pokemon = [
        "bulbasaur", "charmander", "squirtle", "pikachu", "eevee", "jigglypuff", "meowth",
        "psyduck", "growlithe", "poliwag", "abra", "machop", "geodude", "ponyta", "slowpoke",
        "magnemite", "gastly", "onix", "drowzee", "voltorb", "cubone", "hitmonlee", "lickitung",
        "koffing", "chansey", "tangela", "kangaskhan", "staryu", "scyther", "magikarp", "lapras",
        "ditto", "snorlax", "articuno", "zapdos", "moltres", "dratini", "mewtwo", "mew",
        "chikorita", "cyndaquil", "totodile", "togepi", "mareep", "sudowoodo", "wooper",
        "espeon", "umbreon", "murkrow", "slowking", "wobbuffet", "gligar", "snubbull",
        "heracross", "teddiursa", "slugma", "swinub", "corsola", "skarmory", "houndour",
        "phanpy", "larvitar", "lugia", "celebi",
        "treecko", "torchic", "mudkip", "zigzagoon", "ralts", "slakoth", "nincada", "whismur",
        "aron", "meditite", "electrike", "roselia", "gulpin", "carvanha", "numel", "torkoal",
        "trapinch", "swablu", "zangoose", "seviper", "lunatone", "solrock", "baltoy", "feebas",
        "castform", "shuppet", "duskull", "tropius", "absol", "snorunt", "spheal", "bagon",
        "beldum", "jirachi", "rayquaza",
        "turtwig", "chimchar", "piplup", "shinx", "budew", "cranidos", "shieldon", "buizel",
        "drifloon", "buneary", "glameow", "stunky", "bronzor", "gible", "riolu", "hippopotas",
        "skorupi", "croagunk", "finneon", "snover", "rotom", "darkrai", "shaymin", "arceus",
        "snivy", "tepig", "oshawott", "lillipup", "purrloin", "munna", "pidove", "roggenrola",
        "woobat", "drilbur", "sewaddle", "venipede", "cottonee", "sandile", "darumaka",
        "dwebble", "scraggy", "yamask", "zorua", "minccino", "gothita", "solosis", "ducklett",
        "vanillite", "emolga", "joltik", "ferroseed", "litwick", "axew", "cubchoo", "mienfoo",
        "golett", "pawniard", "rufflet", "deino", "larvesta", "reshiram", "zekrom",
        "chespin", "fennekin", "froakie", "fletchling", "litleo", "skiddo", "pancham",
        "espurr", "honedge", "spritzee", "swirlix", "inkay", "helioptile", "tyrunt", "amaura",
        "hawlucha", "dedenne", "goomy", "phantump", "pumpkaboo", "noibat",
        "rowlet", "litten", "popplio", "pikipek", "rockruff", "wishiwashi", "mareanie",
        "mudbray", "dewpider", "fomantis", "salandit", "stufful", "bounsweet", "comfey",
        "oranguru", "passimian", "sandygast", "pyukumuku", "mimikyu", "drampa", "jangmo-o",
        "grookey", "scorbunny", "sobble", "wooloo", "yamper", "rolycoly", "applin",
        "silicobra", "cramorant", "arrokuda", "toxel", "sizzlipede", "clobbopus", "sinistea",
        "hatenna", "impidimp", "milcery", "falinks", "snom", "stonjourner", "eiscue",
        "morpeko", "cufant", "dreepy", "zacian", "zamazenta",
        "sprigatito", "fuecoco", "quaxly", "lechonk", "pawmi", "tandemaus", "fidough",
        "smoliv", "squawkabilly", "nacli", "charcadet", "tadbulb", "capsakid", "rellor",
        "flittle", "greavard", "cetoddle", "veluza", "dondozo", "tatsugiri", "frigibax",
        "gimmighoul"
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
