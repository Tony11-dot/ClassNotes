import Foundation
import UIKit

/// Fixes obvious misspellings in text already read back from handwriting — a
/// beautified "bautiful" becomes "beautiful". Uses `UITextChecker`, the system's
/// own on-device spell checker: no network call, no model, no per-use cost, so
/// it's safe to run on every beautified line.
public enum SpellCorrector {
    /// Replaces each misspelled word with the checker's own top guess, skipping
    /// short words, numbers and ALL-CAPS words (acronyms, not typos) so the pass
    /// stays conservative — a wrong "fix" is worse than leaving a rare word alone.
    @MainActor
    public static func correct(_ text: String, language: String) -> String {
        guard !text.isEmpty else { return text }
        let checker = UITextChecker()
        var result = text as NSString
        var searchRange = NSRange(location: 0, length: result.length)

        while searchRange.length > 0 {
            let misspelled = checker.rangeOfMisspelledWord(
                in: result as String, range: searchRange, startingAt: searchRange.location,
                wrap: false, language: language
            )
            guard misspelled.location != NSNotFound, misspelled.length > 0 else { break }

            let word = result.substring(with: misspelled)
            guard let guess = bestGuess(for: word, range: misspelled, in: result as String, checker: checker, language: language)
            else {
                let next = misspelled.location + misspelled.length
                searchRange = NSRange(location: next, length: max(0, result.length - next))
                continue
            }

            result = result.replacingCharacters(in: misspelled, with: guess) as NSString
            let next = misspelled.location + (guess as NSString).length
            searchRange = NSRange(location: next, length: max(0, result.length - next))
        }
        return result as String
    }

    @MainActor
    private static func bestGuess(
        for word: String, range: NSRange, in text: String, checker: UITextChecker, language: String
    ) -> String? {
        guard word.count > 2, word.rangeOfCharacter(from: .decimalDigits) == nil,
              word != word.uppercased()
        else { return nil }
        guard let guess = checker.guesses(forWordRange: range, in: text, language: language)?.first
        else { return nil }
        return matchCase(of: word, to: guess)
    }

    /// Mirrors the original word's capitalization onto the guess, so correcting a
    /// capitalized sentence-starter doesn't lowercase it, and correcting a plain
    /// lowercase word doesn't capitalize it just because the guess did.
    static func matchCase(of original: String, to guess: String) -> String {
        if original == original.lowercased() { return guess.lowercased() }
        let firstUpper = original.prefix(1) == original.prefix(1).uppercased()
        let restLower = original.dropFirst() == original.dropFirst().lowercased()
        if firstUpper, restLower {
            return guess.prefix(1).uppercased() + guess.dropFirst().lowercased()
        }
        return guess
    }
}
