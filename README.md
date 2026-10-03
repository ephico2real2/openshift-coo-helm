# openshift-coo-helm

A Helm chart to install Red Hat's **Cluster Observability Operator (COO)** on OpenShift, hands-free, as a platform component of its own. Other repositories consume it (for example [`openshift-ipsec-nas`](https://github.com/ephico2real2/openshift-ipsec-nas)), and keep their own application objects, such as their `PersesDashboard`s, in their own repositories.

**Status: investigation.** COO was first installed and studied by hand on OpenShift Local (CRC 4.22.7) to learn the install workflow, what it creates, and how Perses dashboards authenticate. The chart follows once that pattern is fully understood.

## Documents

| Document | What it covers |
|---|---|
| [docs/manual-install-findings.md](docs/manual-install-findings.md) | COO installed by hand: the catalog, the Manual-approval install, what it adds to the cluster, enabling Perses, a COO defect and its fix (`clusterHealthAnalyzer`), how Perses reaches Thanos with each viewer's own token, and what a hands-free chart must do |
| [docs/percli.md](docs/percli.md) | Installing `percli` (the Perses CLI) on Linux and macOS: script, by hand, or the container image; converting a Grafana dashboard |
| [docs/evidence/crc/](docs/evidence/crc/) | The saved command output behind every statement |

## Scripts

| Script | What it does |
|---|---|
| [scripts/install-percli.sh](scripts/install-percli.sh) | Installs `percli` and its plugins for Linux or macOS (amd64, arm64) from the official release, after checking the SHA-256 |
