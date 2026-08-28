// pi-blackhole — dsh agent plugin entry.
//
// Mounted by the my-minimal preset as `./dsh-blackhole/lib/index.js` (agent
// scope). This row contributes the model-facing `recall` tool, the
// observational-memory worker pipeline, and the /blackhole* commands. The
// deterministic compaction backend is a separate row
// (`./dsh-blackhole/lib/compaction.js`) inside the compaction isolate group;
// it imports the same bundled pi-blackhole core.

import { apply as applyRecall } from "./recall.js";
import { apply as applyOm } from "./om.js";
import { apply as applyCommands } from "./commands.js";

const name = "blackhole";
const inject = ["tools", "commands", "sessions", "llm"];

function apply(ctx, config) {
  applyRecall(ctx, config);
  applyOm(ctx, config);
  applyCommands(ctx, config);
}

export { name, inject, apply };
