import RecitationKit
import SwiftUI

/// Focused practice on a possible mistake. Presentation only: every state
/// comes from the engine's acoustic evidence.
struct CorrectionSheet: View {
  let correction: RecitationModel.OpenCorrection
  let acting: Bool
  let act: (CorrectionAction) -> Void

  private var state: CorrectionState { correction.state }
  private var issue: CorrectionIssue { state.issue! }
  private var wholeAyah: Bool { issue.kind.isAyahLevel }

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        Text(status)
          .font(.caption.weight(.semibold))
          .foregroundStyle(state.phase == .retrying ? Color.rose : Color.muted)
          .tracking(1.2)
        Text("\(correction.surahName) · Ayah \(issue.ayah) of \(correction.ayahCount)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        AyahView(surah: issue.surah, ayah: issue.ayah, text: correction.text,
                 flagged: wholeAyah ? 0..<Int.max : issue.word..<(issue.word + max(1, issue.words ?? 1)),
                 size: 28)
        VStack(spacing: 6) {
          Text(title).font(.title3.weight(.semibold))
          Text(description).font(.body).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        VStack(spacing: 10) {
          Button { act(primary.action) } label: { Text(primary.label).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34) }
            .primaryAction()
          Button { act(secondary.action) } label: { Text(secondary.label).frame(maxWidth: .infinity, minHeight: 34) }
            .secondaryAction()
        }
        .disabled(acting)
      }
      .padding(24)
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .sensoryFeedback(.success, trigger: state.phase) { _, phase in phase == .corrected }
  }

  private var status: String {
    switch state.phase {
    case .retrying: return "RETRYING · MICROPHONE ON"
    case .corrected: return "RETRY COMPLETE"
    default:
      switch issue.kind {
      case .possibleVowel: return "POSSIBLE VOWEL SLIP"
      case .possibleSkippedAyah: return "POSSIBLE SKIPPED AYAH"
      case .unclearAyah: return "AYAH NOT FOLLOWED"
      default: return "POSSIBLE MISTAKE"
      }
    }
  }

  private var title: String {
    switch state.phase {
    case .retrying: return "Take your time."
    case .corrected: return "That’s corrected."
    default:
      switch issue.kind {
      case .possibleVowel: return "Check the vowel on this word."
      case .possibleSkippedAyah: return "Ayah \(issue.ayah) may have been skipped."
      case .unclearAyah: return "We couldn’t follow ayah \(issue.ayah). Recite it again."
      default: return "One word. Try again."
      }
    }
  }

  private var description: String {
    let n = issue.ayah
    switch state.phase {
    case .retrying:
      return wholeAyah ? "Repeat ayah \(n) from the beginning. We’ll listen for the whole ayah."
        : "Repeat ayah \(n) from the beginning. We’ll check the highlighted word again."
    case .corrected:
      return wholeAyah ? "The ayah was detected in your retry. Continue from your saved place."
        : "The word was detected in your retry. Continue from your saved place."
    default:
      switch issue.kind {
      case .possibleSkippedAyah: return "We heard ayah \(n - 1) and then ayah \(n + 1), but not ayah \(n). Recite it before you continue."
      case .unclearAyah: return "We heard you recite, but could not match ayah \(n). Recite it from the beginning at a steady pace."
      case .possibleVowel: return "Recite ayah \(n) again and listen for the highlighted word’s harakah."
      default: return "Recite the ayah above, including the highlighted word."
      }
    }
  }

  private var primary: (label: String, action: CorrectionAction) {
    switch state.phase {
    case .retrying: ("Stop retry", .stopRetry)
    case .corrected: ("Continue reciting", .continueReciting)
    default: ("Retry ayah", .retry)
    }
  }

  private var secondary: (label: String, action: CorrectionAction) {
    switch state.phase {
    case .retrying: ("Review later", .reviewLater)
    case .corrected: ("Practice once more", .retry)
    default: ("I recited it correctly", .dismiss)
    }
  }
}
