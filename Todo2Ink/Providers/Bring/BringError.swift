import Foundation

/// Everything the Bring layer can fail with, in the shape the UI needs to talk about it.
///
/// The distinction that matters is `notLoggedIn`/`invalidCredentials` (the user must do something —
/// log in again) versus `http`/`network`/`malformedResponse` (the service is having a moment, and
/// retrying later is the right response). `BringProvider` maps the first pair onto
/// `ProviderAuthState.notConfigured` and the rest onto `.failed`, so a flaky network never silently
/// throws away a working login.
enum BringError: LocalizedError, Equatable {
    /// No stored session at all, or the refresh token is gone. The user has to log in.
    case notLoggedIn

    /// Bring rejected the email/password, or refused to refresh — same user-facing consequence.
    case invalidCredentials

    case http(status: Int)

    /// A 2xx response whose body wasn't what this client expects. Reverse-engineered API: this is
    /// the shape a server-side change arrives in, so it says *which* request to make that
    /// diagnosable without a debugger.
    case malformedResponse(String)

    case network(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not signed in to Bring!"
        case .invalidCredentials:
            return "Bring! rejected your email or password."
        case .http(let status):
            return "Bring! returned an error (HTTP \(status))."
        case .malformedResponse(let detail):
            return "Unexpected response from Bring! (\(detail))."
        case .network(let detail):
            return "Couldn't reach Bring! (\(detail))."
        }
    }

    /// Whether this means the user must supply credentials again, as opposed to the service being
    /// temporarily unhappy.
    var requiresReauthentication: Bool {
        switch self {
        case .notLoggedIn, .invalidCredentials: return true
        case .http, .malformedResponse, .network: return false
        }
    }
}
