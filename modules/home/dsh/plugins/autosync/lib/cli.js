//#region lib/cli.js
/**
 * dsh-models-sync — 把「网关现在有什么」和「routes.nix 声明了什么」对一次账。
 *
 * ## 为什么是离线 CLI，而不是继续让插件写
 *
 * nix 求值期拿不到带凭据的 `/v1/models`（flake 纯求值，IFD 也过不去），所以
 * 「网关上有哪些模型」这个事实只能由一个**人跑一次、看一眼、提交**的动作带进
 * 仓库。运行期的 autosync 因此退化成漂移探测器（`reportOnly`），profile 层归
 * nix；两者职责分开之后，网上事实进入配置的唯一路径就是这次 diff。
 *
 * ## 为什么不重新实现一遍合并
 *
 * 直接 import `./plugin.js` 的 `reconcile` / `resolveOptions` 与各描述符的
 * `spec`：CLI 与运行期插件必须对同一份清单得出同一个结论，否则两边会各自漂移
 * ——那正是这个包当初合并三个副本要解决的问题。
 *
 * ## 声明从哪来
 *
 * `--routes <file>`：nix 渲染的 JSON（`modules/home/dsh/default.nix` 的
 * `dshModelsRoutesJson`），形如
 *
 *     { "routes": { "deepseek-relay": { "models": [ ... ],
 *         "baseURLEnv": "DEEPSEEK_RELAY_API_KEY", "api": "...",
 *         "apiKeyEnv": "...", "includePrefixes": [ ... ] } } }
 *
 * 只含**已经在 routes.nix 里声明过**的路由。没声明的路由这里不处理：它们的清单
 * 仍是运行期状态，归插件管。
 *
 * ## 退出码
 *
 * 0 = 无差异；1 = 有差异（`--check` 用，可挂 timer）；2 = 跑不起来（缺 key、
 * 网络失败、上游非 200）。**差异不算错误**，是待提交的输入。
 */
import { messageOf, reconcile, resolveOptions } from "./plugin.js";
import { spec as opencodeFree } from "./opencode-free.js";
import { spec as opencode } from "./opencode.js";
import { spec as runinfra } from "./runinfra.js";
import { spec as deepseekRelay } from "./deepseek-relay.js";

/** 有描述符的路由 → spec。没有描述符的声明只可能是路由表里的死条目。 */
const SPECS = new Map(
	[opencode, opencodeFree, runinfra, deepseekRelay].map((spec) => [spec.route, spec])
);

const FETCH_TIMEOUT_MS = 20000;

const USAGE = `用法: dsh-models-sync --routes <routes.json> [--route <name>] [--check] [--json]

  --routes <file>   nix 渲染的声明清单（必填）
  --route <name>    只对账这一条路由，可重复
  --check           有差异时退出码 1（无差异 0）
  --json            机器可读输出
  -h, --help        这段说明

凭据按各路由的 apiKeyEnv 从环境变量取（与 dsh 运行时同一份 dsh.env）。
`;

function parseArgs(argv) {
	const options = { routes: undefined, only: [], json: false, check: false, help: false };
	for (let index = 0; index < argv.length; index += 1) {
		const arg = argv[index];
		if (arg === "--routes") {
			options.routes = argv[index + 1];
			index += 1;
		} else if (arg === "--route") {
			options.only.push(argv[index + 1]);
			index += 1;
		} else if (arg === "--json") {
			options.json = true;
		} else if (arg === "--check") {
			options.check = true;
		} else if (arg === "-h" || arg === "--help") {
			options.help = true;
		} else {
			throw new Error(`未知参数: ${arg}`);
		}
	}
	return options;
}

/**
 * 取在线清单。
 *
 * 描述符自带 `discover` 的（runinfra：它的 payload 里带 reasoning_efforts /
 * input_modalities，`discoverModels` 的归一化会把这些抹掉）走描述符；其余走
 * 这里的最小实现 —— 与 `discoverLive` 打到同一个端点、同一套鉴权，只是不经过
 * cordis 的 llm 服务（CLI 里没有 ctx）。
 */
async function fetchListing(opts) {
	const base = String(opts.baseURL ?? "").replace(/\/+$/, "");
	if (base.length === 0) throw new Error("baseURL 未解析");
	const apiKey = process.env[opts.apiKeyEnv];
	const response = await fetch(`${base}/models`, {
		headers: {
			accept: "application/json",
			...(typeof apiKey === "string" && apiKey.length > 0
				? { authorization: `Bearer ${apiKey}` }
				: {}),
		},
		signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
	});
	if (!response.ok) throw new Error(`${base}/models answered ${response.status}`);
	const payload = await response.json();
	const rows = Array.isArray(payload)
		? payload
		: Array.isArray(payload?.data)
			? payload.data
			: Array.isArray(payload?.models)
				? payload.models
				: [];
	return rows
		.map((row) => (typeof row?.id === "string" ? { id: row.id } : undefined))
		.filter((row) => row !== undefined && row.id.length > 0);
}

/** 一条路由的对账结果。永不抛：把失败原样放进报告，交给调用方决定退出码。 */
async function inspect(route, declared) {
	const spec = SPECS.get(route);
	if (spec === undefined) {
		return { route, ok: false, reason: "routes.nix 里有这条路由，但 autosync 没有对应的描述符" };
	}
	const baseURL =
		declared.baseURL ??
		(typeof declared.baseURLEnv === "string" ? process.env[declared.baseURLEnv] : undefined);
	if (typeof baseURL !== "string" || baseURL.length === 0) {
		return {
			route,
			ok: false,
			reason:
				typeof declared.baseURLEnv === "string"
					? `baseURL 未解析：${declared.baseURLEnv} 不在环境里`
					: "baseURL 未解析：声明里既没有 baseURL 也没有 baseURLEnv",
		};
	}
	// 行里的 reportOnly 是「运行期别写」，与这里的对账无关：CLI 要的正是
	// 「如果写，会写什么」。描述符自己的默认值仍然生效（catalog 路由只报不采）。
	const { reportOnly: _runtimeOnly, ...facts } = declared;
	const opts = resolveOptions({ ...facts, route, baseURL }, spec);

	let live;
	try {
		live = typeof opts.discover === "function" ? await opts.discover(null, opts) : await fetchListing(opts);
	} catch (error) {
		return { route, ok: false, reason: `取在线清单失败: ${messageOf(error)}` };
	}
	if (live.length === 0) {
		return { route, ok: false, reason: "在线清单为空，不动" };
	}

	let capabilities;
	if (typeof opts.capabilitySource === "function") {
		try {
			capabilities = await opts.capabilitySource(live, opts);
		} catch (error) {
			return { route, ok: false, reason: `能力来源失败: ${messageOf(error)}` };
		}
	}

	const existing = Array.isArray(declared.models) ? declared.models : [];
	const { added, dropped, repaired, unresolved } = reconcile(
		existing,
		live,
		opts,
		undefined,
		capabilities
	);
	return {
		route,
		ok: true,
		declaredCount: existing.length,
		liveCount: live.length,
		added,
		dropped,
		repaired,
		unresolved,
	};
}

function render(report) {
	if (report.ok === false) return `${report.route}: ${report.reason}`;
	const lines = [`${report.route}  声明 ${report.declaredCount} / 在线 ${report.liveCount}`];
	if (report.added.length > 0) {
		lines.push(`  + 在线有、声明无（${report.added.length}）——reconcile 会采纳，先在 routes.nix 补条目`);
		lines.push(...report.added.map((id) => `      ${id}`));
	}
	if (report.dropped.length > 0) {
		lines.push(`  - 声明有、在线无（${report.dropped.length}）——reconcile 会删掉`);
		lines.push(...report.dropped.map((id) => `      ${id}`));
	}
	if (report.repaired.length > 0) {
		lines.push(`  ~ 缺 reasoningEfforts、会被默认档补齐（${report.repaired.length}）`);
		lines.push(...report.repaired.map((id) => `      ${id}`));
	}
	if (report.unresolved.length > 0) {
		lines.push(`  ! 未决（${report.unresolved.length}）——没有容量来源，不采纳、不写`);
		lines.push(...report.unresolved.map((id) => `      ${id}`));
	}
	if (lines.length === 1) lines.push("  无差异");
	return lines.join("\n");
}

function drifted(report) {
	return (
		report.ok === true &&
		(report.added.length > 0 || report.dropped.length > 0 || report.repaired.length > 0)
	);
}

async function main() {
	const options = parseArgs(process.argv.slice(2));
	if (options.help) {
		process.stdout.write(USAGE);
		return 0;
	}
	if (options.routes === undefined) throw new Error("缺少 --routes");
	const document = JSON.parse(await (await import("node:fs/promises")).readFile(options.routes, "utf8"));
	const routes = document?.routes ?? {};
	const names = options.only.length > 0 ? options.only : Object.keys(routes);
	if (names.length === 0) {
		throw new Error(`${options.routes} 里没有任何已声明的路由`);
	}

	const reports = [];
	for (const route of names) {
		if (routes[route] === undefined) {
			reports.push({ route, ok: false, reason: "routes.nix 没有声明这条路由" });
			continue;
		}
		reports.push(await inspect(route, routes[route]));
	}

	if (options.json) {
		process.stdout.write(JSON.stringify(reports, null, 2) + "\n");
	} else {
		process.stdout.write(reports.map(render).join("\n\n") + "\n");
	}

	if (reports.some((report) => report.ok === false)) return 2;
	if (options.check && reports.some(drifted)) return 1;
	return 0;
}

main().then(
	(code) => {
		process.exitCode = code;
	},
	(error) => {
		process.stderr.write(`dsh-models-sync: ${messageOf(error)}\n`);
		process.exitCode = 2;
	}
);
//#endregion
