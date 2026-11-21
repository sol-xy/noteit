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
- **Markdown export & Desktop Web UI:** Share `.md` files via the iOS Share Sheet (Obsidian, Apple Notes, Notion) or browse/edit/chat/export from your Windows PC via the auth-gated Web UI.

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

## 2. Building the iOS App on GitHub Actions & Sideloading (No Mac Required)

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

## 3. Setting Up the iPhone App & Action Button

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

## 4. Local Windows Development (Optional)

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
