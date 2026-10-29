import Foundation
import UIKit
import GoogleSignIn

/// Google sign-in with the narrow `drive.file` scope (the app only sees files it created).
@MainActor
public final class GoogleAuth: TokenProvider {
    public static let shared = GoogleAuth()
    public static let driveScope = "https://www.googleapis.com/auth/drive.file"

    public init() {}

    public enum RestoreResult: Sendable {
        case restored
        case noPreviousUser
        /// A previous sign-in exists but could not be restored right now (e.g. offline).
        case unavailable
    }

    /// True when a user is signed in, or a previous sign-in is stored in the keychain and merely
    /// couldn't be restored yet (offline); the pipeline then retries instead of reporting signed-out.
    public var isSignedIn: Bool {
        GIDSignIn.sharedInstance.currentUser != nil || GIDSignIn.sharedInstance.hasPreviousSignIn()
    }

    /// Email of the signed-in account, for the Settings screen.
    public var email: String? { GIDSignIn.sharedInstance.currentUser?.profile?.email }

    /// Restores a previous sign-in from the keychain.
    @discardableResult
    public func restorePreviousSignIn() async -> RestoreResult {
        do {
            try await restore()
            return .restored
        } catch DriveError.notSignedIn {
            return .noPreviousUser
        } catch {
            return .unavailable
        }
    }

    private func restore() async throws {
        do {
            _ = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
        } catch {
            throw Self.map(error)
        }
    }

    /// Classifies an error from GoogleSignIn/AppAuth. Network failures (including ones wrapped in
    /// AppAuth/GoogleSignIn NSErrors, found via the underlying-error chain) become `.network`;
    /// only genuine auth failures become `.notSignedIn`; anything else is returned unchanged.
    nonisolated static func map(_ error: Error) -> Error {
        if error is DriveError { return error }
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 8 {
            if ns.domain == NSURLErrorDomain { return DriveError.network(error) }
            if ns.domain == "org.openid.appauth.general", ns.code == -5 { return DriveError.network(error) }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        let ns = error as NSError
        // GIDSignInError.hasNoAuthInKeychain
        if ns.domain == "com.google.GIDSignIn", ns.code == -4 { return DriveError.notSignedIn }
        // OAuth token endpoint rejected the refresh token (invalid_grant, revoked, ...)
        if ns.domain.hasPrefix("org.openid.appauth.oauth") { return DriveError.notSignedIn }
        return error
    }

    public func signIn(presenting: UIViewController) async throws {
        _ = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presenting, hint: nil, additionalScopes: [Self.driveScope])
    }

    public func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    /// Forward the URL from `.onOpenURL` / the app delegate.
    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    public func accessToken() async throws -> String {
        if GIDSignIn.sharedInstance.currentUser == nil {
            try await restore()
        }
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw DriveError.notSignedIn }
        do {
            let refreshed = try await user.refreshTokensIfNeeded()
            return refreshed.accessToken.tokenString
        } catch {
            throw Self.map(error)
        }
    }
}
