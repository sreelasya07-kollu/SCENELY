import Foundation

/// "What was found in the room" for the review screens: lifted objects counted per class plus the doors and windows the
/// core found, e.g. "2 chairs, 1 sofa, 1 TV, 1 door". Port of the Kotlin ObjectSummary.
public enum ObjectSummary {
    /// One line of the summary: `name` is the core class name (or "door" / "window"), `n` >= 1.
    public struct Count: Equatable {
        public let name: String
        public let n: Int
        public init(name: String, n: Int) { self.name = name; self.n = n }
        public var text: String { "\(n) \(LabelMap.displayName(name, plural: n != 1))" }
    }

    /// Counts, most frequent first; ties keep the order in which each kind first appears (objects before openings).
    /// Blank / "unknown" class names and openings of another kind are skipped.
    public static func counts(objects: [ObjectBox], openings: [Opening] = []) -> [Count] {
        var order: [String] = []
        var n: [String: Int] = [:]
        func add(_ k: String) {
            if n[k] == nil { order.append(k); n[k] = 0 }
            n[k]! += 1
        }
        for o in objects where !o.cls.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && o.cls != "unknown" { add(o.cls) }
        for o in openings where o.kind == "door" || o.kind == "window" { add(o.kind) }
        let all = order.map { Count(name: $0, n: n[$0]!) }
        // Stable sort by count descending (first-seen order on ties).
        return all.enumerated().sorted { a, b in a.element.n != b.element.n ? a.element.n > b.element.n : a.offset < b.offset }.map { $0.element }
    }

    /// "2 chairs, 1 sofa, 1 door"; "" when nothing was found.
    public static func text(objects: [ObjectBox], openings: [Opening] = []) -> String {
        counts(objects: objects, openings: openings).map { $0.text }.joined(separator: ", ")
    }
}
