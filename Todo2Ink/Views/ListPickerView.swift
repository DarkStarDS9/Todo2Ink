import SwiftUI

/// Lets the user choose which Reminders lists sync to the reader. Never "all lists" by default —
/// see `CLAUDE.md`'s "Data model notes".
struct ListPickerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(model.lists) { list in
            Button {
                model.toggleListSelection(list.id)
            } label: {
                HStack {
                    Text(list.title)
                    Spacer()
                    if model.selectedListIds.contains(list.id) {
                        Image(systemName: "checkmark")
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .task { await model.loadLists() }
        .navigationTitle("Lists")
    }
}
