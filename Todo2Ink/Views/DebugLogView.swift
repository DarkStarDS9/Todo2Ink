import SwiftUI
import UIKit

/// Read-only view over `DebugLog`, for pulling a trace off a phone after a bug happened on it.
/// Same view, same reasoning, as Snap2Ink's.
///
/// Not `#if DEBUG`: the symptoms this exists to diagnose — a stuck reconnect, a sync that fails
/// against a real Bring! account — are ones a TestFlight tester hits in the field, where the error
/// on screen has room for a sentence and the interesting part is everything leading up to it.
///
/// Shareable because the useful next step is usually to send it to someone. `BringHTTP` only ever
/// logs request shapes and response *keys*, never bodies, headers or tokens, so what leaves the
/// phone here is structure rather than the user's lists.
struct DebugLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [DebugLog.Entry] = DebugLog.shared.entries
    @State private var isSharing = false

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                Text(entry.formatted)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .listStyle(.plain)
            .navigationTitle("Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        entries = DebugLog.shared.entries
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isSharing = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $isSharing) {
                ActivityView(text: DebugLog.shared.formattedText)
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
