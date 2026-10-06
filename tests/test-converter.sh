#!/usr/bin/env bash
# Functional test of the Grafana-to-Perses converter (charts/openshift-coo/files/converter/server.py), no cluster
# needed:  tests/test-converter.sh
# It starts the official Perses image as the engine, runs server.py against it, and converts tests/fixtures/
# ipsec-nas.json. Needs podman or docker, python3 and curl; skips when there is no container engine.
#   PERSES_IMAGE=docker.io/persesdev/perses:v0.54.0
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
IMAGE="${PERSES_IMAGE:-docker.io/persesdev/perses:v0.54.0}"
ENGINE="$(command -v podman || command -v docker)" || { echo "skip  no podman or docker"; exit 0; }
FIXTURE=tests/fixtures/ipsec-nas.json
tmp="$(mktemp -d)"; chmod a+rx "${tmp}"; cp "${FIXTURE}" "${tmp}/dashboard.json"; chmod a+r "${tmp}/dashboard.json"
cleanup() { [[ -n "${SERVER_PID:-}" ]] && kill "${SERVER_PID}" 2>/dev/null; "${ENGINE}" rm -f converter-test >/dev/null 2>&1; rm -rf "${tmp}"; }
trap cleanup EXIT

"${ENGINE}" rm -f converter-test >/dev/null 2>&1
"${ENGINE}" run -d --name converter-test -p 18092:8080 -v "${tmp}:/work" "${IMAGE}" >/dev/null || { echo "FAIL  could not start ${IMAGE}"; exit 1; }
PERSES_URL=http://localhost:18092 PERSES_VERSION=0.54.0 LISTEN_PORT=18093 python3 charts/openshift-coo/files/converter/server.py 2>"${tmp}/server.log" &
SERVER_PID=$!
for _ in $(seq 1 30); do curl -sf localhost:18093/readyz >/dev/null 2>&1 && break; sleep 1; done

# The reference: percli offline in the same image, with the same option.
"${ENGINE}" exec converter-test /bin/percli migrate -f /work/dashboard.json --format native \
  --plugin.path /etc/perses/plugins --use-default-datasource -o json > "${tmp}/percli.json" 2>/dev/null

python3 - "${FIXTURE}" "${tmp}" <<'PY'
import json, sys, urllib.request, urllib.error
fixture, tmp = sys.argv[1], sys.argv[2]
grafana = json.load(open(fixture)); fails = 0
def check(what, ok, detail=""):
    global fails
    print(("ok    " if ok else "FAIL  ") + what + ("" if ok else f": {detail}")); fails += 0 if ok else 1
def post(payload=None, raw=None):
    data = raw if raw is not None else json.dumps(payload).encode()
    req = urllib.request.Request("http://localhost:18093/api/convert", data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=90) as r: return r.status, json.load(r)
    except urllib.error.HTTPError as e: return e.code, json.load(e)

page = urllib.request.urlopen("http://localhost:18093/", timeout=10).read().decode()
check("the page is served and names the Perses version", "<title>Grafana to Perses</title>" in page and "<strong>0.54.0</strong>" in page)

st, out = post({"grafana": grafana, "namespace": "kcs-ipsec", "output": "native"})
report = out.get("report", {})
want = json.load(open(f"{tmp}/percli.json"))["spec"]
check("the conversion equals percli migrate --use-default-datasource, offline", st == 200 and json.loads(out["content"])["spec"] == want)
check("23 of 23 panels converted, none a placeholder", report.get("converted") == 23 and report.get("placeholders") == 0, str(report.get("byKind")))
check("the report counts the charts by kind", report.get("byKind") == {"BarChart": 1, "StatChart": 16, "Table": 3, "TimeSeriesChart": 3}, str(report.get("byKind")))
check("the report lists the six sections", len(report.get("sections", [])) == 6)
notes = {p["title"]: p["notes"] for p in report.get("panels", [])}
check("Grafana transformations are flagged for a check", any("transformations" in n for n in notes.get("Per node", [])))
types = [(p["grafanaType"], p["persesKind"]) for p in report.get("panels", []) if p["title"] == "Claims on the NAS"]
check("two panels with one title keep their own Grafana type", types == [("stat", "StatChart"), ("table", "Table")], str(types))

st, out = post({"grafana": grafana, "namespace": "kcs-ipsec", "name": "ipsec-nas", "datasource": "ipsec-nas-thanos", "includeDatasource": True})
content = out.get("content", "")
check("the custom resource is perses.dev/v1alpha2 for the namespace", st == 200 and content.startswith("apiVersion: perses.dev/v1alpha2\nkind: PersesDashboard\nmetadata:\n  name: ipsec-nas\n  namespace: kcs-ipsec\n"))
check("every query names the datasource, and the Grafana input variable is dropped", "${DS_PROMETHEUS}" not in content and "name: ipsec-nas-thanos" in content and any("dropped the variable DS_PROMETHEUS" in a for a in out["report"]["adjustments"]))
check("the PersesDatasource for Thanos port 9091 is added on request", "\n---\napiVersion: perses.dev/v1alpha2\nkind: PersesDatasource" in content and ":9091" in content)
open(f"{tmp}/out.yaml", "w").write(content)

st, out = post(raw=b"{not json");                                              check("malformed JSON is refused with the reason", st == 400 and "not valid JSON" in out.get("error", ""), str(out))
as_text = post({"grafana": open(fixture).read(), "namespace": "kcs-ipsec", "output": "native"})
check("the dashboard sent as text, the way the page sends it, converts to the same as percli", as_text[0] == 200 and json.loads(as_text[1]["content"])["spec"] == want)
st, out = post({"grafana": {"title": "x"}, "namespace": "a"});                 check("a JSON that is not a dashboard is refused", st == 400 and "no 'panels' list" in out.get("error", ""), str(out))
st, out = post({"grafana": grafana, "namespace": "Bad_Name"});                 check("an invalid namespace is refused", st == 400, str(out))
st, out = post(raw=json.dumps({"grafana": {"panels": [], "pad": "x" * 2200000}, "namespace": "a"}).encode())
check("an oversized upload is refused with the limit", st == 413 and "2097152" in out.get("error", ""), str(out))
sys.exit(1 if fails else 0)
PY
status=$?

# The YAML the page writes must read back as the same data (the page has no YAML library).
if command -v yq >/dev/null; then
  python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["spec"], sort_keys=True))' "${tmp}/percli.json" > "${tmp}/a.json"
  curl -s -X POST -H 'Content-Type: application/json' localhost:18093/api/convert \
    -d "$(python3 -c 'import json, sys; print(json.dumps({"grafana": json.load(open(sys.argv[1])), "namespace": "kcs-ipsec"}))' "${FIXTURE}")" \
    | python3 -c 'import json, sys; sys.stdout.write(json.load(sys.stdin)["content"])' | yq -o=json '.spec.config' \
    | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))' > "${tmp}/b.json"
  cmp -s "${tmp}/a.json" "${tmp}/b.json" && echo "ok    the YAML reads back as percli's dashboard" || { echo "FAIL  the YAML does not read back as percli's dashboard"; status=1; }
fi
grep -q '"panels"' "${tmp}/server.log" && { echo "FAIL  the server log contains upload content"; status=1; } || echo "ok    the server log holds no upload content"
[[ ${status} == 0 ]] && echo "all converter tests passed" || { echo "converter tests failed"; exit 1; }
