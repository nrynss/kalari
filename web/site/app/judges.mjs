import { boot } from "./boot.mjs";
import { loadJudgesData } from "./api.mjs";
import { judges023View as judgesView } from "./judges023.mjs";

boot(async () => {
  const data = await loadJudgesData();
  return { html: judgesView(data), title: "For judges" };
});
