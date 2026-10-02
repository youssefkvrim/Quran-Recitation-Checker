/// Engine events forwarded for diagnostics (`RecitationSession.Options.debug`).
public enum DebugEvent: Equatable, Sendable {
  case engine(EngineEvent)
  case fallback(FallbackHit)
}

/// What a recognition session reports, in order.
public enum RecitationEvent: Equatable, Sendable {
  /// The engine located the recitation (before any ayah is confirmed).
  case verseCandidate(surah: Int, ayah: Int, confidence: Double)
  /// An ayah passed the gate (at least half its words heard): emitted once per ayah.
  case verseMatch(surah: Int, ayah: Int, confidence: Double)
  /// Where the reciter is inside the current ayah.
  case wordProgress(WordProgress)
  /// The phoneme transcript so far (`Options.emitRawTranscript`).
  case rawTranscript(text: String, confidence: Double)
  /// End of recitation: the ordered ayahs recited.
  case finalSequence(verses: [FinalVerse], confidence: Double)
  /// Correction mode: a possible mistake, a retry state, or its resolution.
  case correction(CorrectionState, totalWords: Int)
  /// The istiʿādha or basmala being recited while the surah is not yet known
  /// (`Options.emitPreamble`).
  case preamble(PreambleProgress)
  case debug(DebugEvent)
}

/// Mean heard ratio over an unmatched ayah at or above which a gap counts as
/// heard-but-unfollowed (`unclearAyah`) rather than skipped.
public let ayahHeardFraction = 0.5

/// Streaming recognition: 16 kHz PCM -> fbank -> Zipformer CTC -> engine ->
/// verse events. Port of `@tilawa/core`'s `ZipformerSession` (v0.1).
///
/// Not thread-safe: feed, stop, reset and correction actions must be serialised.
public final class RecitationSession {
  public struct Options: Sendable {
    public var config = EngineConfig.default
    /// Silence appended by `stop()` to flush the CTC tail.
    public var tailSeconds = 2.0
    public var minWordFraction = RecitationKit.minWordFraction
    /// Never relocate off the surah first locked onto.
    public var stayOnSurah = false
    /// Whole-ayah search over the transcript when nothing was emitted.
    public var enableFallback = true
    public var fallbackMaxDistance = RecitationKit.fallbackMaxDistance
    /// Let `verses` bridge a single short skipped ayah.
    public var allowGaps = false
    public var gapMaxWords = RecitationKit.gapMaxWords
    /// Forward engine events as `.debug`.
    public var debug = false
    /// Emit `.rawTranscript` after every decoded chunk (O(transcript) each time).
    public var emitRawTranscript = true
    /// Emit `.preamble` while an opening istiʿādha or basmala is recited (v0.2;
    /// off reproduces the v0.1 event stream).
    public var emitPreamble = false
    public init() {}
  }

  public let corpus: QuranCorpus
  public let index: QuranIndex
  public let correction = CorrectionController()
  public var options: Options
  public private(set) var lastFallback: FallbackHit?

  private let cfg: EngineConfig
  private let fbank = KaldiFbank()
  private let decoder = GreedyCtcDecoder()
  private let runner: ZipformerRunner
  private var engine: RecitationEngine!
  private var practiceEngine: RecitationEngine?
  private var accumulated = TallyMap()
  private var emitted = Set<AyahRef>()
  private var transcriptUnits: [Phone] = []
  private var lastCursor: RecitationPosition?
  private var lastWordProgress: WordProgress?
  /// Last verse match of the current tracker lock; cleared on (re)locate so an
  /// ayah gap across a jump never flags.
  private var lastMatch: AyahRef?
  private var lastPreamble: PreambleProgress?
  private var ayahIssuesRaised = Set<AyahRef>()
  private var stopping = false

  public init(corpus: QuranCorpus, index: QuranIndex? = nil, backend: ZipformerBackend, io: ZipformerIO = .shipped, options: Options = Options()) {
    self.corpus = corpus
    self.options = options
    self.cfg = options.config
    self.index = index ?? QuranIndex(corpus: corpus, config: options.config)
    self.runner = ZipformerRunner(backend: backend, io: io)
    self.engine = makeEngine()
  }

  public var mode: RecitationMode { correction.mode }

  /// Every ayah scored so far, in the order first seen.
  public var tallies: [AyahTally] { accumulated.values.stableSorted { $0.firstSeen < $1.firstSeen } }

  /// The ayahs that pass the emission gate.
  public var verses: [AyahTally] {
    let gated = tallies.filter { $0.meetsGate(minWordFraction: options.minWordFraction) }
    return options.allowGaps ? bridgeGapAyahs(gated, tallies, gapMaxWords: options.gapMaxWords) : gated
  }

  public var transcript: String { String(decoding: transcriptUnits, as: UTF16.self) }

  public var engineState: EngineState { engine.state }

  /// Wall-clock time spent in the acoustic model since creation, and how many
  /// 480 ms windows it ran. Time `feed` around it to get the engine's share.
  public var modelTime: Duration { runner.modelTime }
  public var modelRuns: Int { runner.modelRuns }

  /// Latest per-word verdicts of the active tracker (diagnostics).
  public func verdicts() -> [WordVerdict] {
    (practiceEngine ?? engine).tracer?.verdicts(settled: false) ?? []
  }

  /// Drop all state: new recitation, same model and corpus.
  public func reset() {
    correction.reset()
    practiceEngine = nil
    accumulated = TallyMap()
    emitted.removeAll()
    transcriptUnits.removeAll()
    lastCursor = nil
    lastWordProgress = nil
    lastMatch = nil
    ayahIssuesRaised.removeAll()
    lastFallback = nil
    lastPreamble = nil
    resetDecoder()
    engine = makeEngine()
  }

  /// Push mono 16 kHz float PCM, any chunk size.
  public func feed<C: Collection<Float>>(_ samples: C) throws -> [RecitationEvent] {
    if correction.state.phase == .error || correction.state.phase == .corrected { return [] }
    return dispatch(try feedSamples(samples))
  }

  public func setMode(_ mode: RecitationMode) -> [RecitationEvent] {
    let out = correction.state.phase != .idle ? correct(.close) : []
    correction.setMode(mode)
    return out
  }

  public func correct(_ action: CorrectionAction) -> [RecitationEvent] {
    guard correction.act(action) else { return [] }
    let state = correction.state
    resetDecoder()
    if state.phase == .retrying, let issue = state.issue {
      let practice = RecitationEngine(corpus: corpus, index: index, config: cfg)
      practice.setStayOnSurah(true)
      _ = try? practice.track(surah: issue.surah, ayah: issue.ayah, word: 0)
      practiceEngine = practice
    } else {
      practiceEngine = nil
      if state.phase == .idle, let resume = state.resume {
        // Keep verse history, but discard pre-practice acoustic context.
        engine = makeEngine()
        _ = try? engine.track(surah: resume.surah, ayah: resume.ayah, word: resume.word)
        lastCursor = resume
      }
    }
    return dispatch([correctionEvent()])
  }

  /// End of audio: flush the model tail and emit the final sequence.
  public func stop() throws -> [RecitationEvent] {
    if correction.state.phase != .idle { return [] }
    stopping = true
    defer { stopping = false }
    return try finish()
  }

  // MARK: - Pipeline

  private func finish() throws -> [RecitationEvent] {
    var out: [RecitationEvent] = []
    out += try feedSamples(repeatElement(Float(0), count: Int((options.tailSeconds * Double(Audio.sampleRate)).rounded())))
    let frames = fbank.inputFinished()
    if !frames.isEmpty { out += try runFrames(frames) }
    let flushed = decoder.flush()
    if !flushed.isEmpty { out += consumeTokens(flushed) }

    dumpTallies()
    for t in newlyEligibleAyahs(accumulated.values, alreadyEmitted: emitted, minWordFraction: options.minWordFraction) {
      emitted.insert(t.ref)
      out.append(verseMatch(t))
    }

    var fallback: FallbackHit?
    if options.enableFallback && emitted.isEmpty {
      fallback = wholeAyahFallback(transcriptUnits, corpus: corpus, table: index.table,
                                   minChars: cfg.searchMinChars, maxDistance: options.fallbackMaxDistance)
      lastFallback = fallback
      if let fallback {
        let words = corpus.ayahWordCount(fallback.surah, fallback.ayah)
        let tally = AyahTally(surah: fallback.surah, ayah: fallback.ayah, ok: words, words: words, firstSeen: accumulated.count)
        accumulated.set(tally)
        if !emitted.contains(tally.ref) {
          emitted.insert(tally.ref)
          out.append(verseMatch(tally))
        }
        if options.debug { out.append(.debug(.fallback(fallback))) }
      }
    }

    let seq = buildFinalSequence(accumulated.values, fallback: fallback, minWordFraction: options.minWordFraction)
    out.append(.finalSequence(verses: seq.verses, confidence: roundToHundredths(seq.confidence)))
    if options.emitRawTranscript { out.append(.rawTranscript(text: transcript, confidence: seq.confidence)) }
    return dispatch(out)
  }

  private func makeEngine() -> RecitationEngine {
    let e = RecitationEngine(corpus: corpus, index: index, config: cfg)
    e.setStayOnSurah(options.stayOnSurah)
    e.startSearch()
    e.onBeforeRelocate = { [unowned self] in self.dumpTallies() }
    return e
  }

  private func resetDecoder() {
    fbank.reset()
    decoder.reset()
    runner.reset()
  }

  private func wordCount(_ surah: Int, _ ayah: Int) -> Int { corpus.ayahWordCount(surah, ayah) }

  private func dumpTallies() {
    guard engine.tracer != nil else { return }
    accumulateSnapshot(&accumulated, currentSnapshot())
  }

  private func currentSnapshot() -> TallyMap {
    guard let tracer = engine.tracer else { return TallyMap() }
    return snapshotTallies(tracer.verdicts(settled: true), wordCount: wordCount)
  }

  private func dispatch(_ events: [RecitationEvent]) -> [RecitationEvent] {
    // Anything the UI draws from besides word progress (a verse match can move
    // the highlighted ayah) means the next word progress must go out again.
    for e in events {
      switch e {
      case .wordProgress, .rawTranscript, .debug: continue
      default: lastWordProgress = nil
      }
    }
    return events
  }

  private func feedSamples<C: Collection<Float>>(_ samples: C) throws -> [RecitationEvent] {
    try runFrames(fbank.acceptWaveform(samples))
  }

  private func runFrames(_ frames: [Float]) throws -> [RecitationEvent] {
    if frames.isEmpty { return [] }
    let (logProbs, count) = try runner.accept(frames)
    if count == 0 { return [] }
    return consumeTokens(decoder.consume(logProbs, frames: count, classes: runner.io.vocabSize))
  }

  private func consumeTokens(_ tokens: [CtcToken]) -> [RecitationEvent] {
    var out: [RecitationEvent] = []
    let frame = decoder.framesDecoded
    if let practice = practiceEngine {
      _ = practice.feed(tokens, framesDecoded: frame)
      var settled = false
      if tokens.isEmpty, let last = practice.tracker?.heard.last { settled = frame - last.frame >= cfg.settleFrames }
      if let tracer = practice.tracer, let tracker = practice.tracker, !tracker.lost,
         (tracker.costRate(window: cfg.holdWindow) ?? 0) < cfg.holdRate, let resume = correction.state.resume {
        if correction.observe(tracer.verdicts(settled: settled), cursor: resume, frame: frame) { out.append(correctionEvent()) }
      } else {
        correction.clearEvidence()
      }
      return out
    }
    for t in tokens { transcriptUnits.append(contentsOf: t.symbol) }
    for ev in engine.feed(tokens, framesDecoded: frame) { out += handle(ev) }
    if options.emitPreamble, !tokens.isEmpty { out += preambleEvent() }
    out += emitNewMatches(nil)
    // Tracking mode never flags: skip the (non-settled) verdict trace entirely.
    if correction.mode == .correction, !stopping, let tracer = engine.tracer, let tracker = engine.tracker,
       !tracker.lost, let cursor = lastCursor, (tracker.costRate(window: cfg.holdWindow) ?? 0) < cfg.holdRate {
      let settled = tracker.heard.last.map { decoder.framesDecoded - $0.frame >= cfg.settleFrames } ?? false
      if correction.observe(tracer.verdicts(settled: settled), cursor: cursor, frame: decoder.framesDecoded) {
        // Keep main-session coverage before a practice exit replaces the tracker.
        dumpTallies()
        out.append(correctionEvent())
      }
    } else {
      correction.clearEvidence()
    }
    if !tokens.isEmpty && options.emitRawTranscript { out.append(.rawTranscript(text: transcript, confidence: 1)) }
    return out
  }

  private func preambleEvent() -> [RecitationEvent] {
    let heard = engine.searchBuffer.prefix(istiadhaIds.count + basmalaIds.count + 16).map { Phonemes.id($0.ch) }
    guard let p = preambleProgress(heard), p != lastPreamble else { return [] }
    lastPreamble = p
    return [.preamble(p)]
  }

  private func handle(_ ev: EngineEvent) -> [RecitationEvent] {
    var out: [RecitationEvent] = []
    switch ev {
    case let .cursor(surah, ayah, word, _):
      lastCursor = RecitationPosition(surah: surah, ayah: ayah, word: word)
      out += wordProgressEvent()
    case .verdicts:
      if lastCursor != nil { out += wordProgressEvent() }
    case .lost:
      // Transient: the tracker keeps its place, so the match chain stays.
      lastWordProgress = nil
      correction.clearEvidence()
    case .relocated:
      lastWordProgress = nil
      correction.clearEvidence()
      lastMatch = nil
    case let .located(surah, ayah, _, _):
      lastWordProgress = nil
      correction.clearEvidence()
      lastMatch = nil
      out.append(.verseCandidate(surah: surah, ayah: ayah, confidence: 0.5))
    case .idle, .completed:
      lastWordProgress = nil
      correction.clearEvidence()
      lastMatch = nil
      dumpTallies()
      out += emitNewMatches(accumulated)
      engine.startSearch()
      resetDecoder()
      lastCursor = nil
    case .locateFailed:
      lastWordProgress = nil
    }
    if options.debug {
      switch ev {
      case .cursor, .verdicts: break
      default: out.append(.debug(.engine(ev)))
      }
    }
    return out
  }

  /// The cursor ayah's progress, unless identical to the last one sent.
  private func wordProgressEvent() -> [RecitationEvent] {
    guard let cursor = lastCursor else { return [] }
    let verdicts = engine.tracer?.verdicts(settled: true) ?? []
    let p = wordProgress(cursor: (cursor.surah, cursor.ayah, cursor.word), verdicts: verdicts,
                         totalWords: wordCount(cursor.surah, cursor.ayah))
    if p == lastWordProgress { return [] }
    lastWordProgress = p
    return [.wordProgress(p)]
  }

  private func emitNewMatches(_ source: TallyMap?) -> [RecitationEvent] {
    let tallies = source ?? mergeTallies(accumulated, currentSnapshot())
    let batch = newlyEligibleAyahs(tallies.values, alreadyEmitted: emitted, minWordFraction: options.minWordFraction)
    var out: [RecitationEvent] = []
    for t in batch {
      emitted.insert(t.ref)
      out.append(verseMatch(t))
    }
    for t in batch { out += checkAyahGap(t) }
    return out
  }

  /// Correction mode only: ayah N+2 matched right after N with N+1 never
  /// matched raises one ayah-level issue for N+1.
  private func checkAyahGap(_ t: AyahTally) -> [RecitationEvent] {
    let prev = lastMatch
    lastMatch = t.ref
    guard !stopping, correction.mode == .correction, let prev, let cursor = lastCursor,
          prev.surah == t.surah, t.ayah == prev.ayah + 2 else { return [] }
    let gap = AyahRef(surah: t.surah, ayah: t.ayah - 1)
    if emitted.contains(gap) || ayahIssuesRaised.contains(gap) { return [] }
    let words = wordCount(gap.surah, gap.ayah)
    // A real skip leaves most words `skipped` (heard ratio 0); a heard but
    // unfollowed ayah has `wrong` words with heard ratio near 1.
    let heard = (engine.tracer?.verdicts(settled: true) ?? [])
      .filter { $0.surah == gap.surah && $0.ayah == gap.ayah }
      .reduce(0.0) { $0 + min(1, max(0, $1.heardRatio.isNaN ? 0 : $1.heardRatio)) }
    let kind: CorrectionIssue.Kind = heard / Double(max(1, words)) >= ayahHeardFraction ? .unclearAyah : .possibleSkippedAyah
    let issue = CorrectionIssue(surah: gap.surah, ayah: gap.ayah, word: 0,
                                wordIndex: corpus.ayahFirstWord(gap.surah, gap.ayah), kind: kind, words: words)
    guard correction.raise(issue, cursor: cursor) else { return [] }
    ayahIssuesRaised.insert(gap)
    dumpTallies()
    return [correctionEvent()]
  }

  private func verseMatch(_ t: AyahTally) -> RecitationEvent {
    .verseMatch(surah: t.surah, ayah: t.ayah, confidence: roundToHundredths(t.confidence))
  }

  private func correctionEvent() -> RecitationEvent {
    let issue = correction.state.issue
    return .correction(correction.state, totalWords: issue.map { wordCount($0.surah, $0.ayah) } ?? 0)
  }
}
