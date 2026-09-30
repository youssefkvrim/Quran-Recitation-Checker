import SwiftUI
import UIKit

/// On-device profile, refreshed every second: model and engine time per
/// 480 ms window, lag, share of real time, thermal state, battery and memory.
/// Touch and hold it to copy the numbers.
struct PerformanceReadout: View {
  let model: RecitationModel
  @State private var report = ""

  var body: some View {
    Text(report)
      .font(.caption2.monospaced())
      .foregroundStyle(.secondary)
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(.regularMaterial, in: .rect(cornerRadius: 12))
      .contextMenu {
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = report }
      }
      .environment(\.layoutDirection, .leftToRight)
      .task {
        while !Task.isCancelled {
          report = await model.performanceReport()
          try? await Task.sleep(for: .seconds(1))
        }
      }
  }
}
