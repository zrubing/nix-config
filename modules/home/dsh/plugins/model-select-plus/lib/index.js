//#region lib/index.js
/**
 * @local/dsh-model-select-plus, node half. Pure UI plugin: the empty apply
 * exists so the loader row (inserted by the nix-managed ~/.dsh/cordis.patch.yml)
 * resolves this package; the browser half ships via exports["./client"],
 * discovered through the package.json dsh.client declaration.
 *
 * The model directory service (ModelDirectoryResolver, ctx.modelDirectories)
 * and the /model command stay owned by the official
 * @deepseek-ai/dsh-client-ui-model-selection bundle, which remains mounted —
 * this plugin only replaces the composer seat's occupant on the browser side.
 */
/** Host plugin body — no host-side behavior for this surface plugin. */
function apply() {}
//#endregion
export { apply };
