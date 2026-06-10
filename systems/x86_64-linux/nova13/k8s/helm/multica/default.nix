{ pkgs, hostname ? "nova13" }:
let
  namespace = "multica";
  releaseName = "multica";
  secretName = "multica-secrets";
  frontendNodePort = 30082;
  backendNodePort = 30081;
  chart =
    let
      src = pkgs.fetchFromGitHub {
        owner = "multica-ai";
        repo = "multica";
        rev = "v0.3.19";
        sha256 = "QXQ1N9TMMAPGmDp4A4G15u/jsvXa2fOTyFQy01/FYGM=";
      };
    in
    pkgs.runCommand "multica-chart" { inherit src; } ''
      mkdir -p $out
      cp -r $src/deploy/helm/multica/* $out/
    '';

  valuesFile = ./values.yaml;
  extraResourcesFile = ./extra-resources.yaml;
  postRenderer = pkgs.writeShellScript "multica-helm-post-renderer" ''
    set -euo pipefail

    tmp_yaml=$(mktemp)
    cat > "$tmp_yaml"

    ${pkgs.python3.withPackages (ps: [ ps.pyyaml ])}/bin/python - "$tmp_yaml" <<'PY'
import sys, yaml
src = sys.argv[1]
with open(src) as f:
    docs = list(yaml.safe_load_all(f))

pin_names = {"multica-backend", "multica-frontend", "multica-postgres"}
node_port_map = {
    "multica-frontend": ${toString frontendNodePort},
    "multica-backend": ${toString backendNodePort},
}

for doc in docs:
    if not isinstance(doc, dict):
        continue

    kind = doc.get("kind")
    metadata = doc.get("metadata") or {}
    name = metadata.get("name")

    if doc.get("apiVersion") == "apps/v1" and kind == "Deployment":
        if name in pin_names:
            spec = doc.setdefault("spec", {}).setdefault("template", {}).setdefault("spec", {})
            spec["nodeSelector"] = {"kubernetes.io/hostname": "${hostname}"}
            spec["tolerations"] = [{
                "key": "dedicated",
                "operator": "Equal",
                "value": "${hostname}",
                "effect": "NoSchedule",
            }]

    if doc.get("apiVersion") == "v1" and kind == "Service" and name in node_port_map:
        spec = doc.setdefault("spec", {})
        spec["type"] = "NodePort"
        ports = spec.get("ports") or []
        if ports:
            ports[0]["nodePort"] = node_port_map[name]

first = True
for doc in docs:
    if doc is None:
        continue
    if not first:
        print('---')
    print(yaml.safe_dump(doc, sort_keys=False), end="")
    first = False
PY
  '';
in
{
  inherit namespace releaseName secretName chart valuesFile extraResourcesFile postRenderer frontendNodePort backendNodePort;
}
