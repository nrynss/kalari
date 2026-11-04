import { boot } from "./boot.mjs";
import { loadRunData } from "./api.mjs";
import { runView } from "./views.mjs";

function runIdFromLocation() {
  const params = new URLSearchParams(window.location.search);
  const id = params.get("id");
  return id ? id.trim() : "";
}

boot(async () => {
  const runId = runIdFromLocation();
  if (!runId) {
    return {
      html: `<article class="error-page"><p class="breadcrumb"><a href="index.html">For judges</a></p><h1>No run id</h1><p>This page needs an <code>id</code> in the address. Open a run from the evidence index.</p><p><a class="button" href="index.html">For judges</a></p></article>`,
      title: "No run id",
    };
  }
  const data = await loadRunData(runId);
  return { html: runView(data), title: "Run" };
});
