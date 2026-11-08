/* Read the evidence API. The paths are relative, so the same app works when
   Caddy serves it at / and proxies /api. No host or port is written here. */

export class ApiError extends Error {
  constructor(status, message, path) {
    super(message || "The API answered with an error.");
    this.name = "ApiError";
    this.status = status;
    this.path = path;
  }
}

/* The app only talks to its own origin. Reject any path that is not relative,
   so a value assembled at runtime cannot reach another host. The published
   pages also carry a Content-Security-Policy, which blocks the request in the
   browser even if this guard were bypassed. */
const LOCAL_PATH = /^(?!\/\/)[A-Za-z0-9._~!$&'()*+,;=:@%/?-]+$/;
const SCHEME = /^[A-Za-z][A-Za-z0-9+.-]*:/;

export function localPath(path) {
  if (typeof path !== "string" || !path || !LOCAL_PATH.test(path) || SCHEME.test(path)) {
    throw new ApiError(0, "The app only requests relative paths.", String(path || ""));
  }
  return path;
}

async function getJson(path) {
  let response;
  try {
    response = await fetch(localPath(path), {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
  } catch (cause) {
    if (cause instanceof ApiError) throw cause;
    throw new ApiError(0, "The evidence API could not be reached.", path);
  }
  let body = null;
  const text = await response.text();
  if (text) {
    try {
      body = JSON.parse(text);
    } catch (cause) {
      if (response.ok) {
        throw new ApiError(response.status, "The API answered with something that is not JSON.", path);
      }
    }
  }
  if (!response.ok) {
    const message = body && typeof body.error === "string" ? body.error : "";
    throw new ApiError(response.status, message, path);
  }
  return body;
}

function valueOf(result) {
  return result.status === "fulfilled" ? result.value : null;
}

function errorOf(result) {
  return result.status === "rejected" ? result.reason : null;
}

function warningsFrom(entries) {
  return entries
    .filter((entry) => entry.error)
    .map((entry) => `${entry.label}: ${describeError(entry.error).message}`);
}

/* The containment runs keep their own session, apart from
   the benchmark records. A 404 means it is not published, which is not an error. */
const CONTAINMENT_SESSION = "containment-023";

export async function loadJudgesData() {
  const [benchmark, runs, sessions, lessons, containment] = await Promise.allSettled([
    getJson("api/benchmark"),
    getJson("api/runs"),
    getJson("api/sessions"),
    getJson("api/lessons"),
    getJson(`api/sessions/${encodeURIComponent(CONTAINMENT_SESSION)}`),
  ]);
  if (benchmark.status === "rejected") {
    throw benchmark.reason;
  }
  const benchmarkValue = valueOf(benchmark);
  const runsValue = valueOf(runs);
  const benchmarkIds = new Set(
    (Array.isArray(benchmarkValue) ? benchmarkValue : [])
      .filter((record) => record?.kind === "benchmark" && typeof record.run_id === "string")
      .map((record) => record.run_id),
  );
  const otherRunIds =
    Array.isArray(runsValue) && Array.isArray(benchmarkValue) && benchmarkValue.length
      ? runsValue.filter((runId) => !benchmarkIds.has(runId))
      : [];
  const detailResults = await Promise.allSettled(
    otherRunIds.map((runId) => getJson(`api/runs/${encodeURIComponent(runId)}`)),
  );
  const runDetails = {};
  const entries = [
    { label: "The run index", error: errorOf(runs) },
    { label: "The session index", error: errorOf(sessions) },
    { label: "The lesson index", error: errorOf(lessons) },
  ];
  const containmentError = errorOf(containment);
  if (containmentError && !(containmentError instanceof ApiError && containmentError.status === 404)) {
    entries.push({ label: "The containment runs", error: containmentError });
  }
  detailResults.forEach((result, index) => {
    if (result.status === "fulfilled") runDetails[otherRunIds[index]] = result.value;
    else entries.push({ label: "A run detail", error: result.reason });
  });
  return {
    benchmark: benchmarkValue,
    runs: runsValue,
    sessions: valueOf(sessions),
    lessons: valueOf(lessons),
    containment: valueOf(containment),
    runDetails,
    warnings: warningsFrom(entries),
  };
}

export async function loadSessionData(sessionId) {
  const [records, lessons, runs] = await Promise.allSettled([
    getJson(`api/sessions/${encodeURIComponent(sessionId)}`),
    getJson("api/lessons"),
    getJson("api/runs"),
  ]);
  if (records.status === "rejected") {
    throw records.reason;
  }
  return {
    sessionId,
    records: records.value || [],
    lessons: valueOf(lessons) || [],
    runs: valueOf(runs),
    warnings: warningsFrom([
      { label: "The lesson index", error: errorOf(lessons) },
      { label: "The run index", error: errorOf(runs) },
    ]),
  };
}

export async function loadRunData(runId) {
  const [records, runs] = await Promise.allSettled([
    getJson(`api/runs/${encodeURIComponent(runId)}`),
    getJson("api/runs"),
  ]);
  if (records.status === "rejected") {
    throw records.reason;
  }
  return {
    runId,
    records: records.value || [],
    runs: valueOf(runs),
    warnings: warningsFrom([{ label: "The run index", error: errorOf(runs) }]),
  };
}

export function describeError(error) {
  if (!(error instanceof ApiError)) {
    return {
      title: "The page could not read the evidence",
      message: "Something went wrong while the page was preparing the records.",
      detail: "",
    };
  }
  if (error.status === 0) {
    return {
      title: "The evidence API could not be reached",
      message:
        "The page asked for the evidence store and got no answer. Start the fixture server, or check that the Kalari service is running.",
      detail: error.path ? `Request: ${error.path}` : "",
    };
  }
  if (error.status === 400) {
    return {
      title: "The API rejected the request",
      message:
        "The id may contain characters the API does not accept. Go back to the evidence index and choose a run or session from a link.",
      detail: error.path ? `Request: ${error.path}` : "",
    };
  }
  if (error.status === 404) {
    return {
      title: "No evidence for that id",
      message:
        "The store has no record for this id. The run or session may have been removed, or the link may be mistyped.",
      detail: error.path ? `Request: ${error.path}` : "",
    };
  }
  if (error.status === 413) {
    return {
      title: "The request was too large",
      message:
        "The API refused the request because its body was over the size cap. This page only reads, so that should not happen.",
      detail: error.path ? `Request: ${error.path}` : "",
    };
  }
  if (error.status >= 500) {
    return {
      title: "The evidence API had a problem",
      message: "The API answered with a server error. Try again, or look at the service log.",
      detail: error.path ? `Request: ${error.path}` : "",
    };
  }
  return {
    title: "The evidence API answered with an error",
    message: error.message || "The store returned an error.",
    detail: error.path ? `Request: ${error.path}` : "",
  };
}
