# NoteIt

An **Anarlog-inspired, privacy-conscious iOS meeting notetaker** built with Flutter, native Swift `AppIntents` (iPhone Action Button), background audio recording, native iOS `URLSession` background uploads, and a Dockerized FastAPI backend for your Oracle Cloud ARM64 instance.

> **Public Repo Safety:** This repository contains **zero secrets, zero API keys, zero signing certificates, and zero personal domains**. Your server URL and personal access token are stored exclusively in the iOS Keychain (entered once in the app's Settings screen) and `.env` on your server.

---

## Features

- **One-press Action Button start/toggle:** Native Swift `AppIntents` (`Start NoteIt Recording` / `Toggle NoteIt Recording`) ready to map in **iOS Settings → Action Button → Shortcut** (plus `noteit://record` URL scheme).
- **Background audio recording:** Continues recording cleanly when you switch apps or lock your iPhone (`UIBackgroundModes: audio`), pausing safely on phone/Siri audio interruptions.
- **Anarlog-style rough notes:** Jot down quick manual thoughts while recording (or edit them later); the AI merges your manual notes as priority anchors with the full transcript.
- **Reliable post-stop uploads:** Uses native iOS `URLSession` (`background_downloader`) from disk so recordings finish uploading even if you lock your phone right after stopping.
- **Free-tier AI pipeline (Groq + Gemini):**
  - `ffmpeg` normalizes audio to 16 kHz mono and splits long meetings into overlapping <20 MB chunks.
  - **Groq Whisper (`whisper-large-v3-turbo`)** transcribes quickly with automatic fallback to **Gemini Flash**.
  - Raw audio files are automatically deleted from both iPhone and server once processed (`DELETE_AUDIO_AFTER_TRANSCRIPTION=true`).
  - **Gemini Flash** produces structured Markdown summaries (`Overview`, `Key Points`, `Decisions`, `Action Items`, `Open Questions`) and powers grounded per-meeting **Ask AI** chat.
- **Markdown export & PWA / Desktop Web UI:** Install NoteIt as a mobile-first iOS PWA (offline read cache, foreground recording with rough notes, audio file upload, Share Sheet `.md` export), pair with **Apple Voice Memos + Action Button Shortcut** for locked-screen recording with zero sideloading, or browse/edit/chat/export from your desktop browser.

---

## 1. Backend Deployment (Oracle Cloud ARM64 + Existing Nginx & Certbot)

### Prerequisites on Your Oracle Cloud VM
- Docker & Docker Compose (`docker compose version`)
- Nginx (`nginx -v`) and Certbot (`certbot --version`)
- API keys from [Groq Console](https://console.groq.com/keys) and [Google AI Studio](https://aistudio.google.com/apikey)

### Steps
1. **Clone the repository and create `.env`:**
   ```bash
   git clone https://github.com/<your-username>/noteit.git
   cd noteit
   cp deploy/.env.example .env
   ```

2. **Generate a strong access token and configure `.env`:**
   ```bash
   openssl rand -hex 32
   ```
   Edit `.env` and fill in:
   - `AUTH_TOKEN=<generated-64-char-hex-token>`
   - `GROQ_API_KEY=...`
   - `GEMINI_API_KEY=...`
   - `VAPID_SUBJECT=mailto:you@example.com` *(optional, for iOS PWA Web Push notifications; VAPID keys are auto-generated in `/data/vapid_private.pem`)*
   - Keep `COOKIE_SECURE=true` once HTTPS is enabled.

3. **Start the Docker container (bound strictly to `127.0.0.1:8080`):**
   ```bash
   docker compose -f backend/docker-compose.yml up -d --build
   curl http://127.0.0.1:8080/health
   # Expected: {"status":"ok"}
   ```

4. **Configure Nginx and Certbot:**
   ```bash
   sudo cp deploy/nginx.noteit.conf.example /etc/nginx/sites-available/noteit
   # Replace `noteit.example.com` with your actual subdomain:
   sudo nano /etc/nginx/sites-available/noteit
   sudo ln -s /etc/nginx/sites-available/noteit /etc/nginx/sites-enabled/noteit
   sudo nginx -t && sudo systemctl reload nginx
   sudo certbot --nginx -d <your-domain>
   ```
   *(If your main `/etc/nginx/nginx.conf` already defines rate-limit zones or complains about `limit_req_zone` placement, ensure the `limit_req_zone` line sits inside `http {}`.)*

5. Open `https://<your-domain>` in your browser and unlock with your `AUTH_TOKEN`.

---

## 2. iOS PWA + Voice Memos Shortcut Setup (Recommended — No Sideloading Required)

Running NoteIt as a Progressive Web App paired with Apple's built-in **Voice Memos** and **Shortcuts** avoids the 7-day free Apple ID sideloading/SideStore refresh cycle while still giving you instant Action Button recording with the screen locked.

### A. Install the NoteIt PWA on iPhone
1. Open `https://<your-domain>` in **Safari** on your iPhone and unlock with your `AUTH_TOKEN`.
2. Tap **Share** (the square-with-arrow icon) → **Add to Home Screen** → **Add**.
3. Open **NoteIt** from your Home Screen:
   - **Enable lock-screen notifications:** Tap **Setup → Push Notifications → Enable Notifications** (only available when launched from the Home Screen icon over HTTPS; use **Send Test** to verify). NoteIt will notify you as soon as transcription and summarization finish or fail.
   - **Live updates & manual refresh:** The meeting list automatically polls while any meeting is `queued`, `transcribing`, or `summarizing`, refreshes automatically when returning from Voice Memos, and includes a manual **Refresh (↻)** button next to search.
   - **Foreground recording + rough notes:** Tap **Record** inside NoteIt whenever you can keep the app open on screen (uses Screen Wake Lock on iOS 18.4+ and stores audio chunks locally in IndexedDB if interrupted or offline).
   - **Upload audio:** Tap **Upload Audio** to send any `.m4a`, `.mp3`, `.wav`, `.webm`, or `.caf` file.
   - **Export:** Tap **Share .md** in any meeting to send Markdown directly to Obsidian, Apple Notes, or Notion.

### B. Locked-Screen Action Button Recording (Voice Memos + "Send to NoteIt" Shortcut)
Use this whenever you want one-press recording with your iPhone screen locked:

1. **Map your Action Button to Voice Memos:**
   - Open iPhone **Settings → Action Button → Shortcut** (or **Voice Memo** / **Controls → Voice Memo**) so a single press starts/stops recording even while locked.
2. **Create the "Send to NoteIt" Share Sheet Shortcut:**
   - Open the Apple **Shortcuts** app and tap **+** to create a new shortcut (name it **Send to NoteIt**).
   - Tap the **(i)** / details icon at the bottom and enable **Show in Share Sheet** (set accepted types to **Audio** and **Files**).
   - Add action **Get Contents of URL**:
     - **URL:** `https://<your-domain>/api/meetings/quick-upload` (also copyable inside NoteIt PWA under **Setup**)
     - **Method:** `POST`
     - **Headers:** `Authorization` = `Bearer <AUTH_TOKEN>`
     - **Request Body:** `Form`
       - Add field `file` (**Type:** `File`) → set value to **Shortcut Input**
       - *(Optional)* Add field `title` (**Type:** `Text`) → e.g. **Ask Each Time** (leave blank to let AI auto-title)
   - *(Optional)* Add a **Show Notification** action (`"Sent to NoteIt for transcription"`) after **Get Contents of URL**.
3. **Workflow:** Press the Action Button to record in **Voice Memos** (screen locked, full background audio), then tap **Share → Send to NoteIt** when finished. Your summary, transcript, and Ask AI chat appear in the NoteIt PWA moments later.

---

## 3. Native iOS App via GitHub Actions & Sideloading (Optional)

1. Push this repository to a **public GitHub repository** (GitHub Actions macOS runners are free for public repos).
2. Open the **Actions** tab → **Build Unsigned iOS IPA** (runs automatically on pushes to `main` touching `app/`, or trigger manually via **Run workflow**).
3. Download the **`NoteIt-unsigned.ipa`** build artifact.
4. Sideload onto your iPhone from Windows using your free Apple ID:
   - **SideStore** *(recommended — refreshes over Wi-Fi without plugging into your PC every 7 days)*
   - **AltStore** (with AltServer running on Windows)
   - **Sideloadly** (USB or Wi-Fi refresh from Windows)

> **Free Apple ID Notes:**
> - Sideloaded apps expire every **7 days** unless refreshed (SideStore/AltStore handle this automatically on Wi-Fi).
> - Free Apple IDs are limited to **3 active sideloaded apps** and do not support Live Activities / App Groups / Remote Push Notifications.

---

## 4. Setting Up the Native iPhone App & Action Button

1. Open **NoteIt** on your iPhone and tap **Settings**:
   - **Server URL:** `https://<your-domain>` (e.g., `https://noteit.example.com`)
   - **Access Token:** paste the same `AUTH_TOKEN` from your server `.env` (stored in iOS Keychain)
   - Tap **Test Connection** to verify authentication.
2. Grant **Microphone** permission by starting & stopping a quick 2-second test recording inside the app.
3. Map your **Action Button** (iPhone 15 Pro / 16 and newer):
   - Open iPhone **Settings → Action Button → Shortcut**
   - Pick **Toggle NoteIt Recording** (starts recording if idle, stops & uploads if currently recording) or **Start NoteIt Recording**.
   - *(Note: On iOS, if your phone is locked when pressing the Action Button, Face ID/passcode unlock is required to bring the app up and start the audio session; once recording starts, you can lock your screen immediately and recording continues in the background.)*

---

## 5. Local Windows Development (Optional)

Once Flutter is installed on your Windows machine:
```powershell
cd app
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

For backend development & tests locally:
```powershell
docker build -t noteit-backend-test ./backend
docker run --rm --user root -v "${PWD}/backend:/src" -w /src noteit-backend-test sh -c "pip install -q -r requirements-dev.txt && ruff check app tests && pytest -v"
```
