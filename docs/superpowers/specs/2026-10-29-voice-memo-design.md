# Voice Memo → Drive: Design

## Intent

You're out, often walking the dog with your hands half-full, and want to dump thoughts, to-dos and reminders by voice, mostly in Hebrew, sometimes in English. Today that turns into a WhatsApp voice note that never gets used. With this app you tap a home-screen widget, talk, and stop. Later, with no further action, the memo is transcribed on the phone and saved as a text file in a Google Drive folder. A scheduled Claude task reads that folder and updates to-do lists and similar notes.

The main reader of the output is **Claude**, not the user.

## Goals

- One tap on a home-screen widget starts recording right away, without opening the app.
- Recording runs with the screen locked. A Live Activity (lock screen + Dynamic Island) shows that it's recording and has a Stop button.
- On-device Whisper transcription, tuned for Hebrew, with English supported.
- Each memo becomes one Markdown file in a Drive folder the user configures.
- The app itself is mostly settings plus a small list of recent memos and their status.

## Non-goals

- Fast transcription. Minutes later, or the next time the phone is idle or charging, is fine.
- Editing transcripts, tagging, search, or summaries in the app.
- The Claude scheduled task itself. It's out of scope, but the file format is designed for it.
- App Store distribution.

## Anti-goals (failure even if it "works")

- **Losing a recording.** Audio must be saved to disk the moment recording stops and kept until its transcript is uploaded. An interruption such as a phone call or Siri ends the recording but keeps what was captured.
- Starting a recording takes more than one tap, or needs the app opened and navigated.
- Silent failures. Anything stuck shows up in the memo list with a reason and a Retry button.

## Constraints

- **Device:** iPhone 12 (A14, 4 GB RAM) on **iOS 27**. Deployment target: iOS 26, so iOS 26+ APIs are fine.
- **No Mac.** The user has Windows only and a **free Apple ID**.
  - Project defined with **XcodeGen** (`project.yml`). No hand-maintained `.xcodeproj`.
  - Built by **GitHub Actions on a macOS runner**, which produces an unsigned `.ipa` as a build artifact.
  - Installed with **Sideloadly** on Windows, which re-signs with the free Apple ID. The app expires every 7 days and must be re-sideloaded, so all data must survive a re-install over the top.
  - Unit tests run in CI on the iOS simulator.
- Recordings are usually under 2 minutes, sometimes longer, and 10 minutes at most.

## How it works (decided)

### Targets
- **App** (SwiftUI): settings, memo list, the processing pipeline.
- **Widget extension**: an interactive home-screen widget with a big Record/Stop button, plus the Live Activity UI.
- Both share data through an **App Group** container: the memo queue, audio files and settings.

### Recording
- The widget button triggers an App Intent that conforms to **`AudioRecordingIntent`**. This is the iOS 18+ way for a widget to start recording without opening the app, and it requires starting a Live Activity when recording begins.
- `AVAudioRecorder` saves mono 16 kHz AAC (`.m4a`) to the App Group container. The `audio` background mode is enabled.
- Stop is available from the Live Activity, from the widget (which shows that it's recording), and inside the app.
- **Fallback:** if the intent path fails, the widget opens the app through a deep link that starts recording immediately.

### Processing pipeline
Each memo is a record in a persisted queue (JSON in the App Group). States: `recorded → transcribing → transcribed → uploading → done`, plus `failed(reason)`.

1. When recording stops, submit a **`BGContinuedProcessingTask`** (iOS 26+) to transcribe and upload right away in the background, with system progress UI.
2. If that doesn't run or is cut short, a `BGProcessingTask` (prefers power and network) picks up the queue later.
3. Opening the app always resumes the queue.

The pipeline must be safe to resume: any memo can be interrupted mid-step and retried.

### Transcription
- **whisper.cpp**, integrated through its prebuilt XCFramework or Swift package, with Metal enabled.
- **Default model:** ivrit.ai Hebrew-tuned `whisper-large-v3-turbo` in ggml format, quantized (~0.5–0.8 GB).
- **Alternative:** OpenAI multilingual `small`, which is faster and worse at Hebrew.
- Models are **downloaded in the app** from Hugging Face on first run, not bundled, so the `.ipa` stays small. Downloads happen on Wi-Fi with progress shown, and the model is stored in the App Group.
- **Language setting:** Hebrew (default) / English / Auto-detect.
- Audio is decoded from m4a to 16 kHz float PCM for whisper.

### Google Drive
- **GoogleSignIn-iOS** with scope **`drive.file`**: the app can only see files it created, and this scope needs no Google verification.
- The user creates an iOS OAuth client in Google Cloud Console and sets the OAuth consent screen to "In production". In "Testing" mode, sign-ins expire every 7 days. A setup guide in the README walks through this.
- **Folder:** the user types a path such as `Memos/Inbox`. The app creates any missing folders and caches the folder ID. If the folder is deleted, the app recreates it on the next upload.
- Uploads use Drive v3 multipart upload. Failed uploads retry with backoff, and when the network returns.

### Output format
Filename: `2026-10-29 07-42-13.md`, the local time when recording started.

```markdown
---
id: 3F2A…              # UUID, stable across retries
recorded_at: 2026-10-29T07:42:13+02:00
duration_sec: 94
language: he
model: ivrit-whisper-large-v3-turbo-q5
---

<transcript text>
```

To avoid duplicates on retry, the app checks whether a file with the same `id` (stored in the Drive file's `appProperties`) already exists before uploading.

### Audio retention
- **Upload audio too:** off by default. When on, the `.m4a` goes next to the `.md` with the same base name.
- Local audio is deleted once the memo is `done`. A **"Keep audio on phone"** toggle can turn that off.

### App screens
- **Memos:** recent memos with date, duration, status and the first line of text. Tap one to see the full text, retry it, or share it. A Record button is here too.
- **Settings:** Google account (sign in/out), Drive folder path, model picker with download status, language, upload audio, keep audio, and a "Test Drive connection" button.

## Risks to check first (spike before the full build)

1. **Sideloading with extensions and App Groups.** Sideloadly re-signs with a free Apple ID, which may rename bundle and App Group IDs. Confirm that the widget installs and that the app and widget share the container. If App Groups break, fall back to an intent that runs in the app process and keeps all data in the app's own container.
2. **`AudioRecordingIntent` from a widget** actually recording while the phone is locked on iOS 27.
3. **The turbo model's memory and speed on an iPhone 12.** Target: a 2-minute memo transcribed in under about 2 minutes, with no memory kill. If it fails, default to a smaller quantization or to `small`.

## Left to the builder

Code structure, UI styling, retry and backoff numbers, exact quantization choice, the widget's visual design, and how to wire whisper.cpp into XcodeGen.

## Calls made by Claude (not discussed with the user)

- Hebrew as the default language, with Auto as an option.
- Audio upload off and local audio deleted after upload, both by default.
- The `drive.file` scope plus a typed folder path, instead of picking an existing Drive folder. Picking would need broader permissions.
- The Markdown + front-matter format and the filename scheme.
- Models downloaded in the app rather than bundled.
- `BGContinuedProcessingTask` for prompt background processing.
