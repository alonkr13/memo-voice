# Memo

Memo is an iPhone voice-memo app. You tap a widget on the home screen, talk, and tap again. The app transcribes the recording on the phone with Whisper (Hebrew first), then uploads one Markdown file per memo to a folder in your Google Drive. A Claude scheduled task can read that folder later.

You do not need a Mac. The app is built by GitHub Actions and installed from Windows with Sideloadly, using a free Apple ID.

Repo: https://github.com/alonkr13/memo-voice

## What you need

- An iPhone running iOS 26 or newer.
- A Windows PC and a USB cable.
- A free Apple ID.
- A Google account (for Drive).
- A GitHub account that can edit the repo settings.

Setup order: Google sign-in key first (part 2), then download the app (part 1), then install (part 3). The sign-in key is baked into the app when GitHub builds it, so the key has to exist before the build you install.

## 1. Get Memo.ipa from GitHub

1. Open https://github.com/alonkr13/memo-voice and click the **Actions** tab.
2. Click the latest run with a green check mark on the branch you want.
3. Scroll to **Artifacts** at the bottom and download **Memo-ipa**. It is a zip file that contains `Memo.ipa`. Unzip it.

Command-line alternative (PowerShell, after a one-time `gh auth login`):

```powershell
& "C:\Program Files\GitHub CLI\gh.exe" run download --repo alonkr13/memo-voice --name Memo-ipa
```

Google sign-in only works in builds made after the `GOOGLE_CLIENT_ID` secret exists (part 2). An IPA built earlier installs and records, but "Sign in with Google" will not work.

## 2. Google Cloud setup

Memo uploads with the `drive.file` permission: the app can only see files and folders that it created itself, not the rest of your Drive.

1. Go to https://console.cloud.google.com and create a new project (any name, for example "Memo").
2. Open **APIs & Services > Library**, search for **Google Drive API**, and click **Enable**.
3. Open **APIs & Services > OAuth consent screen** (Google may call it "Google Auth Platform").
   - User type: **External**.
   - App name: for example "Memo". Support email and developer contact: your email.
   - Scopes: add `.../auth/drive.file`.
   - Test users: add your own Google account.
4. Click **Publish app** to move it from "Testing" to "In production".
   - This matters. In "Testing" mode, Google signs you out every 7 days.
   - `drive.file` is a non-sensitive scope, so Google does not require a verification review.
   - The first time you sign in, Google may show an "unverified app" screen. Click **Advanced**, then continue to Memo. This is normal for your own app.
5. Open **APIs & Services > Credentials > Create credentials > OAuth client ID**.
   - Application type: **iOS**.
   - Bundle ID: `com.alonk.memo`
   - Create it and copy the **Client ID**. It looks like `1234567890-abc123.apps.googleusercontent.com`.
6. In GitHub, open the repo **Settings > Secrets and variables > Actions > New repository secret**.
   - Name: `GOOGLE_CLIENT_ID`
   - Secret: the Client ID from step 5.
7. Open the **Actions** tab, pick the **build** workflow, click **Run workflow**, and wait for the green check mark. Download the new `Memo-ipa` artifact as in part 1. This new IPA, downloaded after the secret was added, is the one to install.

The workflow reads the secret and writes `Config.xcconfig` (the client ID and its reversed form, used as the sign-in redirect) before building. Without the secret it builds with placeholders that cannot sign in.

## 3. Install on the iPhone with Sideloadly

Free Apple ID limits: a sideloaded app works for 7 days, you can have at most 3 sideloaded apps at once, and an Apple ID can create about 10 app IDs per week. Memo uses two (the app and its widget).

### One-time setup

1. Install iTunes and iCloud for Windows from Apple's website, as Sideloadly's site instructs. Do not use the Microsoft Store versions.
2. Install Sideloadly from https://sideloadly.io.
3. On the iPhone: **Settings > Privacy & Security > Developer Mode**, turn it on, and restart when asked. Confirm after the restart.

### Install

1. Connect the iPhone with USB and tap **Trust** on the phone if asked.
2. Open Sideloadly and drag `Memo.ipa` into it.
3. Enter your Apple ID. Open **Advanced Options** and leave the app-extension and App Group handling **enabled**. Memo's widget is an extension, and the app and widget share data through an App Group, so both must be kept.
4. Click **Start** and enter your Apple ID password in Sideloadly when it asks.
5. On the iPhone: **Settings > General > VPN & Device Management**, tap your Apple ID under "Developer App", and tap **Trust**.
6. Open Memo.

### Every 7 days

The app stops opening after 7 days. Repeat the install steps with the same IPA (or a newer one) while the phone is connected. Installing over the existing app keeps your settings and memos. Do not delete the app first.

## 4. First launch and in-app setup

1. Allow the **microphone** when asked.
2. Allow Live Activities: **Settings > Memo > Live Activities**. Widget recording shows a Live Activity and needs this on.
3. In Memo, open **Settings** and work top to bottom:
   - **Google account:** tap **Sign in with Google** and use the account you added in part 2.
   - **Drive folder:** type a folder path, for example `Memos` or `Notes/Voice` (use `/` for subfolders). The app creates this folder in your Drive. Do not point it at a folder you made by hand: the app cannot see it, so it would create a new folder with the same name.
   - Tap **Test Drive connection**. It should report success.
   - **Model:** choose **ivrit.ai large-v3-turbo (Hebrew, q5_0)** and tap **Download**. It is shown in the app as 547 MB, so use Wi-Fi. The file is verified after download. The alternative, **OpenAI small (multilingual)**, is shown as 465 MB and weaker at Hebrew.
   - **Language:** Hebrew, English, or Auto. Hebrew is the default.
   - **Upload audio** (off by default) also puts the `.m4a` in Drive next to the `.md`. **Keep audio on phone** (off by default) keeps the local recording after upload. Audio is always kept until its transcript has been uploaded.

## 5. Add the widget

1. Long-press an empty spot on the home screen, tap **+**, and search for **Memo**.
2. There are two widgets:
   - **Record:** one tap starts a memo, tap again to stop. Use this one normally.
   - **Record (opens app):** a tap opens Memo and starts recording right away. Use it as a fallback if the first widget does nothing.
3. Add one or both to the home screen.

## 6. What ends up in Google Drive

One file per memo in your chosen folder. The file name is the local time when recording started:

```
2026-10-29 07-42-13.md
```

Content:

```markdown
---
id: 3F2A9C1E-5B7D-4E21-9A80-0C6D4B1E7F22
recorded_at: 2026-10-29T07:42:13+02:00
duration_sec: 94
language: he
model: ivrit-whisper-large-v3-turbo-q5_0
---

<transcript text>
```

Notes for anything that reads these files:

- `id` is a UUID and stays the same on retries, so the same memo is never uploaded twice.
- `language` and `model` are `null` if unknown.
- A memo with no speech still uploads, with the body `(no speech detected)`.
- If "Upload audio" is on, the `.m4a` has the same base name as the `.md`.

### Suggested prompt for a Claude scheduled task

> Read the memo files (`*.md`) in the "Memos" folder of my Google Drive. Handle only memos recorded since your last run, using `recorded_at` from the front matter. Update my to-do list with any action items, and note the `id` of each memo you processed so you skip it next time. Ignore memos whose body is "(no speech detected)".

## Troubleshooting

- **Tapping the widget does nothing.** Use the **Record (opens app)** widget instead. Also check that **Settings > Memo > Live Activities** is on.
- **The "App Group" row in Settings shows "no".** The app and widget are not sharing data, usually because extension or App Group handling was off in Sideloadly. Reinstall with those Advanced options enabled.
- **A memo is stuck.** Open Memo, tap the memo, and tap **Retry**. Check your connection, that you are signed in, and that **Test Drive connection** works.
- **Google sign-in expires about every week.** The consent screen is still in "Testing" mode. Publish it to production (part 2, step 4), then sign in again.
- **Sign-in fails immediately.** The installed build was made before the `GOOGLE_CLIENT_ID` secret existed. Re-run the workflow and reinstall.
- **The app will not open.** If it has been over 7 days, re-sideload (part 3). Otherwise trust the profile under **Settings > General > VPN & Device Management**.
- **Sideloadly reports an app-ID limit.** Free Apple IDs get about 10 new app IDs per week. Wait, or remove an old sideloaded app.

## Developer notes

- No Mac is needed. GitHub Actions (`.github/workflows/build.yml`, macOS runner) generates the Xcode project with XcodeGen from `project.yml`, runs the MemoKit tests, archives without signing, ad-hoc signs with the entitlements, and uploads `Memo.ipa` as the `Memo-ipa` artifact. Sideloadly then re-signs it with your Apple ID.
- The workflow runs on every push, pull request and manual dispatch.
- For a local build on a Mac, create the config before generating the project:

  ```sh
  cp Config.example.xcconfig Config.xcconfig   # then put your real client ID in it
  xcodegen generate
  ```

- Layout: `Memo/` (app), `MemoWidget/` (widget and Live Activity), `MemoKit/` (Swift package), `Shared/`, `docs/superpowers/specs/` (design).
