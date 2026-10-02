/// Split tokens into heard chars (spec §3): each UTF-16 unit is one phoneme;
/// vowel alternatives belong to the token's final char only.
public func expandTokens(_ tokens: [CtcToken]) -> [HeardChar] {
  var out: [HeardChar] = []
  for t in tokens {
    for (i, ch) in t.symbol.enumerated() {
      out.append(HeardChar(ch: ch, frame: t.frame, margin: t.margin,
                           vowels: i == t.symbol.count - 1 ? t.vowels : nil))
    }
  }
  return out
}

/// The previous relocation tick's candidate: resolved, or the query it would
/// be resolved from (searched only once a tick could actually relocate).
private enum RelocateCandidate {
  case none
  case resolved(AyahRef?)
  case pending([UInt8])
}

/// Searching / tracking state machine over a frame clock of CTC frames (spec §10).
public final class RecitationEngine {
  public let corpus: QuranCorpus
  public let index: QuranIndex
  public let cfg: EngineConfig
  public private(set) var state: EngineState = .searching
  public private(set) var tracker: Tracker?
  public private(set) var tracer: VerdictTracer?
  public private(set) var framesDecoded = 0
  public private(set) var heardTotal = 0
  /// Called right before a relocation replaces the tracker.
  public var onBeforeRelocate: (() -> Void)?

  private var buffer: [HeardChar] = []
  private var hint: SearchHint?
  private var stay = false
  private var searchStartFrame = 0
  private var lastSearchFrame = 0
  private var lastSearchHeard = 0
  private var lastRelocateFrame = 0
  private var lastProgressFrame = 0
  private var lastCharFrame = 0
  private var locateFailedEmitted = false
  private var lostEmitted = false
  private var completedEmitted = false
  private var struggles = 0
  private var relocateCandidate = RelocateCandidate.none
  private var lastCursorWord = -1
  /// Last emitted verdict per word (the tracer reuses objects, so identity implies no change).
  private var lastStates: [Int: WordVerdict] = [:]
  private var prevSettled = false
  private var lastStruggleChars = 0

  public init(corpus: QuranCorpus, index: QuranIndex, config: EngineConfig = .default) {
    self.corpus = corpus
    self.index = index
    self.cfg = config
  }

  public func setHint(_ hint: SearchHint?) { self.hint = hint }

  public func setStayOnSurah(_ stay: Bool) { self.stay = stay }

  /// What was heard since the search started, while it is searching.
  public var searchBuffer: ArraySlice<HeardChar> { state == .searching ? buffer[...] : [] }

  public func startSearch() {
    state = .searching
    tracker = nil
    tracer = nil
    buffer.removeAll()
    heardTotal = 0
    searchStartFrame = framesDecoded
    lastSearchFrame = framesDecoded
    lastSearchHeard = 0
    lastRelocateFrame = framesDecoded
    lastProgressFrame = framesDecoded
    lastCharFrame = framesDecoded
    locateFailedEmitted = false
    lostEmitted = false
    completedEmitted = false
    struggles = 0
    relocateCandidate = .none
    lastCursorWord = -1
    lastStates.removeAll()
    prevSettled = false
    lastStruggleChars = 0
  }

  /// Lock directly onto a word (practice mode, resuming a saved position).
  @discardableResult
  public func track(surah: Int, ayah: Int, word: Int = 0) throws -> [EngineEvent] {
    lock(try corpus.wordIndex(surah, ayah, word), replay: [], relocatedFrom: nil)
  }

  public func feed(_ tokens: [CtcToken], framesDecoded: Int) -> [EngineEvent] {
    if framesDecoded < self.framesDecoded {
      searchStartFrame = framesDecoded
      lastSearchFrame = framesDecoded
      lastRelocateFrame = framesDecoded
      lastProgressFrame = framesDecoded
      lastCharFrame = framesDecoded
    }
    self.framesDecoded = framesDecoded
    let chars = expandTokens(tokens)
    if !chars.isEmpty {
      lastCharFrame = framesDecoded
      heardTotal += chars.count
      buffer.append(contentsOf: chars)
      if buffer.count > bufferCap { buffer.removeFirst(buffer.count - bufferCap) }
    }
    return state == .searching ? feedSearching() : feedTracking(chars)
  }

  private func lock(_ wordIndex: Int, replay: ArraySlice<HeardChar>, relocatedFrom: AyahRef?) -> [EngineEvent] {
    if relocatedFrom != nil { onBeforeRelocate?() }
    let loc = corpus.location(ofWord: wordIndex)
    let prev = tracker.map { AyahRef(surah: $0.surah, ayah: Int(corpus.wordAyah[$0.cursorWordIndex])) } ?? relocatedFrom
    let t = Tracker(corpus: corpus, table: index.table, surah: loc.surah, startWordIndex: wordIndex, config: cfg)
    tracker = t
    tracer = VerdictTracer(tracker: t, table: index.table, config: cfg)
    state = .tracking
    lostEmitted = false
    completedEmitted = false
    struggles = 0
    relocateCandidate = .none
    lastCursorWord = -1
    lastStates.removeAll()
    prevSettled = false
    lastRelocateFrame = framesDecoded
    lastStruggleChars = heardTotal
    var events: [EngineEvent] = []
    if relocatedFrom != nil, let prev {
      events.append(.relocated(from: prev, to: AyahRef(surah: loc.surah, ayah: loc.ayah), word: loc.word))
    } else {
      events.append(.located(surah: loc.surah, ayah: loc.ayah, word: loc.word, replayed: replay.count))
    }
    if !replay.isEmpty { t.feed(replay) }
    events.append(contentsOf: trackingEvents(gotChars: false))
    return events
  }

  private func query(last count: Int) -> (ids: [UInt8], start: Int) {
    let qLen = min(count, buffer.count)
    let start = buffer.count - qLen
    return (buffer[start...].map { Phonemes.id($0.ch) }, start)
  }

  private func feedSearching() -> [EngineEvent] {
    var events: [EngineEvent] = []
    let due = buffer.count >= cfg.searchMinChars
      && (heardTotal - lastSearchHeard >= cfg.searchEveryChars
        || (heardTotal - lastSearchHeard > 0 && framesDecoded - lastSearchFrame >= cfg.searchEveryFrames))
    if due {
      lastSearchFrame = framesDecoded
      lastSearchHeard = heardTotal
      let q = query(last: cfg.searchQueryChars)
      let result = index.search(q.ids, hint: hint)
      if result.decisive, let hit = result.hits.first {
        return lock(hit.wordIndex, replay: buffer[(q.start + hit.queryStart)...], relocatedFrom: nil)
      }
    }
    if !locateFailedEmitted && framesDecoded - searchStartFrame >= cfg.locateFailedFrames {
      locateFailedEmitted = true
      events.append(.locateFailed)
    }
    return events
  }

  private func feedTracking(_ chars: [HeardChar]) -> [EngineEvent] {
    guard let tracker else { return [] }
    if !chars.isEmpty { tracker.feed(chars) }
    var events = trackingEvents(gotChars: !chars.isEmpty)
    if tracker.lost {
      if !lostEmitted {
        lostEmitted = true
        events.append(.lost)
      }
    } else {
      lostEmitted = false
    }

    if framesDecoded - lastRelocateFrame >= cfg.relocateEveryFrames {
      lastRelocateFrame = framesDecoded
      let heardSinceTick = heardTotal - lastStruggleChars
      lastStruggleChars = heardTotal
      if stay {
        struggles = 0
      } else {
        if let moved = maybeRelocate() { return events + moved }
        if heardSinceTick > 0 {
          struggles = tracker.lost || isHeld() ? struggles + 1 : 0
          if cfg.maxStruggles > 0 && struggles >= cfg.maxStruggles {
            events.append(.idle(.lost))
            struggles = 0
            lastProgressFrame = framesDecoded
          }
        }
      }
    }

    if framesDecoded - lastProgressFrame >= cfg.idleFrames {
      events.append(.idle(.silent))
      lastProgressFrame = framesDecoded
    }
    return events
  }

  private func maybeRelocate() -> [EngineEvent]? {
    guard let tracker, buffer.count >= cfg.searchMinChars else { return nil }
    let q = query(last: cfg.relocateQueryChars)
    let previous = relocateCandidate
    guard let rate = tracker.costRate(), rate >= cfg.lostRate else {
      relocateCandidate = .pending(q.ids)
      return nil
    }
    let hit = index.search(q.ids, limit: 1).hits.first
    relocateCandidate = .resolved(hit.map { AyahRef(surah: $0.surah, ayah: $0.ayah) })
    guard let hit, hit.surah != tracker.surah, hit.distance <= cfg.relocateMaxDistance,
          hit.distance + cfg.relocateRateMargin <= rate else { return nil }
    guard let before = resolve(previous), before.surah == hit.surah, before.ayah == hit.ayah else { return nil }
    let from = AyahRef(surah: tracker.surah, ayah: Int(corpus.wordAyah[tracker.cursorWordIndex]))
    return lock(hit.wordIndex, replay: buffer[(q.start + hit.queryStart)...], relocatedFrom: from)
  }

  private func resolve(_ c: RelocateCandidate) -> AyahRef? {
    switch c {
    case .none: return nil
    case .resolved(let ref): return ref
    case .pending(let ids): return index.search(ids, limit: 1).hits.first.map { AyahRef(surah: $0.surah, ayah: $0.ayah) }
    }
  }

  private func isHeld() -> Bool {
    guard let rate = tracker?.costRate(window: cfg.holdWindow) else { return false }
    return rate >= cfg.holdRate
  }

  private func isSettled() -> Bool { framesDecoded - lastCharFrame >= cfg.settleFrames }

  private func trackingEvents(gotChars: Bool) -> [EngineEvent] {
    guard let tracker, let tracer else { return [] }
    if isHeld() { return [] }
    var events: [EngineEvent] = []
    let cursorIdx = tracker.cursorWordIndex
    if cursorIdx != lastCursorWord {
      lastCursorWord = cursorIdx
      lastProgressFrame = framesDecoded
      let loc = corpus.location(ofWord: cursorIdx)
      events.append(.cursor(surah: loc.surah, ayah: loc.ayah, word: loc.word, wordIndex: cursorIdx))
    }
    let settled = isSettled()
    let silenceSettle = !gotChars && settled && !prevSettled
    let vs = tracer.verdicts(settled: settled)
    var changes: [WordVerdict] = []
    let refreshPending = gotChars && prevSettled
    var present = Set<Int>()
    present.reserveCapacity(vs.count)
    for v in vs {
      present.insert(v.wordIndex)
      let prev = lastStates[v.wordIndex]
      if let prev {
        if prev === v { continue }
        if prev.state == v.state && prev.distance == v.distance && prev.heardRatio == v.heardRatio && prev.margin == v.margin { continue }
        if prev.state == .pending && v.state == .pending && !refreshPending { continue }
      }
      changes.append(v)
      lastStates[v.wordIndex] = v
      if v.state != .pending && !silenceSettle { lastProgressFrame = framesDecoded }
    }
    if !changes.isEmpty { events.append(.verdicts(changes)) }
    if lastStates.count > present.count { lastStates = lastStates.filter { present.contains($0.key) } }
    prevSettled = settled
    if !completedEmitted && tracker.reachedEnd {
      let lastWord = tracker.endWord - 1
      if let lastV = vs.first(where: { $0.wordIndex == lastWord }), lastV.state != .pending {
        completedEmitted = true
        events.append(.completed(surah: tracker.surah))
      }
    }
    return events
  }
}
