import AVFoundation
import Foundation
import Observation
import RecitationKit
import UIKit
import os

/// UI state for one screen: follows the engine's events and drives the microphone.
@MainActor
@Observable
final class RecitationModel {
  enum Phase: Equatable {
    case loading
    case ready
    case listening
    case failed(String)
  }

  /// Where the reciter is.
  struct Position: Equatable {
    var surah: Int
    var ayah: Int
    /// Acoustic word index inside the ayah (see `DisplayWord`).
    var word: Int
  }

  /// An open correction, with the display words to show it on.
  struct OpenCorrection: Identifiable, Equatable {
    var state: CorrectionState
    var words: [DisplayWord]
    /// Uthmani text of the flagged ayah.
    var text: String
    var surahName: String
    var ayahCount: Int
    /// One sheet per issue, kept open across its retry phases.
    var id: String {
      guard let i = state.issue else { return "" }
      return "\(i.surah):\(i.ayah):\(i.wordIndex):\(i.kind.rawValue)"
    }
  }

  private(set) var phase: Phase = .loading
  private(set) var position: Position?
  private(set) var level: Float = 0
  private(set) var summary: String?
  /// A recoverable problem to show under the button (permission, microphone).
  private(set) var notice: String?
  private(set) var correction: OpenCorrection?
  private(set) var text: QuranText?
  /// Whether a correction action is waiting for the engine.
  private(set) var acting = false

  var mode: RecitationMode {
    didSet {
      guard mode != oldValue else { return }
      UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
      Task { apply(await service.setMode(mode)) }
    }
  }

  /// The hidden performance readout (long-press the status line).
  var showsPerformance: Bool {
    didSet {
      UserDefaults.standard.set(showsPerformance, forKey: Self.performanceKey)
      UIDevice.current.isBatteryMonitoringEnabled = showsPerformance
    }
  }

  private static let modeKey = "recitation-mode"
  private static let performanceKey = "performance-readout"
  private let service = RecognitionService()
  private let microphone = MicrophoneCapture()
  private var listening: Task<Void, Never>?
  /// Start or stop in progress: ignore further taps until it settles.
  private var transitioning = false
  private var stopping = false
  private var interruptionObserver: NSObjectProtocol?
  /// Battery level at the start and end of the last recitation, for the readout.
  private var battery: (start: ContinuousClock.Instant, level: Float, end: ContinuousClock.Instant?, endLevel: Float)?

  init() {
    mode = RecitationMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .tracking
    showsPerformance = UserDefaults.standard.bool(forKey: Self.performanceKey)
    UIDevice.current.isBatteryMonitoringEnabled = showsPerformance
  }

  var isListening: Bool { phase == .listening }

  func load() async {
    guard phase == .loading else { return }
    do {
      text = try await service.load()
      phase = .ready
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  func toggleListening() async {
    guard !transitioning else { return }
    transitioning = true
    defer { transitioning = false }
    if isListening { await stop() } else { await start() }
  }

  func start() async {
    guard phase == .ready else { return }
    notice = nil
    guard await MicrophoneCapture.requestPermission() else {
      notice = "Microphone access is off. Turn it on in Settings to recite."
      return
    }
    position = nil
    summary = nil
    correction = nil
    apply(await service.begin(mode: mode))
    let stream: AsyncStream<MicrophoneCapture.Chunk>
    do {
      stream = try microphone.start()
    } catch {
      notice = error.localizedDescription
      return
    }
    phase = .listening
    UIApplication.shared.isIdleTimerDisabled = true
    battery = (ContinuousClock.now, UIDevice.current.batteryLevel, nil, 0)
    // A call or another app taking the microphone ends the recitation.
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] note in
      let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
      guard type == .began else { return }
      Task { @MainActor in await self?.stop() }
    }
    listening = Task { [service] in
      for await chunk in stream {
        self.level = chunk.level
        do {
          self.apply(try await service.feed(chunk.samples, capturedAt: chunk.captured))
        } catch {
          // Inference failed: release the microphone and say so.
          self.microphone.stop()
          UIApplication.shared.isIdleTimerDisabled = false
          self.phase = .failed(error.localizedDescription)
          break
        }
      }
    }
  }

  func stop() async {
    // Reached from the button and from audio interruptions: finish only once.
    guard isListening, !stopping else { return }
    stopping = true
    defer { stopping = false }
    microphone.stop()
    await listening?.value
    listening = nil
    if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    interruptionObserver = nil
    UIApplication.shared.isIdleTimerDisabled = false
    battery?.end = ContinuousClock.now
    battery?.endLevel = UIDevice.current.batteryLevel
    level = 0
    phase = .ready
    do {
      apply(try await service.finish())
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  func correct(_ action: CorrectionAction) async {
    guard !acting else { return }
    acting = true
    apply(await service.correct(action))
    acting = false
  }

  // MARK: - Performance readout

  /// The readout's text for the current (or last) recitation.
  func performanceReport() async -> String {
    let profile = await service.profile
    let stats = profile.stats
    func line(_ name: String, _ summary: PerformanceStats.Summary?, _ unit: String) -> String {
      guard let s = summary else { return "\(name)  –" }
      return String(format: "%@  p50 %5.1f  p95 %5.1f  max %5.1f %@", name, s.p50, s.p95, s.max, unit)
    }
    let cpu = stats.realTimeFactor.map {
      String(format: "CPU     %.1f%% of real time · %ld windows · %.0f s audio", $0 * 100, stats.runs, stats.audioSeconds)
    } ?? "CPU     –"
    return [
      line("Model ", stats.model, "ms/480ms"),
      line("Engine", stats.engine, "ms/480ms"),
      line("Lag   ", stats.lag, "ms"),
      cpu,
      "Device  thermal \(Self.thermalState) · battery \(batteryTrend) · memory left \(Self.memoryHeadroom)",
      String(format: "Load    %.2f s · warm-up %.0f ms · %@ · iOS %@",
             profile.loadSeconds, profile.warmUpSeconds * 1000, Self.deviceModel, UIDevice.current.systemVersion),
    ].joined(separator: "\n")
  }

  private var batteryTrend: String {
    let device = UIDevice.current
    if device.batteryState == .charging || device.batteryState == .full { return "charging" }
    guard let battery, battery.level >= 0 else { return "–" }
    let end = battery.end ?? .now
    let level = battery.end == nil ? device.batteryLevel : battery.endLevel
    let components = (end - battery.start).components
    let minutes = (Double(components.seconds) + Double(components.attoseconds) * 1e-18) / 60
    guard level >= 0, minutes >= 1 else { return "measuring" }
    let percentDrop = Double(battery.level - level) * 100
    return String(format: "−%.1f%%/10 min over %.0f min", percentDrop / minutes * 10, minutes)
  }

  private static var thermalState: String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }

  private static var memoryHeadroom: String {
    String(format: "%.0f MB", Double(os_proc_available_memory()) / 1_048_576)
  }

  private static var deviceModel: String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }

  // MARK: - Events

  private func apply(_ events: [RecitationEvent]) {
    for event in events {
      switch event {
      case let .verseCandidate(surah, ayah, _):
        if position == nil || position!.surah != surah { position = Position(surah: surah, ayah: ayah, word: 0) }
      case let .verseMatch(surah, ayah, _):
        // Matches only move the reader forward; word progress follows repeats back.
        if position == nil || position!.surah != surah || ayah > position!.ayah {
          position = Position(surah: surah, ayah: ayah, word: 0)
        }
      case let .wordProgress(p):
        position = Position(surah: p.surah, ayah: p.ayah, word: p.wordIndex)
      case let .finalSequence(verses, _):
        summary = Self.describe(verses, text: text)
      case let .correction(state, totalWords):
        openCorrection(state, totalWords: totalWords)
      case .rawTranscript, .debug:
        break
      }
    }
  }

  private func openCorrection(_ state: CorrectionState, totalWords: Int) {
    guard state.phase != .idle, let issue = state.issue else {
      correction = nil
      return
    }
    guard let surah = text?.surah(issue.surah), issue.ayah >= 1, issue.ayah <= surah.ayahs.count else { return }
    let ayahText = surah.ayahs[issue.ayah - 1]
    let words = QuranText.ayahWords(surah: issue.surah, ayah: issue.ayah, text: ayahText)
    // Never attach acoustic indices to a display tokenization that disagrees.
    guard mode == .correction, isListening, words.reduce(0, { $0 + $1.count }) == totalWords,
          words.contains(where: { $0.covers(issue.word) }) else {
      Task { await correct(.close) }
      return
    }
    if correction == nil { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    correction = OpenCorrection(state: state, words: words, text: ayahText, surahName: surah.nameEn, ayahCount: surah.ayahs.count)
  }

  private static func describe(_ verses: [FinalVerse], text: QuranText?) -> String? {
    guard let first = verses.first, let last = verses.last else { return nil }
    let name = text?.surah(first.surah)?.nameEn ?? "Surah \(first.surah)"
    if first.surah == last.surah {
      return first.ayah == last.ayah ? "\(name) \(first.ayah)" : "\(name) \(first.ayah)–\(last.ayah)"
    }
    let lastName = text?.surah(last.surah)?.nameEn ?? "Surah \(last.surah)"
    return "\(name) \(first.ayah) – \(lastName) \(last.ayah)"
  }
}
