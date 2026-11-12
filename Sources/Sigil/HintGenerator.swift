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
    /// Appended to the letters only when a scan needs more labels than two letters can give, so
    /// everyday hints stay letters-only while large budgets still fit in two keystrokes.
    static let digitAlphabet = Array("123456789")
    /// Most labels two letters can produce (26 × 26).
    static let twoCharacterLetterLimit = defaultAlphabet.count * defaultAlphabet.count

    /// The alphabet used for `count` labels: letters alone up to the two-letter limit, letters
    /// plus digits beyond it (35 characters → 1225 two-character labels).
    static func alphabet(forCount count: Int) -> [Character] {
        count > twoCharacterLetterLimit ? defaultAlphabet + digitAlphabet : defaultAlphabet
    }

    /// `nil` means "choose by count" via `alphabet(forCount:)`; a value fixes the alphabet.
    private let fixedAlphabet: [Character]?

    init() {
        fixedAlphabet = nil
    }

    init(alphabet: [Character]) {
        fixedAlphabet = alphabet
    }

    func generate(count: Int) -> [String] {
        let alphabet = fixedAlphabet ?? Self.alphabet(forCount: count)
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
