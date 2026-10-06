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

# The post-uninstall cleanup (templates/50-cleanup.yaml).
c="$(render -s templates/50-cleanup.yaml)"
[[ "$(grep -c 'helm.sh/hook: post-delete' <<<"$c")" == 4 && "$(grep -c 'argocd.argoproj.io/hook: PostDelete' <<<"$c")" == 4 ]] \
  && ok "cleanup: four post-delete hooks, for Helm and Argo CD" || bad "cleanup hooks"
grep -q 'resourceNames: \["persesdashboard-editor-role","persesdashboard-viewer-role","persesdatasource-editor-role","persesdatasource-viewer-role","persesglobaldatasource-editor-role","persesglobaldatasource-viewer-role"\]' <<<"$c" \
  && ok "cleanup: delete limited to COO's six team roles by name" || bad "cleanup role resourceNames"
! grep -q 'customresourcedefinitions' <<<"$c" && ok "cleanup: no access to CRDs" || bad "cleanup must not touch CRDs"
render -s templates/50-cleanup.yaml --set cleanup.consolePlugin=false | grep -q 'resources: \["consoles"\]' \
  && bad "cleanup.consolePlugin=false grants nothing on the console config" || ok "cleanup.consolePlugin=false grants nothing on the console config"
render -s templates/50-cleanup.yaml | grep -q 'resources: \["consoles"\]' && ok "cleanup grants patch on the console config by default" || bad "cleanup console rule missing"
o="$(objects --set cleanup.enabled=false)"
has "$o" "Job/coo-openshift-coo-cleanup" && bad "cleanup.enabled=false renders no cleanup" || ok "cleanup.enabled=false renders no cleanup"
# Argo CD's Application targets COO's namespace, which the chart deletes: the Job must run elsewhere.
argo="$(helm template coo "${CHART}" -n openshift-cluster-observability-operator --kube-version 1.35.0 2>&1)"
grep -q "set cleanup.namespace to a namespace that survives" <<<"$argo" \
  && ok "cleanup refuses to run in the namespace the chart deletes" || bad "cleanup in COO's namespace: ${argo:0:200}"
helm template coo "${CHART}" -n openshift-cluster-observability-operator --kube-version 1.35.0 --set cleanup.namespace=platform-tools \
  -s templates/50-cleanup.yaml 2>&1 | grep -q '^  namespace: platform-tools$' && ok "cleanup.namespace places the Job" || bad "cleanup.namespace"
render --set operator.typo=1 >/dev/null 2>&1 && bad "the schema refuses an unknown key" || ok "the schema refuses an unknown key"

# The Grafana-to-Perses converter page (templates/60-converter.yaml): off by default, self-contained, locked down.
o="$(objects)"
has "$o" "Deployment/perses-converter" && bad "no converter by default" || ok "no converter by default"
c="$(render --set converter.enabled=true --set converter.namespace=platform-tools -s templates/60-converter.yaml)"
[[ "$(grep -c '^kind: ' <<<"$c")" == 6 ]] && ok "converter: ServiceAccount, ConfigMap, Deployment, Service, Route, NetworkPolicy" || bad "converter objects: $(grep '^kind: ' <<<"$c" | tr '\n' ' ')"
[[ "$(grep -c '^  namespace: platform-tools$' <<<"$c")" == 6 ]] && ok "converter.namespace places every converter object" || bad "converter namespace"
grep -q 'image: "docker.io/persesdev/perses:v0.54.0"' <<<"$c" && ok "the engine is the official Perses image at converter.persesVersion" || bad "converter Perses image"
grep -q -- '--web.listen-address=127.0.0.1:8080' <<<"$c" && grep -q -- '-upstream=http://127.0.0.1:8081' <<<"$c" && ok "the engine and the page listen on the loopback; only the login proxy leaves the pod" || bad "converter listen addresses"
[[ "$(grep -c 'automountServiceAccountToken: false' <<<"$c")" == 2 ]] && ok "no ServiceAccount token is mounted by default" || bad "converter automount"
[[ "$(grep -c 'mountPath: /var/run/secrets/kubernetes.io/serviceaccount' <<<"$c")" == 1 ]] && ok "the token is mounted in one container, the login proxy" || bad "converter token mount"
grep -q 'readOnlyRootFilesystem: true' <<<"$c" && ! grep -q 'persistentVolumeClaim' <<<"$c" && ok "read-only root filesystem and no persistent volume" || bad "converter storage"
grep -q 'termination: reencrypt' <<<"$c" && ok "the Route re-encrypts to the proxy" || bad "converter Route"
grep -q 'grafana: text,' charts/openshift-coo/files/converter/index.html && ok "the page sends the dashboard as the text it was given, not re-written by the browser" || bad "page re-writes the upload"
[[ "$(grep -c 'startupProbe:' <<<"$c")" == 2 && "$(grep -c 'livenessProbe:' <<<"$c")" == 2 ]] && ! grep -q 'readinessProbe:' <<<"$c" \
  && ok "converter: a start-up check and a liveness check per served container, no periodic readiness check" || bad "converter probes"
[[ "$(grep -A8 'livenessProbe:' <<<"$c" | grep -c 'periodSeconds: 1800')" == 2 && "$(grep -A8 'livenessProbe:' <<<"$c" | grep -c 'failureThreshold: 1$')" == 2 ]] \
  && ok "the liveness checks run every 30 minutes by default, and one failure restarts the container" || bad "converter liveness period"
render --set converter.enabled=true --set converter.livenessPeriodSeconds=900 -s templates/60-converter.yaml | grep -q 'periodSeconds: 900' \
  && ok "converter.livenessPeriodSeconds sets the liveness interval" || bad "converter.livenessPeriodSeconds"
grep -q 'policyTypes: \[Ingress, Egress\]' <<<"$c" && ok "the NetworkPolicy limits both directions" || bad "converter NetworkPolicy"
render --set converter.enabled=true --set converter.networkPolicy.enabled=false -s templates/60-converter.yaml | grep -q 'kind: NetworkPolicy' \
  && bad "converter.networkPolicy.enabled=false renders none" || ok "converter.networkPolicy.enabled=false renders none"
grep -q 'def convert(request):' <<<"$c" && grep -q '<title>Grafana to Perses</title>' <<<"$c" && ok "the ConfigMap carries server.py and index.html from files/converter" || bad "converter ConfigMap content"
render --set converter.enabled=true --set converter.persesVersion=v0.54.0 >/dev/null 2>&1 && bad "the schema refuses a Perses version with a v" || ok "the schema refuses a Perses version with a v"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "${CHART}/files/converter/server.py" 2>/dev/null && ok "server.py parses" || bad "server.py does not parse"

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
[[ $n == 4 ]] && ok "four Job scripts checked" || bad "expected four Job scripts, found $n"

[[ $fails == 0 ]] && echo "all chart tests passed" || { echo "${fails} failed"; exit 1; }
