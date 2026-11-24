"use strict";

const DEFAULT_STT_KEY = "noteit_stt_provider";
const THEME_STORAGE_KEY = "noteit_theme";
const LOGGED_IN_HINT_KEY = "noteit_logged_in";

const state = {
  authenticated: false,
  offline: typeof navigator !== "undefined" ? !navigator.onLine : false,
  meetings: [],
  pendingUploads: [],
  selectedId: null,
  selectedMeeting: null,
  activeTab: "summary",
  transcriptFilter: "",
  pollTimer: null,
  activeRecording: null, // { id, mimeType, extension, filename, durationSeconds, autosaveTimer, interrupted }
  uploadingPendingIds: new Set(),
};

const els = {
  loginView: document.getElementById("login-view"),
  appView: document.getElementById("app-view"),
  loginForm: document.getElementById("login-form"),
  tokenInput: document.getElementById("token-input"),
  loginError: document.getElementById("login-error"),
  settingsBtn: document.getElementById("settings-btn"),
  logoutBtn: document.getElementById("logout-btn"),
  themeToggleBtn: document.getElementById("theme-toggle-btn"),
  themeColorMeta: document.getElementById("theme-color-meta"),
  recordBtn: document.getElementById("record-btn"),
  openUploadBtn: document.getElementById("open-upload-btn"),
  offlineBanner: document.getElementById("offline-banner"),
  searchInput: document.getElementById("search-input"),
  pendingUploadsSection: document.getElementById("pending-uploads-section"),
  pendingUploadsList: document.getElementById("pending-uploads-list"),
  meetingList: document.getElementById("meeting-list"),
  emptyState: document.getElementById("empty-state"),
  detailView: document.getElementById("detail-view"),
  backBtn: document.getElementById("back-btn"),
  titleInput: document.getElementById("meeting-title-input"),
  statusBadge: document.getElementById("status-badge"),
  metaInfo: document.getElementById("meta-info"),
  errorBanner: document.getElementById("error-banner"),
  retryBtn: document.getElementById("retry-btn"),
  shareMdBtn: document.getElementById("share-md-btn"),
  copyMdBtn: document.getElementById("copy-md-btn"),
  downloadMdBtn: document.getElementById("download-md-btn"),
  deleteBtn: document.getElementById("delete-btn"),
  customInstructionsInput: document.getElementById("custom-instructions-input"),
  resummarizeBtn: document.getElementById("resummarize-btn"),
  summaryContent: document.getElementById("summary-content"),
  manualNotesInput: document.getElementById("manual-notes-input"),
  saveNotesBtn: document.getElementById("save-notes-btn"),
  saveResummarizeBtn: document.getElementById("save-resummarize-btn"),
  transcriptFilterInput: document.getElementById("transcript-filter-input"),
  transcriptContent: document.getElementById("transcript-content"),
  chatMessages: document.getElementById("chat-messages"),
  chatForm: document.getElementById("chat-form"),
  chatInput: document.getElementById("chat-input"),
  clearChatBtn: document.getElementById("clear-chat-btn"),

  // Recorder overlay
  recorderView: document.getElementById("recorder-view"),
  recDiscardBtn: document.getElementById("rec-discard-btn"),
  recDoneBtn: document.getElementById("rec-done-btn"),
  recDot: document.getElementById("rec-dot"),
  recTimer: document.getElementById("rec-timer"),
  recAmpMeter: document.getElementById("rec-amp-meter"),
  recWakeHint: document.getElementById("rec-wake-hint"),
  recWakelockBadge: document.getElementById("rec-wakelock-badge"),
  recInterruptedBanner: document.getElementById("rec-interrupted-banner"),
  recUploadSavedBtn: document.getElementById("rec-upload-saved-btn"),
  recDiscardSavedBtn: document.getElementById("rec-discard-saved-btn"),
  recErrorBanner: document.getElementById("rec-error-banner"),
  recTitleInput: document.getElementById("rec-title-input"),
  recNotesInput: document.getElementById("rec-notes-input"),
  recUploadProgressWrap: document.getElementById("rec-upload-progress-wrap"),
  recUploadProgress: document.getElementById("rec-upload-progress"),
  recUploadProgressText: document.getElementById("rec-upload-progress-text"),
  recPauseBtn: document.getElementById("rec-pause-btn"),
  recStopBtn: document.getElementById("rec-stop-btn"),

  // Upload modal
  uploadModal: document.getElementById("upload-modal"),
  uploadCloseBtn: document.getElementById("upload-close-btn"),
  uploadCancelBtn: document.getElementById("upload-cancel-btn"),
  uploadForm: document.getElementById("upload-form"),
  uploadDropzone: document.getElementById("upload-dropzone"),
  uploadFileInput: document.getElementById("upload-file-input"),
  uploadFileLabel: document.getElementById("upload-file-label"),
  uploadTitleInput: document.getElementById("upload-title-input"),
  uploadNotesInput: document.getElementById("upload-notes-input"),
  uploadSttSelect: document.getElementById("upload-stt-select"),
  uploadError: document.getElementById("upload-error"),
  uploadProgressWrap: document.getElementById("upload-progress-wrap"),
  uploadProgress: document.getElementById("upload-progress"),
  uploadProgressText: document.getElementById("upload-progress-text"),
  uploadSubmitBtn: document.getElementById("upload-submit-btn"),

  // Settings modal
  settingsModal: document.getElementById("settings-modal"),
  settingsCloseBtn: document.getElementById("settings-close-btn"),
  settingsSttSelect: document.getElementById("settings-stt-select"),
  shortcutEndpointInput: document.getElementById("shortcut-endpoint-input"),
  copyEndpointBtn: document.getElementById("copy-endpoint-btn"),
  clearCacheBtn: document.getElementById("clear-cache-btn"),

  toast: document.getElementById("toast"),
};

let toastTimer = null;

function showToast(msg) {
  els.toast.textContent = msg;
  els.toast.classList.remove("hidden");
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => els.toast.classList.add("hidden"), 2800);
}

function generateUuid() {
  if (window.crypto && typeof window.crypto.randomUUID === "function") {
    return window.crypto.randomUUID();
  }
  const bytes = new Uint8Array(16);
  if (window.crypto && typeof window.crypto.getRandomValues === "function") {
    window.crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0"));
  return `${hex.slice(0, 4).join("")}-${hex.slice(4, 6).join("")}-${hex.slice(6, 8).join("")}-${hex.slice(8, 10).join("")}-${hex.slice(10, 16).join("")}`;
}

function getDefaultSttProvider() {
  const saved = localStorage.getItem(DEFAULT_STT_KEY) || "auto";
  return ["auto", "groq", "gemini"].includes(saved) ? saved : "auto";
}

function setOffline(isOffline) {
  state.offline = Boolean(isOffline);
  els.offlineBanner.classList.toggle("hidden", !state.offline);
}

function escapeHtml(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function renderInlineMarkdown(escaped) {
  let out = escaped.replace(/`([^`]+)`/g, "<code>$1</code>");
  out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  out = out.replace(/\*([^*]+)\*/g, "<em>$1</em>");
  out = out.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, (_m, label, url) => {
    return `<a href="${url}" target="_blank" rel="noopener noreferrer">${label}</a>`;
  });
  return out;
}

function renderSafeMarkdown(rawText) {
  if (!rawText || !rawText.trim()) {
    return '<p class="muted">No summary generated yet.</p>';
  }
  const lines = escapeHtml(rawText).split(/\r?\n/);
  const html = [];
  let inList = false;

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) {
      if (inList) {
        html.push("</ul>");
        inList = false;
      }
      continue;
    }
    if (trimmed.startsWith("### ")) {
      if (inList) { html.push("</ul>"); inList = false; }
      html.push(`<h3>${renderInlineMarkdown(trimmed.slice(4))}</h3>`);
    } else if (trimmed.startsWith("## ")) {
      if (inList) { html.push("</ul>"); inList = false; }
      html.push(`<h2>${renderInlineMarkdown(trimmed.slice(3))}</h2>`);
    } else if (trimmed.startsWith("# ")) {
      if (inList) { html.push("</ul>"); inList = false; }
      html.push(`<h1>${renderInlineMarkdown(trimmed.slice(2))}</h1>`);
    } else if (trimmed.startsWith("- [ ] ")) {
      if (!inList) { html.push("<ul>"); inList = true; }
      html.push(`<li>&#9744; ${renderInlineMarkdown(trimmed.slice(6))}</li>`);
    } else if (trimmed.startsWith("- [x] ") || trimmed.startsWith("- [X] ")) {
      if (!inList) { html.push("<ul>"); inList = true; }
      html.push(`<li>&#9745; ${renderInlineMarkdown(trimmed.slice(6))}</li>`);
    } else if (trimmed.startsWith("- ") || trimmed.startsWith("* ")) {
      if (!inList) { html.push("<ul>"); inList = true; }
      html.push(`<li>${renderInlineMarkdown(trimmed.slice(2))}</li>`);
    } else {
      if (inList) { html.push("</ul>"); inList = false; }
      html.push(`<p>${renderInlineMarkdown(trimmed)}</p>`);
    }
  }
  if (inList) {
    html.push("</ul>");
  }
  return html.join("\n");
}

function formatDuration(sec) {
  if (sec === null || sec === undefined) return "";
  const total = Math.max(0, Math.floor(sec));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

function formatDate(iso) {
  if (!iso) return "";
  try {
    return new Date(iso).toLocaleString();
  } catch {
    return iso;
  }
}

function safeMarkdownFilename(title, id) {
  const slug = String(title || "")
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  const base = slug || `meeting-${String(id || "note").slice(0, 8)}`;
  return `${base.slice(0, 80)}.md`;
}

function escapeYamlStr(value) {
  const escaped = String(value || "")
    .replaceAll("\\", "\\\\")
    .replaceAll('"', '\\"')
    .replaceAll("\n", " ");
  return `"${escaped}"`;
}

function renderLocalMarkdown(meeting) {
  const durationStr =
    meeting.duration_seconds !== null && meeting.duration_seconds !== undefined
      ? formatDuration(meeting.duration_seconds)
      : "unknown";
  const provider = meeting.stt_used || meeting.stt_provider || "";
  const lines = [
    "---",
    `title: ${escapeYamlStr(meeting.title || "Untitled Meeting")}`,
    `date: ${escapeYamlStr(meeting.created_at || "")}`,
    `duration: ${escapeYamlStr(durationStr)}`,
    `stt_provider: ${escapeYamlStr(provider)}`,
    "---",
    "",
    `# ${meeting.title || "Untitled Meeting"}`,
    "",
  ];
  if (meeting.summary && meeting.summary.trim()) {
    lines.push("## Enhanced Summary", "", meeting.summary.trim(), "");
  }
  if (meeting.manual_notes && meeting.manual_notes.trim()) {
    lines.push("## My Notes", "", meeting.manual_notes.trim(), "");
  }
  lines.push("## Transcript", "");
  if (Array.isArray(meeting.segments) && meeting.segments.length > 0) {
    for (const seg of meeting.segments) {
      const ts = formatDuration(seg.start_sec);
      const text = String(seg.text || "").trim();
      if (text) lines.push(`- **[${ts}]** ${text}`);
    }
  } else if (meeting.transcript && meeting.transcript.trim()) {
    lines.push(meeting.transcript.trim());
  } else {
    lines.push("_No transcript available._");
  }
  lines.push("");
  return lines.join("\n");
}

function getMeetingIdFromUrl() {
  try {
    return new URLSearchParams(window.location.search).get("meeting");
  } catch {
    return null;
  }
}

function pushMeetingUrl(meetingId) {
  if (!window.history || typeof window.history.pushState !== "function") return;
  const target = meetingId ? `/?meeting=${encodeURIComponent(meetingId)}` : "/";
  const current = window.location.pathname + window.location.search;
  if (current !== target) {
    window.history.pushState({ meetingId: meetingId || null }, "", target);
  }
}

async function apiFetch(path, options = {}) {
  let resp;
  try {
    resp = await fetch(path, {
      credentials: "same-origin",
      headers: {
        ...(options.body instanceof FormData ? {} : { "Content-Type": "application/json" }),
        ...(options.headers || {}),
      },
      ...options,
    });
  } catch (networkErr) {
    setOffline(true);
    const err = new Error("Offline or server unreachable");
    err.isNetworkError = true;
    err.cause = networkErr;
    throw err;
  }

  setOffline(false);
  if (resp.status === 401) {
    localStorage.removeItem(LOGGED_IN_HINT_KEY);
    state.authenticated = false;
    showLogin();
    const err = new Error("Authentication required");
    err.status = 401;
    throw err;
  }
  if (!resp.ok) {
    let detail = `Request failed (${resp.status})`;
    try {
      const errData = await resp.json();
      if (errData && errData.detail) detail = errData.detail;
    } catch {
      // ignore JSON parse errors
    }
    const err = new Error(detail);
    err.status = resp.status;
    throw err;
  }
  return resp;
}

function uploadAudioWithProgress({
  blob,
  filename,
  title,
  manualNotes,
  sttProvider,
  clientId,
  onProgress,
}) {
  return new Promise((resolve, reject) => {
    const formData = new FormData();
    formData.append("file", blob, filename || "recording.m4a");
    if (title && title.trim()) {
      formData.append("title", title.trim());
    }
    formData.append("manual_notes", manualNotes || "");
    formData.append("stt_provider", sttProvider || getDefaultSttProvider());
    if (clientId) {
      formData.append("client_id", clientId);
    }

    const xhr = new XMLHttpRequest();
    xhr.open("POST", "/api/meetings/quick-upload", true);
    xhr.withCredentials = true;
    xhr.timeout = 10 * 60 * 1000;

    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable && typeof onProgress === "function") {
        const pct = Math.min(100, Math.max(0, Math.round((event.loaded / event.total) * 100)));
        onProgress(pct);
      }
    };

    xhr.onload = () => {
      if (xhr.status === 401) {
        localStorage.removeItem(LOGGED_IN_HINT_KEY);
        state.authenticated = false;
        showLogin();
        reject(new Error("Authentication required"));
        return;
      }
      if (xhr.status >= 200 && xhr.status < 300) {
        setOffline(false);
        try {
          resolve(JSON.parse(xhr.responseText));
        } catch {
          reject(new Error("Invalid server response"));
        }
        return;
      }
      let detail = `Upload failed (${xhr.status})`;
      try {
        const parsed = JSON.parse(xhr.responseText);
        if (parsed && parsed.detail) detail = parsed.detail;
      } catch {
        // Ignore parse error
      }
      reject(new Error(detail));
    };

    xhr.onerror = () => {
      setOffline(true);
      const err = new Error("Network error while uploading");
      err.isNetworkError = true;
      reject(err);
    };

    xhr.ontimeout = () => {
      const err = new Error("Upload timed out");
      err.isNetworkError = true;
      reject(err);
    };

    xhr.send(formData);
  });
}

function applyTheme(theme) {
  document.documentElement.setAttribute("data-theme", theme);
  if (els.themeColorMeta) {
    els.themeColorMeta.setAttribute("content", theme === "dark" ? "#141413" : "#f8f7f4");
  }
}

function initTheme() {
  const saved = localStorage.getItem(THEME_STORAGE_KEY);
  const prefersDark =
    window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  applyTheme(saved || (prefersDark ? "dark" : "light"));
}

function toggleTheme() {
  const current = document.documentElement.getAttribute("data-theme") || "light";
  const next = current === "dark" ? "light" : "dark";
  applyTheme(next);
  localStorage.setItem(THEME_STORAGE_KEY, next);
}

function showLogin() {
  stopPolling();
  els.recorderView.classList.add("hidden");
  els.uploadModal.classList.add("hidden");
  els.settingsModal.classList.add("hidden");
  els.appView.classList.add("hidden");
  els.loginView.classList.remove("hidden");
}

function showApp() {
  els.loginView.classList.add("hidden");
  els.appView.classList.remove("hidden");
}

function stopPolling() {
  if (state.pollTimer) {
    clearInterval(state.pollTimer);
    state.pollTimer = null;
  }
}

function startPollingIfActive(meeting) {
  stopPolling();
  if (!meeting || state.offline) return;
  if (["queued", "transcribing", "summarizing"].includes(meeting.status)) {
    state.pollTimer = setInterval(async () => {
      if (!state.selectedId || state.offline) return;
      try {
        await loadMeetingDetail(state.selectedId, { silent: true });
        await loadMeetings(els.searchInput.value);
      } catch {
        // Polling failure handled inside helpers.
      }
    }, 3000);
  }
}

async function enterAuthenticatedWorkspace() {
  state.authenticated = true;
  localStorage.setItem(LOGGED_IN_HINT_KEY, "1");
  showApp();

  if (navigator.storage && typeof navigator.storage.persist === "function") {
    navigator.storage.persist().catch(() => {});
  }

  await window.NoteItDB.recoverInterruptedRecordings();
  await renderPendingUploads();
  await loadMeetings();

  const initialMeetingId = getMeetingIdFromUrl();
  if (initialMeetingId) {
    await loadMeetingDetail(initialMeetingId, { pushHistory: false });
  }
}

async function checkSession() {
  try {
    const resp = await fetch("/api/auth/me", { credentials: "same-origin" });
    if (resp.ok) {
      setOffline(false);
      await enterAuthenticatedWorkspace();
      return;
    }
    if (resp.status === 401) {
      localStorage.removeItem(LOGGED_IN_HINT_KEY);
      state.authenticated = false;
      showLogin();
      return;
    }
  } catch {
    setOffline(true);
    const cachedMeetings = await window.NoteItDB.listMeetings();
    const pending = await window.NoteItDB.listPendingUploads();
    if (
      localStorage.getItem(LOGGED_IN_HINT_KEY) === "1" ||
      cachedMeetings.length > 0 ||
      pending.length > 0
    ) {
      await enterAuthenticatedWorkspace();
      return;
    }
  }
  showLogin();
}

async function loadMeetings(query = "") {
  const cached = await window.NoteItDB.listMeetings(query);
  if (cached.length > 0 && state.meetings.length === 0) {
    state.meetings = cached;
    renderMeetingList();
  }

  try {
    const qs = query.trim() ? `?q=${encodeURIComponent(query.trim())}` : "";
    const resp = await apiFetch(`/api/meetings${qs}`);
    const data = await resp.json();
    state.meetings = data.meetings || [];
    await window.NoteItDB.upsertMeetings(state.meetings);
    renderMeetingList();
  } catch (err) {
    if (err.status === 401) return;
    state.meetings = await window.NoteItDB.listMeetings(query);
    renderMeetingList();
  }
}

function renderMeetingList() {
  els.meetingList.innerHTML = "";
  if (state.meetings.length === 0) {
    const p = document.createElement("p");
    p.className = "muted empty-list-note";
    p.textContent = "No meetings found.";
    els.meetingList.appendChild(p);
    return;
  }
  for (const m of state.meetings) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = `meeting-item${m.id === state.selectedId ? " active" : ""}`;
    btn.addEventListener("click", () => {
      loadMeetingDetail(m.id, { pushHistory: true });
    });

    const titleEl = document.createElement("div");
    titleEl.className = "meeting-item-title";
    titleEl.textContent = m.title || "Untitled Meeting";

    const metaEl = document.createElement("div");
    metaEl.className = "meeting-item-meta";

    const dateSpan = document.createElement("span");
    dateSpan.textContent = formatDate(m.created_at);

    const badge = document.createElement("span");
    badge.className = `badge ${m.status}`;
    badge.textContent = m.status;

    metaEl.append(dateSpan, badge);
    btn.append(titleEl, metaEl);
    els.meetingList.appendChild(btn);
  }
}

async function renderPendingUploads() {
  const all = await window.NoteItDB.listPendingUploads();
  const visible = all.filter((item) => item.status !== "recording");
  state.pendingUploads = visible;

  els.pendingUploadsList.innerHTML = "";
  if (visible.length === 0) {
    els.pendingUploadsSection.classList.add("hidden");
    return;
  }

  els.pendingUploadsSection.classList.remove("hidden");
  for (const item of visible) {
    const isUploading = state.uploadingPendingIds.has(item.id);
    const card = document.createElement("div");
    card.className = "pending-upload-item";

    const head = document.createElement("div");
    head.className = "pending-upload-head";
    const titleSpan = document.createElement("span");
    titleSpan.textContent = (item.title || "").trim() || "Untitled Recording";
    const badge = document.createElement("span");
    badge.className = `badge ${isUploading ? "uploading" : item.status}`;
    badge.textContent = isUploading ? "uploading" : item.status;
    head.append(titleSpan, badge);

    const meta = document.createElement("div");
    meta.className = "pending-upload-meta";
    const parts = [formatDate(item.created_at)];
    if (item.duration_seconds) {
      parts.push(formatDuration(item.duration_seconds));
    }
    meta.textContent = parts.filter(Boolean).join(" · ");

    card.append(head, meta);

    if (item.error_message) {
      const errEl = document.createElement("div");
      errEl.className = "pending-upload-error";
      errEl.textContent = item.error_message;
      card.appendChild(errEl);
    }

    const actions = document.createElement("div");
    actions.className = "pending-upload-actions";

    const uploadBtn = document.createElement("button");
    uploadBtn.type = "button";
    uploadBtn.className = "btn btn-primary btn-sm";
    uploadBtn.disabled = isUploading;
    uploadBtn.textContent = isUploading ? "Uploading..." : "Upload Now";
    uploadBtn.addEventListener("click", () => retryPendingUpload(item.id));

    const deleteBtn = document.createElement("button");
    deleteBtn.type = "button";
    deleteBtn.className = "btn btn-danger btn-sm";
    deleteBtn.disabled = isUploading;
    deleteBtn.textContent = "Delete";
    deleteBtn.addEventListener("click", async () => {
      if (!confirm("Delete this saved local recording?")) return;
      await window.NoteItDB.deletePendingUpload(item.id);
      await renderPendingUploads();
      showToast("Local recording deleted");
    });

    actions.append(uploadBtn, deleteBtn);
    card.appendChild(actions);
    els.pendingUploadsList.appendChild(card);
  }
}

async function retryPendingUpload(uploadId) {
  if (state.uploadingPendingIds.has(uploadId)) return;
  const item = await window.NoteItDB.getPendingUpload(uploadId);
  if (!item) {
    await renderPendingUploads();
    return;
  }

  const blob = await window.NoteItDB.assembleAudioBlob(uploadId, item.mime_type);
  if (!blob || blob.size === 0) {
    await window.NoteItDB.deletePendingUpload(uploadId);
    await renderPendingUploads();
    showToast("Saved audio was empty and removed");
    return;
  }

  state.uploadingPendingIds.add(uploadId);
  await renderPendingUploads();

  try {
    const meeting = await uploadAudioWithProgress({
      blob,
      filename: item.filename || `${uploadId}.m4a`,
      title: item.title,
      manualNotes: item.manual_notes,
      sttProvider: item.stt_provider,
      clientId: item.client_id || uploadId,
    });
    await window.NoteItDB.deletePendingUpload(uploadId);
    state.uploadingPendingIds.delete(uploadId);
    await renderPendingUploads();
    showToast("Recording uploaded — transcribing...");
    await loadMeetings(els.searchInput.value);
    await loadMeetingDetail(meeting.id, { pushHistory: true });
  } catch (err) {
    state.uploadingPendingIds.delete(uploadId);
    if (err.status !== 401) {
      await window.NoteItDB.updatePendingUpload(uploadId, {
        status: err.isNetworkError ? "pending" : "failed",
        error_message: err.message || "Upload failed",
      });
      showToast(err.message || "Upload failed — saved locally");
    }
    await renderPendingUploads();
  }
}

function blurActiveInput() {
  const active = document.activeElement;
  if (active && typeof active.blur === "function" && active !== document.body) {
    active.blur();
  }
}

function resetViewportScroll() {
  if (typeof window.scrollTo === "function") {
    window.scrollTo(0, 0);
  }
}

function closeMobileDetail(opts = { pushHistory: true }) {
  blurActiveInput();
  els.appView.classList.remove("mobile-detail-open");
  resetViewportScroll();
  if (opts.pushHistory) {
    pushMeetingUrl(null);
  }
}

async function loadMeetingDetail(meetingId, opts = {}) {
  const switchedMeeting = state.selectedId !== meetingId;
  state.selectedId = meetingId;
  if (switchedMeeting) {
    state.transcriptFilter = "";
    els.transcriptFilterInput.value = "";
  }
  if (!opts.silent) {
    blurActiveInput();
    resetViewportScroll();
  }
  els.appView.classList.add("mobile-detail-open");
  if (opts.pushHistory !== false) {
    pushMeetingUrl(meetingId);
  }
  renderMeetingList();

  const cached = await window.NoteItDB.getMeeting(meetingId);
  if (cached) {
    state.selectedMeeting = cached;
    renderMeetingDetail(cached);
    if (!opts.silent) {
      const cachedChat = await window.NoteItDB.getChat(meetingId);
      renderChat(cachedChat);
    }
  }

  try {
    const resp = await apiFetch(`/api/meetings/${encodeURIComponent(meetingId)}`);
    const meeting = await resp.json();
    state.selectedMeeting = meeting;
    await window.NoteItDB.upsertMeetingDetail(meeting);
    renderMeetingDetail(meeting);
    startPollingIfActive(meeting);
    if (!opts.silent) {
      await loadChat(meetingId);
    }
  } catch (err) {
    if (err.status === 401) return;
    if (!cached) {
      showToast("Unable to load meeting while offline");
    }
  }
}

function renderMeetingDetail(meeting) {
  els.emptyState.classList.add("hidden");
  els.detailView.classList.remove("hidden");

  els.titleInput.value = meeting.title || "Untitled Meeting";
  els.statusBadge.className = `badge ${meeting.status}`;
  els.statusBadge.textContent = meeting.status;

  const metaParts = [formatDate(meeting.created_at)];
  if (meeting.duration_seconds !== null && meeting.duration_seconds !== undefined) {
    metaParts.push(formatDuration(meeting.duration_seconds));
  }
  if (meeting.stt_used) {
    metaParts.push(`STT: ${meeting.stt_used}`);
  }
  els.metaInfo.textContent = metaParts.join(" · ");

  if (meeting.error_message) {
    els.errorBanner.textContent = meeting.error_message;
    els.errorBanner.classList.remove("hidden");
  } else {
    els.errorBanner.classList.add("hidden");
  }
  els.retryBtn.classList.toggle("hidden", meeting.status !== "failed");

  els.summaryContent.innerHTML = renderSafeMarkdown(meeting.summary || "");
  if (document.activeElement !== els.manualNotesInput) {
    els.manualNotesInput.value = meeting.manual_notes || "";
  }

  renderTranscript(meeting);
}

function renderTranscript(meeting) {
  els.transcriptContent.innerHTML = "";
  const filter = state.transcriptFilter.trim().toLowerCase();
  const segments = meeting.segments || [];

  if (segments.length > 0) {
    const filtered = filter
      ? segments.filter((s) => String(s.text || "").toLowerCase().includes(filter))
      : segments;
    if (filtered.length === 0) {
      const p = document.createElement("p");
      p.className = "muted";
      p.textContent = "No transcript segments match your filter.";
      els.transcriptContent.appendChild(p);
      return;
    }
    for (const seg of filtered) {
      const row = document.createElement("div");
      row.className = "segment-row";
      const ts = document.createElement("span");
      ts.className = "segment-ts";
      ts.textContent = formatDuration(seg.start_sec);
      const txt = document.createElement("span");
      txt.textContent = seg.text;
      row.append(ts, txt);
      els.transcriptContent.appendChild(row);
    }
    return;
  }

  const p = document.createElement("p");
  if (!meeting.transcript) {
    p.className = "muted";
    p.textContent = "No transcript available yet.";
  } else if (filter && !meeting.transcript.toLowerCase().includes(filter)) {
    p.className = "muted";
    p.textContent = "No transcript text matches your filter.";
  } else {
    p.textContent = meeting.transcript;
  }
  els.transcriptContent.appendChild(p);
}

async function loadChat(meetingId) {
  try {
    const resp = await apiFetch(`/api/meetings/${encodeURIComponent(meetingId)}/chat`);
    const messages = await resp.json();
    await window.NoteItDB.saveChat(meetingId, messages);
    renderChat(messages);
  } catch (err) {
    if (err.status === 401) return;
    const cached = await window.NoteItDB.getChat(meetingId);
    renderChat(cached);
  }
}

function renderChat(messages) {
  els.chatMessages.innerHTML = "";
  if (!messages || messages.length === 0) {
    const p = document.createElement("p");
    p.className = "muted";
    p.textContent =
      "Ask a question about decisions, action items, or details from this meeting.";
    els.chatMessages.appendChild(p);
    return;
  }
  for (const msg of messages) {
    const bubble = document.createElement("div");
    bubble.className = `chat-bubble ${msg.role}`;
    if (msg.role === "assistant") {
      bubble.innerHTML = renderSafeMarkdown(msg.content);
    } else {
      bubble.textContent = msg.content;
    }
    els.chatMessages.appendChild(bubble);
  }
  els.chatMessages.scrollTop = els.chatMessages.scrollHeight;
}

function switchTab(tabName) {
  state.activeTab = tabName;
  document.querySelectorAll(".tab").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.tab === tabName);
  });
  document.querySelectorAll(".tab-panel").forEach((panel) => {
    panel.classList.toggle("active", panel.id === `tab-${tabName}`);
  });
}

// Foreground Recorder Flow
function setRecorderBusy(isBusy) {
  els.recDiscardBtn.disabled = isBusy;
  els.recDoneBtn.disabled = isBusy;
  els.recPauseBtn.disabled = isBusy;
  els.recStopBtn.disabled = isBusy;
  els.recUploadSavedBtn.disabled = isBusy;
  els.recDiscardSavedBtn.disabled = isBusy;
}

function resetRecorderUi() {
  els.recTimer.textContent = "00:00";
  els.recDot.classList.remove("paused");
  els.recAmpMeter.value = 8;
  els.recTitleInput.value = "";
  els.recNotesInput.value = "";
  els.recPauseBtn.textContent = "Pause";
  els.recStopBtn.textContent = "Stop & Summarize";
  els.recWakelockBadge.classList.add("hidden");
  els.recInterruptedBanner.classList.add("hidden");
  els.recErrorBanner.classList.add("hidden");
  els.recUploadProgressWrap.classList.add("hidden");
  els.recUploadProgress.value = 0;
  els.recUploadProgressText.textContent = "Uploading... 0%";
  setRecorderBusy(false);
}

function scheduleRecorderDraftSave() {
  const active = state.activeRecording;
  if (!active) return;
  if (active.autosaveTimer) clearTimeout(active.autosaveTimer);
  active.autosaveTimer = setTimeout(() => {
    window.NoteItDB.updatePendingUpload(active.id, {
      title: els.recTitleInput.value.trim(),
      manual_notes: els.recNotesInput.value,
    });
  }, 500);
}

async function startForegroundRecording() {
  if (!window.NoteItRecorder || !window.NoteItRecorder.isSupported()) {
    showToast("In-browser audio recording is unavailable here. Use Upload Audio or Voice Memos.");
    return;
  }

  const uploadId = generateUuid();
  resetRecorderUi();
  els.recorderView.classList.remove("hidden");
  setRecorderBusy(true);

  const active = {
    id: uploadId,
    mimeType: "audio/mp4",
    extension: ".m4a",
    filename: `${uploadId}.m4a`,
    durationSeconds: 0,
    autosaveTimer: null,
    interrupted: false,
  };
  state.activeRecording = active;

  // Trigger getUserMedia synchronously inside the tap gesture before any await.
  let recPromise;
  try {
    recPromise = window.NoteItRecorder.start(uploadId, {
      onDuration: (seconds) => {
        active.durationSeconds = seconds;
        const recState = window.NoteItRecorder.getState();
        const formatted = formatDuration(seconds);
        els.recTimer.textContent = recState === "paused" ? `Paused · ${formatted}` : formatted;
      },
      onAmplitude: (level) => {
        if (window.NoteItRecorder.getState() === "paused") {
          els.recAmpMeter.value = 0;
        } else {
          els.recAmpMeter.value = Math.round(8 + level * 92);
        }
      },
      onStateChange: (nextState) => {
        const paused = nextState === "paused";
        els.recDot.classList.toggle("paused", paused);
        els.recPauseBtn.textContent = paused ? "Resume" : "Pause";
        const formatted = formatDuration(active.durationSeconds);
        els.recTimer.textContent = paused ? `Paused · ${formatted}` : formatted;
      },
      onWakeLockChange: (isActive) => {
        els.recWakelockBadge.classList.toggle("hidden", !isActive);
      },
      onInterrupted: async (result) => {
        active.interrupted = true;
        if (result) {
          active.durationSeconds = result.elapsedSeconds;
          active.mimeType = result.mimeType;
          active.extension = result.extension;
          active.filename = result.filename;
        }
        await window.NoteItDB.updatePendingUpload(uploadId, {
          title: els.recTitleInput.value.trim(),
          manual_notes: els.recNotesInput.value,
          duration_seconds: active.durationSeconds,
          filename: active.filename,
          mime_type: active.mimeType,
          status: "pending",
          error_message: "Recording was interrupted by iOS before finishing.",
        });
        els.recDot.classList.add("paused");
        els.recAmpMeter.value = 0;
        els.recPauseBtn.disabled = true;
        els.recStopBtn.disabled = true;
        els.recDoneBtn.disabled = true;
        els.recInterruptedBanner.classList.remove("hidden");
        await renderPendingUploads();
      },
    });
  } catch (syncErr) {
    state.activeRecording = null;
    setRecorderBusy(false);
    els.recErrorBanner.textContent = syncErr.message || "Unable to access microphone.";
    els.recErrorBanner.classList.remove("hidden");
    els.recPauseBtn.disabled = true;
    els.recStopBtn.disabled = true;
    els.recDoneBtn.disabled = true;
    return;
  }

  try {
    const info = await recPromise;
    active.mimeType = info.mimeType;
    active.extension = info.extension;
    active.filename = info.filename;
    setRecorderBusy(false);

    const nowIso = new Date().toISOString();
    await window.NoteItDB.savePendingUpload({
      id: uploadId,
      client_id: uploadId,
      title: els.recTitleInput.value.trim(),
      manual_notes: els.recNotesInput.value,
      stt_provider: getDefaultSttProvider(),
      filename: info.filename,
      mime_type: info.mimeType,
      duration_seconds: 0,
      created_at: nowIso,
      updated_at: nowIso,
      status: "recording",
      error_message: "",
    });
  } catch (err) {
    state.activeRecording = null;
    setRecorderBusy(false);
    els.recErrorBanner.textContent =
      err.message || "Microphone permission denied or unavailable.";
    els.recErrorBanner.classList.remove("hidden");
    els.recPauseBtn.disabled = true;
    els.recStopBtn.disabled = true;
    els.recDoneBtn.disabled = true;
  }
}

async function finishAndUploadRecording() {
  const active = state.activeRecording;
  if (!active) return;

  if (active.autosaveTimer) {
    clearTimeout(active.autosaveTimer);
    active.autosaveTimer = null;
  }
  setRecorderBusy(true);

  if (!active.interrupted && window.NoteItRecorder.getState() !== "idle") {
    const recResult = await window.NoteItRecorder.stop();
    if (recResult) {
      active.durationSeconds = recResult.elapsedSeconds;
      active.mimeType = recResult.mimeType;
      active.extension = recResult.extension;
      active.filename = recResult.filename;
    }
  }

  const title = els.recTitleInput.value.trim();
  const manualNotes = els.recNotesInput.value;
  const sttProvider = getDefaultSttProvider();

  await window.NoteItDB.updatePendingUpload(active.id, {
    title,
    manual_notes: manualNotes,
    duration_seconds: active.durationSeconds,
    filename: active.filename,
    mime_type: active.mimeType,
    stt_provider: sttProvider,
    status: "pending",
    error_message: "",
  });

  const blob = await window.NoteItDB.assembleAudioBlob(active.id, active.mimeType);
  if (!blob || blob.size === 0) {
    await window.NoteItDB.deletePendingUpload(active.id);
    state.activeRecording = null;
    els.recorderView.classList.add("hidden");
    await renderPendingUploads();
    showToast("No audio captured");
    return;
  }

  await window.NoteItDB.updatePendingUpload(active.id, { status: "uploading" });
  els.recUploadProgressWrap.classList.remove("hidden");
  els.recUploadProgress.value = 0;
  els.recUploadProgressText.textContent = "Uploading... 0%";
  els.recStopBtn.textContent = "Uploading...";

  try {
    const meeting = await uploadAudioWithProgress({
      blob,
      filename: active.filename,
      title,
      manualNotes,
      sttProvider,
      clientId: active.id,
      onProgress: (pct) => {
        els.recUploadProgress.value = pct;
        els.recUploadProgressText.textContent = `Uploading... ${pct}%`;
      },
    });
    await window.NoteItDB.deletePendingUpload(active.id);
    state.activeRecording = null;
    els.recorderView.classList.add("hidden");
    await renderPendingUploads();
    await loadMeetings(els.searchInput.value);
    await loadMeetingDetail(meeting.id, { pushHistory: true });
    showToast("Recording uploaded — summarizing...");
  } catch (err) {
    if (err.status !== 401) {
      await window.NoteItDB.updatePendingUpload(active.id, {
        status: err.isNetworkError ? "pending" : "failed",
        error_message: err.message || "Upload failed",
      });
      state.activeRecording = null;
      els.recorderView.classList.add("hidden");
      await renderPendingUploads();
      showToast("Saved locally — tap Upload Now when online");
    } else {
      state.activeRecording = null;
    }
  }
}

async function discardActiveRecording() {
  const active = state.activeRecording;
  if (!active) {
    els.recorderView.classList.add("hidden");
    return;
  }
  if (!confirm("Discard this recording and its rough notes?")) return;

  if (active.autosaveTimer) {
    clearTimeout(active.autosaveTimer);
  }
  setRecorderBusy(true);
  await window.NoteItRecorder.discard();
  await window.NoteItDB.deletePendingUpload(active.id);
  state.activeRecording = null;
  els.recorderView.classList.add("hidden");
  await renderPendingUploads();
}

// Upload Modal helpers
let selectedUploadFile = null;

function openUploadModal() {
  selectedUploadFile = null;
  els.uploadFileInput.value = "";
  els.uploadFileLabel.textContent =
    "Tap to choose an audio file or drop it here (.m4a, .mp3, .wav, .webm, .caf)";
  els.uploadTitleInput.value = "";
  els.uploadNotesInput.value = "";
  els.uploadSttSelect.value = getDefaultSttProvider();
  els.uploadError.classList.add("hidden");
  els.uploadProgressWrap.classList.add("hidden");
  els.uploadProgress.value = 0;
  els.uploadProgressText.textContent = "Uploading... 0%";
  els.uploadSubmitBtn.disabled = false;
  els.uploadCancelBtn.disabled = false;
  els.uploadCloseBtn.disabled = false;
  els.uploadModal.classList.remove("hidden");
}

function closeUploadModal() {
  els.uploadModal.classList.add("hidden");
}

function setSelectedUploadFile(file) {
  selectedUploadFile = file || null;
  if (file) {
    const mb = (file.size / (1024 * 1024)).toFixed(2);
    els.uploadFileLabel.textContent = `${file.name} (${mb} MB)`;
    els.uploadError.classList.add("hidden");
  } else {
    els.uploadFileLabel.textContent =
      "Tap to choose an audio file or drop it here (.m4a, .mp3, .wav, .webm, .caf)";
  }
}

// Settings Modal helpers
function openSettingsModal() {
  els.settingsSttSelect.value = getDefaultSttProvider();
  els.shortcutEndpointInput.value = `${window.location.origin}/api/meetings/quick-upload`;
  els.settingsModal.classList.remove("hidden");
}

function closeSettingsModal() {
  els.settingsModal.classList.add("hidden");
}

// Markdown Share / Copy / Download helpers
async function resolveMeetingMarkdown() {
  const m = state.selectedMeeting;
  if (!m) return "";
  try {
    const resp = await apiFetch(`/api/meetings/${encodeURIComponent(m.id)}/export.md`);
    return await resp.text();
  } catch (err) {
    if (err.status === 401) throw err;
    return renderLocalMarkdown(m);
  }
}

function triggerBlobDownload(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// Event Listeners
els.loginForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  els.loginError.classList.add("hidden");
  try {
    await apiFetch("/api/auth/login", {
      method: "POST",
      body: JSON.stringify({ token: els.tokenInput.value.trim() }),
    });
    els.tokenInput.value = "";
    await enterAuthenticatedWorkspace();
  } catch (err) {
    els.loginError.textContent = err.message || "Login failed";
    els.loginError.classList.remove("hidden");
  }
});

els.logoutBtn.addEventListener("click", async () => {
  try {
    await fetch("/api/auth/logout", { method: "POST", credentials: "same-origin" });
  } catch {
    // Allow clearing local session even if offline.
  }
  await window.NoteItDB.clearAll();
  localStorage.removeItem(LOGGED_IN_HINT_KEY);
  state.authenticated = false;
  state.meetings = [];
  state.pendingUploads = [];
  state.selectedId = null;
  state.selectedMeeting = null;
  els.detailView.classList.add("hidden");
  els.emptyState.classList.remove("hidden");
  els.appView.classList.remove("mobile-detail-open");
  if (window.history && typeof window.history.replaceState === "function") {
    window.history.replaceState({}, "", "/");
  }
  showLogin();
});

els.themeToggleBtn.addEventListener("click", toggleTheme);
els.settingsBtn.addEventListener("click", openSettingsModal);
els.settingsCloseBtn.addEventListener("click", closeSettingsModal);
els.settingsSttSelect.addEventListener("change", () => {
  localStorage.setItem(DEFAULT_STT_KEY, els.settingsSttSelect.value);
  showToast("Default STT preference saved");
});

els.copyEndpointBtn.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(els.shortcutEndpointInput.value);
    showToast("Endpoint URL copied");
  } catch {
    els.shortcutEndpointInput.select();
    showToast("Select and copy the URL");
  }
});

els.clearCacheBtn.addEventListener("click", async () => {
  if (!confirm("Clear locally cached meetings, chats, and unsent local recordings?")) return;
  await window.NoteItDB.clearAll();
  await renderPendingUploads();
  if (!state.offline) {
    await loadMeetings(els.searchInput.value);
  } else {
    state.meetings = [];
    renderMeetingList();
  }
  showToast("Local offline cache cleared");
});

els.recordBtn.addEventListener("click", startForegroundRecording);
els.recPauseBtn.addEventListener("click", () => {
  if (window.NoteItRecorder.getState() === "paused") {
    window.NoteItRecorder.resume();
  } else {
    window.NoteItRecorder.pause();
  }
});
els.recStopBtn.addEventListener("click", finishAndUploadRecording);
els.recDoneBtn.addEventListener("click", finishAndUploadRecording);
els.recUploadSavedBtn.addEventListener("click", finishAndUploadRecording);
els.recDiscardBtn.addEventListener("click", discardActiveRecording);
els.recDiscardSavedBtn.addEventListener("click", discardActiveRecording);
els.recTitleInput.addEventListener("input", scheduleRecorderDraftSave);
els.recNotesInput.addEventListener("input", scheduleRecorderDraftSave);

els.openUploadBtn.addEventListener("click", openUploadModal);
els.uploadCloseBtn.addEventListener("click", closeUploadModal);
els.uploadCancelBtn.addEventListener("click", closeUploadModal);
els.uploadFileInput.addEventListener("change", () => {
  setSelectedUploadFile(els.uploadFileInput.files && els.uploadFileInput.files[0]);
});
els.uploadDropzone.addEventListener("dragover", (e) => {
  e.preventDefault();
  els.uploadDropzone.classList.add("dragover");
});
els.uploadDropzone.addEventListener("dragleave", () => {
  els.uploadDropzone.classList.remove("dragover");
});
els.uploadDropzone.addEventListener("drop", (e) => {
  e.preventDefault();
  els.uploadDropzone.classList.remove("dragover");
  const file = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
  if (file) {
    setSelectedUploadFile(file);
  }
});

els.uploadForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  const file =
    selectedUploadFile || (els.uploadFileInput.files && els.uploadFileInput.files[0]);
  if (!file) {
    els.uploadError.textContent = "Please choose an audio file first.";
    els.uploadError.classList.remove("hidden");
    return;
  }

  els.uploadError.classList.add("hidden");
  els.uploadProgressWrap.classList.remove("hidden");
  els.uploadProgress.value = 0;
  els.uploadProgressText.textContent = "Uploading... 0%";
  els.uploadSubmitBtn.disabled = true;
  els.uploadCancelBtn.disabled = true;
  els.uploadCloseBtn.disabled = true;

  try {
    const meeting = await uploadAudioWithProgress({
      blob: file,
      filename: file.name || "audio.m4a",
      title: els.uploadTitleInput.value,
      manualNotes: els.uploadNotesInput.value,
      sttProvider: els.uploadSttSelect.value,
      clientId: generateUuid(),
      onProgress: (pct) => {
        els.uploadProgress.value = pct;
        els.uploadProgressText.textContent = `Uploading... ${pct}%`;
      },
    });
    closeUploadModal();
    showToast("Audio uploaded — transcribing...");
    await loadMeetings(els.searchInput.value);
    await loadMeetingDetail(meeting.id, { pushHistory: true });
  } catch (err) {
    els.uploadError.textContent = err.message || "Upload failed";
    els.uploadError.classList.remove("hidden");
    els.uploadSubmitBtn.disabled = false;
    els.uploadCancelBtn.disabled = false;
    els.uploadCloseBtn.disabled = false;
  }
});

els.backBtn.addEventListener("click", () => closeMobileDetail({ pushHistory: true }));

let searchTimer = null;
els.searchInput.addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => loadMeetings(els.searchInput.value), 220);
});

els.transcriptFilterInput.addEventListener("input", () => {
  state.transcriptFilter = els.transcriptFilterInput.value;
  if (state.selectedMeeting) {
    renderTranscript(state.selectedMeeting);
  }
});

document.querySelectorAll(".tab").forEach((btn) => {
  btn.addEventListener("click", () => switchTab(btn.dataset.tab));
});

els.titleInput.addEventListener("blur", async () => {
  if (!state.selectedMeeting || state.offline) return;
  const nextTitle = els.titleInput.value.trim();
  if (!nextTitle || nextTitle === state.selectedMeeting.title) return;
  try {
    const resp = await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}`, {
      method: "PATCH",
      body: JSON.stringify({ title: nextTitle }),
    });
    const updated = await resp.json();
    state.selectedMeeting = { ...state.selectedMeeting, ...updated };
    await window.NoteItDB.upsertMeetingDetail(state.selectedMeeting);
    showToast("Title saved");
    await loadMeetings(els.searchInput.value);
  } catch (err) {
    showToast(err.message || "Unable to save title");
  }
});

els.saveNotesBtn.addEventListener("click", async () => {
  if (!state.selectedId) return;
  if (state.offline) {
    showToast("You are offline — reconnect to save changes");
    return;
  }
  try {
    await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}`, {
      method: "PATCH",
      body: JSON.stringify({ manual_notes: els.manualNotesInput.value }),
    });
    showToast("Notes saved");
    await loadMeetingDetail(state.selectedId, { silent: true, pushHistory: false });
  } catch (err) {
    showToast(err.message || "Unable to save notes");
  }
});

async function triggerResummarize(includeNotes) {
  if (!state.selectedId) return;
  if (state.offline) {
    showToast("You are offline — reconnect to re-summarize");
    return;
  }
  const body = {
    custom_instructions: els.customInstructionsInput.value.trim() || null,
  };
  if (includeNotes) {
    body.manual_notes = els.manualNotesInput.value;
  }
  try {
    await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}/resummarize`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    showToast("Re-summarizing...");
    switchTab("summary");
    await loadMeetingDetail(state.selectedId, { silent: true, pushHistory: false });
  } catch (err) {
    showToast(err.message || "Re-summarize failed");
  }
}

els.resummarizeBtn.addEventListener("click", () => triggerResummarize(false));
els.saveResummarizeBtn.addEventListener("click", () => triggerResummarize(true));

els.retryBtn.addEventListener("click", async () => {
  if (!state.selectedId) return;
  if (state.offline) {
    showToast("You are offline — reconnect to retry");
    return;
  }
  try {
    await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}/retry`, {
      method: "POST",
    });
    showToast("Retry queued");
    await loadMeetingDetail(state.selectedId, { silent: true, pushHistory: false });
  } catch (err) {
    showToast(err.message || "Retry failed");
  }
});

els.shareMdBtn.addEventListener("click", async () => {
  if (!state.selectedMeeting) return;
  try {
    const md = await resolveMeetingMarkdown();
    const filename = safeMarkdownFilename(
      state.selectedMeeting.title,
      state.selectedMeeting.id
    );
    let file = new File([md], filename, { type: "text/markdown" });
    if (navigator.canShare && !navigator.canShare({ files: [file] })) {
      file = new File([md], filename, { type: "text/plain" });
    }
    if (
      typeof navigator.share === "function" &&
      (!navigator.canShare || navigator.canShare({ files: [file] }))
    ) {
      try {
        await navigator.share({
          title: state.selectedMeeting.title || "Meeting Notes",
          files: [file],
        });
        return;
      } catch (shareErr) {
        if (shareErr && shareErr.name === "AbortError") return;
      }
    }
    triggerBlobDownload(file, filename);
    showToast("Downloaded .md file");
  } catch (err) {
    if (err.status !== 401) {
      showToast(err.message || "Share failed");
    }
  }
});

els.copyMdBtn.addEventListener("click", async () => {
  if (!state.selectedId) return;
  try {
    const md = await resolveMeetingMarkdown();
    await navigator.clipboard.writeText(md);
    showToast("Markdown copied");
  } catch (err) {
    if (err.status !== 401) {
      showToast(err.message || "Unable to copy Markdown");
    }
  }
});

els.downloadMdBtn.addEventListener("click", async () => {
  if (!state.selectedMeeting) return;
  if (!state.offline) {
    window.location.href = `/api/meetings/${encodeURIComponent(state.selectedMeeting.id)}/export.md`;
    return;
  }
  const md = renderLocalMarkdown(state.selectedMeeting);
  const filename = safeMarkdownFilename(
    state.selectedMeeting.title,
    state.selectedMeeting.id
  );
  triggerBlobDownload(new Blob([md], { type: "text/markdown" }), filename);
});

els.deleteBtn.addEventListener("click", async () => {
  if (!state.selectedId) return;
  if (state.offline) {
    showToast("You are offline — reconnect to delete");
    return;
  }
  if (!confirm("Delete this meeting permanently?")) return;
  const deletedId = state.selectedId;
  try {
    await apiFetch(`/api/meetings/${encodeURIComponent(deletedId)}`, {
      method: "DELETE",
    });
    await window.NoteItDB.deleteMeeting(deletedId);
    stopPolling();
    state.selectedId = null;
    state.selectedMeeting = null;
    els.detailView.classList.add("hidden");
    els.emptyState.classList.remove("hidden");
    closeMobileDetail({ pushHistory: true });
    showToast("Meeting deleted");
    await loadMeetings(els.searchInput.value);
  } catch (err) {
    showToast(err.message || "Delete failed");
  }
});

els.chatForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  if (!state.selectedId) return;
  if (state.offline) {
    showToast("You are offline — reconnect to ask AI");
    return;
  }
  const msg = els.chatInput.value.trim();
  if (!msg) return;
  els.chatInput.value = "";
  const sendBtn = els.chatForm.querySelector("button[type='submit']");
  sendBtn.disabled = true;
  try {
    await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}/chat`, {
      method: "POST",
      body: JSON.stringify({ message: msg }),
    });
    await loadChat(state.selectedId);
  } catch (err) {
    showToast(err.message || "Chat failed");
  } finally {
    sendBtn.disabled = false;
  }
});

els.clearChatBtn.addEventListener("click", async () => {
  if (!state.selectedId) return;
  if (state.offline) {
    showToast("You are offline — reconnect to clear chat");
    return;
  }
  try {
    await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}/chat`, {
      method: "DELETE",
    });
    await window.NoteItDB.saveChat(state.selectedId, []);
    renderChat([]);
    showToast("Chat cleared");
  } catch (err) {
    showToast(err.message || "Unable to clear chat");
  }
});

window.addEventListener("popstate", () => {
  if (!state.authenticated) return;
  const id = getMeetingIdFromUrl();
  if (id) {
    loadMeetingDetail(id, { pushHistory: false });
  } else {
    closeMobileDetail({ pushHistory: false });
    stopPolling();
    state.selectedId = null;
    state.selectedMeeting = null;
    els.detailView.classList.add("hidden");
    els.emptyState.classList.remove("hidden");
    renderMeetingList();
  }
});

window.addEventListener("offline", () => {
  setOffline(true);
  stopPolling();
});

window.addEventListener("online", () => {
  setOffline(false);
  if (state.authenticated) {
    loadMeetings(els.searchInput.value);
    if (state.selectedId) {
      loadMeetingDetail(state.selectedId, { silent: true, pushHistory: false });
    }
  }
});

if (window.history && "scrollRestoration" in window.history) {
  window.history.scrollRestoration = "manual";
}

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {});
}

initTheme();
setOffline(typeof navigator !== "undefined" ? !navigator.onLine : false);
checkSession();
