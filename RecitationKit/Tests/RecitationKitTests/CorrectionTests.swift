import Testing
@testable import RecitationKit

private func word(_ n: Int, _ state: VerdictState = .ok, distance: Double = 0, margin: Double = 0.9, heardRatio: Double = 1,
                  vowelErrors: Int = 0, vowelMargin: Double = 0) -> WordVerdict {
  WordVerdict(surah: 112, ayah: 3, word: n, wordIndex: 100 + n, state: state, distance: distance, heardRatio: heardRatio,
              margin: margin, vowelErrors: vowelErrors, vowelMargin: vowelMargin)
}

private let correct = [word(0), word(1), word(2), word(3)]
private let omission = [word(0), word(1, .skipped, distance: 1, margin: 0, heardRatio: 0), word(2), word(3)]
private let substitution = [word(0), word(1, .wrong, distance: 0.8), word(2), word(3)]
private let vowel = [word(0), word(1, distance: 0.02, vowelErrors: 1, vowelMargin: 0.8), word(2), word(3)]
private let cursor = RecitationPosition(surah: 112, ayah: 3, word: 3)

private func flagged() -> CorrectionController {
  let c = CorrectionController()
  c.setMode(.correction)
  #expect(!c.observe(omission, cursor: cursor, frame: 30))
  #expect(c.observe(omission, cursor: cursor, frame: 42))
  return c
}

@Suite("Correction")
struct CorrectionTests {
  @Test func tracksByDefaultAndLeavesCorrectRecitationAlone() {
    let c = CorrectionController()
    #expect(c.mode == .tracking)
    #expect(!c.observe(omission, cursor: cursor, frame: 100))
    c.setMode(.correction)
    #expect(possibleWordIssues(correct).isEmpty)
  }

  @Test func omissionsSubstitutionsAndVowels() {
    #expect(possibleWordIssues(omission).map(\.kind) == [.possibleOmission])
    #expect(possibleWordIssues(substitution).map(\.kind) == [.possibleSubstitution])
    #expect(possibleWordIssues(vowel).map(\.kind) == [.possibleVowel])
    // Below the vowel margin, or with a shaky word, there is no vowel flag.
    #expect(possibleWordIssues([word(0), word(1, distance: 0.02, vowelErrors: 1, vowelMargin: 0.01), word(2)]).isEmpty)
    #expect(possibleWordIssues([word(0), word(1, distance: 0.02, margin: 0.3, vowelErrors: 1, vowelMargin: 0.8), word(2)]).isEmpty)
  }

  @Test func abstainsOnUnclearAudioPendingNearMissesAndBoundaries() {
    #expect(possibleWordIssues([word(0, .unsure), omission[1], word(2)]).isEmpty)
    #expect(possibleWordIssues([word(0), word(1, .pending), word(2)]).isEmpty)
    #expect(possibleWordIssues([word(0), word(1, .wrong, distance: 0.5), word(2)]).isEmpty)
    #expect(possibleWordIssues([omission[1], word(2)]).isEmpty)
    let otherAyah = WordVerdict(surah: 112, ayah: 4, word: 0, wordIndex: 102, state: .ok, distance: 0, heardRatio: 1, margin: 0.9)
    #expect(possibleWordIssues([word(0), omission[1], otherAyah]).isEmpty)
  }

  @Test func needsPersistentEvidenceAndCancelsRevisions() {
    let c = CorrectionController()
    c.setMode(.correction)
    #expect(!c.observe(omission, cursor: cursor, frame: 10))
    #expect(!c.observe(correct, cursor: cursor, frame: 15))
    #expect(!c.observe(omission, cursor: cursor, frame: 20))
    #expect(!c.observe(omission, cursor: cursor, frame: 31))
    #expect(c.observe(omission, cursor: cursor, frame: 32))
    #expect(c.state.phase == .error && c.state.issue?.word == 1 && c.state.resume == cursor)
  }

  @Test func dismissalAndCorrectionAreDistinct() {
    let c = flagged()
    #expect(c.act(.dismiss))
    #expect(c.state.phase == .idle && c.state.outcome == .dismissed)
    #expect(!c.observe(omission, cursor: cursor, frame: 100))
    #expect(!c.observe(omission, cursor: cursor, frame: 200)) // suppressed for the session
    c.reset()
    #expect(!c.observe(omission, cursor: cursor, frame: 0))
    #expect(c.observe(omission, cursor: cursor, frame: 12))
  }

  @Test func retryNeedsAFreshClearPrefix() {
    let c = flagged()
    #expect(c.act(.retry))
    #expect(c.state.phase == .retrying)
    let attempt = c.state.attempt
    #expect(!c.observe(correct, cursor: cursor, frame: 5, attempt: attempt - 1)) // stale
    #expect(!c.observe(Array(correct.prefix(1)), cursor: cursor, frame: 5)) // not through the flagged word
    #expect(!c.observe(correct, cursor: cursor, frame: 6))
    #expect(!c.observe(omission, cursor: cursor, frame: 10)) // a relapse resets the clock
    #expect(!c.observe(correct, cursor: cursor, frame: 11))
    #expect(c.observe(correct, cursor: cursor, frame: 23))
    #expect(c.state.phase == .corrected && c.state.outcome == .corrected)
    #expect(c.act(.retry)) // practice once more
    #expect(c.state.phase == .retrying)
  }

  @Test func repeatingAConfidentVowelErrorIsNotACorrection() {
    let c = CorrectionController()
    c.setMode(.correction)
    #expect(!c.observe(vowel, cursor: cursor, frame: 0))
    #expect(c.observe(vowel, cursor: cursor, frame: 12))
    #expect(c.act(.retry))
    #expect(!c.observe(vowel, cursor: cursor, frame: 1))
    #expect(!c.observe(vowel, cursor: cursor, frame: 40))
    #expect(c.state.phase == .retrying)
  }

  @Test func ayahLevelIssuesNeedTheWholeAyah() {
    let c = CorrectionController()
    c.setMode(.correction)
    let issue = CorrectionIssue(surah: 112, ayah: 3, word: 0, wordIndex: 100, kind: .unclearAyah, words: 4)
    #expect(c.raise(issue, cursor: cursor))
    #expect(!c.raise(issue, cursor: cursor))
    #expect(c.act(.retry))
    #expect(!c.observe(Array(correct.prefix(3)), cursor: cursor, frame: 0))
    #expect(!c.observe(Array(correct.prefix(3)), cursor: cursor, frame: 20))
    #expect(!c.observe(correct, cursor: cursor, frame: 21))
    #expect(c.observe(correct, cursor: cursor, frame: 33))
    #expect(c.act(.continueReciting))
    #expect(!c.raise(issue, cursor: cursor)) // suppressed after the outcome
  }

  @Test func closingOrReviewingLaterNeverClaimsSuccess() {
    for action in [CorrectionAction.close, .reviewLater] {
      let c = flagged()
      #expect(c.act(.retry))
      #expect(c.act(action))
      #expect(c.state.phase == .idle && c.state.outcome == .deferred)
    }
  }

  @Test func vowelMismatchesIgnoreTheCaseEnding() throws {
    // Interior fatha heard as kasra counts; the word-final vowel never does.
    let expected = Array("كَتَبَ".utf16)
    var heard = Array("كِتَبِ".utf16).enumerated().map { HeardChar(ch: $0.element, frame: $0.offset, margin: 0.9) }
    heard[1].vowels = VowelProbs(fatha: 0.1, damma: 0, kasra: 0.85)
    let r = vowelMismatches(heard: heard, from: 0, heardSlice: heard.map(\.ch), expected: expected)
    #expect(r.errors == 1)
    #expect(abs(r.margin - 0.75) < 1e-12)
  }
}
