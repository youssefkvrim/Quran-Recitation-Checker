import RecitationKit
import SwiftUI

/// The surah header and the last few ayahs, the current one highlighted word by word.
struct PassageView: View {
  let surah: QuranText.Surah
  let position: RecitationModel.Position

  var body: some View {
    VStack(spacing: 14) {
      VStack(spacing: 2) {
        Text(surah.name)
          .font(.quran(size: 24))
        Text("\(surah.nameEn) · Ayah \(position.ayah) of \(surah.ayahs.count)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
      }
      ScrollView {
        VStack(spacing: 22) {
          ForEach(max(1, position.ayah - 2)...min(position.ayah, surah.ayahs.count), id: \.self) { ayah in
            AyahView(
              surah: surah.number, ayah: ayah, text: surah.ayahs[ayah - 1],
              progress: ayah == position.ayah ? .reading(position.word) : .recited
            )
            .opacity(ayah == position.ayah ? 1 : 0.45)
            .id(ayah)
          }
        }
        .padding(.vertical, 8)
      }
      .defaultScrollAnchor(.bottom)
      .scrollIndicators(.hidden)
      .animation(.smooth, value: position.ayah)
    }
  }
}

/// One ayah in Uthmani script. Words before the cursor are recited, the
/// cursor's word is highlighted, later words are dimmed.
struct AyahView: View {
  enum Progress: Equatable {
    case recited
    case reading(Int)
    /// Flagged acoustic words `lowerBound..<upperBound` (correction).
    case flagged(Range<Int>)
  }

  let surah: Int
  let ayah: Int
  let text: String
  var progress: Progress = .recited
  var size: CGFloat = 30

  var body: some View {
    let words = QuranText.ayahWords(surah: surah, ayah: ayah, text: text)
    VStack(spacing: 10) {
      let bismillah = words.filter { $0.count == 0 }.map(\.text).joined(separator: " ")
      if !bismillah.isEmpty {
        Text(bismillah).font(.quran(size: size * 0.8)).foregroundStyle(.secondary)
      }
      Text(attributed(words.filter { $0.count > 0 }))
        .font(.quran(size: size))
        .lineSpacing(size * 0.45)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(text)
  }

  private func attributed(_ words: [DisplayWord]) -> AttributedString {
    var out = AttributedString()
    for (i, word) in words.enumerated() {
      var piece = AttributedString(word.text)
      switch progress {
      case .recited:
        piece.foregroundColor = .primary
      case let .reading(at):
        if word.covers(at) {
          piece.foregroundColor = .accentColor
          piece.backgroundColor = Color.accentColor.opacity(0.14)
        } else {
          piece.foregroundColor = word.first + word.count <= at ? .primary : .secondary
        }
      case let .flagged(range):
        if range.overlaps(word.first..<(word.first + word.count)) {
          piece.foregroundColor = .red
          piece.backgroundColor = Color.red.opacity(0.12)
        } else {
          piece.foregroundColor = .primary
        }
      }
      out += piece
      if i < words.count - 1 { out += AttributedString(" ") }
    }
    var marker = AttributedString(" \u{06DD}\(arabicDigits(ayah))")
    marker.foregroundColor = .secondary
    return out + marker
  }
}

func arabicDigits(_ n: Int) -> String {
  String(String(n).map { ch in ch.wholeNumberValue.map { Character(UnicodeScalar(0x0660 + $0)!) } ?? ch })
}

extension Font {
  /// Amiri (OFL, bundled): renders every Uthmani mark the text uses.
  static func quran(size: CGFloat) -> Font { .custom("Amiri", size: size) }
}
