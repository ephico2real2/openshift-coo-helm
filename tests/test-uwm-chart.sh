#!/usr/bin/env bash
# Template tests for charts/openshift-user-workload-monitoring, no cluster needed:  tests/test-uwm-chart.sh
# Needs helm (3 or 4) and ruby (for YAML).
set -uo pipefail
cd "$(dirname "$0")/.."
CHART=charts/openshift-user-workload-monitoring
fails=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
render() { helm template uwm "${CHART}" -n openshift-user-workload-monitoring --kube-version 1.35.0 "$@" 2>&1; }

helm lint "${CHART}" >/dev/null 2>&1 && ok "helm lint" || bad "helm lint"

out="$(render -f "${CHART}/examples/values-ipsec-nas.yaml")"
[[ "$(grep -c '^kind:' <<<"$out")" == 1 && "$(grep '^kind:' <<<"$out")" == "kind: ConfigMap" ]] && ok "exactly one object, a ConfigMap" || bad "objects: $(grep '^kind:' <<<"$out" | tr '\n' ' ')"
grep -q '^  name: user-workload-monitoring-config$' <<<"$out" && grep -q '^  namespace: openshift-user-workload-monitoring$' <<<"$out" \
  && ok "user-workload-monitoring-config in openshift-user-workload-monitoring" || bad "name or namespace"
# config.yaml, parsed back, equals the example's config
ruby -ryaml -e '
  cm = YAML.load_stream(ARGV[0]).compact.first
  want = YAML.load_file(ARGV[1])["config"]
  exit(YAML.safe_load(cm["data"]["config.yaml"]) == want ? 0 : 1)' -- "$out" "${CHART}/examples/values-ipsec-nas.yaml" \
  && ok "config.yaml equals the example's config" || bad "config.yaml differs from the example's config"
render -n other | grep -q '^  namespace: openshift-user-workload-monitoring$' && ok "the namespace does not follow the release" || bad "namespace follows the release"

grep -q '^data: {}$' <<<"$(render)" && ok "empty config renders data: {} (the operator's default)" || bad "empty config"
render --set config.alertmanagr.enabled=true >/dev/null 2>&1 && bad "a misspelt top-level key is refused" || ok "a misspelt top-level key is refused"
render --set 'config.namespacesWithoutLabelEnforcement=kcs-ipsec' >/dev/null 2>&1 && bad "namespacesWithoutLabelEnforcement must be a list" || ok "namespacesWithoutLabelEnforcement must be a list"
old="$(render --kube-version 1.30.9)"
grep -q 'requires kubeVersion: >=1.31.0-0' <<<"$old" && ok "Kubernetes 1.30 (OpenShift 4.17) is refused" || bad "kubeVersion check: ${old}"

[[ ${fails} == 0 ]] && echo "all user-workload-monitoring chart tests passed" || { echo "${fails} failed"; exit 1; }
