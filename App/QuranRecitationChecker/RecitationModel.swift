import AVFoundation
import Foundation
import Observation
import RecitationKit
import UIKit

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

  private static let modeKey = "recitation-mode"
  private let service = RecognitionService()
  private let microphone = MicrophoneCapture()
  private var listening: Task<Void, Never>?
  /// Start or stop in progress: ignore further taps until it settles.
  private var transitioning = false
  private var stopping = false
  private var interruptionObserver: NSObjectProtocol?

  init() {
    mode = RecitationMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .tracking
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
          self.apply(try await service.feed(chunk.samples))
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
