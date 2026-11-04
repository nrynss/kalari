/* Formatting helpers. Every number the app shows passes through here, so the
   same rules apply on every page. Nothing in this file touches the DOM. */

const HTML_ESCAPES = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

export function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => HTML_ESCAPES[char]);
}

export function attr(value) {
  return escapeHtml(value);
}

export function isNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function numberFormat(value, minimumFractionDigits = 0, maximumFractionDigits = 0) {
  return Number(value).toLocaleString("en-US", {
    minimumFractionDigits,
    maximumFractionDigits,
  });
}

export function count(value) {
  return numberFormat(value, 0, 0);
}

export function decimal(value, digits = 1) {
  return numberFormat(value, digits, digits);
}

export function seconds(value) {
  if (!isNumber(value)) return "";
  if (value === 0) return "0.0 s";
  return `${numberFormat(value, 1, 3)} s`;
}

export function milliseconds(value) {
  if (!isNumber(value)) return "";
  return `${numberFormat(value / 1000, 1, 3)} s`;
}

export function tokens(value) {
  return numberFormat(value, 0, 0);
}

export function percent(value) {
  return `${numberFormat(value * 100, 1, 1)}%`;
}

export function money(value) {
  if (!isNumber(value)) return "";
  return `$${numberFormat(value, 4, 4)}`;
}

/* The API accepts only these characters in a run or session id, so the app
   refuses to build a link for anything else. A slash would read as a path
   separator and the API would answer 400. */
const ID_PATTERN = /^[A-Za-z0-9._-]+$/;

export function isId(value) {
  return typeof value === "string" && ID_PATTERN.test(value);
}

export function runHref(runId) {
  return `run.html?id=${encodeURIComponent(runId)}`;
}

export function sessionHref(sessionId) {
  return `session.html?id=${encodeURIComponent(sessionId)}`;
}

/* A run link is only rendered when the run id passes the API id rule and is
   in the served run index. When it is not, the caller gets a plain word
   instead of a number, so a figure can never appear without a working
   destination. */
export function runLink(runId, inner, runIds, label) {
  if (!runIds) {
    return `<span class="measure-unavailable" title="The run index could not be loaded.">unavailable</span>`;
  }
  if (!isId(runId) || !runIds.has(runId)) {
    return `<span class="measure-missing" title="This run is not in the evidence store.">evidence missing</span>`;
  }
  return `<a class="run-link" href="${attr(runHref(runId))}" data-run-link="${attr(runId)}" title="${attr(label)}">${inner}</a>`;
}

/* A measured value. `formatter` returns the display text. */
export function measure(runId, value, formatter, label, runIds) {
  if (!isNumber(value)) {
    return `<span class="measure-unknown" title="The record does not carry this measure.">unknown</span>`;
  }
  return runLink(runId, escapeHtml(formatter(value)), runIds, label);
}

export function plain(value, formatter, fallback = "unknown") {
  if (!isNumber(value)) return `<span class="measure-unknown">${escapeHtml(fallback)}</span>`;
  return escapeHtml(formatter(value));
}

export function verdictWord(value) {
  switch (value) {
    case "PASS":
      return "Passed";
    case "FAIL":
      return "Failed";
    case "exited":
      return "Completed";
    case "killed_timeout":
      return "Stopped by the time cap";
    case "killed_output_cap":
      return "Stopped by the output cap";
    default:
      return value ? String(value) : "Unknown";
  }
}

export function boolWord(value) {
  if (value === true) return "Yes";
  if (value === false) return "No";
  return "Unknown";
}

export function countWord(value) {
  const words = [
    "none",
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
  ];
  if (Number.isInteger(value) && value >= 0 && value < words.length) return words[value];
  return "more than ten";
}

export function capitalise(value) {
  if (!value) return "";
  return value.charAt(0).toUpperCase() + value.slice(1);
}

export function truncate(value, limit = 160) {
  if (typeof value !== "string") return "";
  if (value.length <= limit) return value;
  return `${value.slice(0, limit - 1)}…`;
}

/* Commands can carry an endpoint. The page never needs to print a scheme, and
   a fixture must not carry a real one, so show a neutral placeholder. */
export function redactUrls(value) {
  return String(value).replace(/https?:\/\/\S+/gi, "<endpoint>");
}

export function unique(values) {
  const seen = new Set();
  const result = [];
  for (const value of values) {
    if (!seen.has(value)) {
      seen.add(value);
      result.push(value);
    }
  }
  return result;
}
