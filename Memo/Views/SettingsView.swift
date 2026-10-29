import MemoKit
import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject private var models = ModelManager.shared
    @State private var settings = AppSettings.load()
    @State private var folderText = AppSettings.load().driveFolderPath
    @FocusState private var folderFocused: Bool

    @State private var signedIn = GoogleAuth.shared.isSignedIn
    @State private var email: String? = GoogleAuth.shared.email
    @State private var authError: String?
    @State private var driveTest: String?
    @State private var driveTesting = false
    @State private var modelError: String?

    var body: some View {
        Form {
            accountSection
            folderSection
            modelSection
            Section("Language") {
                Picker("Language", selection: $settings.language) {
                    Text("Hebrew").tag("he")
                    Text("English").tag("en")
                    Text("Auto").tag("auto")
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Upload audio", isOn: $settings.uploadAudio)
                Toggle("Keep audio on phone", isOn: $settings.keepAudio)
            } footer: {
                Text("Audio is always kept until its transcript has been uploaded. Uploading audio also puts the .m4a in the Drive folder.")
            }
            Section {
                DisclosureGroup("Debug") {
                    LabeledContent("App Group", value: AppPaths.usingAppGroup ? "yes" : "no")
                    NavigationLink("Transcription test") { DebugTranscriptionView() }
                }
            }
        }
        .navigationTitle("Settings")
        .onChange(of: settings) { _, new in new.save() }
        .onChange(of: folderFocused) { _, focused in if !focused { commitFolder() } }
        .onDisappear { commitFolder() }
        .task {
            if await GoogleAuth.shared.restorePreviousSignIn() == .restored { refreshAccount() }
        }
    }

    // MARK: - Google account and Drive folder

    private var accountSection: some View {
        Section("Google account") {
            if signedIn {
                LabeledContent("Signed in", value: email ?? "Account saved")
                Button("Sign out", role: .destructive) {
                    GoogleAuth.shared.signOut()
                    refreshAccount()
                }
            } else {
                Button("Sign in with Google") { Task { await signIn() } }
            }
            if let authError {
                Text(authError).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var folderSection: some View {
        Section {
            TextField("Memos", text: $folderText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($folderFocused)
                .submitLabel(.done)
                .onSubmit { commitFolder() }
            Button {
                Task { await testDrive() }
            } label: {
                HStack {
                    Text("Test Drive connection")
                    if driveTesting { Spacer(); ProgressView() }
                }
            }
            .disabled(driveTesting)
            if let driveTest {
                Text(driveTest)
                    .font(.footnote)
                    .foregroundStyle(driveTest.hasPrefix("✓") ? Color.green : Color.red)
            }
        } header: {
            Text("Drive folder")
        } footer: {
            Text("The app can only see folders it created itself, so it will create this folder path in your Drive (use / for subfolders). Don't point it at a folder you made by hand; it would create a new one with the same name instead.")
        }
    }

    private func commitFolder() {
        let normalized = AppSettings.normalizedFolderPath(folderText)
        let final = normalized.isEmpty ? AppSettings.defaultFolderPath : normalized
        folderText = final
        if settings.driveFolderPath != final { settings.driveFolderPath = final }
    }

    private func refreshAccount() {
        signedIn = GoogleAuth.shared.isSignedIn
        email = GoogleAuth.shared.email
    }

    private func signIn() async {
        authError = nil
        guard let presenter = Self.topViewController() else {
            authError = "Could not open the sign-in screen."
            return
        }
        do {
            try await GoogleAuth.shared.signIn(presenting: presenter)
            refreshAccount()
            BackgroundTasks.processNow()   // memos waiting for sign-in continue now
        } catch {
            let ns = error as NSError
            // GIDSignInError.canceled (-5): the user closed the sheet; not an error.
            if ns.domain == "com.google.GIDSignIn", ns.code == -5 { return }
            authError = error.localizedDescription
        }
    }

    private func testDrive() async {
        commitFolder()
        driveTesting = true
        driveTest = nil
        defer { driveTesting = false }
        let path = settings.driveFolderPath
        do {
            _ = try await AppServices.drive.ensureFolder(path: path)
            driveTest = "✓ Folder “\(path)” is ready in Drive"
        } catch {
            driveTest = "✗ \(error.localizedDescription)"
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // MARK: - Model

    private var selectedModel: WhisperModel { WhisperModel.find(settings.modelId) ?? .ivritTurbo }

    private var modelSection: some View {
        Section("Model") {
            Picker("Model", selection: $settings.modelId) {
                ForEach(WhisperModel.all) { model in
                    Text("\(model.displayName) · \(DebugTranscriptionView.mb(model.sizeBytes))").tag(model.id)
                }
            }
            .pickerStyle(.menu)
            let model = selectedModel
            if let fraction = models.progress[model.id] {
                ProgressView(value: fraction) {
                    Text("Downloading… \(Int(fraction * 100))% of \(DebugTranscriptionView.mb(model.sizeBytes))")
                }
            } else if models.isDownloaded(model) {
                LabeledContent("Status", value: "Downloaded (\(DebugTranscriptionView.mb(model.sizeBytes)))")
                Button("Delete model", role: .destructive) { models.delete(model) }
            } else {
                Button("Download (\(DebugTranscriptionView.mb(model.sizeBytes)), use Wi-Fi)") {
                    Task { await download(model) }
                }
            }
            if let error = models.errors[model.id] ?? modelError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func download(_ model: WhisperModel) async {
        modelError = nil
        do {
            try await models.download(model)
            BackgroundTasks.processNow()   // memos waiting for the model continue now
        } catch {
            modelError = error.localizedDescription
        }
    }
}
