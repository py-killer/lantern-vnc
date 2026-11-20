(() => {
  "use strict";
  const API_ORIGIN = window.location.origin;
  const isLocalhost = ["localhost", "127.0.0.1", "[::1]", "::1"].includes(window.location.hostname.toLowerCase());
  const dataset = isLocalhost && new URLSearchParams(window.location.search).get("qa") === "1" ? "qa" : "production";
  const formatCount = new Intl.NumberFormat(undefined, {maximumFractionDigits: 0});
  const byId = (id) => document.getElementById(id);
  let request = null;

  if (dataset === "qa") {
    byId("stats-qa").hidden = false;
    byId("stats-dataset").textContent = "Local QA counts";
  }

  function count(value) {
    if (!Number.isSafeInteger(value) || value < 0) throw new Error("invalid_snapshot");
    return value;
  }
  function validate(snapshot) {
    if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot)) throw new Error("invalid_snapshot");
    for (const key of ["visits", "visitors", "supportClicks", "downloads", "responses", "feedback"]) count(snapshot.totals?.[key]);
    for (const [property, keys] of [["usefulness", ["yes", "partly", "not_yet"]], ["intent", ["yes", "maybe", "no"]], ["feedbackKinds", ["thanks", "idea", "bug"]]]) {
      keys.forEach((key) => count(snapshot[property]?.[key]));
    }
    for (const [property, label] of [["sources", "source"], ["countries", "country"], ["campaigns", "campaign"], ["daily", "date"]]) {
      if (!Array.isArray(snapshot[property])) throw new Error("invalid_snapshot");
      snapshot[property].forEach((row) => {
        if (!row || typeof row[label] !== "string" || row[label].length > 500) throw new Error("invalid_snapshot");
        count(row.visits);
        if (property === "daily" && !/^\d{4}-\d{2}-\d{2}$/.test(row.date)) throw new Error("invalid_snapshot");
      });
    }
    return snapshot;
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function breakdown(containerId, rows, options = {}) {
    const container = byId(containerId);
    container.replaceChildren();
    if (!rows.length) {
      container.appendChild(element("p", "stats-empty", options.empty || "No aggregate records yet."));
      return;
    }
    const sum = rows.reduce((total, row) => total + row.count, 0);
    const maximum = options.percent ? sum : Math.max(...rows.map((row) => row.count), 1);
    for (const row of rows) {
      const item = element("div", "stats-row");
      const top = element("div", "stats-row-top");
      top.appendChild(element("span", "stats-row-label", row.label || "Not reported"));
      const value = element("strong", "stats-row-value", formatCount.format(row.count));
      if (options.percent) value.appendChild(element("span", "stats-percent", `${sum ? (row.count / sum * 100).toFixed(1) : "0.0"}%`));
      top.appendChild(value);
      const track = element("div", "stats-track");
      track.setAttribute("aria-hidden", "true");
      const fill = document.createElement("span");
      fill.style.width = `${maximum ? Math.min(100, row.count / maximum * 100) : 0}%`;
      track.appendChild(fill);
      item.append(top, track);
      container.appendChild(item);
    }
  }

  function categoryNote(id, sum) {
    byId(id).textContent = sum === 0 ? "No responses in this category yet." : `${formatCount.format(sum)} ${sum === 1 ? "response" : "responses"} in this breakdown.`;
  }

  function daily(rows) {
    const container = byId("daily-content");
    container.replaceChildren();
    if (!rows.length) {
      container.appendChild(element("p", "stats-empty", "No daily aggregate records yet."));
      return;
    }
    const ordered = [...rows].sort((a, b) => b.date.localeCompare(a.date));
    const maximum = Math.max(...ordered.map((row) => row.visits), 1);
    const wrapper = element("div", "stats-table-wrap");
    wrapper.tabIndex = 0;
    wrapper.setAttribute("role", "region");
    wrapper.setAttribute("aria-label", "Daily visits table");
    const table = element("table", "stats-table");
    const caption = element("caption", "sr-only", "Daily visit totals, newest reporting day first");
    const head = document.createElement("thead");
    const header = document.createElement("tr");
    for (const label of ["Reporting day", "Visits", "Relative activity"]) {
      const cell = element("th", "", label); cell.scope = "col"; header.appendChild(cell);
    }
    head.appendChild(header);
    const body = document.createElement("tbody");
    for (const row of ordered) {
      const tr = document.createElement("tr");
      const date = element("th", "", row.date); date.scope = "row";
      const value = element("td", "", formatCount.format(row.visits));
      const visual = element("td", "stats-trend-cell");
      const track = element("div", "stats-trend"); track.setAttribute("aria-hidden", "true");
      const fill = document.createElement("span"); fill.style.width = `${row.visits / maximum * 100}%`;
      track.appendChild(fill); visual.appendChild(track);
      tr.append(date, value, visual); body.appendChild(tr);
    }
    table.append(caption, head, body); wrapper.appendChild(table); container.appendChild(wrapper);
  }

  function render(snapshot) {
    for (const key of ["visits", "visitors", "supportClicks", "downloads", "responses", "feedback"]) byId(`total-${key}`).textContent = formatCount.format(snapshot.totals[key]);
    const usefulness = [{label: "Useful", count: snapshot.usefulness.yes}, {label: "Partly useful", count: snapshot.usefulness.partly}, {label: "Not yet useful", count: snapshot.usefulness.not_yet}];
    const intent = [{label: "Yes", count: snapshot.intent.yes}, {label: "Maybe", count: snapshot.intent.maybe}, {label: "No", count: snapshot.intent.no}];
    const kinds = [{label: "Thanks", count: snapshot.feedbackKinds.thanks}, {label: "Ideas", count: snapshot.feedbackKinds.idea}, {label: "Bugs", count: snapshot.feedbackKinds.bug}];
    breakdown("usefulness-chart", usefulness, {percent: true});
    breakdown("intent-chart", intent, {percent: true});
    breakdown("feedback-chart", kinds, {percent: true});
    categoryNote("usefulness-note", usefulness.reduce((sum, row) => sum + row.count, 0));
    categoryNote("intent-note", intent.reduce((sum, row) => sum + row.count, 0));
    categoryNote("feedback-note", kinds.reduce((sum, row) => sum + row.count, 0));
    for (const [property, key, container] of [["sources", "source", "sources-chart"], ["countries", "country", "countries-chart"], ["campaigns", "campaign", "campaigns-chart"]]) {
      const rows = [...snapshot[property]].sort((a, b) => b.visits - a.visits).map((row) => ({label: row[key], count: row.visits}));
      breakdown(container, rows);
    }
    daily(snapshot.daily);
    const updated = typeof snapshot.updatedAt === "string" || typeof snapshot.updatedAt === "number" ? new Date(snapshot.updatedAt) : new Date(NaN);
    byId("stats-updated").textContent = Number.isFinite(updated.getTime()) ? `Updated ${updated.toLocaleString()}` : "Update time was not supplied.";
    const totalActivity = Object.values(snapshot.totals).reduce((sum, value) => sum + value, 0);
    byId("stats-status").textContent = totalActivity ? "Shared aggregate snapshot loaded." : "The shared snapshot is ready. No activity has been counted yet.";
    byId("stats-content").hidden = false;
  }

  async function load() {
    if (request) return;
    const controller = new AbortController();
    request = controller;
    const timer = setTimeout(() => controller.abort(), 12000);
    byId("stats-error").hidden = true;
    byId("stats-refresh").disabled = true;
    byId("stats-retry").disabled = true;
    byId("stats-status").textContent = "Loading owner aggregate counts…";
    try {
      const url = new URL("/api/stats", API_ORIGIN); url.searchParams.set("dataset", dataset);
      const response = await fetch(url.href, {method: "GET", credentials: "same-origin", cache: "no-store", referrerPolicy: "no-referrer", signal: controller.signal, headers: {Accept: "application/json"}});
      if (!response.ok) { const error = new Error("http_error"); error.status = response.status; throw error; }
      const snapshot = validate(await response.json());
      render(snapshot);
    } catch (error) {
      byId("stats-content").hidden = true;
      byId("stats-error").hidden = false;
      byId("stats-status").textContent = "Aggregate counts could not be loaded.";
      const signInRequired = error?.status === 401 || error?.status === 403;
      byId("stats-error-title").textContent = signInRequired ? "Owner sign-in required." : "The snapshot is unavailable.";
      byId("stats-error-message").textContent = signInRequired ? "Sign in with the dashboard’s owner account, then retry. These statistics are not available publicly." : error?.name === "AbortError" ? "The shared snapshot took too long to respond. Please try again. Nothing has been estimated or filled in." : "We couldn’t load a valid shared snapshot. Please try again. Nothing has been estimated or filled in.";
    } finally {
      clearTimeout(timer); request = null;
      byId("stats-refresh").disabled = false;
      byId("stats-retry").disabled = false;
    }
  }

  byId("stats-refresh").addEventListener("click", load);
  byId("stats-retry").addEventListener("click", load);
  let inboxRequest = null;
  async function loadInbox() {
    if (inboxRequest) return;
    const controller = new AbortController(); inboxRequest = controller;
    const timer = setTimeout(() => controller.abort(), 12000);
    byId("inbox-refresh").disabled = true;
    byId("inbox-error").hidden = true;
    byId("inbox-status").textContent = "Loading the owner inbox…";
    try {
      const inboxURL = new URL("/api/inbox", API_ORIGIN); inboxURL.searchParams.set("dataset", dataset);
      const response = await fetch(inboxURL.href, {method: "GET", credentials: "same-origin", cache: "no-store", referrerPolicy: "no-referrer", signal: controller.signal, headers: {Accept: "application/json"}});
      if (!response.ok) { const error = new Error("http_error"); error.status = response.status; throw error; }
      const result = await response.json();
      if (!result || !Array.isArray(result.items) || result.items.length > 100) throw new Error("invalid_inbox");
      for (const item of result.items) {
        if (!item || typeof item.id !== "string" || item.id.length > 100 || !["thanks", "idea", "bug"].includes(item.kind) || typeof item.message !== "string" || item.message.length > 4000 || !Number.isFinite(item.created) || typeof item.status !== "string" || item.status.length > 100) throw new Error("invalid_inbox");
      }
      const container = byId("inbox-items"); container.replaceChildren();
      const kindNames = {thanks: "Thanks", idea: "Idea", bug: "Bug report"};
      for (const item of result.items) {
        const card = element("article", "inbox-card");
        card.appendChild(element("h3", "", kindNames[item.kind]));
        card.appendChild(element("p", "inbox-message", item.message));
        const created = new Date(item.created * 1000);
        const date = Number.isFinite(created.getTime()) ? created.toLocaleString() : "Date unavailable";
        card.appendChild(element("p", "inbox-meta", `${date} · ${item.status}`));
        card.appendChild(element("p", "inbox-meta", `Ticket: ${item.id}`));
        if (typeof item.github_url === "string") {
          try {
            const url = new URL(item.github_url);
            if (url.protocol === "https:" && url.hostname === "github.com" && /^\/py-killer\/lantern-vnc\/issues\/\d+$/.test(url.pathname)) {
              const link = element("a", "", "Related GitHub issue"); link.href = url.href;
              card.appendChild(link);
            }
          } catch { /* A malformed external link is never rendered. */ }
        }
        container.appendChild(card);
      }
      byId("inbox-status").textContent = result.items.length ? `${result.items.length} recent ${result.items.length === 1 ? "message" : "messages"} loaded.` : "No feedback messages have arrived yet.";
    } catch (error) {
      byId("inbox-items").replaceChildren();
      byId("inbox-status").textContent = "The owner inbox could not be loaded.";
      byId("inbox-error").hidden = false;
      byId("inbox-error").textContent = error?.status === 401 || error?.status === 403 ? "Owner sign-in required. Sign in with the dashboard’s owner account, then retry." : error?.name === "AbortError" ? "The inbox request timed out. Please retry." : "A valid inbox response could not be loaded. Please retry.";
    } finally {
      clearTimeout(timer); inboxRequest = null; byId("inbox-refresh").disabled = false;
    }
  }
  byId("inbox-refresh").addEventListener("click", loadInbox);
  load();
  loadInbox();
})();
