#!/usr/bin/env bash
# Template tests for charts/openshift-coo, no cluster needed:  tests/test-chart.sh
# Needs helm (3 or 4) and python3; uses shellcheck on the Jobs' scripts when it is installed.
set -uo pipefail
cd "$(dirname "$0")/.."
CHART=charts/openshift-coo
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
render() { helm template coo "${CHART}" -n platform-tools --kube-version 1.35.0 "$@" 2>&1; }
# kinds/names of one rendering, one per line: "Kind/name"
objects() { render "$@" | python3 -c '
import sys, re
for doc in sys.stdin.read().split("\n---"):
    k = re.search(r"^kind: (\S+)", doc, re.M); n = re.search(r"^  name: (\S+)", doc, re.M)
    if k and n: print(f"{k.group(1)}/{n.group(1)}")'; }
has()  { grep -qx "$2" <<<"$1"; }

helm lint "${CHART}" >/dev/null 2>&1 && ok "helm lint" || bad "helm lint"

out="$(render)"; [[ $? -eq 0 ]] && ok "renders with the defaults" || bad "renders with the defaults: ${out}"
grep -q '^  startingCSV: cluster-observability-operator.v1.5.3$' <<<"$out" && ok "the Subscription starts at the pinned CSV" || bad "startingCSV"
grep -q '^  installPlanApproval: Manual$' <<<"$out" && ok "Manual approval" || bad "Manual approval"
[[ "$(grep -c 'value: "cluster-observability-operator.v1.5.3"' <<<"$out")" == 2 ]] && ok "the approver and the gate target the pinned CSV" || bad "TARGET in approver and gate"
grep -q 'openshift.io/cluster-monitoring: "true"' <<<"$out" && ok "the namespace carries the cluster-monitoring label" || bad "namespace label"

# helm exits non-zero here by design; capture first (with pipefail, piping it would fail even on the right message).
old="$(render --kube-version 1.31.9)"
grep -q "requires kubeVersion: >=1.32.0-0" <<<"$old" && ok "Kubernetes 1.31 (OpenShift 4.18) is refused by the version check" || bad "Kubernetes 1.31 (OpenShift 4.18) is refused by the version check: ${old}"
render --kube-version 1.32.0 >/dev/null 2>&1 && ok "Kubernetes 1.32 (OpenShift 4.19) renders" || bad "Kubernetes 1.32 (OpenShift 4.19) renders"

o="$(objects)"
has "$o" "ClusterRoleBinding/coo-openshift-coo-cluster-monitoring-view" && bad "no metrics binding without groups" || ok "no metrics binding without groups"
o="$(objects --set 'metricsAccess.groups={system:authenticated,team-a}')"
has "$o" "ClusterRoleBinding/coo-openshift-coo-cluster-monitoring-view" && ok "metricsAccess.groups binds cluster-monitoring-view" || bad "metrics binding"
[[ "$(render --set 'metricsAccess.groups={system:authenticated,team-a}' | grep -c 'kind: Group')" == 2 ]] && ok "one subject per group" || bad "one subject per group"

o="$(objects --set namespace.create=false)"
{ has "$o" "Namespace/openshift-cluster-observability-operator" || has "$o" "OperatorGroup/cluster-observability-operator"; } \
  && bad "namespace.create=false renders no Namespace and no OperatorGroup" || ok "namespace.create=false renders no Namespace and no OperatorGroup"
o="$(objects --set csvReclaim.enabled=false)"
has "$o" "Job/coo-openshift-coo-csv-reclaim" && bad "csvReclaim.enabled=false renders no reclaim" || ok "csvReclaim.enabled=false renders no reclaim"
o="$(objects --set platformScrapeRBAC=false)"
has "$o" "Role/coo-openshift-coo-prometheus-k8s" && bad "platformScrapeRBAC=false renders no grant" || ok "platformScrapeRBAC=false renders no grant"
render --set platformScrapeRBAC=false | grep -A1 'name: SCRAPE_ROLE' | grep -q 'value: "prometheus-k8s"' \
  && ok "without the chart's grant, the gate checks COO's own" || bad "gate SCRAPE_ROLE"
render --set uiPlugin.clusterHealthAnalyzer=false | grep -A1 'clusterHealthAnalyzer:' | grep -q 'enabled: false' \
  && ok "uiPlugin.clusterHealthAnalyzer=false reaches the UIPlugin" || bad "clusterHealthAnalyzer value"

render --set operator.version=v1.5.3 >/dev/null 2>&1 && bad "the schema refuses a version with a v" || ok "the schema refuses a version with a v"
render --set operator.typo=1 >/dev/null 2>&1 && bad "the schema refuses an unknown key" || ok "the schema refuses an unknown key"

# The three Jobs' scripts: bash syntax, and shellcheck when available.
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
render --set 'metricsAccess.groups={x}' | python3 -c '
import sys, re
docs = sys.stdin.read().split("\n---")
for doc in docs:
    if "kind: Job" not in doc: continue
    name = re.search(r"^  name: (\S+)", doc, re.M).group(1)
    m = re.search(r"\n          args:\n            - \|\n(.*)", doc, re.S)
    lines = [l[14:] if l.startswith(" " * 14) else l.strip() for l in m.group(1).splitlines()]
    open(sys.argv[1] + "/" + name + ".sh", "w").write("\n".join(lines) + "\n")' "${tmp}"
n=0
for f in "${tmp}"/*.sh; do
  n=$((n + 1))
  bash -n "$f" 2>/dev/null && ok "bash -n $(basename "$f" .sh)" || bad "bash -n $(basename "$f" .sh): $(bash -n "$f" 2>&1)"
  if command -v shellcheck >/dev/null; then
    shellcheck -S warning -s bash "$f" >/dev/null && ok "shellcheck $(basename "$f" .sh)" || bad "shellcheck $(basename "$f" .sh): $(shellcheck -S warning -s bash -f gcc "$f" | head -5)"
  fi
done
[[ $n == 3 ]] && ok "three Job scripts checked" || bad "expected three Job scripts, found $n"

[[ $fails == 0 ]] && echo "all chart tests passed" || { echo "${fails} failed"; exit 1; }
