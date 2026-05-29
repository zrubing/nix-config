{ pkgs, hostname ? "nova13" }:
let
  namespace = "multica";
  releaseName = "multica";
  secretName = "multica-secrets";
  chart =
    let
      src = pkgs.fetchFromGitHub {
        owner = "multica-ai";
        repo = "multica";
        rev = "v0.3.11";
        sha256 = "0j3r1qmqfq4fwr3n4xypnzf9niaw9xzp6l83zd81vc08s9cldr2r";
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
for doc in docs:
    if not isinstance(doc, dict):
        continue
    if doc.get("apiVersion") == "apps/v1" and doc.get("kind") == "Deployment":
        name = ((doc.get("metadata") or {}).get("name"))
        if name in pin_names:
            spec = doc.setdefault("spec", {}).setdefault("template", {}).setdefault("spec", {})
            spec["nodeSelector"] = {"kubernetes.io/hostname": "${hostname}"}
            spec["tolerations"] = [{
                "key": "dedicated",
                "operator": "Equal",
                "value": "${hostname}",
                "effect": "NoSchedule",
            }]

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
  inherit namespace releaseName secretName chart valuesFile extraResourcesFile postRenderer;
}
