# openshift-coo

Installs Red Hat's **Cluster Observability Operator (COO)** with **Perses** on OpenShift, with no human step: from Helm or from Argo CD. Applications then ship their own `PersesDashboard` and `PersesDatasource`, and their dashboards appear in the console under **Observe → Dashboards (Perses)**.

Every behaviour below was measured on OpenShift Local (CRC 4.22.7) with COO 1.5.2 and 1.5.3, Helm 4.3.0 and OpenShift GitOps: [evidence 10](../../docs/evidence/crc/10-lifecycle-uninstall-reinstall-upgrade.txt) (COO's lifecycle by hand) and [evidence 11](../../docs/evidence/crc/11-chart-on-crc.txt) (this chart).

**Supported:** OpenShift **4.18** or later (Kubernetes 1.31), COO **1.5** or later. On 4.18, read [Known issues](#known-issues) first.

## What it does

| Step | Objects | Measured |
|---|---|---|
| Namespace | `openshift-cluster-observability-operator`, labelled `openshift.io/cluster-monitoring: "true"` so the platform Prometheus scrapes COO; an OperatorGroup with no target namespaces (COO supports AllNamespaces only) | |
| Subscription | channel `stable`, **Manual** approval, `startingCSV` = `operator.version` | |
| Reclaim (hook) | Deletes a CSV an earlier uninstall left behind, after OLM reports `ResolutionFailed`; nothing else | reinstall over a left-over CSV: 60 s, no human step |
| Approve (hook) | Approves the InstallPlan for **`operator.version` only** (exact CSV name), then waits for it to complete | clean install: approved 21 s after `helm install` |
| UIPlugin `monitoring` | Perses and incident detection; COO runs the Perses server and adds the console plugin itself | Available as soon as COO runs |
| Scrape grant | A Role and RoleBinding for the platform Prometheus, under the chart's name ([Known issues](#known-issues)) | |
| Metrics access | `cluster-monitoring-view` for the groups in `metricsAccess.groups` (none by default) | |
| Gate (hook) | Returns when the CSV is `Succeeded`, the UIPlugin `Available`, the plugin listed in the console, Perses ready, the namespace labelled and the scrape grant present; else fails naming which | clean install: `helm install` returned in **52 s** |

## Install

**Helm.** The chart creates COO's namespace, so Helm's record of the release lives in another one, for example `platform-tools`:

```bash
helm install openshift-coo charts/openshift-coo -n platform-tools --create-namespace \
  --set 'metricsAccess.groups={system:authenticated}' --timeout 15m
oc logs -n openshift-cluster-observability-operator job/openshift-coo-wait     # the gate's verdict
```

`--timeout 15m`: Helm waits for the hooks only up to its timeout (default 5 minutes).

**Argo CD:** [`examples/argocd-application.yaml`](examples/argocd-application.yaml). The Application points at COO's namespace, without `CreateNamespace`, and sets `skipCrds: true`: the UIPlugin CRD then comes from OLM before the UIPlugin's wave. Measured: first sync **green in 72 s** on a cluster with no COO CRDs.

| Wave | Objects |
|---|---|
| -3 | Namespace |
| -2 | OperatorGroup; the Jobs' ServiceAccounts and RBAC; the scrape grant |
| -1 | Subscription, with the reclaim and approver as Sync hooks |
| 0 | The metrics-access binding |
| 1 | UIPlugin (dry run skipped while its CRD is missing) |
| 3 | The gate, a Sync hook |

## Values

| Value | Default | What it does |
|---|---|---|
| `operator.version` | `1.5.3` | The COO version installed, and the only one approved |
| `operator.channel`, `.source`, `.sourceNamespace`, `.package` | `stable`, `redhat-operators`, `openshift-marketplace`, `cluster-observability-operator` | Where OLM finds COO; a mirrored catalog changes `source` |
| `namespace.name` | `openshift-cluster-observability-operator` | COO's namespace |
| `namespace.create` | `true` | `false`: the namespace exists, carries the label, and holds an OperatorGroup |
| `uiPlugin.perses` | `true` | Perses dashboards in the console |
| `uiPlugin.clusterHealthAnalyzer` | `true` | Incident detection. **`false` on OpenShift 4.18** ([Known issues](#known-issues)) |
| `platformScrapeRBAC` | `true` | The chart's own scrape grant for the platform Prometheus. Keep it on |
| `metricsAccess.groups` | `[]` | Groups bound to `cluster-monitoring-view`, so they see the data behind dashboards. `[system:authenticated]`: everyone who logs in |
| `csvReclaim.enabled` | `true` | The reclaim hook |
| `installPlanApprover.waitSeconds`, `wait.waitSeconds` | 300, 600 | The hooks' budgets |
| `jobs.image` | `registry.redhat.io/openshift4/ose-cli:latest` | The Jobs' image: a shell and `oc` |

`values.schema.json` refuses unknown keys and a version written with a `v`.

## Upgrade COO

The approver approves **only `operator.version`**. With one version installed, OLM stages the next one and points the Subscription at it (`UpgradePending`): measured, the 1.5.3 plan was there at the first sample, 43 s after 1.5.2 was approved and 5 s after it Succeeded. The `openshift-grafana` approver takes the plan the Subscription references and approves it if it names the package ([its lines 211-212, 287, 295](https://github.com/ephico2real2/group-sync-dashboard/blob/main/charts/openshift-grafana/templates/02-installplan-approver.yaml#L211-L295), read, not run), so on a sync while such a plan is pending it would approve the upgrade. Here, that plan waits:

```text
[approver] cluster-observability-operator.v1.5.2 is the installed CSV; nothing to approve
[approver] InstallPlan install-rzsdz (cluster-observability-operator.v1.5.3) is not operator.version: left for a human;
           to take it, set operator.version and upgrade the release
```

To upgrade, change `operator.version` in Git (or `--set`) and sync. Measured 1.5.2 → 1.5.3: **70 s**, gate green. If OLM offers a different version than the one set, the approver fails and names it (by design; not exercised on CRC, where the channel's next version was always the one set).

## Uninstall

`helm uninstall openshift-coo -n platform-tools` (or deleting the Argo CD Application with its resources finalizer). Measured, both ways:

| Removed | Left on the cluster |
|---|---|
| The namespace and everything in it: Subscription, **CSV**, operator, Perses; the UIPlugin; the chart's ClusterRoleBindings | The **18 COO CRDs** and their 5 APIServices: applications' `PersesDashboard`/`PersesDatasource` stay, with the CRDs |
| | 84 ClusterRoles the CRDs own, and COO's 6 Perses team roles (`perses*-editor-role`, `perses*-viewer-role`), which nothing owns |
| | After `helm uninstall`: the `monitoring-console-plugin` entry in `console.operator.openshift.io/cluster` `.spec.plugins` (its ConsolePlugin is gone). After the Argo CD deletion COO removed it itself |

To remove COO completely, after the uninstall:

```bash
oc get crd -o name | grep -E '\.monitoring\.rhobs$|\.perses\.dev$|\.observability\.openshift\.io$' | xargs oc delete   # deletes every app's Perses objects
oc delete clusterrole persesdashboard-editor-role persesdashboard-viewer-role persesdatasource-editor-role \
  persesdatasource-viewer-role persesglobaldatasource-editor-role persesglobaldatasource-viewer-role
i=$(oc get console.operator.openshift.io cluster -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["spec"]["plugins"].index("monitoring-console-plugin"))')
oc patch console.operator.openshift.io cluster --type json \
  -p "[{\"op\":\"test\",\"path\":\"/spec/plugins/$i\",\"value\":\"monitoring-console-plugin\"},{\"op\":\"remove\",\"path\":\"/spec/plugins/$i\"}]"
```

## Known issues

### COO deletes its own scrape grant (fixed by this chart)

**What happens.** COO creates a Role and RoleBinding `prometheus-k8s` in its namespace, so the platform Prometheus may discover and scrape it. COO itself deletes them:
- on every UIPlugin reconcile, when the UIPlugin enables Perses and **not** `clusterHealthAnalyzer` (evidence 03, 06; reproduced by this chart, evidence 11 §2);
- when the UIPlugin is deleted (evidence 10, step 1).

**Why.** In `rhobs/observability-operator`, two controllers own objects with these names: the operator's self-monitoring and the UIPlugin's health analyzer. `pkg/controllers/uiplugin/components.go:133,145-146` registers the health analyzer's copies as optional, deleted when it is off ([findings §5](../../docs/manual-install-findings.md#5-a-defect-in-coo-the-uiplugin-deletes-coos-own-monitoring-rbac-03-06)).

**The effect.** `prometheus-k8s` may no longer list endpoints, pods, services or endpointslices in COO's namespace (measured: `oc auth can-i ... --as system:serviceaccount:openshift-monitoring:prometheus-k8s` → `no`). Observed twice: on a fresh install, with the grant deleted 54 s after COO created it, COO was not scraped (evidence 03: 0 series); on an install already being scraped, scraping continued at every sample from 05:08:54 to 05:12:38Z (evidence 11 §3), and was not watched longer. Why it continued is not known; it was not investigated.

**The fix: `platformScrapeRBAC` (on by default).** The chart ships the same rules as its own Role and RoleBinding, `<release>-openshift-coo-prometheus-k8s`. COO never touches them. Measured with `clusterHealthAnalyzer=false`: COO's `prometheus-k8s` gone, the chart's present, `observability-operator` scraped (`up` = 1) throughout. The gate checks the grant the platform actually relies on, so turning both off fails the install, measured with `wait.waitSeconds=60`: `FAILED: Role and RoleBinding prometheus-k8s for the platform Prometheus: not within 60s`.

**Upstream:** a bug report is drafted, not filed ([#4](https://github.com/ephico2real2/openshift-coo-helm/issues/4)): [docs/upstream/observability-operator-prometheus-k8s-rbac.md](../../docs/upstream/observability-operator-prometheus-k8s-rbac.md). The cited source lines are the same at `v1.5.2`, both 1.5 release branches and `main` (read 2026-10-04).

### OpenShift 4.18: turn incident detection off

**What Red Hat says.** Incident detection (`spec.monitoring.clusterHealthAnalyzer`) is GA on OpenShift 4.19 and later ([COO release notes](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/html/red_hat_openshift_cluster_observability_operator_release_notes/cluster-observability-operator-release-notes)). Perses needs COO 1.5 or later on OpenShift 4.15 or later ([UI plugins](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/html-single/ui_plugins_for_red_hat_openshift_cluster_observability_operator/index)). COO 1.4 replaced the field `incidents` with `clusterHealthAnalyzer`.

**What to do on 4.18:**

```bash
helm install openshift-coo charts/openshift-coo -n platform-tools --create-namespace \
  --set uiPlugin.clusterHealthAnalyzer=false --set 'metricsAccess.groups={system:authenticated}' --timeout 15m
```

Without `platformScrapeRBAC` this setting would trigger the defect above. With it, COO stays scraped (measured on 4.22 with the setting off; **not measured on a 4.18 cluster**, none was available: [#3](https://github.com/ephico2real2/openshift-coo-helm/issues/3)). You lose only incident detection (the `health-analyzer` Deployment), which 4.18 does not support anyway.

### Others

- **The Subscription's state is not readiness.** After an approval the Subscription read `AtLatestKnown` while the new CSV was still `Pending`. The gate waits for the CSV's phase.
- **Scraping starts after the gate.** Measured: the platform Prometheus's last configuration reload was at 05:01:55Z, before COO's ServiceMonitors existed; it scraped `health-analyzer` at 05:03:23Z and `observability-operator` at 05:03:38Z, 62 s after the gate passed at 05:02:36Z. The gate checks what scraping needs, not the first scrape.
- **A UIPlugin made by hand blocks the install.** The UIPlugin's name is fixed (the CRD: "UIPlugin name must be 'monitoring' if type is Monitoring"). Delete the hand-made one first, or adopt it into the release.
- **Argo CD does not put back what you delete by hand** unless the Application has `selfHeal`. Deleting COO's CRDs deletes every application's Perses objects; sync those applications again afterwards (measured with openshift-ipsec-nas).

## Tests

```bash
tests/test-chart.sh            # helm lint, renderings, schema, bash -n and shellcheck on the three Jobs' scripts
scripts/refresh-uiplugin-crd.sh  # after changing appVersion: refresh crds/ from a cluster running that version
```
