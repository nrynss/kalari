import { boot } from "./boot.mjs";
import { loadJudgesData } from "./api.mjs";
import { judgesView } from "./views.mjs";

boot(async () => {
  const data = await loadJudgesData();
  return { html: judgesView(data), title: "For judges" };
});
