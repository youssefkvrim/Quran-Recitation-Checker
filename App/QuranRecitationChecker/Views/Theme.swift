import SwiftUI
import UIKit

/// The web app's palette: ink on paper, muted for what is behind the reader,
/// rose for a possible mistake. Ink and paper swap in dark mode.
extension Color {
  static let ink = Color(uiColor: .label)
  static let paper = Color(uiColor: .systemBackground)
  static let muted = Color(uiColor: .secondaryLabel)
  static let rule = Color(uiColor: .separator)
  static let surface = Color(uiColor: .secondarySystemBackground)
  static let rose = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
    ? UIColor(red: 0.95, green: 0.55, blue: 0.66, alpha: 1)
    : UIColor(red: 0.608, green: 0.161, blue: 0.282, alpha: 1) })
  static let roseWash = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
    ? UIColor(red: 0.36, green: 0.13, blue: 0.19, alpha: 1)
    : UIColor(red: 0.973, green: 0.918, blue: 0.941, alpha: 1) })
}

extension Font {
  /// Amiri (OFL, bundled): renders every Uthmani mark the text uses.
  static func quran(size: CGFloat) -> Font { .custom("Amiri", size: size) }
}

/// Full-width primary and secondary actions, like the web app's buttons.
struct ActionLabel: View {
  let title: String
  let systemImage: String
  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.body.weight(.semibold))
      .frame(maxWidth: .infinity, minHeight: 34)
  }
}

extension View {
  func primaryAction() -> some View {
    buttonStyle(.glassProminent)
      .tint(Color.ink)
      .foregroundStyle(Color.paper)
      .controlSize(.large)
      .buttonBorderShape(.roundedRectangle(radius: 16))
  }

  func secondaryAction() -> some View {
    buttonStyle(.glass)
      .foregroundStyle(Color.ink)
      .controlSize(.large)
      .buttonBorderShape(.roundedRectangle(radius: 16))
  }
}
