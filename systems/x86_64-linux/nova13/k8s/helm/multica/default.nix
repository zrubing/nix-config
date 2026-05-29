{ pkgs, hostname ? "nova13" }:
let
  namespace = "multica";
  releaseName = "multica";
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

  manifest = pkgs.runCommand "multica-manifest.yaml"
    {
      nativeBuildInputs = [
        pkgs.kubernetes-helm
        (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
      ];
    }
    ''
      tmp_yaml=$(mktemp)
      helm template ${releaseName} ${chart} -f ${valuesFile} > "$tmp_yaml"

      python - "$tmp_yaml" "$out" <<'PY'
import sys, yaml
src, out = sys.argv[1], sys.argv[2]
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

with open(out, 'w') as f:
    first = True
    for doc in docs:
        if doc is None:
            continue
        if not first:
            f.write('---\n')
        yaml.safe_dump(doc, f, sort_keys=False)
        first = False
    f.write('---\n')
    with open('${extraResourcesFile}') as extra:
        f.write(extra.read())
PY
    '';
in
{
  inherit namespace releaseName chart manifest valuesFile extraResourcesFile;
}
