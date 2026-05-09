import Foundation

/// `ATTN-1.21`: returns the closest registered subcommand to `input`
/// when within Levenshtein distance 2; otherwise nil. Callers append
/// "Did you mean '<closest>'?" to their error text.
public enum SubcommandSuggestions {
    public static func suggest(_ input: String, from candidates: [String]) -> String? {
        guard !input.isEmpty, !candidates.isEmpty else { return nil }
        var bestName: String?
        var bestDistance = Int.max
        for c in candidates {
            let d = levenshtein(input, c)
            if d < bestDistance {
                bestDistance = d
                bestName = c
            }
        }
        return bestDistance <= 2 ? bestName : nil
    }

    /// Standard iterative Levenshtein with two rolling rows. ~30 lines,
    /// no third-party dep. Subcommand counts are tiny (<20 per group),
    /// so an O(n*m) implementation is more than fast enough.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,        // deletion
                    curr[j - 1] + 1,    // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }
}
