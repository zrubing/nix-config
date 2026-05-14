---
name: sealed-secrets
description: 用于生成、审查和排查 Kubernetes SealedSecret，特别是无本地 PEM 时通过 kubeseal 拉取 controller 公钥、从 env 文件生成 Secret 并加密为 SealedSecret；包含常见错误“输出成 CERT 而不是 SealedSecret”的修正。
---

# Kubernetes SealedSecret

当用户要求把 K8s Secret 改为 SealedSecret、生成 sealed-secret.yaml、使用 kubeseal、处理 `sealed-secrets-public-key.pem`、或排查生成结果是 `-----BEGIN CERTIFICATE-----` 时，使用此技能。

## 核心原则

- 应用 Deployment 不直接读取 SealedSecret；Deployment 仍通过 `envFrom.secretRef` 或 `secretKeyRef` 读取普通 `Secret`。
- SealedSecret 由集群内 Sealed Secrets Controller 解密为同名普通 Secret。
- 明文 `.env` / Secret YAML 不提交 Git；提交的是加密后的 `SealedSecret` YAML。
- `metadata.name`、`metadata.namespace` 必须和目标 Secret / 目标 namespace 一致；strict scope 下命名空间和名称会参与加密绑定。

## 关键坑：`--fetch-cert` 只输出证书

当前常见 `kubeseal` 版本中：

```bash
kubeseal --fetch-cert ...
```

只会向 stdout 输出 PEM 证书，例如：

```text
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
```

它不会同时读取 stdin 并生成 SealedSecret。因此不要写成：

```bash
kubectl create secret ... -o yaml | kubeseal --fetch-cert -o yaml > sealed-secret.yaml
```

这类命令的输出通常会是 cert，而不是 `kind: SealedSecret`。

正确做法是两步：

1. `kubeseal --fetch-cert > /tmp/sealed-secrets-public-key.pem`
2. `kubectl create secret ... --dry-run=client -o yaml | kubeseal --cert /tmp/sealed-secrets-public-key.pem -o yaml > sealed-secret.yaml`

## 无本地 PEM：从 env 文件生成 SealedSecret

生产环境示例：

```bash
cd /path/to/repo && \
kubeseal \
  --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > /tmp/sealed-secrets-public-key.pem && \
kubectl create secret generic <secret-name> \
  --from-env-file=.env.prod \
  --namespace=<prod-namespace> \
  --dry-run=client -o yaml | \
kubeseal \
  --cert /tmp/sealed-secrets-public-key.pem \
  -o yaml \
  > k8s/sealed-secret.yaml
```

测试环境示例：

```bash
cd /path/to/repo && \
kubeseal \
  --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > /tmp/sealed-secrets-public-key.pem && \
kubectl create secret generic <secret-name> \
  --from-env-file=.env.test \
  --namespace=<test-namespace> \
  --dry-run=client -o yaml | \
kubeseal \
  --cert /tmp/sealed-secrets-public-key.pem \
  -o yaml \
  > k8s/sealed-secret-test.yaml
```

## 有本地 PEM：从 env 文件生成 SealedSecret

```bash
cd /path/to/repo && \
kubectl create secret generic <secret-name> \
  --from-env-file=.env.test \
  --namespace=<namespace> \
  --dry-run=client -o yaml | \
kubeseal \
  --cert sealed-secrets-public-key.pem \
  -o yaml \
  > k8s/sealed-secret-test.yaml
```

## 从字面值生成 SealedSecret

适合临时少量字段；注意 shell history 可能留下敏感值，优先用 env 文件。

```bash
cd /path/to/repo && \
kubeseal \
  --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > /tmp/sealed-secrets-public-key.pem && \
kubectl create secret generic <secret-name> \
  --from-literal=KEY1='value1' \
  --from-literal=KEY2='value2' \
  --namespace=<namespace> \
  --dry-run=client -o yaml | \
kubeseal \
  --cert /tmp/sealed-secrets-public-key.pem \
  -o yaml \
  > k8s/sealed-secret.yaml
```

## Deployment 读取示例

SealedSecret 解密后生成普通 Secret，例如 `my-app-env`。Deployment 应这样读：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      containers:
        - name: my-app
          envFrom:
            - secretRef:
                name: my-app-env
                optional: true
```

## CI 部署资源要求

如果使用 GitOps/CI 直接 apply manifest，部署资源列表必须包含 SealedSecret，且顺序建议在 Deployment 前：

```text
k8s/sealed-secret.yaml,k8s/service.yaml,k8s/deployment.yaml,k8s/httproute.yaml
```

测试环境类似：

```text
k8s/sealed-secret-test.yaml,k8s/service.yaml,k8s/deployment.yaml,k8s/httproute-test.yaml
```

## 自检命令

生成后先看文件头：

```bash
head -20 k8s/sealed-secret-test.yaml
```

正确结果应包含：

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: <secret-name>
  namespace: <namespace>
spec:
  encryptedData:
```

如果看到：

```text
-----BEGIN CERTIFICATE-----
```

说明输出的是 controller 公钥证书，不是 SealedSecret。重新按“两步法”生成。

验证集群解密：

```bash
kubectl get sealedsecret -n <namespace> <secret-name>
kubectl get secret -n <namespace> <secret-name>
kubectl describe sealedsecret -n <namespace> <secret-name>
```

## 常见排障

1. **`sealed-secret.yaml` 是证书**
   - 原因：误把 `kubeseal --fetch-cert` 的 stdout 重定向到了 sealed-secret 文件。
   - 修复：先保存到 `/tmp/sealed-secrets-public-key.pem`，再用 `kubeseal --cert` 加密。

2. **Secret 没有生成**
   - 检查 controller：`kubectl get deploy -n sealed-secrets`。
   - 检查 SealedSecret 状态：`kubectl describe sealedsecret -n <namespace> <secret-name>`。

3. **无法解密 / scope 不匹配**
   - 确认生成时的 `--namespace`、Secret name、最终 apply 的 namespace 完全一致。
   - strict scope 下不能把一个 namespace 生成的 SealedSecret 拿去另一个 namespace 用。

4. **controller 名称不一致**
   - 默认可能是 `sealed-secrets-controller` / `kube-system`。
   - 当前 hinihao 常用：`--controller-name=sealed-secrets --controller-namespace=sealed-secrets`。
   - 不确定时执行：`kubectl get deploy -A | grep sealed`。

## 输出要求

实施时需明确给出：

1. 目标 Secret 名称与 namespace。
2. 是否使用本地 PEM；无 PEM 时必须使用“两步法”。
3. 最终写入的 SealedSecret 文件路径。
4. 自检结果：文件头必须是 `kind: SealedSecret`，不能是 PEM certificate。
