import SwiftUI

@main
struct QuranRecitationCheckerApp: App {
  @State private var model = RecitationModel()

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .task { await model.load() }
    }
  }
}
