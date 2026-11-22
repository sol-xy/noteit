"use strict";

(function () {
  const DB_NAME = "noteit_pwa_v1";
  const DB_VERSION = 1;
  const STORES = ["meetings", "chats", "pending_uploads", "audio_chunks"];

  let dbPromise = null;

  function hasIndexedDb() {
    return typeof window !== "undefined" && typeof window.indexedDB !== "undefined";
  }

  function openDb() {
    if (!hasIndexedDb()) {
      return Promise.resolve(null);
    }
    if (dbPromise) {
      return dbPromise;
    }
    dbPromise = new Promise((resolve) => {
      try {
        const req = window.indexedDB.open(DB_NAME, DB_VERSION);
        req.onupgradeneeded = (event) => {
          const db = event.target.result;
          if (!db.objectStoreNames.contains("meetings")) {
            db.createObjectStore("meetings", { keyPath: "id" });
          }
          if (!db.objectStoreNames.contains("chats")) {
            db.createObjectStore("chats", { keyPath: "meeting_id" });
          }
          if (!db.objectStoreNames.contains("pending_uploads")) {
            db.createObjectStore("pending_uploads", { keyPath: "id" });
          }
          if (!db.objectStoreNames.contains("audio_chunks")) {
            const chunks = db.createObjectStore("audio_chunks", {
              keyPath: ["upload_id", "seq"],
            });
            chunks.createIndex("by_upload_id", "upload_id", { unique: false });
          }
        };
        req.onsuccess = () => {
          const db = req.result;
          db.onversionchange = () => {
            db.close();
            dbPromise = null;
          };
          resolve(db);
        };
        req.onerror = () => {
          dbPromise = null;
          resolve(null);
        };
        req.onblocked = () => {
          dbPromise = null;
          resolve(null);
        };
      } catch (_) {
        dbPromise = null;
        resolve(null);
      }
    });
    return dbPromise;
  }

  function reqToPromise(req) {
    return new Promise((resolve, reject) => {
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error || new Error("IndexedDB request failed"));
    });
  }

  function txDone(tx) {
    return new Promise((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error || new Error("IndexedDB transaction failed"));
      tx.onabort = () => reject(tx.error || new Error("IndexedDB transaction aborted"));
    });
  }

  function mergeMeetingRecords(existing, incoming) {
    if (!existing) return { ...incoming };
    const merged = { ...existing, ...incoming };
    if (!incoming.transcript && existing.transcript) {
      merged.transcript = existing.transcript;
    }
    if (
      (!Array.isArray(incoming.segments) || incoming.segments.length === 0) &&
      Array.isArray(existing.segments) &&
      existing.segments.length > 0
    ) {
      merged.segments = existing.segments;
    }
    return merged;
  }

  async function upsertMeetings(list) {
    if (!Array.isArray(list) || list.length === 0) return;
    try {
      const db = await openDb();
      if (!db) return;
      const tx = db.transaction("meetings", "readwrite");
      const store = tx.objectStore("meetings");
      for (const item of list) {
        if (!item || !item.id) continue;
        const existing = await reqToPromise(store.get(item.id));
        store.put(mergeMeetingRecords(existing, item));
      }
      await txDone(tx);
    } catch (_) {
      // Degrade gracefully when storage fails.
    }
  }

  async function upsertMeetingDetail(meeting) {
    if (!meeting || !meeting.id) return;
    try {
      const db = await openDb();
      if (!db) return;
      const tx = db.transaction("meetings", "readwrite");
      const store = tx.objectStore("meetings");
      const existing = await reqToPromise(store.get(meeting.id));
      const merged = mergeMeetingRecords(existing, meeting);
      if (Array.isArray(meeting.segments)) {
        merged.segments = meeting.segments;
      }
      if (typeof meeting.transcript === "string") {
        merged.transcript = meeting.transcript;
      }
      store.put(merged);
      await txDone(tx);
    } catch (_) {
      // Ignore storage error.
    }
  }

  async function listMeetings(query = "") {
    try {
      const db = await openDb();
      if (!db) return [];
      const tx = db.transaction("meetings", "readonly");
      const store = tx.objectStore("meetings");
      const all = (await reqToPromise(store.getAll())) || [];
      const q = String(query || "").trim().toLowerCase();
      const filtered = q
        ? all.filter((m) => {
            const haystack = [
              m.title || "",
              m.manual_notes || "",
              m.summary || "",
              m.transcript || "",
            ]
              .join("\n")
              .toLowerCase();
            return haystack.includes(q);
          })
        : all;
      filtered.sort((a, b) =>
        String(b.created_at || "").localeCompare(String(a.created_at || ""))
      );
      return filtered;
    } catch (_) {
      return [];
    }
  }

  async function getMeeting(id) {
    if (!id) return null;
    try {
      const db = await openDb();
      if (!db) return null;
      const tx = db.transaction("meetings", "readonly");
      const result = await reqToPromise(tx.objectStore("meetings").get(id));
      return result || null;
    } catch (_) {
      return null;
    }
  }

  async function deleteMeeting(id) {
    if (!id) return;
    try {
      const db = await openDb();
      if (!db) return;
      const tx = db.transaction(["meetings", "chats"], "readwrite");
      tx.objectStore("meetings").delete(id);
      tx.objectStore("chats").delete(id);
      await txDone(tx);
    } catch (_) {
      // Ignore storage error.
    }
  }

  async function saveChat(meetingId, messages) {
    if (!meetingId) return;
    try {
      const db = await openDb();
      if (!db) return;
      const tx = db.transaction("chats", "readwrite");
      tx.objectStore("chats").put({
        meeting_id: meetingId,
        messages: Array.isArray(messages) ? messages : [],
      });
      await txDone(tx);
    } catch (_) {
      // Ignore storage error.
    }
  }

  async function getChat(meetingId) {
    if (!meetingId) return [];
    try {
      const db = await openDb();
      if (!db) return [];
      const tx = db.transaction("chats", "readonly");
      const row = await reqToPromise(tx.objectStore("chats").get(meetingId));
      return row && Array.isArray(row.messages) ? row.messages : [];
    } catch (_) {
      return [];
    }
  }

  async function savePendingUpload(record) {
    if (!record || !record.id) return null;
    try {
      const db = await openDb();
      if (!db) return record;
      const tx = db.transaction("pending_uploads", "readwrite");
      tx.objectStore("pending_uploads").put(record);
      await txDone(tx);
      return record;
    } catch (_) {
      return record;
    }
  }

  async function updatePendingUpload(id, patch) {
    if (!id) return null;
    try {
      const db = await openDb();
      if (!db) return null;
      const tx = db.transaction("pending_uploads", "readwrite");
      const store = tx.objectStore("pending_uploads");
      const existing = await reqToPromise(store.get(id));
      if (!existing) return null;
      const updated = {
        ...existing,
        ...patch,
        updated_at: new Date().toISOString(),
      };
      store.put(updated);
      await txDone(tx);
      return updated;
    } catch (_) {
      return null;
    }
  }

  async function getPendingUpload(id) {
    if (!id) return null;
    try {
      const db = await openDb();
      if (!db) return null;
      const tx = db.transaction("pending_uploads", "readonly");
      const row = await reqToPromise(tx.objectStore("pending_uploads").get(id));
      return row || null;
    } catch (_) {
      return null;
    }
  }

  async function listPendingUploads() {
    try {
      const db = await openDb();
      if (!db) return [];
      const tx = db.transaction("pending_uploads", "readonly");
      const rows = (await reqToPromise(tx.objectStore("pending_uploads").getAll())) || [];
      rows.sort((a, b) =>
        String(b.created_at || "").localeCompare(String(a.created_at || ""))
      );
      return rows;
    } catch (_) {
      return [];
    }
  }

  async function deletePendingUpload(id) {
    if (!id) return;
    try {
      const db = await openDb();
      if (!db) return;
      const tx = db.transaction(["pending_uploads", "audio_chunks"], "readwrite");
      tx.objectStore("pending_uploads").delete(id);
      const chunkStore = tx.objectStore("audio_chunks");
      const idx = chunkStore.index("by_upload_id");
      await new Promise((resolve, reject) => {
        const cursorReq = idx.openKeyCursor(IDBKeyRange.only(id));
        cursorReq.onsuccess = (event) => {
          const cursor = event.target.result;
          if (!cursor) {
            resolve();
            return;
          }
          chunkStore.delete(cursor.primaryKey);
          cursor.continue();
        };
        cursorReq.onerror = () => reject(cursorReq.error);
      });
      await txDone(tx);
    } catch (_) {
      // Ignore storage error.
    }
  }

  async function appendAudioChunk(uploadId, seq, blob) {
    if (!uploadId || !blob) return false;
    try {
      const db = await openDb();
      if (!db) return false;
      const tx = db.transaction("audio_chunks", "readwrite");
      tx.objectStore("audio_chunks").put({
        upload_id: uploadId,
        seq,
        blob,
      });
      await txDone(tx);
      return true;
    } catch (_) {
      return false;
    }
  }

  async function countAudioChunks(uploadId) {
    if (!uploadId) return 0;
    try {
      const db = await openDb();
      if (!db) return 0;
      const tx = db.transaction("audio_chunks", "readonly");
      const idx = tx.objectStore("audio_chunks").index("by_upload_id");
      const count = await reqToPromise(idx.count(IDBKeyRange.only(uploadId)));
      return Number(count || 0);
    } catch (_) {
      return 0;
    }
  }

  async function assembleAudioBlob(uploadId, mimeType) {
    if (!uploadId) return null;
    try {
      const db = await openDb();
      if (!db) return null;
      const tx = db.transaction("audio_chunks", "readonly");
      const idx = tx.objectStore("audio_chunks").index("by_upload_id");
      const entries = (await reqToPromise(idx.getAll(IDBKeyRange.only(uploadId)))) || [];
      if (entries.length === 0) return null;
      entries.sort((a, b) => a.seq - b.seq);
      const blobs = entries.map((e) => e.blob).filter(Boolean);
      if (blobs.length === 0) return null;
      const resolvedType = mimeType || blobs[0].type || "audio/mp4";
      return new Blob(blobs, { type: resolvedType });
    } catch (_) {
      return null;
    }
  }

  async function recoverInterruptedRecordings() {
    try {
      const items = await listPendingUploads();
      for (const item of items) {
        if (item.status === "recording" || item.status === "uploading") {
          const count = await countAudioChunks(item.id);
          if (count > 0) {
            await updatePendingUpload(item.id, {
              status: "pending",
              error_message:
                item.status === "recording"
                  ? "Recording was interrupted before finishing. Tap Upload Now to process."
                  : "",
            });
          } else {
            await deletePendingUpload(item.id);
          }
        }
      }
      return await listPendingUploads();
    } catch (_) {
      return [];
    }
  }

  async function clearAll() {
    try {
      const db = await openDb();
      if (!db) return;
      const tx = db.transaction(STORES, "readwrite");
      for (const name of STORES) {
        tx.objectStore(name).clear();
      }
      await txDone(tx);
    } catch (_) {
      // Ignore storage error.
    }
  }

  window.NoteItDB = {
    upsertMeetings,
    upsertMeetingDetail,
    listMeetings,
    getMeeting,
    deleteMeeting,
    saveChat,
    getChat,
    savePendingUpload,
    updatePendingUpload,
    getPendingUpload,
    listPendingUploads,
    deletePendingUpload,
    appendAudioChunk,
    countAudioChunks,
    assembleAudioBlob,
    recoverInterruptedRecordings,
    clearAll,
  };
})();
