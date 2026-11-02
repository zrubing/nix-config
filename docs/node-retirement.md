# 退役一个节点

目标：删掉一个节点后，节点清单、分组、本地适配器、凭据、地址表、DNS 都不留残留，
且不会出现「组 → 不存在的出站」这类运行时才炸的错误。

前置：`scripts/check-nodes.sh` 能跑通（需要 mysecrets 和 admin 私钥）。

## 步骤（以日本节点为例）

1. **节点条目**：`mysecrets/proxy-nodes.json.age` 删掉 `日-*` 的所有条目。
   组归属由条目的 `sibGroups` 决定，删掉后 sib/miho 的组里自动消失。
2. **本地 tuic 适配器**：如果该节点有 tuic，删掉两台主机上的实例：
   - `systems/x86_64-linux/zen14/default.nix` 的 `jp` / `jp6`
   - `systems/x86_64-linux/nova13/default.nix` 的同名实例
3. **服务端凭据**：删 `mysecrets/relay/tuic-server-jp.age`、
   `relay/tuic-server-jp-v6-ip.age`，以及 `secrets.nix` 里对应的两条规则。
4. **直连网段**：从 `mysecrets/net-policy-addresses.json.age` 的 `directCidrs` 里
   删掉该机器的 v4/v6。`check-nodes.sh` 会检查「节点 IP 字面量必须在表里」，
   但不会检查表里多出来的项——这一步要手动做。
5. **DNS**：Cloudflare 删掉属于它的 A/AAAA。只有 AAAA 的节点（如 hk）不要补 A。
6. **验收**：`./scripts/check-nodes.sh` 全绿。
7. **落地**：push mysecrets → `nix flake update mysecrets` → 重新部署
   zen14（miho）和 nova13（sib）。漏了 nova13 的话，它上面的 sib 还会引用旧节点。

## 新增节点

反向操作。注意两点：

- `sibGroups` 要写全该进的组（`全部节点` 是约定必须的），否则节点只出现在
  `proxies` 里、不在任何组里，等于选不到。
- 节点 `server` 是域名时，`directCidrs` 要人工补它实际解析到的地址；是 IP 字面量
  时 `check-nodes.sh` 会替你校验。

## 为什么组成员不再写在 base 里

`sib-conf/zen14.json.age` 的节点组（`日本`/`美国`/`香港`/`全部节点`/`自动选择`/`DNS`）
只保留 `["直连"]` 占位；prepare 阶段有成员时丢掉占位，没有成员时退回 `直连`。
这样 base 只是「组存在 + 默认策略」，成员唯一来源是节点清单，退役不会留 dangling。
miho 那边本来就是 `include-all` + 名称过滤，天然自清理。
