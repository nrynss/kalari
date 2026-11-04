import { describeError } from "./api.mjs";
import { errorView } from "./views.mjs";

/* Run a page's render function, then put its HTML in the app container.
   The render function returns { html, title }. */
export async function boot(render) {
  const app = document.getElementById("app");
  if (!app) return;
  app.setAttribute("aria-busy", "true");
  try {
    const result = await render();
    app.innerHTML = result.html;
    if (result.title) document.title = `${result.title} · Kalari`;
  } catch (error) {
    const info = describeError(error);
    app.innerHTML = errorView(info);
    document.title = `${info.title} · Kalari`;
  } finally {
    app.removeAttribute("aria-busy");
    document.documentElement.dataset.ready = "true";
  }
}
