import Foundation

/// A line-by-line comparison of two texts in the usual unified diff format.
public enum UnifiedDiff {
    /// Returns nil when the texts are the same.
    public static func make(
        old: String, new: String, oldName: String, newName: String, context: Int = 3
    ) -> String? {
        guard old != new else { return nil }
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        // Compare numbers instead of strings; long files have many equal lines.
        var ids: [String: Int] = [:]
        func id(_ line: String) -> Int {
            if let known = ids[line] { return known }
            ids[line] = ids.count
            return ids.count - 1
        }
        let difference = newLines.map(id).difference(from: oldLines.map(id))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        struct Line {
            var mark: Character
            var text: String
            var old: Int
            var new: Int
        }
        var lines: [Line] = []
        var i = 0
        var j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                lines.append(Line(mark: "-", text: oldLines[i], old: i, new: j))
                i += 1
            } else if j < newLines.count, inserted.contains(j) {
                lines.append(Line(mark: "+", text: newLines[j], old: i, new: j))
                j += 1
            } else {
                lines.append(Line(mark: " ", text: oldLines[i], old: i, new: j))
                i += 1
                j += 1
            }
        }

        var output = "--- \(oldName)\n+++ \(newName)\n"
        var index = 0
        while index < lines.count {
            guard lines[index].mark != " " else {
                index += 1
                continue
            }
            // A hunk runs from `context` lines before a change until `context` unchanged lines
            // follow the last change with no further change within reach.
            let start = max(index - context, 0)
            var end = index
            var scan = index
            while scan < lines.count, scan <= end + 2 * context {
                if lines[scan].mark != " " { end = scan }
                scan += 1
            }
            let stop = min(end + context, lines.count - 1)
            let hunk = lines[start...stop]
            let oldCount = hunk.filter { $0.mark != "+" }.count
            let newCount = hunk.filter { $0.mark != "-" }.count
            output += "@@ -\(lines[start].old + 1),\(oldCount) +\(lines[start].new + 1),\(newCount) @@\n"
            for line in hunk { output += "\(line.mark)\(line.text)\n" }
            index = stop + 1
        }
        return output
    }
}
