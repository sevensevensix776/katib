import Foundation

/// Fuzzy string matcher — DP-based. Given a query and a candidate, returns
/// a positive score if query is a subsequence of candidate (case-insensitive),
/// zero otherwise. Higher = better match.
///
/// Scoring:
/// - Each matched char: +10
/// - Match at position 0 of candidate, or after a separator (' ', '.', '_',
///   '-', '/'): additional +15
/// - Unmatched candidate chars between matches incur -1 each (gap penalty)
///
/// Consecutive-run bonus is omitted on purpose — the separator bonus already
/// rewards the patterns users care about ("spl" on "Split Left" beats "spl"
/// on "spinlock"), and dropping it keeps the algorithm pure DP without a
/// third state dimension. Score-wise negligible at palette scale (<50 items).
///
/// Complexity: O(|query| × |candidate|). For Katib's 30-odd commands with
/// sub-100-char titles, a full scan is sub-millisecond.
public enum FuzzyMatch {
    public static func score(query rawQuery: String, candidate rawCandidate: String) -> Int {
        let query = Array(rawQuery.lowercased())
        let candidate = Array(rawCandidate.lowercased())
        guard !query.isEmpty else { return 1 }
        guard query.count <= candidate.count else { return 0 }

        let qLen = query.count
        let cLen = candidate.count
        let notFound = Int.min / 2

        // scores[qIdx][cIdx] = best score matching query[qIdx..] starting at
        // candidate position cIdx. Built bottom-up so each cell reads from
        // cells already filled.
        var scores = Array(repeating: Array(repeating: 0, count: cLen + 1), count: qLen + 1)

        // Base row: candidate exhausted before query fully consumed = no match.
        for qIdx in 0..<qLen { scores[qIdx][cLen] = notFound }

        for qIdx in stride(from: qLen - 1, through: 0, by: -1) {
            for cIdx in stride(from: cLen - 1, through: 0, by: -1) {
                // Option 1: skip this candidate char (gap penalty).
                let skip = scores[qIdx][cIdx + 1] - 1

                // Option 2: take this match if chars agree.
                var take = notFound
                if query[qIdx] == candidate[cIdx] {
                    var delta = 10
                    if cIdx == 0 {
                        delta += 15
                    } else {
                        let prev = candidate[cIdx - 1]
                        if prev == " " || prev == "." || prev == "_" || prev == "-" || prev == "/" {
                            delta += 15
                        }
                    }
                    take = delta + scores[qIdx + 1][cIdx + 1]
                }

                scores[qIdx][cIdx] = max(skip, take)
            }
        }

        return max(0, scores[0][0])
    }
}
