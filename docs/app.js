/* Explicit shared poll/feedback saves. Downloads and app use remain free. */
(() => {
  "use strict";
  const telemetry = window.LanternTelemetry;
  const toggle = document.querySelector(".menu-toggle");
  const nav = document.getElementById("nav-links");
  function setMenu(open) {
    if (!toggle || !nav) return;
    toggle.setAttribute("aria-expanded", String(open));
    toggle.setAttribute("aria-label", open ? "Close navigation" : "Open navigation");
    nav.dataset.open = String(open);
  }
  if (toggle && nav) {
    toggle.addEventListener("click", () => setMenu(toggle.getAttribute("aria-expanded") !== "true"));
    nav.querySelectorAll("a, button").forEach((element) => element.addEventListener("click", () => setMenu(false)));
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && toggle.getAttribute("aria-expanded") === "true") { setMenu(false); toggle.focus(); }
    });
    document.addEventListener("click", (event) => { if (!event.target.closest(".navigation")) setMenu(false); });
  }

  const dialogs = [...document.querySelectorAll("dialog")];
  const fragments = {"support-dialog": "#interest", "feedback-dialog": "#feedback"};
  function replaceFragment(fragment) {
    try { history.replaceState(null, "", window.location.pathname + window.location.search + fragment); }
    catch { /* Dialogs remain usable when history updates are blocked. */ }
  }
  function openDialog(dialog, updateURL = true) {
    if (!dialog || dialog.open) return;
    dialogs.forEach((other) => { if (other.open) other.close(); });
    dialog.showModal();
    if (updateURL) replaceFragment(fragments[dialog.id]);
    if (dialog.id === "support-dialog" && telemetry) void telemetry.recordEvent("support_open");
  }
  dialogs.forEach((dialog) => {
    dialog.querySelectorAll(".dialog-close, [data-close-dialog]").forEach((button) => button.addEventListener("click", () => dialog.close()));
    dialog.addEventListener("close", () => { if (window.location.hash === fragments[dialog.id]) replaceFragment(""); });
    dialog.addEventListener("click", (event) => {
      if (event.target !== dialog) return;
      const rect = dialog.getBoundingClientRect();
      if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close();
    });
  });
  document.querySelectorAll("[data-support]").forEach((button) => button.addEventListener("click", () => openDialog(document.getElementById("support-dialog"))));
  document.querySelectorAll("[data-feedback]").forEach((button) => button.addEventListener("click", () => openDialog(document.getElementById("feedback-dialog"))));
  function openFragment() {
    if (window.location.hash === "#feedback") openDialog(document.getElementById("feedback-dialog"), false);
    if (window.location.hash === "#interest") openDialog(document.getElementById("support-dialog"), false);
  }
  window.addEventListener("hashchange", openFragment);
  openFragment();

  async function post(path, payload) {
    if (!telemetry) throw new Error("Service unavailable");
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch(`${telemetry.API_ORIGIN}${path}`, {
        method: "POST", mode: "cors", credentials: "omit",
        headers: {"Content-Type": "application/json"}, body: JSON.stringify(payload), signal: controller.signal,
      });
      if (!response.ok) throw new Error("Save not confirmed");
      const result = await response.json();
      if (!result || result.ok !== true) throw new Error("Save not confirmed");
      return result;
    } finally { window.clearTimeout(timeout); }
  }
  function status(element, text, phase) {
    element.textContent = text;
    element.dataset.state = phase;
  }
  function busy(form, value) {
    form.setAttribute("aria-busy", String(value));
    form.querySelectorAll("fieldset, select, textarea, input, button[type=submit]").forEach((control) => { control.disabled = value; });
  }
  function connectForm(form, endpoint, readValues, allowed, onSuccess, statusElement, pendingText, failureText) {
    if (!form) return;
    let pending = null;
    let sending = false;
    let succeeded = false;
    form.addEventListener("input", () => {
      if (sending) return;
      if (succeeded) {
        succeeded = false;
        form.querySelector("[data-submit]").disabled = false;
        status(statusElement, "Your changes are not saved yet.", "");
      } else if (statusElement.dataset.state === "error") status(statusElement, "Your entries are still here. You can retry when ready.", "");
    });
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (sending || succeeded || !form.reportValidity()) return;
      const values = readValues(new FormData(form));
      if (!allowed(values)) {
        status(statusElement, "Please complete both choices or check the message length before sending.", "error");
        return;
      }
      if (!telemetry) { status(statusElement, failureText, "error"); return; }
      const fingerprint = JSON.stringify(values);
      if (!pending || pending.fingerprint !== fingerprint) pending = {fingerprint,
        payload: {dataset: telemetry.getDataset(), eventId: telemetry.uuid(), visitorId: telemetry.getVisitorId(), ...values}};
      sending = true;
      busy(form, true);
      status(statusElement, pendingText, "pending");
      try {
        const result = await post(endpoint, pending.payload);
        const confirmation = onSuccess(result);
        succeeded = true;
        status(statusElement, confirmation, "success");
      } catch {
        status(statusElement, failureText, "error");
      } finally {
        sending = false;
        busy(form, false);
        form.querySelector("[data-submit]").disabled = succeeded;
      }
    });
  }
  connectForm(document.getElementById("interest-form"), "/api/poll",
    (data) => ({usefulness: data.get("usefulness"), intent: data.get("intent")}),
    (value) => ["yes", "partly", "not_yet"].includes(value.usefulness) && ["yes", "maybe", "no"].includes(value.intent),
    () => "Thank you. Your response was saved for the project owner to review. No payment was made.",
    document.getElementById("poll-status"), "Saving your response…",
    "We couldn’t confirm a save. Your choices are still here. Please try again; retries will not create a duplicate response.");
  connectForm(document.getElementById("feedback-form"), "/api/feedback",
    (data) => ({kind: data.get("kind"), message: String(data.get("message") || "").trim()}),
    (value) => ["thanks", "idea", "bug"].includes(value.kind) && value.message.length >= 3 && value.message.length <= 4000,
    (result) => {
      if (typeof result.id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(result.id)) throw new Error("Missing ticket ID");
      return `Thank you. Your feedback was sent. Ticket ID: ${result.id}. Keep this ID if you refer to your message later.`;
    }, document.getElementById("feedback-status"), "Sending your feedback…",
    "We couldn’t confirm that your feedback was saved. Your message is still here. Please retry; the same message keeps its ticket request ID.");
})();
