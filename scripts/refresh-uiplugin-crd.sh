#!/usr/bin/env bash
# Refreshes charts/openshift-coo/crds/uiplugins.observability.openshift.io.yaml from a cluster that runs the COO
# version in Chart.yaml's appVersion. Run it after changing that version:  scripts/refresh-uiplugin-crd.sh
# Needs oc logged in to such a cluster, and python3.
set -euo pipefail

CRD=uiplugins.observability.openshift.io
OUT=charts/openshift-coo/crds/${CRD}.yaml
want="cluster-observability-operator.v$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' charts/openshift-coo/Chart.yaml)"

# OLM's own CSV carries no olm.copiedFrom label; its copies in every other namespace do.
have="$(oc get csv -A -o json | python3 -c '
import json, sys
names = {c["metadata"]["name"] for c in json.load(sys.stdin)["items"]
         if "olm.copiedFrom" not in (c["metadata"].get("labels") or {})}
print("\n".join(sorted(n for n in names if n.startswith("cluster-observability-operator.v"))))')"
[[ "${have}" == "${want}" ]] || { echo "the cluster runs '${have:-no COO}'; Chart.yaml's appVersion wants ${want}" >&2; exit 1; }

{
  cat <<HDR
# The UIPlugin CRD as COO ${want#*.v} installs it (read from the cluster's CRD, status and OLM metadata removed).
# Helm installs crds/ only when the CRD is absent and never changes or deletes it, so \`helm install\` can create
# the chart's UIPlugin before OLM has installed COO; OLM then takes over this identical CRD.
# Do not edit by hand: regenerate with scripts/refresh-uiplugin-crd.sh.
HDR
  # Keep the name, the generator annotation and the spec; oc prints the YAML.
  oc get crd "${CRD}" -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
m = d["metadata"]
gen = {k: v for k, v in (m.get("annotations") or {}).items() if k == "controller-gen.kubebuilder.io/version"}
json.dump({"apiVersion": d["apiVersion"], "kind": d["kind"],
           "metadata": {"name": m["name"], "annotations": gen}, "spec": d["spec"]}, sys.stdout)' \
    | oc create --dry-run=client -f - -o yaml | grep -v '^  creationTimestamp: null$'
} > "${OUT}.tmp"
mv "${OUT}.tmp" "${OUT}"
echo "wrote ${OUT} (COO ${want#*.v})"
