import Foundation

/// Fuzzy matching using sequential forward DP (Forrest Smith / Sublime Text style).
///
/// Two tables over pattern × text:
///   - `D[p][t]` = best score when pattern[p] is matched at text[t]
///   - `M[p][t]` = best score for pattern[0..p] against text[0..t] (may skip text[t])
///
/// O(P×T) time and space.
enum FuzzyMatch {
    static func score(pattern: String, in text: String) -> Int? {
        let pChars = Array(pattern.lowercased())
        let tChars = Array(text)
        let tLower = Array(text.lowercased())
        let pLen = pChars.count
        let tLen = tChars.count

        guard pLen > 0 else { return 0 }
        guard tLen >= pLen else { return nil }

        // Quick bail: check all pattern chars exist in text in order
        var ci = 0
        for ch in tLower {
            if ci < pLen, ch == pChars[ci] { ci += 1 }
        }
        guard ci == pLen else { return nil }

        let NEG = Int.min / 2

        var D = [[Int]](repeating: [Int](repeating: NEG, count: tLen), count: pLen)
        var M = [[Int]](repeating: [Int](repeating: NEG, count: tLen), count: pLen)

        // First pattern character
        for j in 0 ..< tLen {
            if pChars[0] == tLower[j] {
                D[0][j] = charScore(tChars: tChars, j: j, consecutive: false)
            }
            let prev = j > 0 ? M[0][j - 1] : NEG
            M[0][j] = D[0][j] != NEG ? max(D[0][j], prev) : prev
        }

        // Remaining pattern characters
        for i in 1 ..< pLen {
            for j in i ..< tLen {
                if pChars[i] != tLower[j] {
                    M[i][j] = j > 0 ? M[i][j - 1] : NEG
                    continue
                }

                let base = charScore(tChars: tChars, j: j, consecutive: false)
                let consec = charScore(tChars: tChars, j: j, consecutive: true)

                let fromConsec = D[i - 1][j - 1] != NEG ? D[i - 1][j - 1] + consec : NEG
                let fromSkip = (j > 0 && M[i - 1][j - 1] != NEG) ? M[i - 1][j - 1] + base : NEG

                D[i][j] = max(fromConsec, fromSkip)
                M[i][j] = max(j > 0 ? M[i][j - 1] : NEG, D[i][j])
            }
        }

        let result = M[pLen - 1][tLen - 1]
        return result != NEG ? result : nil
    }

    // MARK: - Scoring

    private static func charScore(tChars: [Character], j: Int, consecutive: Bool) -> Int {
        var s = 10
        if consecutive { s += 5 }
        if j == 0 || isBoundary(tChars[j - 1]) {
            s += 8
        } else if j > 0, tChars[j - 1].isLowercase, tChars[j].isUppercase {
            s += 5
        }
        return s
    }

    private static func isBoundary(_ c: Character) -> Bool {
        c == "-" || c == "_" || c == "/" || c == " " || c == "." || c == ":"
    }
}
