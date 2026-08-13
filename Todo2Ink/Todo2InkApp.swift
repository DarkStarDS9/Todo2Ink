import SwiftUI

@main
struct Todo2InkApp: App {
    @StateObject private var model = AppModel(
        transport: Todo2InkApp.makeTransport(),
        providers: Todo2InkApp.makeProviders()
    )
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Same reasoning as Snap2Ink's `Snap2InkApp`: nothing here needs to keep the BLE link
            // held while backgrounded and idle.
            DebugLog.shared.log("scenePhase -> \(newPhase)")
            switch newPhase {
            case .background:
                model.disconnectForBackground()
            case .active:
                model.connect()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    /// The simulator has no Bluetooth radio, so a real transport has nothing to do there but fail.
    /// Unlike Snap2Ink, there's no mock yet — `TodoSyncEngine`'s loop isn't implemented, so a mock
    /// transport would have nothing to exercise. Add one (mirroring `MockDisplayTransport`) once
    /// that loop is real and needs a fast, deviceless test target.
    private static func makeTransport() -> DisplayTransport {
        CompanionKitTransport()
    }

    /// Every sync backend the app knows about, in the order a first-time user meets them.
    ///
    /// This is the *only* place a provider is named. `AppModel`, `TodoSyncEngine` and every view
    /// work from `TodoProvider` alone, so adding a backend means writing one conformance and adding
    /// one line here — the user's own ordering, stored in `SyncConfiguration`, takes over from this
    /// list as soon as they rearrange anything.
    @MainActor
    private static func makeProviders() -> [any TodoProvider] {
        [RemindersProvider(service: RemindersService())]
    }
}
