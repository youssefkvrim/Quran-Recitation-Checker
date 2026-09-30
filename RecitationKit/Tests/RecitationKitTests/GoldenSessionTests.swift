import Foundation
import Testing
@testable import RecitationKit

/// `Fixtures/sessions.json`: event streams recorded from the v0.1 TypeScript
/// session (tools/make-golden.mts). The Swift session must reproduce them.
enum Golden {
  static let file = try! JSONValue.load(Paths.fixtures.appendingPathComponent("sessions.json"))
  static let scenarios = file["scenarios"].array
  static let names = scenarios.map { $0["name"].string }
  static let logProbs = file["logProbs"]
}

@Suite("Golden sessions (v0.1 TypeScript parity)")
struct GoldenSessionTests {
  @Test(.enabled(if: hasCorpus), arguments: Golden.names)
  func replays(_ name: String) throws {
    let scenario = Golden.scenarios.first { $0["name"].string == name }!
    let backend = ScriptedBackend(
      frames: scenario["frames"].array.map(\.int),
      high: Float(Golden.logProbs["high"].double), second: Float(Golden.logProbs["second"].double), low: Float(Golden.logProbs["low"].double))
    var options = RecitationSession.Options()
    options.debug = true
    let session = RecitationSession(corpus: Shared.corpus!, index: Shared.index!, backend: backend, options: options)
    _ = session.setMode(RecitationMode(rawValue: scenario["mode"].string)!)

    var got: [[String: Any]] = []
    func push(_ events: [RecitationEvent]) { got += events.map(\.json) }
    let chunk = [Float](repeating: 0, count: Golden.file["chunkSamples"].int)
    var flags = 0
    var retryChunks = 0
    while !backend.done {
      push(try session.feed(chunk))
      switch session.correction.state.phase {
      case .error:
        flags += 1
        push(session.correct(flags % 3 == 1 ? .retry : flags % 3 == 2 ? .dismiss : .reviewLater))
        retryChunks = 0
      case .retrying:
        retryChunks += 1
        if retryChunks > 15 { push(session.correct(.stopRetry)) }
      case .corrected:
        push(session.correct(.continueReciting))
      case .idle:
        break
      }
      got.append(["type": "probe", "verdicts": session.verdicts().count, "state": session.engineState.rawValue])
    }
    push(try session.stop())
    got.append(["type": "end", "transcript": session.transcript, "tallies": session.tallies.map(\.json), "verses": session.verses.map(\.json)])

    let want = scenario["messages"].array
    let have = got.map { JSONValue($0) }
    let firstDiff = (0..<min(want.count, have.count)).first { want[$0] != have[$0] } ?? min(want.count, have.count)
    #expect(have.count == want.count, "message count")
    if firstDiff < max(want.count, have.count) {
      Issue.record("first difference at message \(firstDiff):\n  want \(firstDiff < want.count ? String(want[firstDiff].description.prefix(400)) : "<end>")\n  have \(firstDiff < have.count ? String(have[firstDiff].description.prefix(400)) : "<end>")")
    }
  }
}
