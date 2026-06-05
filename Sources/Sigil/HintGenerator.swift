import Foundation

/// Generates short, unique, keyboard-friendly labels ("sigils"), mirroring Vimium's algorithm.
///
/// Properties guaranteed:
/// - No label is a prefix of another, so a completed label is unambiguous.
/// - Labels are kept as short as the alphabet allows for the requested count.
/// - Home-row characters come first in the alphabet so the most common (single-char) hints
///   are the easiest to type.
struct HintGenerator {
    /// Home row first, then top row, then bottom row.
    static let defaultAlphabet = Array("ASDFGHJKLQWERTYUIOPZXCVBNM")

    let alphabet: [Character]

    init(alphabet: [Character] = HintGenerator.defaultAlphabet) {
        self.alphabet = alphabet
    }

    func generate(count: Int) -> [String] {
        guard count > 0, !alphabet.isEmpty else { return [] }

        // Build candidate labels by repeatedly prepending alphabet characters to a growing
        // queue. Prepending (rather than appending) keeps short labels in front.
        var hints: [String] = [""]
        var offset = 0
        while (hints.count - offset) < count || hints.count == 1 {
            let prefix = hints[offset]
            offset += 1
            for character in alphabet {
                hints.append(String(character) + prefix)
            }
        }

        let slice = hints[offset ..< (offset + count)]
        // Each candidate was built reversed; flip back, then sort for stable visual ordering.
        return slice.map { String($0.reversed()) }.sorted()
    }
}
