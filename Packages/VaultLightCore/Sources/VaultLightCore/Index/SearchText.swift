import Foundation

/// Text normalized for matching: case-, diacritic- and width-folded Unicode scalars (spec 5.1).
///
/// Scalars instead of `String` keep each keystroke's comparisons cheap and exact once both sides are folded.
struct SearchText: Sendable, Equatable {
    let scalars: [Unicode.Scalar]

    init(_ text: String) {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        scalars = Array(folded.unicodeScalars)
    }

    var isEmpty: Bool { scalars.isEmpty }

    /// Offsets where a word starts after the first one: an alphanumeric scalar after a non-alphanumeric one.
    var innerWordStarts: [Int] {
        scalars.indices.dropFirst().filter { Self.isAlphanumeric(scalars[$0]) && !Self.isAlphanumeric(scalars[$0 - 1]) }
    }

    /// Offsets where a host label starts: the beginning, and after every "." or "-".
    var labelStarts: [Int] {
        [0] + scalars.indices.dropLast().filter { scalars[$0] == "." || scalars[$0] == "-" }.map { $0 + 1 }
    }

    func hasPrefix(_ query: SearchText, at offset: Int = 0) -> Bool {
        scalars[offset...].starts(with: query.scalars)
    }

    /// Whether every non-whitespace scalar of `query` appears in this text, in order.
    func containsSubsequence(_ query: SearchText) -> Bool {
        var remaining = query.scalars.lazy.filter { !$0.properties.isWhitespace }.makeIterator()
        guard var next = remaining.next() else { return false }
        for scalar in scalars where scalar == next {
            guard let following = remaining.next() else { return true }
            next = following
        }
        return false
    }

    /// Whether this text precedes `other` in result order (folded name order).
    func precedes(_ other: SearchText) -> Bool {
        scalars.lexicographicallyPrecedes(other.scalars)
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
