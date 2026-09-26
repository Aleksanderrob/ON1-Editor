import SwiftUI

@main
struct ON1EditorApp: App {
    @StateObject private var model = TripViewModel()

    var body: some Scene {
        WindowGroup("ON1 Editor") {
            ContentView(model: model)
                .frame(minWidth: 1050, minHeight: 700)
        }
    }
}
