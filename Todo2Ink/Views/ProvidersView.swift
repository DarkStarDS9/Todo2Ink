import SwiftUI

/// The root screen: which sync sources are on, in which order, and what the reader will end up
/// showing because of it.
///
/// Providers are reorderable here rather than on a screen of their own because their order is only
/// ever meaningful in combination with the list order inside each one — the reader has a single
/// flat run of lists and no idea that providers exist. The "On Your Reader" section at the bottom
/// is that flattening made visible, so the effect of a drag is on screen at the same time as the
/// drag.
struct ProvidersView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                ForEach(model.orderedProviders, id: \.id) { provider in
                    NavigationLink {
                        ProviderListsView(model: model, providerId: provider.id)
                    } label: {
                        ProviderRow(model: model, provider: provider)
                    }
                }
                .onMove { model.moveProviders(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Sync Sources")
            } footer: {
                Text("Sources sync in this order. Drag to rearrange.")
            }

            readerOrderSection
        }
        .navigationTitle("Todo2Ink")
        .toolbar { EditButton() }
        .task { await model.loadAllLists() }
    }

    @ViewBuilder
    private var readerOrderSection: some View {
        let order = model.readerOrder
        Section {
            if order.isEmpty {
                Text("Nothing selected yet — pick a source above and choose its lists.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(order.enumerated()), id: \.offset) { _, entry in
                    HStack {
                        Text(entry.list)
                        Spacer()
                        Text(entry.provider)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("On Your Reader")
        } footer: {
            // A `u8` list count on the wire, so this is a hard limit and not a guideline — better to
            // say so here than to let a push fail with a decoding error the user can't act on.
            if model.exceedsListLimit {
                Text("Too many lists — the reader can show at most \(TodoDocumentBuilder.maxLists).")
                    .foregroundStyle(.red)
            } else {
                Text("The order your lists appear in on the reader.")
            }
        }
    }
}

private struct ProviderRow: View {
    @ObservedObject var model: AppModel
    let provider: any TodoProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider.displayName)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(isFailed ? Color.red : .secondary)
        }
    }

    private var isFailed: Bool {
        if case .failed = model.authStates[provider.id] { return true }
        return false
    }

    private var subtitle: String {
        guard model.isEnabled(provider.id) else { return "Off" }
        if case .failed(let message) = model.authStates[provider.id] { return message }
        let count = model.configuration[provider.id]?.selectedListIds.count ?? 0
        return count == 1 ? "1 list" : "\(count) lists"
    }
}
