import Foundation
import Testing
@testable import RecitationKit

/// The frozen oracle vectors in spec/vectors (spec §1-§11).
@Suite("Spec oracle vectors")
struct SpecVectorTests {
  @Test func defaultConfig() throws {
    let v = try vector("default_config.json").object
    let c = EngineConfig.default
    let mine: [String: Double] = [
      "jumpCost": c.jumpCost, "repeatCost": c.repeatCost, "commitDwell": Double(c.commitDwell), "okDistance": c.okDistance,
      "unsureDistance": c.unsureDistance, "minHeardFraction": c.minHeardFraction, "minMargin": c.minMargin,
      "lostWindow": Double(c.lostWindow), "lostRate": c.lostRate, "holdWindow": Double(c.holdWindow), "holdRate": c.holdRate,
      "searchMinChars": Double(c.searchMinChars), "searchQueryChars": Double(c.searchQueryChars),
      "searchDecisiveDistance": c.searchDecisiveDistance, "searchDecisiveMargin": c.searchDecisiveMargin,
      "searchEveryFrames": Double(c.searchEveryFrames), "searchEveryChars": Double(c.searchEveryChars),
      "locateFailedFrames": Double(c.locateFailedFrames), "relocateEveryFrames": Double(c.relocateEveryFrames),
      "relocateQueryChars": Double(c.relocateQueryChars), "relocateMaxDistance": c.relocateMaxDistance,
      "relocateRateMargin": c.relocateRateMargin, "idleFrames": Double(c.idleFrames), "maxStruggles": Double(c.maxStruggles),
      "settleFrames": Double(c.settleFrames),
    ]
    #expect(Set(v.keys) == Set(mine.keys))
    for (k, value) in v { #expect(value.double == mine[k], "\(k)") }
  }

  @Test func tokens() throws {
    let v = try vector("tokens.json")
    #expect(v["blankId"].int == 250)
    #expect(v["tokens"].array.map(\.string) == zipformerTokens)
  }

  @Test func costTable() throws {
    let v = try vector("cost_table.json")
    #expect(String(decoding: Phonemes.alphabet, as: UTF16.self) == v["alphabet"].string)
    #expect(v["size"].int == CostTable.shared.size)
    #expect(v["unknownId"].int == Int(Phonemes.unknownId))
    for (i, row) in v["matrix"].array.enumerated() {
      for (j, x) in row.array.enumerated() {
        #expect(Double(CostTable.shared.cost(UInt8(i), UInt8(j))) == x.double, "\(i),\(j)")
      }
    }
    for row in v["worked"].array {
      let h = Array(row["heard"].string.utf16)[0]
      let e = Array(row["expected"].string.utf16)[0]
      #expect(Phonemes.charCost(h, e) == row["cost"].double, "\(row)")
    }
  }

  @Test func alignment() throws {
    let v = try vector("alignment.json")
    for p in v["pairs"].array {
      let d = normalizedDistance(Phonemes.encode(p["a"].string), Phonemes.encode(p["b"].string))
      #expect(d == p["distance"].double, "\(p["name"])")
    }
    let ex = v["semiGlobalExample"]
    let ref = Phonemes.encode(ex["ref"].string)
    let r = alignSemiGlobal(Phonemes.encode(ex["query"].string), ref, from: 0, to: ref.count, headSkipCost: ex["headSkipCost"].double)
    #expect(Double(r.cost) == ex["cost"].double)
    #expect(r.distance == ex["distance"].double)
    #expect(r.refStart == ex["refStart"].int && r.refEnd == ex["refEnd"].int && r.queryStart == ex["queryStart"].int)
  }

  @Test func fnv1a() throws {
    for row in try vector("hash_examples.json")["fnv1a"].array {
      let ids = Phonemes.encode(row["text"].string)
      #expect(ids.map(Int.init) == row["ids"].array.map(\.int))
      #expect(fnv1aBucket(ids, at: 0) == row["bucket"].int)
    }
  }

  @Test(.enabled(if: hasCorpus)) func corpus() throws {
    let v = try vector("corpus.json")
    let c = Shared.corpus!
    #expect(c.surahs.count == v["surahCount"].int)
    #expect(c.wordCount == v["wordCount"].int)
    #expect(c.text.count == v["textLength"].int)
    let f = v["fatiha"]
    let s = c.surahs[0]
    #expect(s.number == f["n"].int && s.name == f["name"].string && s.nameEn == f["nameEn"].string)
    #expect(s.ayahCount == f["ayahCount"].int && s.firstWord == f["firstWord"].int && s.endWord == f["endWord"].int)
    #expect(String(decoding: c.ayahPhonemes(1, 1), as: UTF16.self) == f["ayah1"]["phonemes"].string)
    for w in f["ayah1"]["words"].array {
      let gi = try c.wordIndex(1, 1, w["word"].int)
      #expect(String(decoding: c.wordPhonemes(gi), as: UTF16.self) == w["phonemes"].string)
      #expect(c.plain[gi] == w["plain"].string)
    }
    for ex in v["wordAtExamples"].array { #expect(c.wordAt(ex["offset"].int) == ex["wordIndex"].int) }
  }

  private func hitsJSON(_ hits: [SearchHit]) -> JSONValue {
    JSONValue(hits.map { ["surah": $0.surah, "ayah": $0.ayah, "word": $0.word, "wordIndex": $0.wordIndex, "refOffset": $0.refOffset,
                          "refEnd": $0.refEnd, "queryStart": $0.queryStart, "distance": $0.distance] as [String: Any] })
  }

  @Test(.enabled(if: hasCorpus)) func search() throws {
    let v = try vector("search.json")
    #expect(String(decoding: istiadhaPhonemes, as: UTF16.self) == v["istiadha"].string)
    #expect(String(decoding: basmalaPhonemes, as: UTF16.self) == v["basmala"].string)
    let index = Shared.index!
    for q in v["queries"].array {
      let name = q["name"].string
      let ids = Phonemes.encode(q["text"].string)
      #expect(ids.count == q["length"].int, "\(name)")
      if !q["growingIstiadha"].bool {
        let want = q["stripped"]
        #expect(stripPreambles(ids) == StripResult(offset: want["offset"].int, basmala: want["basmala"].bool, basmalaOffset: want["basmalaOffset"].int), "\(name)")
      }
      let plain = index.search(ids)
      #expect(plain.decisive == q["decisive"].bool, "\(name)")
      #expect(hitsJSON(plain.hits) == q["hits"], "\(name)")
      let hinted = index.search(ids, hint: SearchHint(surah: 1, ayah: 1))
      #expect(hinted.decisive == q["hintFatiha"]["decisive"].bool, "\(name) hinted")
      #expect(hitsJSON(hinted.hits) == q["hintFatiha"]["hits"], "\(name) hinted")
    }
  }

  @Test func waqf() throws {
    func text(_ p: [Phone]?) -> String? { p.map { String(decoding: $0, as: UTF16.self) } }
    for ex in try vector("waqf.json")["examples"].array {
      let ph = Array(ex["phonemes"].string.utf16)
      let plain = ex["plain"].string
      #expect(text(pausalPhonemes(ph, plain: plain, atAyahEnd: ex["atAyahEnd"].bool)) == ex["pausal"].stringOrNil)
      #expect(text(pausalPhonemes(ph, plain: plain, atAyahEnd: false)) == ex["pausalIfForcedNotAyahEnd"].stringOrNil)
    }
  }

  @Test func fbankReadiness() throws {
    for row in try vector("fbank_readiness.json")["rows"].array {
      let n = row["samples"].int
      let pcm = (0..<n).map { Float(Double(($0 * 17) % 100) / 200 - 0.25) }
      let fbank = KaldiFbank()
      let streaming = fbank.acceptWaveform(pcm).count / 80
      let flushed = fbank.inputFinished().count / 80
      #expect(streaming == row["streamingReady"].int, "n=\(n)")
      #expect(streaming + flushed == row["inputFinishedTotal"].int, "n=\(n)")
    }
  }

  @Test func fbankSynthetic() throws {
    let v = try vector("fbank_synthetic.json")
    let data = try Data(contentsOf: Paths.fixtures.appendingPathComponent("fbank_synthetic_input.f32"))
    let pcm = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    #expect(pcm.count == v["sampleCount"].int)
    let fbank = KaldiFbank()
    var frames: [Float] = []
    for start in stride(from: 0, to: pcm.count, by: 7680) { frames += fbank.acceptWaveform(pcm[start..<min(pcm.count, start + 7680)]) }
    #expect(frames.count / 80 == v["streamingFrames"].int)
    frames += fbank.inputFinished()
    #expect(frames.count / 80 == v["totalFrames"].int)
    var maxAbs = 0.0
    for (f, row) in v["frames"].array.enumerated() {
      for (b, x) in row.array.enumerated() { maxAbs = max(maxAbs, abs(Double(frames[f * 80 + b]) - x.double)) }
    }
    #expect(maxAbs < 1e-3, "max abs error \(maxAbs)")
  }

  @Test func ctcDecoderTiesAndRuns() {
    // Ties pick the lowest class; a blank ends a run; a repeat after a blank is a new token.
    let dec = GreedyCtcDecoder()
    var lp = [Float](repeating: -10, count: 6 * 251)
    func set(_ t: Int, _ c: Int, _ p: Float) { lp[t * 251 + c] = p }
    set(0, 3, -0.1); set(0, 4, -0.1)
    set(1, 3, -0.05)
    set(2, 250, -0.01)
    set(3, 3, -0.2)
    set(4, 5, -0.3)
    set(5, 250, -0.01)
    let tokens = dec.consume(lp, frames: 6, classes: 251)
    #expect(tokens.map(\.frame) == [0, 3, 4])
    #expect(tokens.map(\.text) == [zipformerTokens[3], zipformerTokens[3], zipformerTokens[5]])
    #expect(abs(tokens[0].margin - (exp(-0.05) - exp(-10))) < 1e-6)
    #expect(dec.framesDecoded == 6)
  }

  @Test func windowing() throws {
    let v = try vector("zipformer_windows.json")
    let shipped = ZipformerIO.shipped
    #expect(v["T"].int == shipped.windowFrames && v["hop"].int == shipped.hopFrames)
    #expect(v["featureDim"].int == shipped.featureDim && v["vocabSize"].int == shipped.vocabSize)
    let inputs = try vector("zipformer_io.json")["inputs"].array
    #expect(inputs.count == shipped.inputs.count)
    for (a, b) in zip(inputs, shipped.inputs) {
      #expect(a["name"].string == b.name && a["dims"].array.map(\.int) == b.dims && a["dtype"].string == b.dtype.rawValue)
    }
    for probe in v["probe"].array {
      // Steady state: the first 480 ms chunk yields 47 frames and no forward.
      let runner = ZipformerRunner(backend: ScriptedBackend(frames: []))
      #expect(try runner.accept([Float](repeating: 0, count: 47 * 80)).frames == 0)
      for w in probe["windows"].array where w["kind"].stringOrNil == "audio" {
        #expect(runner.leftoverFrames == w["bufferedBefore"].int)
        let out = try runner.accept([Float](repeating: 0, count: w["fbankIn"].int * 80))
        #expect(out.frames == w["logProbFrames"].int)
        #expect(runner.leftoverFrames == w["leftoverAfter"].int)
      }
    }
  }

  // MARK: Engine and host replays of real decodes (spec §10-§11)

  @Test(.enabled(if: hasCorpus), arguments: [
    ("events_001002.json", "host_001002.json"),
    ("events_001001.json", "host_001001.json"),
    ("events_ea_alafasy_multi_001_001_007.json", "host_ea_alafasy_multi_001_001_007.json"),
  ])
  func engineAndHost(_ eventsFile: String, _ hostFile: String) throws {
    let v = try vector(eventsFile)
    let c = Shared.corpus!
    let engine = RecitationEngine(corpus: c, index: Shared.index!)
    engine.startSearch()
    for (i, chunk) in v["chunks"].array.enumerated() {
      let tokens = chunk["tokens"].array.map { CtcToken($0["sym"].string, frame: $0["frame"].int, margin: $0["margin"].double) }
      let events = engine.feed(tokens, framesDecoded: chunk["framesDecoded"].int)
      #expect(JSONValue(events.map(\.json)) == chunk["events"], "\(eventsFile) chunk \(i)")
    }
    #expect(engine.state.rawValue == v["finalState"].string)
    #expect(engine.framesDecoded == v["framesDecoded"].int)
    let cursor = v["cursor"]
    if cursor.isNull {
      #expect(engine.tracker == nil)
    } else {
      let t = try #require(engine.tracker)
      #expect(t.cursorWordIndex == cursor["wordIndex"].int && t.surah == cursor["surah"].int)
      #expect(Int(c.wordAyah[t.cursorWordIndex]) == cursor["ayah"].int && Int(c.wordInAyah[t.cursorWordIndex]) == cursor["word"].int)
      #expect(Double(t.cursorCost) == cursor["cost"].double)
    }
    let settled = v["settledVerdicts"].array
    if !settled.isEmpty { #expect(JSONValue(engine.tracer!.verdicts(settled: true).map(\.json)) == v["settledVerdicts"]) }

    let host = try vector(hostFile)
    let snap = engine.tracer.map { snapshotTallies($0.verdicts(settled: true), wordCount: c.ayahWordCount) } ?? TallyMap()
    #expect(JSONValue(snap.values.filter { $0.meetsGate() }.map(\.json)) == host["tallies"])
    let fallback = wholeAyahFallback(Array(v["transcript"].string.utf16), corpus: c)
    let want = host["fallback"]
    if want.isNull {
      #expect(fallback == nil)
    } else {
      #expect(fallback == FallbackHit(surah: want["surah"].int, ayah: want["ayah"].int, distance: want["distance"].double,
                                      how: FallbackHit.How(rawValue: want["how"].string)!))
    }
  }
}
