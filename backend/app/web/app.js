"use strict";

const state = {
  meetings: [],
  selectedId: null,
  selectedMeeting: null,
  activeTab: "summary",
  pollTimer: null,
};

const els = {
  loginView: document.getElementById("login-view"),
  appView: document.getElementById("app-view"),
  loginForm: document.getElementById("login-form"),
  tokenInput: document.getElementById("token-input"),
  loginError: document.getElementById("login-error"),
  logoutBtn: document.getElementById("logout-btn"),
  themeToggleBtn: document.getElementById("theme-toggle-btn"),
  searchInput: document.getElementById("search-input"),
  meetingList: document.getElementById("meeting-list"),
  emptyState: document.getElementById("empty-state"),
  detailView: document.getElementById("detail-view"),
  titleInput: document.getElementById("meeting-title-input"),
  statusBadge: document.getElementById("status-badge"),
  metaInfo: document.getElementById("meta-info"),
  errorBanner: document.getElementById("error-banner"),
  retryBtn: document.getElementById("retry-btn"),
  copyMdBtn: document.getElementById("copy-md-btn"),
  downloadMdBtn: document.getElementById("download-md-btn"),
  deleteBtn: document.getElementById("delete-btn"),
  customInstructionsInput: document.getElementById("custom-instructions-input"),
  resummarizeBtn: document.getElementById("resummarize-btn"),
  summaryContent: document.getElementById("summary-content"),
  manualNotesInput: document.getElementById("manual-notes-input"),
  saveNotesBtn: document.getElementById("save-notes-btn"),
  saveResummarizeBtn: document.getElementById("save-resummarize-btn"),
  transcriptContent: document.getElementById("transcript-content"),
  chatMessages: document.getElementById("chat-messages"),
  chatForm: document.getElementById("chat-form"),
  chatInput: document.getElementById("chat-input"),
  clearChatBtn: document.getElementById("clear-chat-btn"),
  toast: document.getElementById("toast"),
};

function showToast(msg) {
  els.toast.textContent = msg;
  els.toast.classList.remove("hidden");
  setTimeout(() => els.toast.classList.add("hidden"), 2500);
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

async function apiFetch(path, options = {}) {
  const resp = await fetch(path, {
    credentials: "same-origin",
    headers: {
      ...(options.body instanceof FormData ? {} : { "Content-Type": "application/json" }),
      ...(options.headers || {}),
    },
    ...options,
  });
  if (resp.status === 401) {
    showLogin();
    throw new Error("Authentication required");
  }
  if (!resp.ok) {
    let detail = `Request failed (${resp.status})`;
    try {
      const errData = await resp.json();
      if (errData && errData.detail) detail = errData.detail;
    } catch {
      // ignore JSON parse errors
    }
    throw new Error(detail);
  }
  return resp;
}

function initTheme() {
  const saved = localStorage.getItem("noteit_theme");
  const prefersDark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  document.documentElement.setAttribute("data-theme", saved || (prefersDark ? "dark" : "light"));
}

function toggleTheme() {
  const current = document.documentElement.getAttribute("data-theme") || "light";
  const next = current === "dark" ? "light" : "dark";
  document.documentElement.setAttribute("data-theme", next);
  localStorage.setItem("noteit_theme", next);
}

function showLogin() {
  stopPolling();
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
  if (!meeting) return;
  if (["queued", "transcribing", "summarizing"].includes(meeting.status)) {
    state.pollTimer = setInterval(async () => {
      if (!state.selectedId) return;
      await loadMeetingDetail(state.selectedId, { silent: true });
      await loadMeetings(els.searchInput.value);
    }, 3000);
  }
}

async function checkSession() {
  try {
    const resp = await fetch("/api/auth/me", { credentials: "same-origin" });
    if (resp.ok) {
      showApp();
      await loadMeetings();
    } else {
      showLogin();
    }
  } catch {
    showLogin();
  }
}

async function loadMeetings(query = "") {
  const qs = query.trim() ? `?q=${encodeURIComponent(query.trim())}` : "";
  const resp = await apiFetch(`/api/meetings${qs}`);
  const data = await resp.json();
  state.meetings = data.meetings || [];
  renderMeetingList();
}

function renderMeetingList() {
  els.meetingList.innerHTML = "";
  if (state.meetings.length === 0) {
    const p = document.createElement("p");
    p.className = "muted";
    p.style.padding = "1rem";
    p.textContent = "No meetings found.";
    els.meetingList.appendChild(p);
    return;
  }
  for (const m of state.meetings) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = `meeting-item${m.id === state.selectedId ? " active" : ""}`;
    btn.addEventListener("click", () => loadMeetingDetail(m.id));

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

async function loadMeetingDetail(meetingId, opts = {}) {
  state.selectedId = meetingId;
  renderMeetingList();
  const resp = await apiFetch(`/api/meetings/${encodeURIComponent(meetingId)}`);
  const meeting = await resp.json();
  state.selectedMeeting = meeting;
  renderMeetingDetail(meeting);
  startPollingIfActive(meeting);
  if (!opts.silent) {
    await loadChat(meetingId);
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
  const segments = meeting.segments || [];
  if (segments.length > 0) {
    for (const seg of segments) {
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
  p.className = meeting.transcript ? "" : "muted";
  p.textContent = meeting.transcript || "No transcript available yet.";
  els.transcriptContent.appendChild(p);
}

async function loadChat(meetingId) {
  const resp = await apiFetch(`/api/meetings/${encodeURIComponent(meetingId)}/chat`);
  const messages = await resp.json();
  renderChat(messages);
}

function renderChat(messages) {
  els.chatMessages.innerHTML = "";
  if (!messages || messages.length === 0) {
    const p = document.createElement("p");
    p.className = "muted";
    p.textContent = "Ask a question about decisions, action items, or details from this meeting.";
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
    showApp();
    await loadMeetings();
  } catch (err) {
    els.loginError.textContent = err.message || "Login failed";
    els.loginError.classList.remove("hidden");
  }
});

els.logoutBtn.addEventListener("click", async () => {
  await fetch("/api/auth/logout", { method: "POST", credentials: "same-origin" });
  state.selectedId = null;
  state.selectedMeeting = null;
  showLogin();
});

els.themeToggleBtn.addEventListener("click", toggleTheme);

let searchTimer = null;
els.searchInput.addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => loadMeetings(els.searchInput.value), 220);
});

document.querySelectorAll(".tab").forEach((btn) => {
  btn.addEventListener("click", () => switchTab(btn.dataset.tab));
});

els.titleInput.addEventListener("blur", async () => {
  if (!state.selectedMeeting) return;
  const nextTitle = els.titleInput.value.trim();
  if (!nextTitle || nextTitle === state.selectedMeeting.title) return;
  await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}`, {
    method: "PATCH",
    body: JSON.stringify({ title: nextTitle }),
  });
  showToast("Title saved");
  await loadMeetings(els.searchInput.value);
});

els.saveNotesBtn.addEventListener("click", async () => {
  if (!state.selectedId) return;
  await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}`, {
    method: "PATCH",
    body: JSON.stringify({ manual_notes: els.manualNotesInput.value }),
  });
  showToast("Notes saved");
  await loadMeetingDetail(state.selectedId, { silent: true });
});

async function triggerResummarize(includeNotes) {
  if (!state.selectedId) return;
  const body = {
    custom_instructions: els.customInstructionsInput.value.trim() || null,
  };
  if (includeNotes) {
    body.manual_notes = els.manualNotesInput.value;
  }
  await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}/resummarize`, {
    method: "POST",
    body: JSON.stringify(body),
  });
  showToast("Re-summarizing...");
  switchTab("summary");
  await loadMeetingDetail(state.selectedId, { silent: true });
}

els.resummarizeBtn.addEventListener("click", () => triggerResummarize(false));
els.saveResummarizeBtn.addEventListener("click", () => triggerResummarize(true));

els.retryBtn.addEventListener("click", async () => {
  if (!state.selectedId) return;
  await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}/retry`, {
    method: "POST",
  });
  showToast("Retry queued");
  await loadMeetingDetail(state.selectedId, { silent: true });
});

els.copyMdBtn.addEventListener("click", async () => {
  if (!state.selectedId) return;
  const resp = await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}/export.md`);
  const md = await resp.text();
  await navigator.clipboard.writeText(md);
  showToast("Markdown copied");
});

els.downloadMdBtn.addEventListener("click", () => {
  if (!state.selectedId) return;
  window.location.href = `/api/meetings/${encodeURIComponent(state.selectedId)}/export.md`;
});

els.deleteBtn.addEventListener("click", async () => {
  if (!state.selectedId) return;
  if (!confirm("Delete this meeting permanently?")) return;
  await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}`, {
    method: "DELETE",
  });
  stopPolling();
  state.selectedId = null;
  state.selectedMeeting = null;
  els.detailView.classList.add("hidden");
  els.emptyState.classList.remove("hidden");
  showToast("Meeting deleted");
  await loadMeetings(els.searchInput.value);
});

els.chatForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  if (!state.selectedId) return;
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
  await apiFetch(`/api/meetings/${encodeURIComponent(state.selectedId)}/chat`, {
    method: "DELETE",
  });
  renderChat([]);
  showToast("Chat cleared");
});

initTheme();
checkSession();
