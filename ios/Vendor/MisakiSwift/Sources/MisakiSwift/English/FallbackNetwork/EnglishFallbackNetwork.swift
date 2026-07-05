import Foundation

/// Rule-based grapheme→phoneme fallback for out-of-lexicon words.
///
/// VENDORED REPLACEMENT: upstream uses an MLX BART model here, but MLX cannot link
/// against the iOS simulator SDK (missing Metal symbols) and adds ~6MB of weights.
/// The gold/silver lexicons cover the overwhelming majority of news text; this
/// handles the tail (rare names, coinages) with ordered letter-to-sound rules over
/// the Misaki phoneme alphabet. Rougher than BART on exotic names, silent otherwise.
final class EnglishFallbackNetwork {
  private let british: Bool

  init(british: Bool) {
    self.british = british
  }

  func callAsFunction(_ word: MToken) -> (phoneme: String, rating: Int) {
    (Self.letterToSound(word.text.lowercased(), british: british), 1)
  }

  /// Ordered, greedy longest-match rules. Diphthongs use Misaki's capital encodings
  /// (A=eɪ, I=aɪ, O=oʊ, W=aʊ, Y=ɔɪ).
  static func letterToSound(_ text: String, british: Bool) -> String {
    let multi: [(String, String)] = [
      ("tion", "ʃən"), ("sion", "ʒən"), ("ture", "ʧəɹ"),
      ("eigh", "A"), ("aigh", "A"), ("igh", "I"),
      ("ch", "ʧ"), ("sh", "ʃ"), ("th", "θ"), ("ph", "f"), ("wh", "w"),
      ("ck", "k"), ("ng", "ŋ"), ("qu", "kw"), ("gh", "ɡ"),
      ("oo", "u"), ("ee", "i"), ("ea", "i"), ("ai", "A"), ("ay", "A"),
      ("oa", "O"), ("ou", "W"), ("ow", "W"), ("oi", "Y"), ("oy", "Y"),
      ("ie", "i"), ("ew", "ju"), ("au", "ɔ"), ("aw", "ɔ"), ("ey", "A"),
    ]
    let single: [Character: String] = [
      "a": "æ", "b": "b", "c": "k", "d": "d", "e": "ɛ", "f": "f",
      "g": "ɡ", "h": "h", "i": "ɪ", "j": "ʤ", "k": "k", "l": "l",
      "m": "m", "n": "n", "o": british ? "ɒ" : "ɑ", "p": "p", "q": "k",
      "r": "ɹ", "s": "s", "t": "t", "u": "ʌ", "v": "v", "w": "w",
      "x": "ks", "y": "ɪ", "z": "z",
    ]

    let chars = Array(text)
    var out = ""
    var i = 0
    while i < chars.count {
      // Greedy multi-char rules first.
      var matched = false
      for (pattern, phoneme) in multi where chars.count - i >= pattern.count {
        if String(chars[i..<(i + pattern.count)]) == pattern {
          out += phoneme
          i += pattern.count
          matched = true
          break
        }
      }
      if matched { continue }

      let c = chars[i]
      // Contextual singles.
      if c == "c", i + 1 < chars.count, "eiy".contains(chars[i + 1]) {
        out += "s"
      } else if c == "y", i == 0 {
        out += "j"                          // consonantal y (york)
      } else if c == "e", i == chars.count - 1, out.count > 1 {
        // silent final e (close enough for a fallback)
      } else if let p = single[c] {
        out += p
      }
      i += 1
    }
    return out
  }
}
