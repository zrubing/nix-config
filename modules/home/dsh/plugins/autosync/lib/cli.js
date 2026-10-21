//#region lib/cli.js
/**
 * dsh-models-sync — 把「网关现在有什么」和仓库声明对一次账，并可写回锁文件。
 *
 * ## 用法（两种模式）
 *
 *   不带参数            报告差异：声明 vs 在线。有差异退出码 1，跑不起来 2。
 *   --update            抓在线清单，重写 modules/home/llm-routes/models.lock.json。
 *
 * ## 为什么是「锁文件」而不是「整份配置」
 *
 * 网关的 `/v1/models` 只公布 id，公布不了容量、档位、compat —— 这三样是本仓库
 * 反复踩过坑的地方（曾把 1M 的模型按 128k 服务，错数字在后续每一层都与真值无法
 * 区分）。所以能自动生成的只有「哪些 id 存在」，元数据仍人工维护在 routes.nix：
 * 锁里新增的 id 若没有对应元数据，nix 求值期直接报错，而不是带着猜的容量上线。
 *
 * ## 为什么是离线 CLI，而不是继续让插件写
 *
 * nix 求值期拿不到带凭据的 `/v1/models`（flake 纯求值，IFD 也过不去），所以这个
 * 事实只能由一次人工动作带进仓库。运行期的 autosync 因此退化成漂移探测器
 * （`reportOnly`），profile 层归 nix。
 *
 * ## 为什么不重新实现一遍合并
 *
 * 直接 import `./plugin.js` 的 `reconcile` / `resolveOptions` / `inRouteScope` 与
 * 各描述符的 `spec`：CLI 与运行期插件必须对同一份清单得出同一个结论，否则两边
 * 会各自漂移 —— 那正是这个包当初合并三个副本要解决的问题。
 *
 * ## 声明从哪来
 *
 * `--routes <file>`：nix 渲染的 JSON（`modules/home/dsh/default.nix` 的
 * `dshModelsRoutesJson`），形如
 *
 *     { "routes": { "deepseek-relay": { "models": [ ... ], "metaIds": [ ... ],
 *         "baseURLEnv": "...", "api": "...", "apiKeyEnv": "...",
 *         "includePrefixes": [ ... ] } } }
 *
 * 只含**已经在 routes.nix 里声明过**的路由。
 */
import { readFile, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { inRouteScope, messageOf, reconcile, resolveOptions } from "./plugin.js";
import { spec as opencodeFree } from "./opencode-free.js";
import { spec as opencode } from "./opencode.js";
import { spec as runinfra } from "./runinfra.js";
import { spec as deepseekRelay } from "./deepseek-relay.js";

/** 有描述符的路由 → spec。没有描述符的声明只可能是路由表里的死条目。 */
const SPECS = new Map(
	[opencode, opencodeFree, runinfra, deepseekRelay].map((spec) => [spec.route, spec])
);

const FETCH_TIMEOUT_MS = 20000;
/** 锁文件在仓库里的位置；`--update` 相对当前目录解析。 */
const DEFAULT_LOCK = "modules/home/llm-routes/models.lock.json";

const USAGE = `用法: dsh-models-sync [--update] [--route <name>] [--json]

  默认        报告「声明 vs 在线」的差异；有差异退出码 1，出错 2
  --update    抓在线清单，重写 ${DEFAULT_LOCK}
  --route     只处理这一条路由，可重复
  --json      机器可读输出
  -h, --help  这段说明

凭据按各路由的 apiKeyEnv 从环境变量取（nix wrapper 已 source dsh.env）。
`;

function parseArgs(argv) {
	const options = { routes: undefined, lock: DEFAULT_LOCK, only: [], json: false, update: false, help: false };
	for (let index = 0; index < argv.length; index += 1) {
		const arg = argv[index];
		if (arg === "--routes") {
			options.routes = argv[index + 1];
			index += 1;
		} else if (arg === "--lock") {
			options.lock = argv[index + 1];
			index += 1;
		} else if (arg === "--route") {
			options.only.push(argv[index + 1]);
			index += 1;
		} else if (arg === "--json") {
			options.json = true;
		} else if (arg === "--update") {
			options.update = true;
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

/** 解析一条路由的端点与选项；失败时返回原因而不是抛。 */
function optionsFor(route, declared) {
	const spec = SPECS.get(route);
	if (spec === undefined) {
		return { error: "routes.nix 里有这条路由，但 autosync 没有对应的描述符" };
	}
	const baseURL =
		declared.baseURL ??
		(typeof declared.baseURLEnv === "string" ? process.env[declared.baseURLEnv] : undefined);
	if (typeof baseURL !== "string" || baseURL.length === 0) {
		return {
			error:
				typeof declared.baseURLEnv === "string"
					? `baseURL 未解析：${declared.baseURLEnv} 不在环境里`
					: "baseURL 未解析：声明里既没有 baseURL 也没有 baseURLEnv",
		};
	}
	// 行里的 reportOnly 是「运行期别写」，与这里的对账无关：CLI 要的正是
	// 「如果写，会写什么」。描述符自己的默认值仍然生效（catalog 路由只报不采）。
	const { reportOnly: _runtimeOnly, ...facts } = declared;
	return { opts: resolveOptions({ ...facts, route, baseURL }, spec) };
}

async function listing(opts) {
	const live =
		typeof opts.discover === "function" ? await opts.discover(null, opts) : await fetchListing(opts);
	if (live.length === 0) throw new Error("在线清单为空");
	return live;
}

/** 一条路由的对账结果。永不抛：把失败原样放进报告，交给调用方决定退出码。 */
async function inspect(route, declared) {
	const { opts, error } = optionsFor(route, declared);
	if (error !== undefined) return { route, ok: false, reason: error };
	let live;
	try {
		live = await listing(opts);
	} catch (failure) {
		return { route, ok: false, reason: `取在线清单失败: ${messageOf(failure)}` };
	}

	let capabilities;
	if (typeof opts.capabilitySource === "function") {
		try {
			capabilities = await opts.capabilitySource(live, opts);
		} catch (failure) {
			return { route, ok: false, reason: `能力来源失败: ${messageOf(failure)}` };
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
		liveCount: live.filter((entry) => inRouteScope(entry.id, opts)).length,
		added,
		dropped,
		repaired,
		unresolved,
	};
}

/** 改写一条路由在锁文件里的 id 集合。返回新旧差异。 */
async function reconcileLock(route, declared) {
	const { opts, error } = optionsFor(route, declared);
	if (error !== undefined) return { route, ok: false, reason: error };
	let live;
	try {
		live = await listing(opts);
	} catch (failure) {
		return { route, ok: false, reason: `取在线清单失败: ${messageOf(failure)}` };
	}
	// 只有本路由 scope 内的 id 进锁：scope 外的 id 是网关的别家模型，不该进清单。
	const ids = [...new Set(live.map((entry) => entry.id).filter((id) => inRouteScope(id, opts)))].sort();
	const metaIds = Array.isArray(declared.metaIds) ? declared.metaIds : [];
	return {
		route,
		ok: true,
		ids,
		// 锁里新增但还没有人工元数据的 id：nix 求值会为此报错，等于把「补一条」的
		// 提醒提前到这里。
		missingMeta: ids.filter((id) => !metaIds.includes(id)),
		// 有元数据但锁里已经没有的 id：可以删了。
		orphanMeta: metaIds.filter((id) => !ids.includes(id)),
	};
}

function renderReport(report) {
	if (report.ok === false) return `${report.route}: ${report.reason}`;
	const lines = [`${report.route}  声明 ${report.declaredCount} / 在线 ${report.liveCount}`];
	if (report.added.length === 0 && report.dropped.length === 0 && report.repaired.length === 0) {
		lines.push("  无差异");
	} else {
		if (report.added.length > 0) {
			lines.push(`  + 在线有、声明无（${report.added.length}）—— 跑 --update 采纳`);
			lines.push(...report.added.map((id) => `      ${id}`));
		}
		if (report.dropped.length > 0) {
			lines.push(`  - 声明有、在线无（${report.dropped.length}）`);
			lines.push(...report.dropped.map((id) => `      ${id}`));
		}
		if (report.repaired.length > 0) {
			lines.push(`  ~ 缺 reasoningEfforts，会被默认档补齐（${report.repaired.length}）`);
			lines.push(...report.repaired.map((id) => `      ${id}`));
		}
	}
	if (report.unresolved.length > 0) {
		lines.push(`  ! 未决（${report.unresolved.length}）—— 没有容量来源，不采纳`);
		lines.push(...report.unresolved.map((id) => `      ${id}`));
	}
	return lines.join("\n");
}

function renderUpdate(report, before, lockPath) {
	if (report.ok === false) return `${report.route}: ${report.reason}`;
	const previous = new Set(before[report.route] ?? []);
	const next = new Set(report.ids);
	const added = report.ids.filter((id) => !previous.has(id));
	const removed = [...previous].filter((id) => !next.has(id));
	const lines = [
		`${report.route}  锁 ${previous.size} → ${next.size}` +
			(added.length === 0 && removed.length === 0 ? "（无变化）" : ""),
	];
	if (added.length > 0) lines.push(...added.map((id) => `      + ${id}`));
	if (removed.length > 0) lines.push(...removed.map((id) => `      - ${id}`));
	if (report.missingMeta.length > 0) {
		lines.push(
			`  ! 以下 id 在 routes.nix 里没有元数据，rebuild 会在求值期报错，请各补一条：`,
			...report.missingMeta.map((id) => `      ${id}`)
		);
	}
	if (report.orphanMeta.length > 0) {
		lines.push(
			`  · 以下 id 的元数据已无引用，可以删：`,
			...report.orphanMeta.map((id) => `      ${id}`)
		);
	}
	return `${lines.join("\n")}\n  → ${lockPath}`;
}

function drifted(report) {
	return (
		report.ok === true &&
		(report.added.length > 0 || report.dropped.length > 0 || report.repaired.length > 0)
	);
}

async function readLock(lockPath) {
	try {
		return JSON.parse(await readFile(lockPath, "utf8"));
	} catch (error) {
		if (error.code === "ENOENT") return {};
		throw error;
	}
}

async function main() {
	const options = parseArgs(process.argv.slice(2));
	if (options.help) {
		process.stdout.write(USAGE);
		return 0;
	}
	if (options.routes === undefined) throw new Error("缺少 --routes");
	const document = JSON.parse(await readFile(options.routes, "utf8"));
	const routes = document?.routes ?? {};
	const names = options.only.length > 0 ? options.only : Object.keys(routes);
	if (names.length === 0) throw new Error(`${options.routes} 里没有任何已声明的路由`);

	const lockPath = resolve(process.cwd(), options.lock);
	const before = await readLock(lockPath);

	if (options.update) {
		const lock = { ...before };
		const reports = [];
		for (const route of names) {
			if (routes[route] === undefined) {
				reports.push({ route, ok: false, reason: "routes.nix 没有声明这条路由" });
				continue;
			}
			const report = await reconcileLock(route, routes[route]);
			reports.push(report);
			if (report.ok === true) lock[route] = report.ids;
		}
		// 只有真的变了才写：避免把一次无意义的 mtime 变更带进提交。
		const changed = JSON.stringify(lock) !== JSON.stringify(before);
		if (changed) {
			try {
				await writeFile(`${lockPath}.tmp`, JSON.stringify(lock, null, 2) + "\n");
				await rename(`${lockPath}.tmp`, lockPath);
			} catch (failure) {
				throw new Error(`写不了锁文件 ${lockPath}（--update 要在仓库根目录跑）：${messageOf(failure)}`);
			}
		}
		if (options.json) process.stdout.write(JSON.stringify(reports, null, 2) + "\n");
		else process.stdout.write(reports.map((r) => renderUpdate(r, before, lockPath)).join("\n\n") + "\n");
		return reports.some((report) => report.ok === false) ? 2 : 0;
	}

	const reports = [];
	for (const route of names) {
		if (routes[route] === undefined) {
			reports.push({ route, ok: false, reason: "routes.nix 没有声明这条路由" });
			continue;
		}
		reports.push(await inspect(route, routes[route]));
	}

	if (options.json) process.stdout.write(JSON.stringify(reports, null, 2) + "\n");
	else process.stdout.write(reports.map(renderReport).join("\n\n") + "\n");

	if (reports.some((report) => report.ok === false)) return 2;
	return reports.some(drifted) ? 1 : 0;
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
