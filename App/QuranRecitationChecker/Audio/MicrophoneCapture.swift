@preconcurrency import AVFoundation

/// Microphone -> 16 kHz mono float chunks.
///
/// Captures at the hardware rate and resamples with `AVAudioConverter`, whose
/// filter state carries across buffers (no aliasing, no per-buffer phase
/// glitches). `.measurement` mode keeps iOS voice processing (AGC, noise
/// suppression) from reshaping the recitation.
final class MicrophoneCapture: @unchecked Sendable {
  struct Chunk: Sendable {
    var samples: [Float]
    /// RMS level of the chunk, for the UI meter.
    var level: Float
  }

  enum Failure: LocalizedError {
    case noInput
    case unsupportedFormat
    var errorDescription: String? {
      switch self {
      case .noInput: "No microphone input is available."
      case .unsupportedFormat: "The microphone format cannot be converted to 16 kHz."
      }
    }
  }

  static let sampleRate = 16_000.0

  private let engine = AVAudioEngine()
  private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
  private let lock = NSLock()
  private var converter: AVAudioConverter?
  private var continuation: AsyncStream<Chunk>.Continuation?
  private var configurationObserver: NSObjectProtocol?

  static func requestPermission() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }

  /// Start capturing. The stream ends when `stop()` is called.
  func start() throws -> AsyncStream<Chunk> {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: [])
    try session.setActive(true)
    let (stream, continuation) = AsyncStream.makeStream(of: Chunk.self, bufferingPolicy: .unbounded)
    lock.withLock { self.continuation = continuation }
    try installTap()
    // A route change (headset plugged in, Bluetooth) stops the engine with a new format.
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      try? self?.installTap()
    }
    return stream
  }

  func stop() {
    if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    configurationObserver = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    lock.withLock {
      continuation?.finish()
      continuation = nil
      converter = nil
    }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func installTap() throws {
    let input = engine.inputNode
    input.removeTap(onBus: 0)
    engine.stop()
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
    guard let converter = AVAudioConverter(from: format, to: target) else { throw Failure.unsupportedFormat }
    lock.withLock { self.converter = converter }
    // ~85 ms at 48 kHz: small enough that the model sees each window promptly.
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
      self?.convert(buffer)
    }
    engine.prepare()
    try engine.start()
  }

  private func convert(_ buffer: AVAudioPCMBuffer) {
    let (converter, continuation) = lock.withLock { (self.converter, self.continuation) }
    guard let converter, let continuation, buffer.frameLength > 0 else { return }
    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
    var supplied = false
    var error: NSError?
    // `.noDataNow` (not end-of-stream) keeps the resampler's history for the next buffer.
    _ = converter.convert(to: out, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
    let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    var energy: Float = 0
    for s in samples { energy += s * s }
    continuation.yield(Chunk(samples: samples, level: (energy / Float(samples.count)).squareRoot()))
  }
}
