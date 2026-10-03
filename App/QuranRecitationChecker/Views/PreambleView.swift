import RecitationKit
import SwiftUI

/// The istiʿādha or basmala, followed word by word while the surah is not yet known.
struct PreambleView: View {
  let progress: PreambleProgress

  private static let istiadha = ["أَعُوذُ", "بِٱللَّهِ", "مِنَ", "ٱلشَّيْطَٰنِ", "ٱلرَّجِيمِ"]
  private static let basmala = ["بِسْمِ", "ٱللَّهِ", "ٱلرَّحْمَٰنِ", "ٱلرَّحِيمِ"]

  var body: some View {
    let words = progress.kind == .istiadha ? Self.istiadha : Self.basmala
    Text(attributed(words))
      .font(.quran(size: 30))
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .environment(\.layoutDirection, .rightToLeft)
      .animation(.smooth, value: progress)
      .accessibilityLabel(words.joined(separator: " "))
  }

  private func attributed(_ words: [String]) -> AttributedString {
    var out = AttributedString()
    for (i, word) in words.enumerated() {
      var piece = AttributedString(word)
      if i < progress.words {
        piece.foregroundColor = Color.muted
      } else if i == progress.words {
        piece.foregroundColor = Color.paper
        piece.backgroundColor = Color.ink
      } else {
        piece.foregroundColor = Color.ink
      }
      out += piece
      if i < words.count - 1 { out += AttributedString(" ") }
    }
    return out
  }
}
