import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // The status bar sits *outside* the navigation stack, so it stays pinned to the very top
        // instead of scrolling away with the list — matching Snap2Ink. Inside the stack it would
        // sit between the "Lists" title and the list itself, where a large title collapsing on
        // scroll pushes it around and reads as a bug.
        VStack(spacing: 0) {
            LinkStatusBar(model: model)
            NavigationStack {
                ProvidersView(model: model)
            }
        }
        .task { model.connect() }
    }
}
