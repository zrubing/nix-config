# 退役 / 新增一个节点

目标：删掉一个节点后，节点清单、组、本地适配器、凭据、地址表、DNS 都不留残留，
且不会出现「组 → 不存在的出站」这类运行时才炸的错误。

2026-11-05 起，节点身份只有**一份明文事实源**，其余全部派生。退役从一个 7 步手工
清单变成「删清单条目 + 清凭据 + 删 DNS」。

## 事实源分层

| 文件（nix-secrets） | 明文? | 内容 | 谁消费 |
| --- | --- | --- | --- |
| `proxy-nodes.meta.json` | 是 | `name`/`kind`/`port`/`sibGroups`/`relay`/`enabled` | nix 求值（tuic 实例、组归属）与 prepare（合并） |
| `proxy-nodes.creds.json.age` | 否 | 按 `name` 存的 `server`/`server6`/`password`/`uuid`/`sni`/… | prepare 运行时解密后合并 |
| `relay/tuic-server*.age` | 否 | tuic 上游地址（socks 节点的 `relay.serverSecret`） | tuic-client 渲染配置 |
| `net-policy-addresses.json.age` | 否 | **非节点**的敏感地址/域名 | net-policy token 展开 |

合并器：`lib/proxy-nodes-merge.jq`（meta + creds → 转换器输入，顺带过滤 `enabled: false`）。
转换器：`lib/proxy-nodes.jq`（→ sib 出站/组、mihomo proxies、直连地址派生）。

## 退役步骤（以 2026-11-05 退役日本节点为例）

1. **清单**：`proxy-nodes.meta.json` 删掉该节点的条目；临时下线可改成 `"enabled": false`
   （等价于删除，但保留定义便于回滚）。
2. **凭据**：`proxy-nodes.creds.json.age` 删同名键；`relay/tuic-server-jp*.age` 这类
   只属于它的密文删文件，并在 `secrets.nix` 删对应规则。
3. **地址表**：不用动 —— 节点的 `server`/`server6` 由转换器自动并入 `directCidrs`/
   `directDomains`。只有「机器专属、但不属于任何节点」的地址（如该机的 v4 字面量、
   同机的非代理域名）需要手工删。
4. **DNS**：Cloudflare 删属于它的 A/AAAA（该域名不再被任何节点引用时）。
5. **验收**：`scripts/check-nodes.sh` 全绿；它现在会直接报「creds 残留」「地址表重复」。
6. **落地**：push nix-secrets → `nix flake update mysecrets` → 重新部署 zen14 与 nova13。

自动化掉的部分（不用再改）：

- 两台主机的 tuic-client 实例：`modules/nixos/tuic-client` 从 meta 派生 unit
  （`relay.instance` 进 unit 名、`port` 进 listen、`relay.serverSecret` 指向密文）。
- 组归属：只由 meta 的 `sibGroups` 决定；sib base 里的节点组只留 `["直连"]` 占位，
  有成员时丢掉占位，没有成员时退回 `直连`（组永远非空，不会 dangling）。
- 直连表：节点的域名/字面量自动并入，退役时随之消失。
- 手机导出（`clash-export`）：兜底组按「美国 + 香港」的组 filter 现算，不写节点名。
- miho 侧的所有组（含 `DNS`）：`include-all` + `exclude-type: direct` + 名称 filter，
  成员现算，没有一份手写名单会在退役后变悬空。

## 新增节点

1. 在 `proxy-nodes.meta.json` 加条目：`name`、`kind`、`port`、`sibGroups`（`全部节点`
   是约定必须的，否则节点不在任何组里，等于选不到）、`enabled: true`。
2. socks 节点且由本机 tuic-client 提供时，再给 `relay`：
   `{instance, serverSecret, ipSecret?}`；`instance` 是 unit 名后缀（ASCII），
   `port` 就是 sib 出站指向的 `127.0.0.1:<port>`。
3. 在 `proxy-nodes.creds.json.age` 加同名条目（socks 节点只描述本机监听，不需要）。
   缺条目时合并器会直接报错，不会拖到 prepare 阶段。
4. `scripts/check-nodes.sh` → push → `nix flake update mysecrets` → 部署。

## 为什么组不再写成员

sib base（`sib-conf/zen14.json.age`）里的组名（`日本`/`美国`/`香港`/`全部节点`/
`自动选择`/`DNS`）只保留 `["直连"]` 占位。成员唯一来源是 meta 的 `sibGroups`。
退役后 `日本` 组会变成 `["直连"]` 空壳：`默认`/`Google`/`YouTube` 等组仍把它列为
可选项，选中等于直连 —— 这是刻意保留的（删组要改加密 base，且会让这些组的成员列表
指向不存在的组）。mihomo 那一侧（`miho-conf`）的 `日本` 是 `include-all` + filter，
没有成员时会变成空组，手游端不要选它。

## 悬空成员由谁发现

`mihomo-render` 在写出配置前校验：每个组的显式 `proxies` 成员必须是 `proxies` 里的
名字、另一个组名或 mihomo 内建策略（`DIRECT`/`REJECT`/…）。不满足时 prepare 阶段
就失败，并打印「组 → 名字」。

为什么需要它：2026-11-05 退役日本节点后，`miho-conf` 的 `DNS` 组仍手写
`日-hy2`/`日-tuic`，prepare 明明成功，mihomo 却在启动时
`Parse config error: proxy group[N]: DNS: '日-hy2' not found` 反复 fatal 重启。
校验把这一错误前移到 prepare，一次说清。**结论仍是不在 base 里手写成员**：
校验只负责让错的那一次早点、清楚地失败。
