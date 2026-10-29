import Foundation
import UIKit
import GoogleSignIn

/// Google sign-in with the narrow `drive.file` scope (the app only sees files it created).
@MainActor
public final class GoogleAuth: TokenProvider {
    public static let shared = GoogleAuth()
    public static let driveScope = "https://www.googleapis.com/auth/drive.file"

    public init() {}

    public var isSignedIn: Bool { GIDSignIn.sharedInstance.currentUser != nil }

    /// Email of the signed-in account, for the Settings screen.
    public var email: String? { GIDSignIn.sharedInstance.currentUser?.profile?.email }

    /// Restores a previous sign-in from the keychain. Returns whether a user is now signed in.
    @discardableResult
    public func restorePreviousSignIn() async -> Bool {
        do {
            _ = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            return true
        } catch {
            return false
        }
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
            guard await restorePreviousSignIn() else { throw DriveError.notSignedIn }
        }
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw DriveError.notSignedIn }
        do {
            let refreshed = try await user.refreshTokensIfNeeded()
            return refreshed.accessToken.tokenString
        } catch let error as URLError {
            throw DriveError.network(error)
        } catch {
            throw DriveError.notSignedIn
        }
    }
}
