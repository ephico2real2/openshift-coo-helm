# Converting a Grafana Dashboard to Perses

How to turn an application's Grafana dashboard into a Perses dashboard for COO, delivered from the application's own chart. Every step and every pitfall below was measured on one real dashboard: *IPsec to the NAS* from [openshift-ipsec-nas](https://github.com/ephico2real2/openshift-ipsec-nas). Its 16 panels include stat charts with value mappings, a bar chart, time series and a table that merges 11 queries. It ran on CRC 4.22.7 with COO 1.5.3, converted with `percli` 0.54.0. The worked example is linked at each step.

## The steps

**1. Install `percli` at the cluster's Perses version.** COO 1.5.2 and the `release-1.5` branch list Perses **0.54.0** in `go.mod` (1.5.0 and 1.5.1: 0.53.1); COO's server reports no version: [percli.md](percli.md). Its plugins must be **unpacked**.

**2. Convert, offline.** Keep the Grafana JSON as the **only source**. The Perses dashboard is generated from it, never edited by hand:

```bash
percli migrate -f dashboard.json --format native --plugin.path ~/.local/share/perses/plugins \
  --use-default-datasource -o json > dashboard.perses.json

grep -c 'Migration from Grafana not supported' dashboard.perses.json   # must print 0
```

**3. Fix what the converter gets wrong** (next section), in a script, so that step 2 and 3 run together every time the Grafana JSON changes. Worked example: [`scripts/perses-dashboard.sh`](https://github.com/ephico2real2/openshift-ipsec-nas/blob/main/scripts/perses-dashboard.sh) runs `percli`, then [`scripts/perses-dashboard-fix.py`](https://github.com/ephico2real2/openshift-ipsec-nas/blob/main/scripts/perses-dashboard-fix.py).

**4. Ship it from the application's chart** as a `PersesDashboard` (`perses.dev/v1alpha2`, the dashboard under `spec.config`), beside a `PersesDatasource`, in the application's namespace: [the two objects](#the-two-objects-an-application-ships).

**5. Verify it** with the [checklist](#verify-it) before anyone relies on it.

## What `percli` gets wrong, and the fix

Measured with `percli` 0.54.0 on the ipsec dashboard ([evidence 08](evidence/crc/08-percli-conversion.txt), [openshift-ipsec-nas doc 61, appendix A](https://github.com/ephico2real2/openshift-ipsec-nas/blob/main/docs/61-perses-dashboard-review.md#appendix-a--how-we-got-here), [its evidence 43 on sections](https://github.com/ephico2real2/openshift-ipsec-nas/blob/main/docs/evidence/crc/43-dashboard-sections.txt)):

| What happens | Why | Fix |
|---|---|---|
| **Every panel becomes a placeholder** reading `Migration from Grafana not supported !`, and `percli` still exits 0 | `--plugin.path` points at the release's packed `plugins-archive/` | Unpack the plugins ([percli.md](percli.md)); refuse any output that still contains a placeholder |
| A warning `failed query migration: no plugins found matching target`, once per query | — | Harmless: all 27 PromQL expressions came out identical to the Grafana ones (compared, raw output) |
| The Grafana data-source input `${DS_PROMETHEUS}` becomes a datasource variable, and every query names `${DS_PROMETHEUS}` | Perses has no Grafana inputs; `percli` maps the input to a variable | `--input DS_PROMETHEUS=<your PersesDatasource>`, which names it in every query; or `--use-default-datasource`, then name your `PersesDatasource` on **every query** |
| **The variables (filters) query no data source**: in a namespace without a default data source, a filter sent no request at all | `percli` leaves variables without a data source, so they use the namespace's default one | Name your data source on every **variable** too |
| **A table shows one entity in several rows** | Perses' table merge (`MergeSeries`) joins series only when their labels are equal. Queries labelled `node, pod` and `node, peer_id` beside queries labelled `node` gave three rows per node | Aggregate every table query `by` the same labels; move extra label columns to a table of their own |
| A table's value columns are named `value #1`, `value #2`, … | By query number | Renumber the column settings if you remove or reorder queries |
| A stat panel that showed a **label** (Grafana's *name* text mode) shows `1` | The label to show (`metricLabel`) was garbled | Set `metricLabel` to the label, for example `version` |
| A unit is lost (days) | Not every Grafana unit maps | Set `format.unit`. Perses writes a duration in its **largest fitting unit**: 364 days reads "12.1 months" |
| The resource comes out as `perses.dev/v1alpha1` | `--format cr` writes v1alpha1, which the API server reports as **deprecated** | Write `v1alpha2`: the dashboard goes under `spec.config` |
| "No data" where Grafana showed a custom no-value text | Not converted | Accept it, or explain it in the panel's description |
| The whole dashboard sits under one heading, **"Panel Group 1"** | A Grafana dashboard without rows becomes one Perses section, and `percli` titles it so | Give the Grafana dashboard **rows**, named after the question each part answers: each row becomes a titled section (a row saved collapsed comes out folded). The ipsec dashboard: *Summary*, *Tunnels per node*, *Checks (all should be 0)*, *Per-node detail*, *History* |
| A fix script stops finding its panels after a row is added | With rows, `percli` keys panels `<section>_<index>` (`0_3`, `4_1`); without, `0`…`15` | Find panels by **title**, not by key |

**Prefer `percli` over COO's own converter.** COO's Perses converts too (`POST /api/migrate`), and agreed with `percli` on 15 of 16 panels. But it named the table's value columns `Value #A…`, which the table plugin did not render (seen in the upstream Perses 0.54.0 UI), and it dropped value mappings and units.

## The two objects an application ships

From the ipsec chart, rendered (`charts/ipsec-nas/templates/perses-dashboard.yaml`, on by default there):

```yaml
apiVersion: perses.dev/v1alpha2
kind: PersesDatasource
metadata:
  name: ipsec-nas-thanos
  namespace: kcs-ipsec
spec:
  client:
    tls:
      enable: true
      caCert:
        type: file
        certPath: /ca/service-ca.crt
  config:
    display:
      name: OpenShift Thanos (cluster)
    default: false                       # every query names it; the namespace's default stays untouched
    plugin:
      kind: PrometheusDatasource
      spec:
        proxy:
          kind: HTTPProxy
          spec:
            url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
            # the Perses secret COO derives from spec.client.tls; the proxy must name it
            secret: ipsec-nas-thanos-secret
---
apiVersion: perses.dev/v1alpha2
kind: PersesDashboard
metadata:
  name: ipsec-nas
  namespace: kcs-ipsec
spec:
  config:
    { ... the generated dashboard: display, variables, panels, layouts ... }
```

What each choice is, measured ([manual-install findings](manual-install-findings.md), §6 and §6a):

- **Port 9091, not the per-namespace 9092.** The Perses UI sends its data queries as `POST`. Thanos's per-namespace port checks a `POST` as `create pods`, so a namespace reader was refused on every panel. Port 9091 checks it as `create` on `prometheuses/api`, which `cluster-monitoring-view` grants.
- **`secret: <name>-secret`.** COO derives a Perses secret holding the service CA from `spec.client.tls`, but the proxy must name it. Without it: `x509: certificate signed by unknown authority`.
- **No token anywhere.** Perses passes each viewer's own token to Thanos.

## Who can see it

| To | A viewer needs |
|---|---|
| Open the dashboard | `view` in the application's namespace. OLM aggregates the per-kind roles of COO's Perses CRDs into `view`, `edit` and `admin` (for example `persesdashboards.perses.dev-v1alpha2-view`, labelled `rbac.authorization.k8s.io/aggregate-to-view`; COO's six `perses*-viewer/editor-role` roles are not aggregated). Measured: `view` alone reads the dashboard, and cannot change it. So the application ships **no RoleBindings** |
| See its data | `cluster-monitoring-view`, a platform grant |

## Verify it

1. **No placeholders:** `grep -c 'Migration from Grafana not supported'` prints 0, and the panel kinds are the expected ones.
2. **Every expression carried over:** compare the PromQL of the Grafana JSON and of the Perses one; only the queries you moved on purpose may differ.
3. **Accepted by the cluster:** `oc apply --dry-run=server`, then both objects report `Available=True`.
4. **Answers through COO's Perses:** a query through `/proxy/projects/<namespace>/datasources/<name>/api/v1/query` returns data, as `GET` and as `POST`.
5. **Looks right:** open it under **Observe → Dashboards (Perses)**, as a viewer who holds only `view` and `cluster-monitoring-view`. The ipsec dashboard there: [the README's sample](../README.md#example-openshift-ipsec-nas).

The ipsec chart's `tests/test-chart.sh` also keeps its chart and its plain manifest identical, and refuses to install the dashboard on a cluster without COO's Perses API.
