/* Optional support never gates downloading or using Lantern. */
const LANTERN_CONFIG = Object.freeze({
  supportUrl: "", // Configure a verified HTTPS tip URL when one is available.
  suggestedTip: 2.99,
});

(() => {
  "use strict";
  const toggle = document.querySelector(".menu-toggle");
  const nav = document.getElementById("nav-links");
  const setMenu = (open) => {
    toggle.setAttribute("aria-expanded", String(open));
    toggle.setAttribute("aria-label", open ? "Close navigation" : "Open navigation");
    nav.dataset.open = String(open);
  };
  toggle.addEventListener("click", () => setMenu(toggle.getAttribute("aria-expanded") !== "true"));
  nav.querySelectorAll("a, button").forEach((element) => element.addEventListener("click", () => setMenu(false)));
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && toggle.getAttribute("aria-expanded") === "true") { setMenu(false); toggle.focus(); }
  });
  document.addEventListener("click", (event) => {
    if (!event.target.closest(".navigation")) setMenu(false);
  });

  const dialogs = [...document.querySelectorAll("dialog")];
  const openDialog = (dialog) => {
    dialogs.forEach((other) => { if (other.open && other !== dialog) other.close(); });
    if (!dialog.open) dialog.showModal();
  };
  dialogs.forEach((dialog) => {
    dialog.querySelectorAll(".dialog-close, [data-close-dialog]").forEach((button) => button.addEventListener("click", () => dialog.close()));
    dialog.addEventListener("click", (event) => {
      if (event.target !== dialog) return;
      const rect = dialog.getBoundingClientRect();
      if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close();
    });
  });

  let supportUrl = "";
  if (LANTERN_CONFIG.supportUrl) {
    try {
      const url = new URL(LANTERN_CONFIG.supportUrl);
      if (url.protocol === "https:") supportUrl = url.href;
    } catch { /* Invalid links leave the honest support-soon dialog in place. */ }
  }
  if (supportUrl) document.querySelector("[data-support-note]").textContent = "Entirely optional. Review the amount and terms before paying.";
  document.querySelectorAll("[data-support]").forEach((button) => button.addEventListener("click", () => {
    if (supportUrl) { window.location.assign(supportUrl); return; }
    openDialog(document.getElementById("support-dialog"));
  }));
  document.querySelectorAll("[data-feedback]").forEach((button) => button.addEventListener("click", () => {
    document.getElementById("feedback-status").textContent = "";
    openDialog(document.getElementById("feedback-dialog"));
  }));
  document.getElementById("feedback-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const field = document.getElementById("feedback-text");
    const message = field.value.trim();
    if (message.length < 3) { field.setCustomValidity("Please write at least three characters."); field.reportValidity(); return; }
    field.setCustomValidity("");
    const text = `Lantern VNC feedback\nPrepared: ${new Date().toISOString()}\n\n${message}\n\nThis file was saved locally. No feedback was sent automatically.\n`;
    const url = URL.createObjectURL(new Blob([text], {type: "text/plain;charset=utf-8"}));
    const link = document.createElement("a");
    link.href = url; link.download = "Lantern-VNC-feedback.txt";
    document.body.appendChild(link); link.click(); link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 30000);
    document.getElementById("feedback-status").textContent = "Feedback file prepared. Share the downloaded text file with the developer; nothing has been sent.";
  });
  document.getElementById("feedback-text").addEventListener("input", (event) => event.target.setCustomValidity(""));
})();
