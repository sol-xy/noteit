"use strict";

(function () {
  const MIME_CANDIDATES = [
    "audio/mp4;codecs=mp4a.40.2",
    "audio/mp4",
    "audio/webm;codecs=opus",
    "audio/webm",
    "",
  ];

  function isSupported() {
    return Boolean(
      typeof window !== "undefined" &&
        navigator.mediaDevices &&
        typeof navigator.mediaDevices.getUserMedia === "function" &&
        typeof window.MediaRecorder === "function"
    );
  }

  function pickMimeType() {
    if (typeof window.MediaRecorder !== "function") return "";
    if (typeof window.MediaRecorder.isTypeSupported !== "function") return "";
    for (const candidate of MIME_CANDIDATES) {
      if (!candidate) return "";
      try {
        if (window.MediaRecorder.isTypeSupported(candidate)) {
          return candidate;
        }
      } catch (_) {
        // Continue checking fallbacks.
      }
    }
    return "";
  }

  function extensionForMime(mimeType) {
    const lower = String(mimeType || "").toLowerCase();
    if (lower.includes("mp4") || lower.includes("aac") || lower.includes("m4a")) {
      return ".m4a";
    }
    if (lower.includes("webm")) return ".webm";
    if (lower.includes("ogg") || lower.includes("opus")) return ".ogg";
    if (lower.includes("wav")) return ".wav";
    return ".bin";
  }

  function createMediaRecorder(stream, preferredMime) {
    const attempts = [];
    if (preferredMime) {
      attempts.push({ mimeType: preferredMime, audioBitsPerSecond: 32000 });
      attempts.push({ mimeType: preferredMime });
    }
    attempts.push({ audioBitsPerSecond: 32000 });
    attempts.push(undefined);

    let lastErr = null;
    for (const opts of attempts) {
      try {
        return opts ? new window.MediaRecorder(stream, opts) : new window.MediaRecorder(stream);
      } catch (err) {
        lastErr = err;
      }
    }
    throw lastErr || new Error("Unable to initialize audio recorder");
  }

  let session = null;

  function clearTimersAndAudio(s) {
    if (s.durTimer) {
      clearInterval(s.durTimer);
      s.durTimer = null;
    }
    if (s.ampTimer) {
      clearInterval(s.ampTimer);
      s.ampTimer = null;
    }
    if (s.audioCtx) {
      try {
        s.audioCtx.close();
      } catch (_) {
        // Ignore AudioContext close error.
      }
      s.audioCtx = null;
    }
    if (s.stream) {
      try {
        s.stream.getTracks().forEach((t) => t.stop());
      } catch (_) {
        // Ignore track stop error.
      }
      s.stream = null;
    }
  }

  async function releaseWakeLock(s) {
    if (s.wakeLock) {
      try {
        await s.wakeLock.release();
      } catch (_) {
        // Ignore release errors.
      }
      s.wakeLock = null;
    }
    if (s.callbacks && typeof s.callbacks.onWakeLockChange === "function") {
      s.callbacks.onWakeLockChange(false);
    }
  }

  function removeListeners(s) {
    if (s.track && s.onTrackEnded) {
      s.track.removeEventListener("ended", s.onTrackEnded);
    }
    if (s.onVisibilityChange) {
      document.removeEventListener("visibilitychange", s.onVisibilityChange);
    }
  }

  function currentElapsedSeconds(s) {
    let totalMs = s.elapsedMs;
    if (s.state === "recording" && s.segmentStartMs !== null) {
      totalMs += Date.now() - s.segmentStartMs;
    }
    return Math.max(0, totalMs / 1000);
  }

  function flushSegmentElapsed(s) {
    if (s.segmentStartMs !== null) {
      s.elapsedMs += Date.now() - s.segmentStartMs;
      s.segmentStartMs = null;
    }
  }

  async function acquireWakeLock(s) {
    if (!navigator.wakeLock || typeof navigator.wakeLock.request !== "function") {
      return false;
    }
    try {
      const sentinel = await navigator.wakeLock.request("screen");
      if (session !== s || s.ending) {
        sentinel.release().catch(() => {});
        return false;
      }
      s.wakeLock = sentinel;
      sentinel.addEventListener("release", () => {
        if (s.wakeLock === sentinel) {
          s.wakeLock = null;
          if (s.callbacks && typeof s.callbacks.onWakeLockChange === "function") {
            s.callbacks.onWakeLockChange(false);
          }
        }
      });
      if (s.callbacks && typeof s.callbacks.onWakeLockChange === "function") {
        s.callbacks.onWakeLockChange(true);
      }
      return true;
    } catch (_) {
      if (s.callbacks && typeof s.callbacks.onWakeLockChange === "function") {
        s.callbacks.onWakeLockChange(false);
      }
      return false;
    }
  }

  async function finalizeRecorder(s) {
    flushSegmentElapsed(s);
    const elapsedSeconds = currentElapsedSeconds(s);
    const recorder = s.recorder;

    if (recorder && recorder.state !== "inactive") {
      await new Promise((resolve) => {
        let settled = false;
        const done = () => {
          if (settled) return;
          settled = true;
          resolve();
        };
        const timeout = setTimeout(done, 3000);
        recorder.addEventListener(
          "stop",
          () => {
            clearTimeout(timeout);
            done();
          },
          { once: true }
        );
        try {
          recorder.stop();
        } catch (_) {
          clearTimeout(timeout);
          done();
        }
      });
    }

    await Promise.allSettled(s.pendingWrites);
    removeListeners(s);
    clearTimersAndAudio(s);
    await releaseWakeLock(s);
    s.state = "idle";
    if (session === s) {
      session = null;
    }

    const mimeType = s.mimeType || "audio/mp4";
    const extension = extensionForMime(mimeType);
    return {
      elapsedSeconds,
      mimeType,
      extension,
      filename: `${s.uploadId}${extension}`,
    };
  }

  async function start(uploadId, callbacks = {}) {
    if (!isSupported()) {
      throw new Error("Audio recording is not supported in this browser.");
    }
    if (session) {
      await discard();
    }

    // Call getUserMedia and wakeLock synchronously from the user tap gesture for iOS WebKit.
    const streamPromise = navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
      },
    });
    const wakeLockPromise =
      navigator.wakeLock && typeof navigator.wakeLock.request === "function"
        ? navigator.wakeLock.request("screen").catch(() => null)
        : Promise.resolve(null);

    let stream;
    try {
      stream = await streamPromise;
    } catch (err) {
      wakeLockPromise.then((wl) => {
        if (wl) wl.release().catch(() => {});
      });
      throw err;
    }
    const initialWakeLock = await wakeLockPromise;

    const preferredMime = pickMimeType();
    let recorder;
    try {
      recorder = createMediaRecorder(stream, preferredMime);
    } catch (err) {
      stream.getTracks().forEach((t) => t.stop());
      if (initialWakeLock) initialWakeLock.release().catch(() => {});
      throw err;
    }

    const resolvedMime = recorder.mimeType || preferredMime || "audio/mp4";
    const s = {
      uploadId,
      callbacks,
      stream,
      track: stream.getAudioTracks()[0] || null,
      recorder,
      mimeType: resolvedMime,
      seq: 0,
      pendingWrites: [],
      elapsedMs: 0,
      segmentStartMs: Date.now(),
      state: "recording",
      ending: false,
      durTimer: null,
      ampTimer: null,
      audioCtx: null,
      wakeLock: initialWakeLock,
      onTrackEnded: null,
      onVisibilityChange: null,
    };
    session = s;

    if (initialWakeLock) {
      initialWakeLock.addEventListener("release", () => {
        if (s.wakeLock === initialWakeLock) {
          s.wakeLock = null;
          if (callbacks.onWakeLockChange) callbacks.onWakeLockChange(false);
        }
      });
      if (callbacks.onWakeLockChange) callbacks.onWakeLockChange(true);
    } else if (callbacks.onWakeLockChange) {
      callbacks.onWakeLockChange(false);
    }

    recorder.addEventListener("dataavailable", (event) => {
      if (event.data && event.data.size > 0) {
        if (!s.mimeType && event.data.type) {
          s.mimeType = event.data.type;
        }
        const seq = s.seq++;
        const writePromise = window.NoteItDB.appendAudioChunk(
          s.uploadId,
          seq,
          event.data
        );
        s.pendingWrites.push(writePromise);
      }
    });

    // Level meter via Web Audio AnalyserNode (optional; recording still works if unavailable).
    try {
      const AudioCtx = window.AudioContext || window.webkitAudioContext;
      if (AudioCtx) {
        const audioCtx = new AudioCtx();
        if (audioCtx.state === "suspended") {
          audioCtx.resume().catch(() => {});
        }
        const source = audioCtx.createMediaStreamSource(stream);
        const analyser = audioCtx.createAnalyser();
        analyser.fftSize = 256;
        source.connect(analyser);
        s.audioCtx = audioCtx;

        const data = new Uint8Array(analyser.fftSize);
        s.ampTimer = setInterval(() => {
          if (s.state !== "recording") {
            if (callbacks.onAmplitude) callbacks.onAmplitude(0);
            return;
          }
          analyser.getByteTimeDomainData(data);
          let sumSq = 0;
          for (let i = 0; i < data.length; i++) {
            const norm = (data[i] - 128) / 128;
            sumSq += norm * norm;
          }
          const rms = Math.sqrt(sumSq / data.length);
          const level = Math.min(1, Math.max(0, rms * 3.5));
          if (callbacks.onAmplitude) callbacks.onAmplitude(level);
        }, 120);
      }
    } catch (_) {
      // Proceed without amplitude visualization.
    }

    s.durTimer = setInterval(() => {
      if (s.state === "recording" && callbacks.onDuration) {
        callbacks.onDuration(currentElapsedSeconds(s));
      }
    }, 250);

    s.onTrackEnded = async () => {
      if (s.ending) return;
      s.ending = true;
      const result = await finalizeRecorder(s);
      if (callbacks.onInterrupted) {
        callbacks.onInterrupted(result);
      }
    };

    if (s.track) {
      s.track.addEventListener("ended", s.onTrackEnded);
    }

    s.onVisibilityChange = () => {
      if (s.ending) return;
      if (document.visibilityState === "hidden") {
        if (s.recorder && s.recorder.state === "recording") {
          try {
            if (typeof s.recorder.requestData === "function") {
              s.recorder.requestData();
            }
          } catch (_) {
            // Ignore requestData errors on background transition.
          }
        }
      } else if (document.visibilityState === "visible" && s.state === "recording") {
        acquireWakeLock(s);
      }
    };
    document.addEventListener("visibilitychange", s.onVisibilityChange);

    recorder.start(5000);
    if (callbacks.onStateChange) callbacks.onStateChange("recording");

    const ext = extensionForMime(s.mimeType);
    return {
      mimeType: s.mimeType,
      extension: ext,
      filename: `${uploadId}${ext}`,
      wakeLockActive: Boolean(s.wakeLock),
    };
  }

  function pause() {
    if (!session || session.state !== "recording") return;
    const s = session;
    try {
      if (s.recorder && s.recorder.state === "recording") {
        s.recorder.pause();
      }
    } catch (_) {
      // Ignore if browser refuses pause.
    }
    flushSegmentElapsed(s);
    s.state = "paused";
    if (s.callbacks.onDuration) s.callbacks.onDuration(currentElapsedSeconds(s));
    if (s.callbacks.onAmplitude) s.callbacks.onAmplitude(0);
    if (s.callbacks.onStateChange) s.callbacks.onStateChange("paused");
  }

  function resume() {
    if (!session || session.state !== "paused") return;
    const s = session;
    try {
      if (s.recorder && s.recorder.state === "paused") {
        s.recorder.resume();
      }
    } catch (_) {
      // Ignore if browser refuses resume.
    }
    s.segmentStartMs = Date.now();
    s.state = "recording";
    acquireWakeLock(s);
    if (s.callbacks.onStateChange) s.callbacks.onStateChange("recording");
  }

  async function stop() {
    if (!session) return null;
    const s = session;
    if (s.ending) return null;
    s.ending = true;
    return await finalizeRecorder(s);
  }

  async function discard() {
    if (!session) return;
    const s = session;
    s.ending = true;
    await finalizeRecorder(s);
  }

  function getState() {
    return session ? session.state : "idle";
  }

  window.NoteItRecorder = {
    isSupported,
    start,
    pause,
    resume,
    stop,
    discard,
    getState,
  };
})();
