/* First-party aggregate website counts. No cookies or fingerprinting. */
(() => {
  "use strict";
  const API_ORIGIN = "https://lantern-vnc-mac.fts227.chatgpt.site";
  const hostname = window.location.hostname.toLowerCase();
  const local = ["localhost", "127.0.0.1", "::1", "[::1]"].includes(hostname);
  const dataset = local && new URLSearchParams(window.location.search).get("qa") === "1" ? "qa" : "production";
  const optOutKey = "lantern.telemetry.optOut.v1";
  const visitorKey = `lantern.visitor.${dataset}.v1`;
  const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  let memoryVisitor = "";
  let memoryOptOut = false;
  let preferenceSaved = true;
  let visited = false;

  function storages() {
    const result = [];
    for (const name of ["localStorage", "sessionStorage"]) {
      try { if (window[name]) result.push(window[name]); } catch { /* Storage may be blocked. */ }
    }
    return result;
  }
  function read(key) {
    for (const storage of storages()) {
      try { const value = storage.getItem(key); if (value !== null) return value; } catch { /* Use another store or memory. */ }
    }
    return null;
  }
  function write(key, value) {
    for (const storage of storages()) {
      try { storage.setItem(key, value); return true; } catch { /* Use another store or memory. */ }
    }
    return false;
  }
  function remove(key) {
    for (const storage of storages()) {
      try { storage.removeItem(key); } catch { /* Preference still applies in memory. */ }
    }
  }
  function uuid() {
    if (window.crypto && typeof window.crypto.randomUUID === "function") return window.crypto.randomUUID();
    const bytes = new Uint8Array(16);
    if (window.crypto && typeof window.crypto.getRandomValues === "function") window.crypto.getRandomValues(bytes);
    else for (let index = 0; index < bytes.length; index += 1) bytes[index] = Math.floor(Math.random() * 256);
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    const hex = [...bytes].map((value) => value.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }
  function privacySignal() {
    if (navigator.globalPrivacyControl === true) return "Global Privacy Control";
    const signals = [navigator.doNotTrack, window.doNotTrack, navigator.msDoNotTrack];
    if (signals.some((value) => ["1", "yes"].includes(String(value).toLowerCase()))) return "Do Not Track";
    return "";
  }
  function isTrackingEnabled() {
    return !privacySignal() && !memoryOptOut && read(optOutKey) !== "1";
  }
  function getVisitorId() {
    if (!isTrackingEnabled()) {
      // Explicit forms still work without retaining an automatic-count identifier.
      if (!memoryVisitor) memoryVisitor = uuid();
      return memoryVisitor;
    }
    const saved = read(visitorKey);
    if (saved && UUID_PATTERN.test(saved)) { memoryVisitor = saved; return saved; }
    if (!memoryVisitor) memoryVisitor = uuid();
    write(visitorKey, memoryVisitor);
    return memoryVisitor;
  }
  function sanitizedPath() {
    const name = window.location.pathname.split("/").filter(Boolean).pop() || "";
    if (["stats.html", "privacy.html"].includes(name)) return `/lantern-vnc/${name}`;
    return "/lantern-vnc/";
  }
  function referrerOrigin() {
    try { return document.referrer ? new URL(document.referrer).origin + "/" : ""; }
    catch { return ""; }
  }
  function campaign() {
    const params = new URLSearchParams(window.location.search);
    const clean = (name) => (params.get(name) || "").replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 80);
    return {source: clean("utm_source"), medium: clean("utm_medium"), campaign: clean("utm_campaign")};
  }
  async function sendEvent(payload, attempt = 0) {
    if (!isTrackingEnabled()) return false;
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 6000);
    let retry = false;
    try {
      const response = await fetch(`${API_ORIGIN}/api/events`, {
        method: "POST", mode: "cors", credentials: "omit", keepalive: true,
        headers: {"Content-Type": "application/json"}, body: JSON.stringify(payload), signal: controller.signal,
      });
      if (response.ok) return true;
      retry = response.status === 429 || response.status >= 500;
    } catch { retry = true; }
    finally { window.clearTimeout(timeout); }
    if (retry && attempt < 2 && isTrackingEnabled()) {
      // Retries reuse the same event UUID, so the shared service can deduplicate.
      await new Promise((resolve) => window.setTimeout(resolve, [800, 2000][attempt]));
      return sendEvent(payload, attempt + 1);
    }
    return false;
  }
  function recordEvent(type) {
    if (!["visit", "support_open", "download"].includes(type) || !isTrackingEnabled()) return Promise.resolve(false);
    const payload = {dataset, eventId: uuid(), visitorId: getVisitorId(), type,
      path: sanitizedPath(), referrer: referrerOrigin(), campaign: campaign()};
    return sendEvent(payload);
  }
  function recordVisit() {
    if (visited) return Promise.resolve(false);
    visited = true;
    return recordEvent("visit");
  }
  function setTrackingEnabled(enabled) {
    memoryOptOut = !enabled;
    if (enabled) remove(optOutKey);
    else {
      preferenceSaved = write(optOutKey, "1");
      remove("lantern.visitor.production.v1");
      remove("lantern.visitor.qa.v1");
      memoryVisitor = "";
    }
    updatePrivacyControls();
    return isTrackingEnabled();
  }
  function updatePrivacyControls() {
    const enabled = isTrackingEnabled();
    const signal = privacySignal();
    document.querySelectorAll("[data-tracking-status]").forEach((element) => {
      element.textContent = enabled ? "Automatic website counts are on for this browser." : "Automatic website counts are off for this browser.";
    });
    document.querySelectorAll("[data-signal-status]").forEach((element) => {
      element.textContent = signal ? `${signal} is enabled. We honor it; the controls here cannot override that browser signal.` : "No Global Privacy Control or Do Not Track opt-out signal was detected.";
    });
    document.querySelectorAll("[data-disable-tracking]").forEach((button) => { button.disabled = !enabled; });
    document.querySelectorAll("[data-enable-tracking]").forEach((button) => { button.disabled = enabled || Boolean(signal); });
    document.querySelectorAll("[data-storage-status]").forEach((element) => {
      element.textContent = memoryOptOut && !preferenceSaved
        ? "This browser blocked preference storage. Your choice applies to this open page; use browser Global Privacy Control or Do Not Track for a signal across visits. Explicit forms still work."
        : "Your preference is kept locally when browser storage allows it. Stopping counts affects future automatic events, not past aggregate counts. You can still explicitly send poll answers or feedback.";
    });
  }
  function initialize() {
    if (!isTrackingEnabled()) { remove("lantern.visitor.production.v1"); remove("lantern.visitor.qa.v1"); memoryVisitor = ""; }
    document.querySelectorAll("[data-qa-banner]").forEach((element) => { element.hidden = dataset !== "qa"; });
    document.querySelectorAll("[data-disable-tracking]").forEach((button) => button.addEventListener("click", () => setTrackingEnabled(false)));
    document.querySelectorAll("[data-enable-tracking]").forEach((button) => button.addEventListener("click", () => setTrackingEnabled(true)));
    document.addEventListener("click", (event) => {
      const link = event.target.closest && event.target.closest("a[href]");
      if (link && /\/Lantern-VNC-macOS\.zip(?:[?#]|$)/.test(link.href)) void recordEvent("download");
    });
    updatePrivacyControls();
    void recordVisit();
  }
  window.LanternTelemetry = Object.freeze({API_ORIGIN, uuid, getDataset: () => dataset,
    getVisitorId, isTrackingEnabled, recordEvent, recordVisit, setTrackingEnabled, privacySignal});
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initialize, {once: true});
  else initialize();
  window.addEventListener("storage", updatePrivacyControls);
})();
