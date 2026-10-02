import Foundation

/// One number per line of a text, so two versions can be compared without keeping both.
public enum LineHashes {
    public static func make(_ string: NSString) -> [Int] {
        let basis: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        var hashes: [Int] = []
        let length = string.length
        let chunk = min(1 << 16, max(length, 1))
        var buffer = [unichar](repeating: 0, count: chunk)
        var hash = basis
        var position = 0
        while position < length {
            let count = min(chunk, length - position)
            string.getCharacters(&buffer, range: NSRange(location: position, length: count))
            for i in 0..<count {
                let c = buffer[i]
                if c == 0x0A {
                    hashes.append(Int(truncatingIfNeeded: hash))
                    hash = basis
                } else {
                    hash = (hash ^ UInt64(c)) &* prime
                }
            }
            position += count
        }
        hashes.append(Int(truncatingIfNeeded: hash))
        return hashes
    }
}

/// Which lines of a text differ from an earlier version of it.
public struct ChangedLines: Equatable {
    /// Lines that are new or altered, counted from 0.
    public var changed = Set<Int>()
    /// Lines above which something was taken out.
    public var removed = Set<Int>()

    public init() {}

    public var isEmpty: Bool { changed.isEmpty && removed.isEmpty }

    /// Compares the line hashes of two versions. When they differ in more than `maxEdits`
    /// places, every line between the first and the last difference counts as changed.
    public static func compare(old: [Int], new: [Int], maxEdits: Int = 1000) -> ChangedLines {
        var result = ChangedLines()
        // Most edits are in one place: skip what is the same before and after it.
        var start = 0
        let shared = min(old.count, new.count)
        while start < shared, old[start] == new[start] { start += 1 }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        let last = max(new.count - 1, 0)
        if start == oldEnd {
            result.changed = Set(start..<newEnd)
        } else if start == newEnd {
            result.removed = [min(start, last)]
        } else if let script = edits(Array(old[start..<oldEnd]), Array(new[start..<newEnd]), limit: maxEdits) {
            result.changed = Set(script.inserted.map { $0 + start })
            for position in script.removedAt where !result.changed.contains(position + start) {
                result.removed.insert(min(position + start, last))
            }
        } else {
            result.changed = Set(start..<newEnd)
        }
        return result
    }

    /// The shortest set of insertions and removals that turns `a` into `b` (Myers' algorithm):
    /// the places in `b` that were inserted, and the places in `b` where something of `a` was
    /// removed. Nil when it takes more than `limit` of them.
    static func edits(_ a: [Int], _ b: [Int], limit: Int) -> (inserted: [Int], removedAt: [Int])? {
        let n = a.count
        let m = b.count
        let most = min(n + m, limit)
        let offset = most + 1
        var v = [Int32](repeating: 0, count: 2 * most + 3)
        // What `v` held before each round, for walking the path back.
        var trace: [[Int32]] = []
        for d in 0...most {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = Int(v[offset + k + 1])
                } else {
                    x = Int(v[offset + k - 1]) + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = Int32(x)
                if x >= n, y >= m {
                    var inserted: [Int] = []
                    var removedAt: [Int] = []
                    var x = n
                    var y = m
                    for round in stride(from: d, to: 0, by: -1) {
                        let before = trace[round]
                        let k = x - y
                        let down = k == -round || (k != round && before[k - 1 + round] < before[k + 1 + round])
                        let previousK = down ? k + 1 : k - 1
                        let previousX = Int(before[previousK + round])
                        let previousY = previousX - previousK
                        if down { inserted.append(previousY) } else { removedAt.append(previousY) }
                        x = previousX
                        y = previousY
                    }
                    return (inserted, removedAt)
                }
                k += 2
            }
        }
        return nil
    }
}
