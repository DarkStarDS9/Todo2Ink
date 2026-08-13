import SwiftUI

/// Bring!'s own setup: signing in, and the two choices its data model forces that Reminders doesn't.
///
/// Talks to `BringProvider` directly rather than through `AppModel`, so nothing Bring-specific has
/// to exist on the model. What it does route through the model is the refresh afterwards — that is
/// what republishes `authStates` and reloads the list picker above.
///
/// Todo2Ink is not affiliated with Bring! and this is not an official integration; the footer says
/// so where the user is actually entering their Bring! password.
struct BringSettingsView: View {
    @ObservedObject var model: AppModel
    let provider: BringProvider

    @State private var email = ""
    @State private var password = ""
    @State private var signedInEmail: String?
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var options = BringOptions.default

    private var isSignedIn: Bool { model.authStates[.bring] == .authorized }

    var body: some View {
        Group {
            if isSignedIn {
                accountSection
                optionsSection
            } else {
                signInSection
            }
        }
        .task {
            signedInEmail = await provider.signedInEmail()
            email = signedInEmail ?? email
            options = provider.options
        }
    }

    // MARK: - Signed out

    @ViewBuilder
    private var signInSection: some View {
        Section {
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(.password)

            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    Text("Sign In")
                    if isSigningIn {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(email.isEmpty || password.isEmpty || isSigningIn)
        } header: {
            Text("Bring! Account")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                // Said here, at the password field, rather than buried in an About screen: this is
                // the moment the user is deciding whether to trust the app with their account.
                Text("Todo2Ink is not affiliated with Bring! — your password is sent to Bring! "
                     + "only to sign in, and is never stored on this phone.")
            }
        }
    }

    private func signIn() async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }

        do {
            try await provider.logIn(email: email, password: password)
            // Held only as long as the request needs it.
            password = ""
            signedInEmail = email
            await model.requestAccessAndLoadLists(for: .bring)
        } catch {
            errorMessage = (error as? BringError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private var accountSection: some View {
        Section("Bring! Account") {
            LabeledContent("Signed in as", value: signedInEmail ?? "—")
            Button("Sign Out", role: .destructive) {
                Task {
                    await provider.logOut()
                    signedInEmail = nil
                    password = ""
                    await model.requestAccessAndLoadLists(for: .bring)
                }
            }
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        Section {
            Toggle("Show Recently Bought", isOn: $options.showsRecentlyPurchased)
            if options.showsRecentlyPurchased {
                Stepper(
                    "Show \(options.recentlyPurchasedLimit)",
                    value: $options.recentlyPurchasedLimit,
                    in: BringOptions.limitRange
                )
            }
        } header: {
            Text("Recently Bought")
        } footer: {
            // Explains a consequence the user would otherwise only discover by losing an item.
            Text(options.showsRecentlyPurchased
                 ? "Recently bought items appear checked, below the ones still to buy, so you can "
                   + "un-check them from the reader."
                 : "Items you check off on the reader disappear from it at the next sync.")
        }
        .onChange(of: options) { _, newValue in
            provider.options = newValue
        }
    }
}
