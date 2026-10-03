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

  /// What the performance readout shows about recognition.
  struct Profile: Sendable {
    var stats = PerformanceStats()
    /// Seconds to load the display text, corpus, index and model.
    var loadSeconds = 0.0
    /// Seconds for the warm-up run, the slowest one.
    var warmUpSeconds = 0.0
  }

  /// One microphone chunk's outcome, for the main actor.
  struct Update: Sendable {
    var events: [RecitationEvent]
    var level: Float
    /// Seconds from capture to the end of this chunk's processing.
    var lag: Double
  }

  static let modelName = "zipformer_a0w_ep1_a05.int8"

  private var session: RecitationSession?
  private(set) var profile = Profile()
  /// The current recitation as 16 kHz PCM16, kept on device for "Share recording".
  private var recording: [Int16] = []
  private static let maxRecordingSamples = 16_000 * 60 * 10

  /// Load the model, corpus and display text. Takes about a second on device.
  func load() throws -> QuranText {
    let start = ContinuousClock.now
    func resource(_ name: String, _ ext: String) throws -> URL {
      guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { throw Failure.missingResource("\(name).\(ext)") }
      return url
    }
    let text = try QuranText(json: Data(contentsOf: resource("quran-text", "json")))
    let corpus = try QuranCorpus(json: Data(contentsOf: resource("zipformer_quran", "json")))
    let backend = try OnnxZipformerBackend(modelPath: resource(Self.modelName, "onnx").path)
    // Warm up so the first real window is not the slow one.
    let warmUp = ContinuousClock.now
    _ = try backend.run(features: [Float](repeating: 0, count: ZipformerIO.shipped.windowFrames * ZipformerIO.shipped.featureDim))
    profile.warmUpSeconds = Self.seconds(ContinuousClock.now - warmUp)
    backend.reset()
    var options = RecitationSession.Options()
    options.emitRawTranscript = false
    // Respond during the istiʿādha and basmala, decide surah openings right
    // after it, and search on every 480 ms window until the place is found.
    options.emitPreamble = true
    options.config.surahOpenings = .standard
    options.config.searchEveryChars = 1
    options.config.searchEveryFrames = 12
    session = RecitationSession(corpus: corpus, backend: backend, options: options)
    profile.loadSeconds = Self.seconds(ContinuousClock.now - start)
    return text
  }

  /// A new recitation.
  func begin(mode: RecitationMode) -> [RecitationEvent] {
    guard let session else { return [] }
    session.reset()
    profile.stats = PerformanceStats()
    recording.removeAll(keepingCapacity: true)
    return session.setMode(mode)
  }

  /// Recognise the microphone stream until it ends. The loop runs on this
  /// actor, so a busy main thread never holds recognition back; each chunk's
  /// events go out through `updates`.
  func run(_ chunks: AsyncStream<MicrophoneCapture.Chunk>, updates: AsyncStream<Update>.Continuation) async throws {
    defer { updates.finish() }
    for await chunk in chunks {
      let events = try feed(chunk.samples, capturedAt: chunk.captured)
      updates.yield(Update(events: events, level: chunk.level, lag: Self.seconds(ContinuousClock.now - chunk.captured)))
    }
  }

  func feed(_ samples: [Float], capturedAt captured: ContinuousClock.Instant) throws -> [RecitationEvent] {
    guard let session else { return [] }
    if recording.count < Self.maxRecordingSamples {
      recording.append(contentsOf: samples.prefix(Self.maxRecordingSamples - recording.count).map { Int16(max(-1, min(1, $0)) * 32767) })
    }
    let modelTime = session.modelTime, modelRuns = session.modelRuns
    let start = ContinuousClock.now
    let events = try session.feed(samples)
    let end = ContinuousClock.now
    profile.stats.record(audioSamples: samples.count, feed: end - start, model: session.modelTime - modelTime,
                         runs: session.modelRuns - modelRuns, lag: end - captured)
    return events
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

  /// The last recitation as a 16 kHz WAV, plus `report`, in the temporary
  /// directory: what "Share recording" hands to the share sheet.
  func exportRecording(report: String) throws -> [URL]? {
    guard !recording.isEmpty else { return nil }
    let stamp = Int(Date().timeIntervalSince1970)
    let dir = FileManager.default.temporaryDirectory
    let wav = dir.appendingPathComponent("recitation-\(stamp).wav")
    let txt = dir.appendingPathComponent("recitation-\(stamp).txt")
    try Self.wav(recording, sampleRate: 16_000).write(to: wav)
    try Data(report.utf8).write(to: txt)
    return [wav, txt]
  }

  private static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
    var d = Data()
    func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = samples.count * 2
    d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes)); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
    put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
    d.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
    samples.withUnsafeBytes { d.append(contentsOf: $0) }
    return d
  }

  private static func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
  }
}
