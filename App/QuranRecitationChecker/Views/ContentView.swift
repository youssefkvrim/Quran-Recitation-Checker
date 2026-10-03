import RecitationKit
import SwiftUI

/// One screen, after the web app: the mode, a card that shows what the app
/// knows (an example, then the listening state, then the passage), and one
/// action underneath.
struct ContentView: View {
  @Bindable var model: RecitationModel

  var body: some View {
    NavigationStack {
      Group {
        switch model.phase {
        case .loading:
          ProgressView("Preparing the offline model…")
        case let .failed(message):
          ContentUnavailableView("Recitation unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
        case .ready, .listening:
          RecitationScreen(model: model)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.paper)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Picker("Mode", selection: $model.mode) {
            Text("Tracking").tag(RecitationMode.tracking)
            Text("Correction").tag(RecitationMode.correction)
          }
          .pickerStyle(.segmented)
          .fixedSize()
          .disabled(model.isListening)
        }
      }
      .navigationBarTitleDisplayMode(.inline)
    }
    .tint(Color.ink)
  }
}

private struct RecitationScreen: View {
  @Bindable var model: RecitationModel

  var body: some View {
    VStack(spacing: 16) {
      Text(model.mode == .tracking ? "Find your ayah and follow each word." : "Spot missed words and retry as you recite.")
        .font(.footnote)
        .foregroundStyle(Color.muted)
      if model.showsPerformance { PerformanceReadout(model: model) }
      card
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .background(Color.surface, in: .rect(cornerRadius: 24))
      actions
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
    .sheet(item: correctionBinding) { correction in
      CorrectionSheet(correction: correction, acting: model.acting) { action in
        Task { await model.correct(action) }
      }
    }
  }

  @ViewBuilder private var card: some View {
    if let position = model.position, let surah = model.text?.surah(position.surah) {
      PassageView(surah: surah, position: position)
    } else if model.isListening {
      ListeningCard(model: model)
    } else if let summary = model.summary {
      VStack(spacing: 8) {
        Text("Recitation paused.").font(.title2)
        Text(summary).foregroundStyle(Color.muted)
      }
      .frame(maxHeight: .infinity)
    } else {
      ExampleCard(mode: model.mode)
    }
  }

  @ViewBuilder private var actions: some View {
    VStack(spacing: 10) {
      if model.isListening {
        Button { Task { await model.toggleListening() } } label: {
          ActionLabel(title: "Stop reciting", systemImage: "stop.fill")
        }
        .secondaryAction()
      } else {
        Button { Task { await model.toggleListening() } } label: {
          ActionLabel(title: model.summary == nil ? (model.mode == .correction ? "Start with correction" : "Start reciting") : "Recite again",
                      systemImage: "mic.fill")
        }
        .primaryAction()
        .sensoryFeedback(.impact(weight: .medium), trigger: model.isListening)
      }
      HStack(spacing: 16) {
        Text(note)
          .font(.footnote)
          .foregroundStyle(model.isFallingBehind || model.notice != nil ? Color.rose : Color.muted)
          // Hidden: hold the note to show or hide the performance readout.
          .onLongPressGesture(minimumDuration: 0.8) { model.showsPerformance.toggle() }
          .accessibilityAction(named: Text(model.showsPerformance ? "Hide performance readout" : "Show performance readout")) {
            model.showsPerformance.toggle()
          }
        if !model.isListening, let files = model.recordingFiles {
          ShareLink(items: files) { Text("Share recording").font(.footnote).underline() }
            .foregroundStyle(Color.ink)
        }
      }
      .multilineTextAlignment(.center)
    }
  }

  private var note: String {
    if let notice = model.notice { return notice }
    if model.isFallingBehind { return String(format: "This iPhone is %.1f s behind your recitation", model.lag) }
    if model.isListening {
      return model.position == nil ? "Microphone on · Audio stays here" : "Following word by word · Offline"
    }
    return "Works offline · Audio never leaves this iPhone"
  }

  /// Swiping the sheet away closes the correction, like "Close practice".
  private var correctionBinding: Binding<RecitationModel.OpenCorrection?> {
    Binding(
      get: { model.correction },
      set: { newValue in if newValue == nil, model.correction != nil { Task { await model.correct(.close) } } }
    )
  }
}

/// Before reciting: what the app does, shown on al-Ikhlas.
private struct ExampleCard: View {
  let mode: RecitationMode

  var body: some View {
    VStack(spacing: 14) {
      Spacer(minLength: 0)
      Text("EXAMPLE · AL-IKHLAS, 112:1")
        .font(.caption2.weight(.semibold))
        .tracking(1.4)
        .foregroundStyle(Color.muted)
      Text(example)
        .font(.quran(size: 36))
        .environment(\.layoutDirection, .rightToLeft)
      Rectangle().fill(Color.rule).frame(width: 32, height: 1)
      Text(mode == .correction ? "Catch a missed word.\nTry it again." : "Start anywhere\nin the Quran.")
        .font(.title2)
      Text(mode == .correction
           ? "See possible mistakes as you recite, then repeat the ayah to correct them."
           : "Find your ayah and follow each word as you recite.")
        .font(.subheadline)
        .foregroundStyle(Color.muted)
      Spacer(minLength: 0)
    }
    .multilineTextAlignment(.center)
  }

  private var example: AttributedString {
    var spoken = AttributedString("قُلْ")
    spoken.foregroundColor = Color.muted
    var current = AttributedString("هُوَ")
    current.foregroundColor = mode == .correction ? Color.rose : Color.paper
    current.backgroundColor = mode == .correction ? Color.roseWash : Color.ink
    var rest = AttributedString("ٱللَّهُ أَحَدٌ")
    rest.foregroundColor = Color.ink
    var marker = AttributedString("۝١")
    marker.foregroundColor = Color.muted
    let space = AttributedString(" ")
    return spoken + space + current + space + rest + space + marker
  }
}

/// Listening, place not found yet: the waveform, then the istiʿādha or basmala as heard.
private struct ListeningCard: View {
  let model: RecitationModel

  var body: some View {
    VStack(spacing: 18) {
      Spacer(minLength: 0)
      Waveform(model: model)
      if let preamble = model.preamble {
        PreambleView(progress: preamble)
      }
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let slow = model.listeningSince.map { context.date.timeIntervalSince($0) > 15 } ?? false
        VStack(spacing: 8) {
          Text(slow ? "We haven’t found the verse yet." : "Begin your recitation.")
            .font(.title2)
          Text(slow ? "Keep reciting a few more words. Try moving closer to the microphone."
                    : "Start with any ayah. We’ll find your place as you recite.")
            .font(.subheadline)
            .foregroundStyle(Color.muted)
        }
      }
      Spacer(minLength: 0)
    }
    .multilineTextAlignment(.center)
  }
}

/// Eleven bars that rise with the microphone level, as on the web.
private struct Waveform: View {
  let model: RecitationModel
  private static let phases: [Double] = [0.34, 0.72, 0.48, 0.95, 0.58, 1, 0.68, 0.86, 0.42, 0.76, 0.52]

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
      let strength = min(1, max(0, (Double(model.level) - 0.004) * 24))
      let drift = context.date.timeIntervalSinceReferenceDate / 0.18
      HStack(spacing: 5) {
        ForEach(Self.phases.indices, id: \.self) { i in
          let motion = 0.55 + 0.45 * sin(drift + Double(i) * 0.78)
          let level = min(1, 0.18 + strength * (Self.phases[i] * 0.62 + motion * 0.34))
          Capsule().fill(Color.ink).frame(width: 3, height: 54 * level)
        }
      }
      .frame(height: 54)
    }
    .accessibilityHidden(true)
  }
}
