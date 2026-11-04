import { boot } from "./boot.mjs";
import { loadSessionData } from "./api.mjs";
import { sessionView } from "./views.mjs";

function sessionIdFromLocation() {
  const params = new URLSearchParams(window.location.search);
  const id = params.get("id");
  return id ? id.trim() : "";
}

boot(async () => {
  const sessionId = sessionIdFromLocation();
  if (!sessionId) {
    return {
      html: `<article class="error-page"><p class="breadcrumb"><a href="index.html">For judges</a></p><h1>No session id</h1><p>This page needs an <code>id</code> in the address. Open a session from the evidence index.</p><p><a class="button" href="index.html">For judges</a></p></article>`,
      title: "No session id",
    };
  }
  const data = await loadSessionData(sessionId);
  return { html: sessionView(data), title: "Session" };
});
