import Foundation

/// Merging two edits of a note made on different devices since they last agreed (a three-way, line-by-line merge
/// against that common version). Used only by the side whose edit lost (shared/CONTRACT.md → ge.connect.notes).
enum NoteMerge {
    /// The merged text, or nil when both changed the same lines differently (then a copy is kept instead).
    /// Rules per changed stretch: one side changed it → that change; both made the same change → once; both only
    /// added lines there → the winner's, then the loser's; both changed the same number of lines → line by line (so
    /// ticking neighbouring checklist items on each side merges); anything else is a clash.
    static func merge(base: String, winner: String, loser: String) -> String? {
        let o = lines(base), a = lines(winner), b = lines(loser)
        guard o.count * max(a.count, b.count) <= 2_000_000 else { return nil }   // too big to compare quickly
        let ma = matches(o, a), mb = matches(o, b)
        var out: [Substring] = []
        var i = 0, ia = 0, ib = 0
        while true {
            // The next line of the base that both kept, at or after where we are.
            var k = i
            while k < o.count, !(ma[k].map { $0 >= ia } ?? false && mb[k].map { $0 >= ib } ?? false) { k += 1 }
            if k == o.count {
                guard let chunk = resolve(Array(o[i...]), Array(a[ia...]), Array(b[ib...])) else { return nil }
                out += chunk
                break
            }
            let (ka, kb) = (ma[k]!, mb[k]!)
            if k == i, ka == ia, kb == ib {
                out.append(o[i]); i += 1; ia += 1; ib += 1
                continue
            }
            guard let chunk = resolve(Array(o[i..<k]), Array(a[ia..<ka]), Array(b[ib..<kb])) else { return nil }
            out += chunk
            i = k; ia = ka; ib = kb
        }
        return out.joined(separator: "\n")
    }

    /// The copy kept after a clash: its title says where it came from ("Groceries (from Alex's MacBook)").
    static func labelled(_ text: String, from device: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let label = " (from \(device))"
        if let t = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines[t] += label
        } else {
            lines = ["Note" + label] + lines
        }
        return lines.joined(separator: "\n")
    }

    private static func lines(_ s: String) -> [Substring] { s.split(separator: "\n", omittingEmptySubsequences: false) }

    private static func resolve(_ o: [Substring], _ a: [Substring], _ b: [Substring]) -> [Substring]? {
        if a == o { return b }
        if b == o || a == b { return a }
        if o.isEmpty { return a + b }
        if a.count == o.count, b.count == o.count {
            var out: [Substring] = []
            for j in o.indices {
                if a[j] == o[j] { out.append(b[j]) } else if b[j] == o[j] || a[j] == b[j] { out.append(a[j]) } else { return nil }
            }
            return out
        }
        return nil
    }

    /// For each line of `o`, the line of `x` it's matched with in a longest common subsequence (nil: removed or changed).
    private static func matches(_ o: [Substring], _ x: [Substring]) -> [Int?] {
        let n = o.count, m = x.count
        var result = [Int?](repeating: nil, count: n)
        guard n > 0, m > 0 else { return result }
        // Lengths of the common subsequence of o[i...] and x[j...], row by row.
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = o[i] == x[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0
        while i < n, j < m {
            if o[i] == x[j] { result[i] = j; i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return result
    }
}
