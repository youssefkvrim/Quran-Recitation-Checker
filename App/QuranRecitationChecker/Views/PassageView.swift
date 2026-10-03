import RecitationKit
import SwiftUI

/// The surah and the last few ayahs as one flowing paragraph, like the web
/// app: recited ayahs muted, the current ayah's spoken words muted, the
/// current word in ink.
struct PassageView: View {
  let surah: QuranText.Surah
  let position: RecitationModel.Position

  private var range: ClosedRange<Int> {
    let last = min(max(position.ayah, 1), surah.ayahs.count)
    return max(1, last - 2)...last
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(surah.nameEn)
        .font(.title2)
      Text("Surah \(surah.number) · Ayah \(position.ayah)")
        .font(.footnote)
        .foregroundStyle(Color.muted)
        .contentTransition(.numericText())
        .padding(.top, 2)
      Divider().padding(.vertical, 14)
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          if range.lowerBound == 1, surah.number != 1, surah.number != 9, QuranText.startsWithBismillah(surah.ayahs[0]) {
            Text(bismillah).font(.quran(size: 24)).foregroundStyle(Color.muted)
          }
          Text(passage)
            .font(.quran(size: 29))
            .lineSpacing(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, .rightToLeft)
      }
      .defaultScrollAnchor(.bottom)
      .scrollIndicators(.hidden)
    }
    .animation(.smooth, value: position)
  }

  private var bismillah: String {
    QuranText.ayahWords(surah: surah.number, ayah: 1, text: surah.ayahs[0]).filter { $0.count == 0 }.map(\.text).joined(separator: " ")
  }

  private var passage: AttributedString {
    var out = AttributedString()
    for ayah in range {
      let words = QuranText.ayahWords(surah: surah.number, ayah: ayah, text: surah.ayahs[ayah - 1]).filter { $0.count > 0 }
      for (i, word) in words.enumerated() {
        var piece = AttributedString(word.text)
        if ayah < position.ayah {
          piece.foregroundColor = Color.muted
        } else if word.covers(position.word) {
          piece.foregroundColor = Color.paper
          piece.backgroundColor = Color.ink
        } else {
          piece.foregroundColor = word.first + word.count <= position.word ? Color.muted : Color.ink
        }
        out += piece
        if i < words.count - 1 { out += AttributedString(" ") }
      }
      var marker = AttributedString(" \u{06DD}\(arabicDigits(ayah)) ")
      marker.foregroundColor = Color.muted
      out += marker
    }
    return out
  }
}

/// One ayah, for the correction sheet: the flagged words in rose.
struct AyahView: View {
  let surah: Int
  let ayah: Int
  let text: String
  /// Flagged acoustic words `lowerBound..<upperBound`.
  var flagged: Range<Int> = 0..<0
  var size: CGFloat = 28

  var body: some View {
    let words = QuranText.ayahWords(surah: surah, ayah: ayah, text: text).filter { $0.count > 0 }
    Text(attributed(words))
      .font(.quran(size: size))
      .lineSpacing(size * 0.45)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .accessibilityLabel(text)
  }

  private func attributed(_ words: [DisplayWord]) -> AttributedString {
    var out = AttributedString()
    for (i, word) in words.enumerated() {
      var piece = AttributedString(word.text)
      if flagged.overlaps(word.first..<(word.first + word.count)) {
        piece.foregroundColor = Color.rose
        piece.backgroundColor = Color.roseWash
      } else {
        piece.foregroundColor = Color.ink
      }
      out += piece
      if i < words.count - 1 { out += AttributedString(" ") }
    }
    var marker = AttributedString(" \u{06DD}\(arabicDigits(ayah))")
    marker.foregroundColor = Color.muted
    return out + marker
  }
}

func arabicDigits(_ n: Int) -> String {
  String(String(n).map { ch in ch.wholeNumberValue.map { Character(UnicodeScalar(0x0660 + $0)!) } ?? ch })
}
