/**
 * dsh-opencode-session — 给 OpenCode 网关的推理请求补 x-opencode-session。
 *
 * 为什么需要它：OpenCode Go 档强制该头，缺了网关先于鉴权返回 400
 * MissingSessionID。pi-ai 只在自己 catalog 的 provider 上包了
 * withOpenCodeSessionHeader；路由一旦显式声明 api（手写 models 清单必须声明，
 * 否则拿不到协议），走的是 PROTOCOLS 裸工厂，那层包装到不了这里。
 *
 * 为什么是插件而不是改动过的 kernel：dsh 0.2.2-alpha.3 起，适配器在发请求前跑
 * `llm-pi-ai/request-headers` waterfall，并交出不可变的 routing 元数据
 * （provider / model / baseURL / sessionId、可选 purpose）。这正是本逻辑需要的
 * 全部输入，于是它以前打 dsh-llm-pi-ai 编译产物的 kernel 补丁，现在只是这个
 * 贡献点。上游在 waterfall 之后才写 attribution 头，贡献者改不了那些。
 *
 * 为什么值必须按会话给：静态头会让所有会话共用一个亲和桶，实测缓存命中率
 * 99.7%→79%、中位延迟 8s→13.5s（DSH discussion #5495）。sessionId 形如
 * session-<uuid>，跨轮次 / resume / 压缩稳定，正合适。
 *
 * 门控：provider 名以 opencode 开头，或 baseURL 的 host 是 opencode.ai（含子域）；
 * 其余路由的请求头字节不变。已配置过该头时不覆盖（与 pi-ai 的 hasHeader 同义）。
 * 非可见 ASCII 的 sessionId 直接跳过 —— Headers 构造遇到它抛 TypeError，而适配器
 * 会把它变成 REQUEST_HEADERS 硬失败，等于把一次正常请求打死。
 *
 * 插件形状照 @deepseek-ai/dsh-mcp-client：具名导出、无 default、async apply(ctx)。
 */

/** Cordis 插件名（loader 诊断用）。 */
const name = "opencode-session";

const SESSION_HEADER = "x-opencode-session";
const VISIBLE_ASCII = /^[!-~]+$/;

/**
 * 该路由是不是 OpenCode 网关。
 * @param provider 路由名（llm-pi-ai 的 provider id）。
 * @param baseURL 该次请求所用 endpoint（由已准备的 model 决定）。
 */
function usesOpenCode(provider, baseURL) {
	if (typeof provider === "string" && provider.startsWith("opencode")) return true;
	if (typeof baseURL !== "string") return false;
	let host;
	try {
		host = new URL(baseURL).hostname;
	} catch {
		return false;
	}
	return host === "opencode.ai" || host.endsWith(".opencode.ai");
}

/**
 * @param ctx - plugin context (cordis).
 */
async function apply(ctx) {
	ctx.effect(
		() =>
			// waterfall 是同步派发：先改传进来的 Headers 副本，再 next() 放行。
			ctx.on("llm-pi-ai/request-headers", function (request, headers, next) {
				const sessionId = request?.sessionId;
				if (
					typeof sessionId === "string" &&
					VISIBLE_ASCII.test(sessionId) &&
					usesOpenCode(request.provider, request.baseURL) &&
					!headers.has(SESSION_HEADER)
				) {
					headers.set(SESSION_HEADER, sessionId);
				}
				return next();
			}),
		`${name}.request-headers`,
	);
}

export { apply, name };
