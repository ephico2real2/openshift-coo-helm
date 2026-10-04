# openshift-coo-helm

A Helm chart to install Red Hat's **Cluster Observability Operator (COO)** on OpenShift, hands-free, as a platform component of its own. COO brings **Perses**: dashboards in the OpenShift console, under **Observe → Dashboards (Perses)**, that each application keeps in its own namespace.

Applications consume this platform piece, and keep their own dashboards in their own repositories. The first is [openshift-ipsec-nas](https://github.com/ephico2real2/openshift-ipsec-nas): see [the example](#example-openshift-ipsec-nas).

**Status:**
- **Investigation done.** COO was installed and studied by hand on OpenShift Local (CRC 4.22.7, COO 1.5.3): [manual-install findings](docs/manual-install-findings.md).
- **The chart is planned** in [issue #1](https://github.com/ephico2real2/openshift-coo-helm/issues/1).
- **The Grafana-to-Perses converter page** in [issue #2](https://github.com/ephico2real2/openshift-coo-helm/issues/2).

## How an application's dashboard reaches its viewers

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/perses-dashboard-flow.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/images/perses-dashboard-flow.light.png">
  <img alt="Collecting: each application pod reports its metrics, the user workload Prometheus scrapes them every 30 seconds, and Thanos Querier serves them on port 9091. Viewing: you open the dashboard in the OpenShift console; Perses, run by COO, reads the PersesDashboard and PersesDatasource the application's chart puts in its namespace, and queries Thanos with your own token. A viewer needs view in the namespace to open the dashboard and cluster-monitoring-view to see its data." src="docs/images/perses-dashboard-flow.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*Figure 1. The sample: the ipsec application (namespace `kcs-ipsec`). Its source is the fourth figure of [openshift-ipsec-nas `docs/diagrams/ipsec-nas/source.html`](https://github.com/ephico2real2/openshift-ipsec-nas/blob/main/docs/diagrams/ipsec-nas/source.html). Measured on CRC 4.22.7 with COO 1.5.3.*

| Who | Provides |
|---|---|
| **This repository** (the platform) | COO with Perses enabled, in `openshift-cluster-observability-operator`; and `cluster-monitoring-view` for the viewers (a setting of the chart, planned) |
| **Each application's chart** | Its ServiceMonitor, a `PersesDashboard` and a `PersesDatasource`, in its own namespace |
| **OpenShift** | User workload monitoring and Thanos Querier, already there |

Viewers need `view` in the application's namespace, which already lets them read its Perses dashboards, and `cluster-monitoring-view`. No token or password is stored anywhere: Perses passes each viewer's own login to Thanos.

## Example: openshift-ipsec-nas

The ipsec application encrypts NFS between OpenShift nodes and a NAS. It reports per-node IPsec metrics, and ships its dashboard for Perses, on by default:

| What | Where, in openshift-ipsec-nas |
|---|---|
| The two objects (`PersesDatasource` `ipsec-nas-thanos` on Thanos 9091, `PersesDashboard` `ipsec-nas`) | [`charts/ipsec-nas/templates/perses-dashboard.yaml`](https://github.com/ephico2real2/openshift-ipsec-nas/blob/main/charts/ipsec-nas/templates/perses-dashboard.yaml) |
| The switch, and its prerequisite check | `metrics.persesDashboard.enabled` (default `true`): the chart refuses to install without COO's API `perses.dev/v1alpha2`. `false` on a cluster without COO |
| The dashboard, generated from its Grafana one | [`scripts/perses-dashboard.sh`](https://github.com/ephico2real2/openshift-ipsec-nas/blob/main/scripts/perses-dashboard.sh) |
| How to use it: open, who sees it, change it, troubleshoot | [doc 61](https://github.com/ephico2real2/openshift-ipsec-nas/blob/main/docs/61-perses-dashboard-review.md) |

The sample objects, and how the dashboard was converted from Grafana: [docs/grafana-to-perses.md](docs/grafana-to-perses.md).

<!-- markdownlint-disable MD033 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/example-ipsec-dashboard.dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/images/example-ipsec-dashboard.light.png">
  <img alt="The IPsec to the NAS dashboard as a reader with view and cluster-monitoring-view: tunnels up 1, down 0, workers reporting 1, soonest certificate expiry 12.1 months, tunnel state UP, traffic around 3.8 MiB/s, libreswan 5.3, a per-node table with one row for crc (UP, YES, PRESENT, YES, YES, 2 NFS mounts, 39.8 requests/sec, 0 drops), and a NAS identity table showing crc, its reporting pod and O=KCS OpenShift lab, CN=crc-nas.lab.internal." src="docs/images/example-ipsec-dashboard.light.png">
</picture>
<!-- markdownlint-enable MD033 -->

*The ipsec dashboard on CRC's data, as a reader holding `view` and `cluster-monitoring-view`. Taken in the upstream Perses 0.54.0 UI, the version COO 1.5 builds on. COO's Perses has no UI of its own; its UI is the console's. A capture from **Observe → Dashboards (Perses)** in the console will replace this one.*

## Documents

| Document | What it covers |
|---|---|
| [docs/manual-install-findings.md](docs/manual-install-findings.md) | COO installed by hand: the catalog, the Manual-approval install, what it adds to the cluster, enabling Perses, a COO defect and its fix (`clusterHealthAnalyzer`), how Perses reaches Thanos with each viewer's own token, the decision on Thanos 9091, and what a hands-free chart must do |
| [docs/grafana-to-perses.md](docs/grafana-to-perses.md) | **Converting a Grafana dashboard to Perses:** the steps, what the converter gets wrong and how to fix it, the two objects an application ships, who can see it, and how to verify it, all measured on the ipsec dashboard |
| [docs/percli.md](docs/percli.md) | Installing `percli` (the Perses CLI) on Linux and macOS: script, by hand, or the container image |
| [docs/evidence/crc/](docs/evidence/crc/) | The saved command output behind every statement |

## Scripts

| Script | What it does |
|---|---|
| [scripts/install-percli.sh](scripts/install-percli.sh) | Installs `percli` and its plugins (unpacked) for Linux or macOS (amd64, arm64) from the official release, after checking the SHA-256 |
