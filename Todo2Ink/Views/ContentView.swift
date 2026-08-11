import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            VStack {
                PairingView(model: model)
                Divider()
                ListPickerView(model: model)
            }
            .navigationTitle("Todo2Ink")
        }
    }
}
