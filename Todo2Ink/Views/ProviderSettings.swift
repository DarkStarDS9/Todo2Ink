import SwiftUI

/// Where a provider's own setup UI is named — the view layer's counterpart to
/// `Todo2InkApp.makeProviders()`.
///
/// Some providers need setup that the abstraction can't describe: Reminders has a system permission
/// dialog and nothing else, Bring! needs an email, a password and two options that only make sense
/// for Bring!. That can't live on `TodoProvider` without dragging SwiftUI into what is deliberately
/// a sync-layer protocol, and it must not live in `ProviderListsView` as a chain of type checks.
///
/// So it lives here, in one function, and this is the only place in the view layer that knows a
/// concrete provider type exists. A new backend adds a case; nothing else changes.
enum ProviderSettings {
    @ViewBuilder
    static func view(for provider: any TodoProvider, model: AppModel) -> some View {
        if let bring = provider as? BringProvider {
            BringSettingsView(model: model, provider: bring)
        }
    }
}
