#!/usr/bin/env python3
"""The Grafana-to-Perses converter page: upload a Grafana dashboard, get a PersesDashboard and a report.

It converts through the Perses server in the same pod (POST /api/migrate on PERSES_URL), which is the official
Perses image and gives the same result as `percli migrate` offline (docs/converter.md, "The engine"). This file
adds what the engine does not: the page, a report of what converted, the perses.dev/v1alpha2 custom resource,
and the datasource name in every query.

Nothing is stored: the upload is parsed as JSON, converted and returned. Standard library only.
Settings come from the environment: PERSES_URL, MAX_UPLOAD_BYTES, PERSES_VERSION, THANOS_URL, LISTEN_HOST, LISTEN_PORT.
"""
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PERSES_URL = os.environ.get("PERSES_URL", "http://127.0.0.1:8080").rstrip("/")
MAX_UPLOAD_BYTES = int(os.environ.get("MAX_UPLOAD_BYTES", "2097152"))
PERSES_VERSION = os.environ.get("PERSES_VERSION", "")
THANOS_URL = os.environ.get("THANOS_URL", "https://thanos-querier.openshift-monitoring.svc.cluster.local:9091")
LISTEN = (os.environ.get("LISTEN_HOST", "127.0.0.1"), int(os.environ.get("LISTEN_PORT", "8081")))

PLACEHOLDER = "Migration from Grafana not supported"
DNS_LABEL = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
PAGE = (pathlib.Path(__file__).parent / "index.html").read_text()


class Refused(Exception):
    """A request the page answers with a clear message instead of a conversion."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


# ---------------------------------------------------------------- the engine

def migrate(grafana, datasource):
    """The Perses dashboard for a Grafana one. With a datasource name, every Grafana datasource input names it
    (percli's --input); without, the project's default datasource is used (percli's --use-default-datasource)."""
    body = {"grafanaDashboard": grafana, "input": {}}
    if datasource:
        body["input"] = {name: datasource for name in datasource_inputs(grafana)}
    else:
        body["useDefaultDatasource"] = True
    request = urllib.request.Request(PERSES_URL + "/api/migrate", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:500]
        raise Refused(422, f"Perses could not convert this dashboard: {detail}") from error
    except (urllib.error.URLError, TimeoutError) as error:
        raise Refused(503, f"the Perses engine in this pod is not answering yet: {error}") from error


def datasource_inputs(grafana):
    """The names Grafana uses for its datasource: the import inputs and the datasource variables."""
    names = [i.get("name") for i in grafana.get("__inputs", []) if i.get("type") == "datasource"]
    names += [v.get("name") for v in grafana.get("templating", {}).get("list", []) if v.get("type") == "datasource"]
    return sorted({n for n in names if n})


def name_datasource(spec, datasource, inputs):
    """After a conversion that names a datasource: percli leaves the variables (filters) without one, so in a
    namespace with no default datasource they send no query; and it keeps the Grafana input as an unused
    variable. Name the datasource in the variables too, and drop that variable."""
    notes = []
    kept = []
    for variable in spec.get("variables", []):
        plugin = variable["spec"].get("plugin", {})
        if plugin.get("kind") == "DatasourceVariable" and variable["spec"].get("name") in inputs:
            notes.append(f"dropped the variable {variable['spec']['name']}: every query now names the datasource {datasource}")
            continue
        if plugin.get("kind", "").startswith("Prometheus"):
            plugin.setdefault("spec", {})["datasource"] = {"kind": "PrometheusDatasource", "name": datasource}
            notes.append(f"the variable {variable['spec']['name']} now queries the datasource {datasource}")
        kept.append(variable)
    if "variables" in spec:
        spec["variables"] = kept
    return notes


# ---------------------------------------------------------------- the report

def grafana_panels(grafana):
    """Every Grafana panel that is not a row, with the panels folded inside collapsed rows."""
    out = []
    for panel in grafana.get("panels", []):
        if panel.get("type") == "row":
            out.extend(p for p in panel.get("panels", []) if p.get("type") != "row")
        else:
            out.append(panel)
    return out


def perses_unit(plugin_spec):
    for holder in (plugin_spec, plugin_spec.get("yAxis") or {}):
        unit = (holder.get("format") or {}).get("unit")
        if unit:
            return unit
    return None


def build_report(grafana, spec):
    """What converted and what to check, panel by panel. Panels are matched to the Grafana ones by title."""
    by_title = {}
    for panel in grafana_panels(grafana):
        by_title.setdefault(panel.get("title", ""), []).append(panel)
    panels, kinds, placeholders = [], {}, 0
    for panel in spec.get("panels", {}).values():
        title = panel["spec"].get("display", {}).get("name", "")
        plugin = panel["spec"]["plugin"]
        # Two panels may share a title; percli keeps Grafana's order, so they are taken in turn.
        same_title = by_title.get(title) or [{}]
        source = same_title.pop(0) if len(same_title) > 1 else same_title[0]
        defaults = source.get("fieldConfig", {}).get("defaults", {})
        notes = []
        placeholder = plugin["kind"] == "Markdown" and PLACEHOLDER in json.dumps(plugin.get("spec", {}))
        if placeholder:
            placeholders += 1
            notes.append(f"not converted: Perses {PERSES_VERSION} has no chart for the Grafana panel type "
                         f"'{source.get('type', 'unknown')}'; the panel is a text placeholder")
        else:
            kinds[plugin["kind"]] = kinds.get(plugin["kind"], 0) + 1
            if source.get("transformations"):
                names = ", ".join(t.get("id", "?") for t in source["transformations"])
                notes.append(f"Grafana transformations ({names}) are not converted: check the panel")
            if defaults.get("mappings"):
                notes.append("value mappings: check that the panel still shows the mapped text")
            unit = defaults.get("unit")
            if unit and unit not in ("none", "short") and not perses_unit(plugin.get("spec", {})):
                notes.append(f"the unit '{unit}' was not carried over")
            if plugin["kind"] == "Table" and len(panel["spec"].get("queries", [])) > 1:
                notes.append("a table with several queries: Perses joins rows only on equal labels, so one entity may show on several rows")
        panels.append({"title": title, "grafanaType": source.get("type", ""), "persesKind": plugin["kind"],
                       "converted": not placeholder, "notes": notes})
    variables = [{"name": v["spec"].get("name", ""), "kind": v["spec"].get("plugin", {}).get("kind", v["kind"])}
                 for v in spec.get("variables", [])]
    return {
        "panels": panels,
        "converted": sum(1 for p in panels if p["converted"]),
        "placeholders": placeholders,
        "byKind": dict(sorted(kinds.items())),
        "sections": [layout["spec"].get("display", {}).get("title", "") for layout in spec.get("layouts", [])],
        "variables": variables,
        "datasourceInputs": datasource_inputs(grafana),
        "persesVersion": PERSES_VERSION,
    }


# ---------------------------------------------------------------- the output

PLAIN = re.compile(r"^[A-Za-z_][A-Za-z0-9_./-]*$")
RESERVED = {"true", "false", "null", "yes", "no", "on", "off", "y", "n", "~"}


def scalar(value):
    """One YAML scalar. A string is written plain only when no YAML reader could take it for anything else;
    otherwise as a JSON string, which is a valid YAML double-quoted scalar."""
    if isinstance(value, str):
        return value if PLAIN.match(value) and value.lower() not in RESERVED else json.dumps(value, ensure_ascii=False)
    return json.dumps(value)


def to_yaml(value, indent=0):
    """Block-style YAML for JSON data (dict, list, string, number, boolean, null)."""
    pad = "  " * indent
    if isinstance(value, dict) and value:
        lines = []
        for key, item in value.items():
            if isinstance(item, (dict, list)) and item:
                lines.append(f"{pad}{scalar(str(key))}:")
                lines.append(to_yaml(item, indent + 1))
            else:
                lines.append(f"{pad}{scalar(str(key))}: {to_yaml(item, 0)}")
        return "\n".join(lines)
    if isinstance(value, list) and value:
        lines = []
        for item in value:
            if isinstance(item, (dict, list)) and item:
                body = to_yaml(item, indent + 1)
                lines.append(f"{pad}- {body.lstrip()}")
            else:
                lines.append(f"{pad}- {to_yaml(item, 0)}")
        return "\n".join(lines)
    if isinstance(value, dict):
        return "{}"
    if isinstance(value, list):
        return "[]"
    return scalar(value)


def slug(text):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", text.lower())).strip("-")[:63].strip("-")


def datasource_resource(name, namespace):
    """The PersesDatasource a namespace needs for OpenShift's metrics: Thanos Querier's cluster-wide port, which
    checks each viewer's own token (viewers need cluster-monitoring-view). The per-namespace port refuses the
    Perses UI's POST queries for readers."""
    return {
        "apiVersion": "perses.dev/v1alpha2", "kind": "PersesDatasource",
        "metadata": {"name": name, "namespace": namespace},
        "spec": {
            "client": {"tls": {"enable": True, "caCert": {"type": "file", "certPath": "/ca/service-ca.crt"}}},
            "config": {"display": {"name": "OpenShift Thanos (cluster)"}, "default": False,
                       "plugin": {"kind": "PrometheusDatasource", "spec": {"proxy": {"kind": "HTTPProxy", "spec": {
                           "url": THANOS_URL, "secret": f"{name}-secret"}}}}},
        },
    }


def convert(request):
    """The whole conversion for one request: the file to download, and the report."""
    grafana = request.get("grafana")
    if isinstance(grafana, str):
        try:
            grafana = json.loads(grafana)
        except json.JSONDecodeError as error:
            raise Refused(400, f"the upload is not valid JSON: {error}") from error
    if not isinstance(grafana, dict) or not isinstance(grafana.get("panels"), list):
        raise Refused(400, "this is not a Grafana dashboard: it has no 'panels' list (export the dashboard as JSON from Grafana)")

    namespace = (request.get("namespace") or "").strip()
    datasource = (request.get("datasource") or "").strip()
    output = request.get("output") or "cr"
    name = (request.get("name") or "").strip() or slug(grafana.get("uid") or grafana.get("title") or "dashboard")
    if output not in ("cr", "native"):
        raise Refused(400, "output must be 'cr' (a PersesDashboard resource) or 'native' (Perses JSON)")
    if output == "cr" and not DNS_LABEL.match(namespace):
        raise Refused(400, "give the namespace the dashboard is for: lowercase letters, digits and '-', at most 63 characters")
    if not DNS_LABEL.match(name):
        raise Refused(400, f"'{name}' is not a valid resource name: lowercase letters, digits and '-', at most 63 characters")
    if datasource and not DNS_LABEL.match(datasource):
        raise Refused(400, f"'{datasource}' is not a valid datasource name: lowercase letters, digits and '-'")

    dashboard = migrate(grafana, datasource)
    spec = dashboard["spec"]
    inputs = datasource_inputs(grafana)
    adjustments = name_datasource(spec, datasource, inputs) if datasource else []
    report = build_report(grafana, spec)
    report["adjustments"] = adjustments
    report["datasource"] = datasource or "the project's default datasource"
    if report["panels"] and report["converted"] == 0:
        raise Refused(502, "no panel was converted: every panel came back as a placeholder, which means the Perses "
                           "engine has not unpacked its plugins; nothing to download")

    if output == "native":
        dashboard["metadata"] = {"name": name, "project": namespace} if namespace else {"name": name}
        return {"filename": f"{name}.perses.json", "contentType": "application/json",
                "content": json.dumps(dashboard, indent=2) + "\n", "report": report}
    resource = {"apiVersion": "perses.dev/v1alpha2", "kind": "PersesDashboard",
                "metadata": {"name": name, "namespace": namespace}, "spec": {"config": spec}}
    documents = [to_yaml(resource)]
    if request.get("includeDatasource") and datasource:
        documents.append(to_yaml(datasource_resource(datasource, namespace)))
    return {"filename": f"{name}.persesdashboard.yaml", "contentType": "application/yaml",
            "content": "\n---\n".join(documents) + "\n", "report": report}


# ---------------------------------------------------------------- the web handler

class Handler(BaseHTTPRequestHandler):
    server_version = "perses-converter"

    def log_message(self, fmt, *args):
        # One line per request on stderr, without the body: an upload is never logged.
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def send(self, status, body, content_type):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, status, payload):
        self.send(status, json.dumps(payload), "application/json")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self.send(200, "ok\n", "text/plain")
        elif path == "/readyz":
            try:
                with urllib.request.urlopen(PERSES_URL + "/api/v1/health", timeout=5) as response:
                    response.read()
                self.send(200, "ok\n", "text/plain")
            except (urllib.error.URLError, TimeoutError) as error:
                self.send(503, f"the Perses engine is not ready: {error}\n", "text/plain")
        elif path == "/":
            page = PAGE.replace("__PERSES_VERSION__", PERSES_VERSION).replace("__MAX_UPLOAD_BYTES__", str(MAX_UPLOAD_BYTES))
            self.send(200, page, "text/html; charset=utf-8")
        else:
            self.send(404, "not found\n", "text/plain")

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/api/convert":
            self.send(404, "not found\n", "text/plain")
            return
        try:
            length = self.headers.get("Content-Length")
            if length is None or not length.isdigit():
                raise Refused(411, "the request has no Content-Length")
            if int(length) > MAX_UPLOAD_BYTES:
                # Never kept: a moderately oversized body is read and thrown away, so the sender gets this answer
                # instead of a reset connection; a far larger one is not read at all.
                self.close_connection = True
                remaining = int(length) if int(length) <= 8 * MAX_UPLOAD_BYTES else 0
                while remaining > 0:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                raise Refused(413, f"the upload is {int(length)} bytes; the limit is {MAX_UPLOAD_BYTES} bytes")
            try:
                request = json.loads(self.rfile.read(int(length)))
            except json.JSONDecodeError as error:
                raise Refused(400, f"the request is not valid JSON: {error}") from error
            if not isinstance(request, dict):
                raise Refused(400, "the request must be a JSON object")
            self.send_json(200, convert(request))
        except Refused as refused:
            self.send_json(refused.status, {"error": str(refused)})


if __name__ == "__main__":
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
