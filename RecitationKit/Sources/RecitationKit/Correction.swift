// Live correction (docs: spec/live-correction.md). Conservative: only gross
// mismatches between clear neighbouring words become "possible mistakes".

public enum RecitationMode: String, Sendable, CaseIterable {
  case tracking, correction
}

public enum CorrectionAction: String, Sendable {
  case retry
  case stopRetry = "stop_retry"
  case dismiss
  case reviewLater = "review_later"
  case continueReciting = "continue"
  case close
}

public struct RecitationPosition: Equatable, Sendable {
  public var surah: Int
  public var ayah: Int
  public var word: Int
  public init(surah: Int, ayah: Int, word: Int) {
    self.surah = surah
    self.ayah = ayah
    self.word = word
  }
}

public struct CorrectionIssue: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case possibleOmission = "possible_omission"
    case possibleSubstitution = "possible_substitution"
    case possibleVowel = "possible_vowel"
    /// Ayah N+2 matched right after N, and nothing of N+1 was heard.
    case possibleSkippedAyah = "possible_skipped_ayah"
    /// Ayah N+2 matched right after N; N+1 was heard but not followed.
    case unclearAyah = "unclear_ayah"

    public var isAyahLevel: Bool { self == .possibleSkippedAyah || self == .unclearAyah }
  }

  public var surah: Int
  public var ayah: Int
  public var word: Int
  public var wordIndex: Int
  public var kind: Kind
  /// Words covered from `word` (nil = 1). Ayah-level issues cover the whole ayah.
  public var words: Int?
}

public struct CorrectionThresholds: Equatable, Sendable {
  /// Min p(heard vowel) − p(expected vowel) on a mismatched vowel.
  public var vowelMargin: Double = 0.05
  /// Min mean word margin for a vowel flag.
  public var vowelWordMargin: Double = 0.5
  public static let `default` = CorrectionThresholds()
}

public struct CorrectionState: Equatable, Sendable {
  public enum Phase: String, Sendable { case idle, error, retrying, corrected }
  public enum Outcome: String, Sendable { case dismissed, deferred, corrected }
  public var phase: Phase = .idle
  public var issue: CorrectionIssue?
  public var resume: RecitationPosition?
  public var attempt = 0
  public var outcome: Outcome?
}

/// Frames (40 ms each) evidence must persist before it counts.
private let persistFrames = 12

private func isClear(_ v: WordVerdict?) -> Bool {
  guard let v else { return false }
  return v.state == .ok && v.distance.isFinite && v.distance <= 0.15
    && v.margin.isFinite && v.margin >= 0.55
    && v.heardRatio.isFinite && v.heardRatio >= 0.75 && v.heardRatio <= 1.3
}

/// Word-level possible mistakes with clear neighbours in the same ayah.
public func possibleWordIssues(_ verdicts: [WordVerdict], thresholds th: CorrectionThresholds = .default) -> [CorrectionIssue] {
  var byIndex: [Int: WordVerdict] = [:]
  for v in verdicts { byIndex[v.wordIndex] = v }
  return verdicts.compactMap { v in
    guard let before = byIndex[v.wordIndex - 1], let after = byIndex[v.wordIndex + 1],
          isClear(before), isClear(after),
          before.surah == v.surah, after.surah == v.surah, before.ayah == v.ayah, after.ayah == v.ayah else { return nil }
    let omission = v.state == .skipped && v.heardRatio == 0
    let substitution = v.state == .wrong && v.distance.isFinite && v.distance >= 0.6
      && v.margin.isFinite && v.margin >= 0.65 && v.heardRatio >= 0.5 && v.heardRatio <= 1.5
    let vowel = (v.state == .ok || v.state == .unsure) && v.distance.isFinite && v.distance <= 0.15
      && v.vowelErrors >= 1 && v.vowelMargin.isFinite && v.vowelMargin >= th.vowelMargin
      && v.margin.isFinite && v.margin >= th.vowelWordMargin
      && v.heardRatio >= 0.75 && v.heardRatio <= 1.3
    let kind: CorrectionIssue.Kind? = omission ? .possibleOmission : substitution ? .possibleSubstitution : vowel ? .possibleVowel : nil
    return kind.map { CorrectionIssue(surah: v.surah, ayah: v.ayah, word: v.word, wordIndex: v.wordIndex, kind: $0) }
  }
}

/// Pure state machine over full, non-forced acoustic verdict snapshots.
public final class CorrectionController {
  public var mode: RecitationMode = .tracking
  public var thresholds = CorrectionThresholds.default
  public private(set) var state = CorrectionState()
  private var suppressed = Set<Int>()
  private var candidates: [Int: (kind: CorrectionIssue.Kind, frame: Int)] = [:]
  private var retryFrame: Int?

  public init() {}

  public func reset() {
    state = CorrectionState(attempt: state.attempt + 1)
    suppressed.removeAll()
    clearEvidence()
  }

  public func clearEvidence() {
    candidates.removeAll()
    retryFrame = nil
  }

  public func setMode(_ mode: RecitationMode) {
    self.mode = mode
    clearEvidence()
  }

  /// Returns true when the state changed (a flag, or a successful retry).
  public func observe(_ verdicts: [WordVerdict], cursor: RecitationPosition, frame: Int, attempt: Int? = nil) -> Bool {
    if mode != .correction || (attempt ?? state.attempt) != state.attempt { return false }
    if state.phase == .retrying {
      guard let issue = state.issue else { return false }
      // A fresh, clear prefix from the start of the ayah through the flagged
      // words; a verse match or cursor advance alone cannot succeed.
      let through = issue.word + max(1, issue.words ?? 1) - 1
      let prefix = verdicts.filter { $0.surah == issue.surah && $0.ayah == issue.ayah && $0.word <= through }
      let good = (0...through).allSatisfy { word in
        let v = prefix.first { $0.word == word }
        // A retry that repeats a confident vowel error is not a correction.
        return isClear(v) && (v!.vowelErrors == 0 || v!.vowelMargin < thresholds.vowelMargin)
      }
      if !good {
        retryFrame = nil
        return false
      }
      if retryFrame == nil || frame < retryFrame! { retryFrame = frame }
      if frame - retryFrame! < persistFrames { return false }
      state.phase = .corrected
      state.outcome = .corrected
      return true
    }
    if state.phase != .idle { return false }
    let issues = possibleWordIssues(verdicts, thresholds: thresholds).filter { !suppressed.contains($0.wordIndex) }
    let live = Set(issues.map(\.wordIndex))
    candidates = candidates.filter { live.contains($0.key) }
    for issue in issues {
      if let old = candidates[issue.wordIndex], old.kind == issue.kind, frame >= old.frame {
        if frame - old.frame >= persistFrames {
          state = CorrectionState(phase: .error, issue: issue, resume: cursor, attempt: state.attempt, outcome: nil)
          clearEvidence()
          return true
        }
      } else {
        candidates[issue.wordIndex] = (issue.kind, frame)
      }
    }
    return false
  }

  /// Raise an issue inferred outside the word rules (the ayah-level kinds),
  /// with the same gates as a word flag.
  public func raise(_ issue: CorrectionIssue, cursor: RecitationPosition) -> Bool {
    if mode != .correction || state.phase != .idle || suppressed.contains(issue.wordIndex) { return false }
    state = CorrectionState(phase: .error, issue: issue, resume: cursor, attempt: state.attempt, outcome: nil)
    clearEvidence()
    return true
  }

  public func act(_ action: CorrectionAction) -> Bool {
    let phase = state.phase
    guard let issue = state.issue, phase != .idle else { return false }
    if action == .retry && (phase == .error || phase == .corrected) {
      state.phase = .retrying
      state.attempt += 1
      state.outcome = nil
    } else if action == .stopRetry && phase == .retrying {
      state.phase = .error
      state.attempt += 1
    } else if (action == .dismiss && phase == .error) || action == .reviewLater || action == .close
                || (action == .continueReciting && phase == .corrected) {
      let outcome: CorrectionState.Outcome = action == .dismiss ? .dismissed : phase == .corrected ? .corrected : .deferred
      suppressed.insert(issue.wordIndex)
      state.phase = .idle
      state.attempt += 1
      state.outcome = outcome
    } else {
      return false
    }
    clearEvidence()
    return true
  }
}
