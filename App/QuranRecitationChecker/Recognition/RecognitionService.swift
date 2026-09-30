import Foundation
import RecitationKit

/// Owns the model and the recognition session off the main thread. Every
/// call is serialised by the actor, as the session requires.
actor RecognitionService {
  enum Failure: LocalizedError {
    case missingResource(String)
    var errorDescription: String? {
      switch self {
      case let .missingResource(name):
        "\(name) is missing from the app bundle. Run tools/fetch-assets.sh and rebuild."
      }
    }
  }

  private var session: RecitationSession?

  /// Load the model, corpus and display text. Takes about a second on device.
  func load() throws -> QuranText {
    func resource(_ name: String, _ ext: String) throws -> URL {
      guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { throw Failure.missingResource("\(name).\(ext)") }
      return url
    }
    let text = try QuranText(json: Data(contentsOf: resource("quran-text", "json")))
    let corpus = try QuranCorpus(json: Data(contentsOf: resource("zipformer_quran", "json")))
    let backend = try OnnxZipformerBackend(modelPath: resource("zipformer_interp_gentle_a05.int8", "onnx").path)
    // Warm up so the first real window is not the slow one.
    _ = try backend.run(features: [Float](repeating: 0, count: ZipformerIO.shipped.windowFrames * ZipformerIO.shipped.featureDim))
    backend.reset()
    var options = RecitationSession.Options()
    options.emitRawTranscript = false
    session = RecitationSession(corpus: corpus, backend: backend, options: options)
    return text
  }

  /// A new recitation.
  func begin(mode: RecitationMode) -> [RecitationEvent] {
    guard let session else { return [] }
    session.reset()
    return session.setMode(mode)
  }

  func feed(_ samples: [Float]) throws -> [RecitationEvent] {
    try session?.feed(samples) ?? []
  }

  /// End of recitation: flush the model tail and get the final sequence.
  func finish() throws -> [RecitationEvent] {
    guard let session else { return [] }
    // An open correction has no final sequence; close it first.
    var events = session.correction.state.phase == .idle ? [] : session.correct(.close)
    events += try session.stop()
    return events
  }

  func setMode(_ mode: RecitationMode) -> [RecitationEvent] {
    session?.setMode(mode) ?? []
  }

  func correct(_ action: CorrectionAction) -> [RecitationEvent] {
    session?.correct(action) ?? []
  }
}
