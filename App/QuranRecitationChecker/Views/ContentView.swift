import RecitationKit
import SwiftUI

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
          RecitationView(model: model)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Picker("Mode", selection: $model.mode) {
            Text("Tracking").tag(RecitationMode.tracking)
            Text("Correction").tag(RecitationMode.correction)
          }
          .pickerStyle(.segmented)
          .fixedSize()
        }
      }
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

private struct RecitationView: View {
  @Bindable var model: RecitationModel

  var body: some View {
    VStack(spacing: 20) {
      if model.showsPerformance {
        PerformanceReadout(model: model)
      }
      if let position = model.position, let text = model.text, let surah = text.surah(position.surah) {
        PassageView(surah: surah, position: position)
      } else if let preamble = model.preamble {
        Spacer()
        PreambleView(progress: preamble)
      } else {
        Spacer()
        Placeholder(listening: model.isListening, mode: model.mode)
      }
      Spacer(minLength: 0)
      if let summary = model.summary, !model.isListening {
        Label(summary, systemImage: "checkmark.circle")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
      }
      RecordButton(isListening: model.isListening, level: model.level) {
        Task { await model.toggleListening() }
      }
      Text(status)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.bottom, 8)
        // Hidden: hold the status line to show or hide the performance readout.
        .onLongPressGesture(minimumDuration: 0.8) { model.showsPerformance.toggle() }
        .sensoryFeedback(.selection, trigger: model.showsPerformance)
        .accessibilityAction(named: Text(model.showsPerformance ? "Hide performance readout" : "Show performance readout")) {
          model.showsPerformance.toggle()
        }
    }
    .padding(.horizontal, 20)
    .sheet(item: correctionBinding) { correction in
      CorrectionSheet(correction: correction, acting: model.acting) { action in
        Task { await model.correct(action) }
      }
    }
  }

  private var status: String {
    if let notice = model.notice { return notice }
    if model.isListening { return model.position == nil ? "Listening · finding your place" : "Listening · offline" }
    return "Offline · audio never leaves this iPhone"
  }

  /// Swiping the sheet away closes the correction, like "Close practice".
  private var correctionBinding: Binding<RecitationModel.OpenCorrection?> {
    Binding(
      get: { model.correction },
      set: { newValue in if newValue == nil, model.correction != nil { Task { await model.correct(.close) } } }
    )
  }
}

private struct Placeholder: View {
  let listening: Bool
  let mode: RecitationMode

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: listening ? "waveform" : "book.closed")
        .font(.system(size: 40, weight: .light))
        .foregroundStyle(.tint)
        .symbolEffect(.variableColor.iterative, isActive: listening)
      Text(listening ? "Recite from anywhere in the Quran." : "Start anywhere in the Quran.")
        .font(.title3.weight(.semibold))
      Text(mode == .correction
           ? "Possible mistakes appear as you recite. Repeat the ayah to correct them."
           : "The ayah is found in a few words, then followed word by word.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
  }
}

private struct RecordButton: View {
  let isListening: Bool
  let level: Float
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: isListening ? "stop.fill" : "mic.fill")
        .font(.system(size: 30, weight: .semibold))
        .frame(width: 84, height: 84)
    }
    .buttonStyle(.glassProminent)
    .buttonBorderShape(.circle)
    .tint(isListening ? .red : .accentColor)
    .background {
      Circle()
        .fill(.tint.opacity(0.18))
        .scaleEffect(isListening ? 1 + CGFloat(min(level * 6, 0.45)) : 1)
        .animation(.easeOut(duration: 0.12), value: level)
    }
    .sensoryFeedback(.impact(weight: .medium), trigger: isListening)
    .accessibilityLabel(isListening ? "Stop reciting" : "Start reciting")
  }
}
