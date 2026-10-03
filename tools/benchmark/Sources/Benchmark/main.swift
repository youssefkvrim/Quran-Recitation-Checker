import Foundation
import RecitationKit

// The app's session over a real recording, with the model run outside:
// dump  <pcm.f32> <windows.f32>              : model input windows, in run order
// replay <pcm.f32> <logprobs.f32> <variant>  : session events with timing (JSON line)
let args = CommandLine.arguments
func readF32(_ p: String) -> [Float] {
  let d = try! Data(contentsOf: URL(fileURLWithPath: p))
  return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
let chunk = 1365

final class Capture: ZipformerBackend {
  var out = Data()
  func reset() {}
  func run(features: [Float]) throws -> [Float] {
    features.withUnsafeBufferPointer { out.append(Data(buffer: $0)) }
    var lp = [Float](repeating: -20, count: 12 * 251)
    for f in 0..<12 { lp[f * 251 + 250] = 0 }
    return lp
  }
}
final class Replay: ZipformerBackend {
  let lp: [Float]; var run = 0
  init(_ lp: [Float]) { self.lp = lp }
  func reset() {}
  func run(features: [Float]) throws -> [Float] {
    let n = 12 * 251, a = run * n
    run += 1
    if a + n <= lp.count { return Array(lp[a..<(a + n)]) }
    var blank = [Float](repeating: -20, count: n); for f in 0..<12 { blank[f * 251 + 250] = 0 }
    return blank
  }
}

let corpus = try QuranCorpus(json: Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CORPUS"]!)))
let pcm = readF32(args[2])

func options(_ variant: String) -> RecitationSession.Options {
  var o = RecitationSession.Options()
  o.emitRawTranscript = false
  if variant != "original" {
    o.emitPreamble = true
    o.config.surahOpenings = .standard
    o.config.searchEveryChars = 1
    o.config.searchEveryFrames = 12
  }
  return o
}

if args[1] == "dump" {
  let b = Capture()
  let s = RecitationSession(corpus: corpus, backend: b, options: options("original"))
  var i = 0
  while i < pcm.count { _ = try s.feed(pcm[i..<min(pcm.count, i + chunk)]); i += chunk }
  _ = try s.stop()
  try b.out.write(to: URL(fileURLWithPath: args[3]))
} else {
  let variant = args[4]
  let b = Replay(readF32(args[3]))
  let s = RecitationSession(corpus: corpus, backend: b, options: options(variant))
  var i = 0, located: Double? = nil, firstPreamble: Double? = nil
  var matches: [String] = []
  var final: [String] = []
  func take(_ evs: [RecitationEvent], _ t: Double) {
    for e in evs {
      switch e {
      case let .verseCandidate(su, a, _): if located == nil { located = t; matches.append("loc \(su):\(a)@\(String(format: "%.1f", t))") }
      case let .verseMatch(su, a, _): matches.append("\(su):\(a)@\(String(format: "%.1f", t))")
      case let .preamble(p): if firstPreamble == nil { firstPreamble = t }; _ = p
      case let .finalSequence(v, _): final = v.map { "\($0.surah):\($0.ayah)" }
      default: break
      }
    }
  }
  while i < pcm.count { let e = try s.feed(pcm[i..<min(pcm.count, i + chunk)]); i += chunk; take(e, Double(i) / 16000) }
  take(try s.stop(), Double(pcm.count) / 16000 + 2)
  let j: [String: Any] = ["final": final, "located": located ?? -1, "preamble": firstPreamble ?? -1, "matches": matches, "duration": Double(pcm.count) / 16000]
  print(String(data: try JSONSerialization.data(withJSONObject: j), encoding: .utf8)!)
}
