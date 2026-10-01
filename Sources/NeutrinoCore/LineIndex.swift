import Foundation

/// UTF-16 offsets of every line start, kept up to date as the text changes.
/// Lines end with "\n"; the editor normalises other line endings when it loads a file.
public struct LineIndex {
    public private(set) var starts: [Int] = [0]

    public init() {}

    public init(_ string: NSString) {
        rebuild(string)
    }

    public var count: Int { starts.count }

    public mutating func rebuild(_ string: NSString) {
        starts = [0]
        Self.appendLineStarts(in: string, range: NSRange(location: 0, length: string.length), to: &starts)
    }

    /// 0-based line containing the UTF-16 offset.
    public func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    public func start(ofLine line: Int) -> Int {
        starts[min(max(line, 0), starts.count - 1)]
    }

    /// Updates the index after an edit. `newRange` is the edited range in the text as it is now,
    /// `delta` the change in length, as reported by NSTextStorage.
    public mutating func edited(newRange: NSRange, delta: Int, in string: NSString) {
        let location = newRange.location
        let oldEnd = location + newRange.length - delta

        // Line starts whose newline was inside the replaced text go away.
        let first = line(at: location) + 1
        var last = first
        while last < starts.count && starts[last] <= oldEnd { last += 1 }
        if delta != 0 {
            for i in last..<starts.count { starts[i] += delta }
        }
        var inserted: [Int] = []
        Self.appendLineStarts(in: string, range: newRange, to: &inserted)
        starts.replaceSubrange(first..<last, with: inserted)
    }

    private static func appendLineStarts(in string: NSString, range: NSRange, to starts: inout [Int]) {
        let end = NSMaxRange(range)
        guard end > range.location else { return }
        // No larger than the range: this runs for every key typed.
        let chunk = min(1 << 16, range.length)
        var buffer = [unichar](repeating: 0, count: chunk)
        var position = range.location
        while position < end {
            let length = min(chunk, end - position)
            string.getCharacters(&buffer, range: NSRange(location: position, length: length))
            for i in 0..<length where buffer[i] == 0x0A {
                starts.append(position + i + 1)
            }
            position += length
        }
    }
}
