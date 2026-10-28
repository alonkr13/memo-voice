# Voice Memo → Drive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iOS app + home-screen widget ("Memo") that records a voice memo with one tap, transcribes it on-device with Whisper (Hebrew-first), and uploads a Markdown file per memo to a configured Google Drive folder.

**Architecture:** XcodeGen project with three targets: `Memo` (SwiftUI app), `MemoWidget` (widget + Live Activity), and `MemoTests`. A local Swift package `MemoKit` holds all logic (store, recorder, decoding, transcription, Drive, pipeline) so it is testable; app and widget are thin shells. Built and tested on GitHub Actions macOS runners, then sideloaded from Windows with Sideloadly.

**Tech Stack:** Swift 6, SwiftUI, WidgetKit, ActivityKit, AppIntents (`AudioRecordingIntent`), AVFoundation, BackgroundTasks (`BGContinuedProcessingTask`, `BGProcessingTask`), whisper.cpp XCFramework, GoogleSignIn-iOS (SPM), XcodeGen, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-29-voice-memo-design.md`

## Global Constraints

- Deployment target iOS 26.0. Device: iPhone 12 (4 GB RAM), iOS 27.
- No Mac available: every build/test runs in `.github/workflows/build.yml` on `macos-latest`; there is no local Xcode. The `.xcodeproj` is generated, never committed.
- The IPA is unsigned (`CODE_SIGNING_ALLOWED=NO`); Sideloadly re-signs with a free Apple ID.
- Bundle IDs: `com.alonk.memo`, `com.alonk.memo.widget`. App Group: `group.com.alonk.memo`.
- Audio: mono, 16 kHz, AAC `.m4a`. Recordings up to ~10 min.
- Default model: ivrit.ai `whisper-large-v3-turbo` ggml (quantized). Alternative: OpenAI multilingual `small` ggml. Downloaded in-app, never bundled.
- Language setting: `he` (default) / `en` / `auto`.
- Drive scope: `https://www.googleapis.com/auth/drive.file` only.
- Output filename `yyyy-MM-dd HH-mm-ss.md` (local start time); front matter keys exactly `id, recorded_at, duration_sec, language, model`.
- Defaults: upload audio = off, keep audio on phone = off.
- Never delete a memo's audio before its state is `done`.

## Review Focus

1. **App killed mid-step** (memory kill while transcribing, crash while uploading): on next launch, memos stuck in `transcribing`/`uploading` must go back to the previous retryable state, not stay stuck. → test in Task 2.
2. **Recording interrupted** (phone call, Siri, another app grabbing audio): recording ends, captured audio is kept and queued. → test in Task 3.
3. **Offline / Drive errors**: upload fails → memo stays `transcribed` with a visible reason and retries later; a retry never creates a duplicate file. → tests in Task 6.
4. **Model not downloaded yet / Google not signed in** when a memo is recorded: memo waits in the queue with a clear reason; it doesn't count as a failure. → test in Task 7.
5. **Silent or very short recording** (accidental tap): the transcript is empty → still upload, with body `(no speech detected)`, so nothing is silently dropped. → test in Task 5.

---

### Task 1: Project skeleton, CI build, sideload spike (Risk 1)

**Files:**
- Create: `project.yml`, `Memo/MemoApp.swift`, `Memo/Info.plist`, `Memo/Memo.entitlements`, `MemoWidget/MemoWidgetBundle.swift`, `MemoWidget/Info.plist`, `MemoWidget/MemoWidget.entitlements`, `MemoKit/Package.swift`, `MemoKit/Sources/MemoKit/AppPaths.swift`, `MemoKit/Tests/MemoKitTests/AppPathsTests.swift`, `.github/workflows/build.yml`, `.gitignore`

**Interfaces:**
- Produces: `AppPaths.container: URL` (App Group container, or the app's Application Support directory if the group is unavailable), `AppPaths.audioDir`, `AppPaths.modelsDir`, `AppPaths.queueFile`, `AppPaths.usingAppGroup: Bool`.

- [ ] **Step 1:** `git init`, `.gitignore` (`*.xcodeproj`, `build/`, `DerivedData/`, `.build/`).
- [ ] **Step 2:** Write `AppPathsTests.testFallsBackWhenGroupMissing`: with group ID `"group.invalid"`, `container` is under Application Support and `usingAppGroup == false`; `audioDir`/`modelsDir` exist after access.
- [ ] **Step 3:** Implement `AppPaths` (`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`, fall back if nil).
- [ ] **Step 4:** `project.yml`: app + widget extension (embedded) + MemoKit local package; Info.plist keys `NSMicrophoneUsageDescription`, `UIBackgroundModes: [audio, processing]`, `BGTaskSchedulerPermittedIdentifiers: [com.alonk.memo.process, com.alonk.memo.continued]`, `NSSupportsLiveActivities: YES`; App Group entitlement on both targets. Placeholder widget showing "Memo" and whether `AppPaths.usingAppGroup` is true.
- [ ] **Step 5:** `build.yml`: on push → `brew install xcodegen` → `xcodegen` → `xcodebuild test` of the `MemoKit` package on an iOS simulator (it uses iOS-only APIs such as `AVAudioSession`, so plain `swift test` on macOS won't work) → `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO` for `generic/platform=iOS` → zip `Payload/Memo.app` into `Memo.ipa` → upload artifact.
- [ ] **Step 6:** Create the GitHub repo (user: `gh auth login` if needed), push, confirm CI is green and the `Memo.ipa` artifact exists.
- [ ] **Step 7 (USER CHECKPOINT):** User sideloads with Sideloadly, adds the widget, and reports whether it installs and whether the widget shows "App Group: yes". If "no", keep the fallback (`AppPaths` is already written to work with it) and route widget actions through app-process intents only.
- [ ] **Step 8:** Commit.

### Task 2: Memo model and persistent queue

**Files:**
- Create: `MemoKit/Sources/MemoKit/Memo.swift`, `MemoKit/Sources/MemoKit/MemoStore.swift`, `MemoKit/Sources/MemoKit/Settings.swift`
- Test: `MemoKit/Tests/MemoKitTests/MemoStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct Memo: Codable, Identifiable { id: UUID; recordedAt: Date; durationSec: Double; audioFile: String; state: MemoState; transcript: String?; language: String?; model: String?; driveFileId: String?; lastError: String?; waitingReason: String? }`
  - `enum MemoState: String, Codable { recording, recorded, transcribing, transcribed, uploading, done, failed }`
  - `actor MemoStore { init(file: URL); func all() -> [Memo]; func add(_:); func update(_ id: UUID, _ change: (inout Memo) -> Void); func recoverInterrupted() }`
  - `struct AppSettings: Codable { driveFolderPath = "Memos"; modelId = "ivrit-turbo"; language = "he"; uploadAudio = false; keepAudio = false }` with `static func load()/save()` in the shared container.

- [ ] **Step 1:** Tests: `testPersistsAcrossInstances` (add → new store on same file → same memo); `testRecoverInterrupted` (`transcribing`→`recorded`, `uploading`→`transcribed`, `recording` with an audio file on disk →`recorded`, `recording` without one → `failed` with `lastError` set). Run → FAIL.
- [ ] **Step 2:** Implement with atomic JSON writes (`.atomic`). Run → PASS. Commit.

### Task 3: Recording, widget intent, Live Activity (Risk 2)

**Files:**
- Create: `MemoKit/Sources/MemoKit/Recorder.swift`, `MemoKit/Sources/MemoKit/RecordingActivity.swift` (ActivityAttributes), `Memo/Intents/ToggleRecordingIntent.swift`, `MemoWidget/RecordWidget.swift`, `MemoWidget/RecordingLiveActivity.swift`
- Test: `MemoKit/Tests/MemoKitTests/RecorderTests.swift`

**Interfaces:**
- Consumes: `MemoStore`, `AppPaths.audioDir`.
- Produces: `@MainActor final class Recorder { static let shared; var isRecording: Bool; func start() async throws -> UUID; func stop() async -> Memo? }`; `struct ToggleRecordingIntent: AudioRecordingIntent` (start if idle, else stop); posts `Notification.Name.memoRecorded` with the memo ID after stopping.

- [ ] **Step 1:** Tests (simulator, `AVAudioRecorder` may record silence): `testStartStopCreatesRecordedMemo` (state `recorded`, file exists, duration > 0); `testInterruptionKeepsAudio` (post `AVAudioSession.interruptionNotification` with `.began` → memo `recorded`, file kept). Run → FAIL.
- [ ] **Step 2:** Implement `Recorder`: session `.record` category; settings `kAudioFormatMPEG4AAC`, 16000 Hz, 1 channel; add a `recording` memo to the store at start; handle interruption by stopping and finalizing. Run → PASS.
- [ ] **Step 3:** `ToggleRecordingIntent.perform()`: on start, request a `RecordingActivity` Live Activity (required by `AudioRecordingIntent`) and start the recorder; on stop, end the activity and submit processing (hook added in Task 7). Widget: `Button(intent: ToggleRecordingIntent())`, red when recording (`isRecording` stored in shared `UserDefaults(suiteName:)`). Live Activity: elapsed timer (`Text(timerInterval:)`) + Stop button with the same intent.
- [ ] **Step 4:** Fallback deep link `memo://record` → app starts recording on open.
- [ ] **Step 5:** CI green, commit. **USER CHECKPOINT:** sideload; tap the widget with the phone unlocked, lock the phone, talk for 30 s, stop from the lock screen; in the app, check the memo shows ~30 s. If widget recording fails, use the deep-link fallback as the widget action.

### Task 4: Audio decoding to 16 kHz PCM

**Files:**
- Create: `MemoKit/Sources/MemoKit/AudioDecoder.swift`
- Test: `MemoKit/Tests/MemoKitTests/AudioDecoderTests.swift` (+ fixture `Fixtures/tone-2s-44k-stereo.m4a`, generated in test setup with `AVAudioFile` if a binary fixture isn't wanted)

**Interfaces:**
- Produces: `enum AudioDecoder { static func pcm16kMono(from url: URL) throws -> [Float] }`

- [ ] **Step 1:** Test `testResamplesToMono16k`: a 2 s 44.1 kHz stereo file → count within 32000 ± 160, values within [-1, 1]. Run → FAIL.
- [ ] **Step 2:** Implement with `AVAudioFile` + `AVAudioConverter`. Run → PASS. Commit.

### Task 5: Whisper transcription and model management (Risk 3)

**Files:**
- Create: `MemoKit/Sources/MemoKit/WhisperModel.swift`, `MemoKit/Sources/MemoKit/ModelManager.swift`, `MemoKit/Sources/MemoKit/Transcriber.swift`, `MemoKit/Sources/MemoKit/MemoFile.swift`; modify `MemoKit/Package.swift` (binary target for whisper.cpp XCFramework from its GitHub release, pinned version + checksum)
- Test: `MemoKit/Tests/MemoKitTests/MemoFileTests.swift`, `MemoKit/Tests/MemoKitTests/ModelManagerTests.swift`

**Interfaces:**
- Produces:
  - `struct WhisperModel { id; displayName; url: URL; sizeBytes; static let all: [WhisperModel] }`: `ivrit-turbo` (ivrit-ai `whisper-large-v3-turbo` ggml quantized file on Hugging Face; the implementer picks the exact file, ideally q5/q8, and records the URL) and `small` (`ggml-small.bin` from `ggerganov/whisper.cpp`).
  - `@MainActor final class ModelManager: ObservableObject { func isDownloaded(_:) -> Bool; func download(_:) async throws; @Published progress: [String: Double]; func localURL(_:) -> URL }`: a background `URLSession` download, stored as `.part` until finished and then moved.
  - `protocol Transcribing { func transcribe(samples: [Float], language: String) async throws -> (text: String, detectedLanguage: String) }`; `final class WhisperTranscriber: Transcribing` (whisper.cpp, Metal on, `n_threads = 4`, `language = "auto"` when the setting is auto; split the text by segments and join).
  - `enum MemoFile { static func filename(for: Memo, timeZone: TimeZone) -> String; static func markdown(for: Memo) -> String }`

- [ ] **Step 1:** `MemoFileTests`: `testFilename` (2026-10-29 07:42:13 Asia/Jerusalem → `"2026-10-29 07-42-13.md"`); `testMarkdown` (front matter keys exactly as in the spec, `recorded_at` ISO-8601 with offset `+02:00`, `duration_sec` as an integer); `testEmptyTranscript` (empty or whitespace-only → body `(no speech detected)`). `ModelManagerTests.testPartialFileNotDownloaded`. Run → FAIL.
- [ ] **Step 2:** Implement. Run → PASS.
- [ ] **Step 3:** Debug screen in the app: "Transcribe last memo" showing elapsed time and peak memory (`os_proc_available_memory`).
- [ ] **Step 4:** CI green, commit. **USER CHECKPOINT:** download the turbo model and transcribe a ~2 min Hebrew memo; report time, memory and quality. If it's too slow or crashes, switch the default to a smaller quantization or `small`.

### Task 6: Google Drive client

**Files:**
- Create: `MemoKit/Sources/MemoKit/DriveClient.swift`, `MemoKit/Sources/MemoKit/GoogleAuth.swift`; add the GoogleSignIn-iOS package in `project.yml`; `Memo/Info.plist` gets `GIDClientID` and the reversed-client-ID URL scheme from `Config.xcconfig` (gitignored, with a committed `Config.example.xcconfig`)
- Test: `MemoKit/Tests/MemoKitTests/DriveClientTests.swift` (stub `URLProtocol`)

**Interfaces:**
- Produces:
  - `protocol TokenProvider { func accessToken() async throws -> String }`; `GoogleAuth: TokenProvider` (restores the previous sign-in; `signIn(presenting:)` with the `drive.file` scope; `isSignedIn`).
  - `final class DriveClient { init(tokens: TokenProvider, session: URLSession); func ensureFolder(path: String) async throws -> String /* folder id */; func upload(name: String, data: Data, mimeType: String, parent: String, memoId: UUID) async throws -> String /* file id */; func findFile(memoId: UUID, parent: String) async throws -> String? }`
  - `enum DriveError: Error { notSignedIn, http(Int, String), network(Error) }`

- [ ] **Step 1:** Tests: `testEnsureFolderCreatesMissingSegments` (`"Memos/Inbox"`, `Memos` exists → one create call for `Inbox` with parent = `Memos`'s ID); `testEnsureFolderEscapesQuotes` (a name with `'` is escaped in the `q=`); `testUploadSetsAppProperties` (multipart body contains `"appProperties":{"memoId":"<uuid>"}`); `testFindFileByMemoId` (query `appProperties has { key='memoId' and value='<uuid>' }`); `testHttpErrorSurfaced` (403 → `DriveError.http(403, …)`). Run → FAIL.
- [ ] **Step 2:** Implement Drive v3 REST (`files.list`, `files.create` with `uploadType=multipart`) with `URLSession`. Cache folder IDs per path in `UserDefaults`; if an upload gets a 404 on the parent, drop the cache, call `ensureFolder` again, and retry once. Run → PASS.
- [ ] **Step 3:** In `build.yml`, write `Config.xcconfig` from the `GOOGLE_CLIENT_ID` repository secret before running `xcodegen`. If the secret is missing, write the placeholder from `Config.example.xcconfig` so the build still passes. Commit.

### Task 7: Processing pipeline and background tasks

**Files:**
- Create: `MemoKit/Sources/MemoKit/Pipeline.swift`, `Memo/BackgroundTasks.swift`
- Test: `MemoKit/Tests/MemoKitTests/PipelineTests.swift`

**Interfaces:**
- Consumes: `MemoStore`, `AudioDecoder`, `Transcribing`, `ModelManager.isDownloaded`, `DriveClient`, `MemoFile`, `AppSettings`.
- Produces: `actor Pipeline { init(store:, transcriber:, drive:, modelReady: () -> Bool, settings: () -> AppSettings); func processAll() async; func retry(_ id: UUID) async }`; `BackgroundTasks.register()` (in `MemoApp.init`) and `BackgroundTasks.submitContinued()` (called from the stop path in `ToggleRecordingIntent` and from the in-app stop), with `BGProcessingTaskRequest` (`requiresNetworkConnectivity = true`) scheduled as a fallback.

- [ ] **Step 1:** Tests with fakes: `testHappyPath` (`recorded`→`done`; transcript stored; audio deleted when `keepAudio == false`); `testKeepsAudioWhenSettingOn`; `testUploadsAudioWhenSettingOn` (two uploads: `.md` and `.m4a`, same base name); `testUploadFailureKeepsTranscribed` (Drive throws → state `transcribed`, `lastError` set, audio still on disk); `testNoDuplicateOnRetry` (`findFile` returns an ID → no upload, state `done`); `testWaitsForModel` (`modelReady == false` → stays `recorded`, `waitingReason == "Model not downloaded"`, `lastError == nil`); `testWaitsForSignIn` (`DriveError.notSignedIn` → `waitingReason == "Not signed in to Google"`); `testTranscriptionFailure` (transcriber throws → `failed`, audio kept). Run → FAIL.
- [ ] **Step 2:** Implement: process memos one at a time, oldest first; call `store.recoverInterrupted()` first; save the state before and after each step. Run → PASS.
- [ ] **Step 3:** Wire the BG tasks. `BGContinuedProcessingTask` reports progress per memo and finishes when the queue is empty or the task expires (on expiry, cancel and let `recoverInterrupted` handle it). Also call `processAll()` on `scenePhase == .active`, and run it when connectivity returns (`NWPathMonitor`) while the app is active.
- [ ] **Step 4:** CI green, commit.

### Task 8: App UI

**Files:**
- Create: `Memo/Views/MemoListView.swift`, `Memo/Views/MemoDetailView.swift`, `Memo/Views/SettingsView.swift`; modify `Memo/MemoApp.swift`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1:** `MemoListView`: a row per memo showing date, duration, a state badge, `waitingReason` or `lastError` in secondary text, and the first line of the transcript; pull-to-refresh runs `processAll()`; a large Record/Stop button; a toolbar link to Settings. Detail: full text, Copy/Share, Retry (when `failed` or `transcribed`), Delete (after a confirmation alert).
- [ ] **Step 2:** `SettingsView`: Google sign in/out with the account email; folder path text field (trimmed; no leading or trailing `/`); "Test Drive connection" (`ensureFolder` → show ✓ or the error); model picker with size, download button and progress, and a delete-model button; a language segmented control (Hebrew / English / Auto); toggles for Upload audio and Keep audio on phone. Debug section (from Task 5) collapsed at the bottom.
- [ ] **Step 3:** CI green, commit. **USER CHECKPOINT:** full end-to-end on the phone. Record from the widget while walking, lock the phone, stop, then confirm the `.md` appears in Drive with no further action.

### Task 9: README setup guide

**Files:**
- Create: `README.md`

- [ ] **Step 1:** Sections: (1) getting `Memo.ipa` from the GitHub Actions artifacts; (2) Sideloadly install with a free Apple ID, enabling Developer Mode on the iPhone, trusting the profile, and re-sideloading every 7 days (data is kept when installing over the top); (3) Google Cloud: create a project → enable the Drive API → OAuth consent screen (External, add the `drive.file` scope, **Publish to production**) → create an iOS OAuth client with bundle ID `com.alonk.memo` → copy the client ID into the `GOOGLE_CLIENT_ID` GitHub secret (CI writes `Config.xcconfig` from it); (4) adding the widget; (5) how the Drive output looks, so a Claude scheduled task can rely on the format.
- [ ] **Step 2:** Commit, push.
