import SwiftUI

/// One provider's setup: whether it syncs at all, which of its lists do, and in what order.
///
/// Selected and unselected lists live in two sections rather than one section with checkmarks,
/// because only the selected ones have an order and a section is the honest way to say so — a drag
/// handle on a row that isn't syncing would be a control with nothing to control. Selecting a list
/// moves it from the bottom section to the end of the top one, which is also exactly what it does
/// to the reader.
struct ProviderListsView: View {
    @ObservedObject var model: AppModel
    let providerId: ProviderId

    var body: some View {
        List {
            Section {
                Toggle("Sync This Source", isOn: Binding(
                    get: { model.isEnabled(providerId) },
                    set: { model.setEnabled($0, for: providerId) }
                ))
            } footer: {
                statusFooter
            }

            if model.isEnabled(providerId) {
                selectedSection
                availableSection
            }
        }
        .navigationTitle(model.provider(providerId)?.displayName ?? "Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .task { await model.requestAccessAndLoadLists(for: providerId) }
    }

    @ViewBuilder
    private var statusFooter: some View {
        // Only the provider's own words, and only when there are any — a green "everything is fine"
        // line under a toggle that is visibly on says nothing the toggle didn't.
        if let description = model.provider(providerId)?.statusDescription,
           model.isEnabled(providerId) {
            Text(description)
                .foregroundStyle(isFailed ? Color.red : .secondary)
        }
    }

    private var isFailed: Bool {
        if case .failed = model.authStates[providerId] { return true }
        return false
    }

    @ViewBuilder
    private var selectedSection: some View {
        let selected = model.selectedLists(for: providerId)
        Section {
            if selected.isEmpty {
                Text("No lists yet.").foregroundStyle(.secondary)
            } else {
                ForEach(selected) { list in
                    Button {
                        model.toggleListSelection(list.id, for: providerId)
                    } label: {
                        HStack {
                            Text(list.title)
                            Spacer()
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onMove { model.moveLists(for: providerId, fromOffsets: $0, toOffset: $1) }
            }
        } header: {
            Text("Syncing")
        } footer: {
            if !selected.isEmpty {
                Text("Drag to set the order these appear in on the reader.")
            }
        }
    }

    @ViewBuilder
    private var availableSection: some View {
        let available = model.availableLists(for: providerId)
        if !available.isEmpty {
            Section("Available") {
                ForEach(available) { list in
                    Button {
                        model.toggleListSelection(list.id, for: providerId)
                    } label: {
                        HStack {
                            Text(list.title)
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }
}
