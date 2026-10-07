# openshift-coo

Installs Red Hat's **Cluster Observability Operator (COO)** with **Perses** on OpenShift, with no human step: from Helm or from Argo CD. Applications then ship their own `PersesDashboard` and `PersesDatasource`, and their dashboards appear in the console under **Observe → Dashboards (Perses)**.

The behaviours below were measured on OpenShift Local (CRC 4.22.7) with COO 1.5.2 and 1.5.3, Helm 4.3.0 and OpenShift GitOps, except where marked not exercised or not measured: [evidence 10](../../docs/evidence/crc/10-lifecycle-uninstall-reinstall-upgrade.txt) (COO's lifecycle by hand) and [evidence 11](../../docs/evidence/crc/11-chart-on-crc.txt) (this chart).

**Supported:** OpenShift **4.19** or later (Kubernetes 1.32), COO **1.5** or later (measured: 1.5.2 and 1.5.3; `crds/` holds 1.5.3's UIPlugin CRD). The chart refuses an older cluster: [why 4.19](#why-openshift-419-or-later).

## What it does

| Step | Objects | Measured |
|---|---|---|
| Namespace | `openshift-cluster-observability-operator`, labelled `openshift.io/cluster-monitoring: "true"` so the platform Prometheus scrapes COO. Not rendered with `namespace.create: false` | |
| OperatorGroup | One with no target namespaces (COO supports AllNamespaces only). Rendered whether or not the chart creates the namespace (`operatorGroup.create`) | without one OLM stages nothing and reports nothing ([evidence 16](../../docs/evidence/crc/16-operatorgroup.txt)) |
| Subscription | channel `stable`, **Manual** approval, `startingCSV` = `operator.version` | |
| Reclaim (hook) | Deletes a CSV an earlier uninstall left behind, after OLM reports `ResolutionFailed`; nothing else | reinstall over a left-over CSV: 60 s, no human step |
| Approve (hook) | First checks that the namespace holds exactly one OperatorGroup, with no target namespaces, and fails with the reason if not. Then approves the InstallPlan for **`operator.version` only** (exact CSV name), and waits for it to complete | clean install: approved 21 s after `helm install` |
| UIPlugin `monitoring` | Perses and incident detection; COO runs the Perses server and adds the console plugin itself | `Available` 5 s after it was applied to a running COO ([evidence 02](../../docs/evidence/crc/02-uiplugin-perses.txt)) |
| Scrape grant | A Role and RoleBinding for the platform Prometheus, under the chart's name ([Known issues](#known-issues)) | |
| Metrics access | `cluster-monitoring-view` for the groups in `metricsAccess.groups` (none by default) | |
| Gate (hook) | Returns when the CSV is `Succeeded`, the UIPlugin `Available`, the plugin listed in the console, Perses ready, the namespace labelled and the scrape grant present; else fails naming which | clean install: `helm install` returned in **52 s** |
| Cleanup (hook, on uninstall) | Removes COO's six unowned Perses team roles and the console's stale plugin entry; never the CRDs ([Uninstall](#uninstall)) | after `helm uninstall` and an Argo CD delete: both removed, CRDs and other apps' Perses objects untouched ([evidence 13](../../docs/evidence/crc/13-uninstall-cleanup.txt)) |

## Install

**Helm.** The chart creates COO's namespace, so Helm's record of the release lives in another one, for example `platform-tools`:

```bash
helm install openshift-coo charts/openshift-coo -n platform-tools --create-namespace \
  --set 'metricsAccess.groups={system:authenticated}' --timeout 15m
oc logs -n openshift-cluster-observability-operator job/openshift-coo-wait     # the gate's verdict
```

`--timeout 15m`: Helm waits for the hooks only up to its timeout (default 5 minutes). The gate's Job, and its log, are kept for `jobs.ttlSecondsAfterFinished` (600 s) under Helm; Argo CD deletes a hook Job as soon as it succeeds (`HookSucceeded`), so read the result in the Application's sync status there.

**A namespace made outside the chart.** Set `namespace.create: false`. The chart then renders no Namespace and still installs the operator: the OperatorGroup and the Subscription go into the namespace you made. The label `openshift.io/cluster-monitoring: "true"` on that namespace is then yours to set; the gate fails, naming it, when it is missing. The release may live in COO's namespace in this case: the chart no longer deletes it on uninstall, so the cleanup Job can run there too.

If the namespace already holds an OperatorGroup of its own, set `operatorGroup.create: false`: OLM allows one per namespace. The approver Job checks before it waits, and stops within seconds, naming the value to change, when it finds none, more than one, or one that selects namespaces. Measured on CRC ([evidence 16](../../docs/evidence/crc/16-operatorgroup.txt)): a Subscription with no OperatorGroup got no state, no InstallPlan and no event in 90 s; the check stopped the Job 9 s after it was created in each of the three wrong cases.

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
| `namespace.create` | `true` | `false`: the namespace was made outside the chart and carries the label `openshift.io/cluster-monitoring: "true"`. The chart still installs the operator into it |
| `operatorGroup.create` | `true` | The OperatorGroup OLM needs to install COO, with no targetNamespaces. Independent of `namespace.create`. `false`: the namespace already holds one |
| `uiPlugin.perses` | `true` | Perses dashboards in the console |
| `uiPlugin.clusterHealthAnalyzer` | `true` | Incident detection, GA on OpenShift 4.19 and later. Keep it on ([Known issues](#known-issues)) |
| `platformScrapeRBAC` | `true` | The chart's own scrape grant for the platform Prometheus. Keep it on |
| `metricsAccess.groups` | `[]` | Groups bound to `cluster-monitoring-view`, so they see the data behind dashboards. `[system:authenticated]`: everyone who logs in |
| `csvReclaim.enabled` | `true` | The reclaim hook |
| `cleanup.enabled`, `cleanup.consolePlugin` | `true`, `true` | The post-uninstall cleanup ([Uninstall](#uninstall)); `consolePlugin: false` leaves the console's plugin list alone and grants nothing on it |
| `cleanup.namespace` | `""` (the release's namespace) | Where the cleanup Job runs; it must survive the uninstall. Set it under Argo CD (the example: `platform-tools`) |
| `installPlanApprover.waitSeconds`, `wait.waitSeconds` | 300, 600 | The hooks' budgets |
| `jobs.image` | `registry.redhat.io/openshift4/ose-cli:latest` | The Jobs' image: a shell and `oc` |

`values.schema.json` refuses unknown keys and a version written with a `v`.

## The Grafana-to-Perses converter page

Optional (`converter.enabled`, off by default): a web page, behind the OpenShift login, where a team uploads a Grafana dashboard and downloads it as a `PersesDashboard` for its namespace, with a report of what converted. It runs in `converter.namespace` (for example `platform-tools`) from the official Perses image and a small `server.py` mounted from a ConfigMap; nothing is built and nothing is stored.

```yaml
converter:
  enabled: true
  namespace: platform-tools
```

How to use it, how it works and what was measured: [docs/converter.md](../../docs/converter.md).

## Upgrade COO

The approver approves **only `operator.version`**. With one version installed, OLM stages the next one and points the Subscription at it (`UpgradePending`): measured, the 1.5.3 plan was there at the first sample, 43 s after 1.5.2 was approved and 5 s after it Succeeded. The `openshift-grafana` approver takes the plan the Subscription references and approves it if it names the package ([its lines 211-212, 287, 295](https://github.com/ephico2real2/group-sync-dashboard/blob/main/charts/openshift-grafana/templates/02-installplan-approver.yaml#L211-L295), read, not run), so on a sync while such a plan is pending it would approve the upgrade. Here, that plan waits:

```text
[approver] cluster-observability-operator.v1.5.2 is the installed CSV; nothing to approve
[approver] InstallPlan install-rzsdz (cluster-observability-operator.v1.5.3) is not operator.version: left for a human;
           to take it, set operator.version and upgrade the release
```

To upgrade, change `operator.version` in Git (or `--set`) and sync. Measured 1.5.2 → 1.5.3: **70 s**, gate green. If OLM offers a different version than the one set, the approver fails and names it (by design; not exercised on CRC, where the channel's next version was always the one set).

## Uninstall

`helm uninstall openshift-coo -n platform-tools`, or delete the Argo CD Application. [The example](examples/argocd-application.yaml) declares `resources-finalizer.argocd.argoproj.io` in its metadata; Argo CD adds its own post-delete finalizers beside it, which run the cleanup. Do not replace the finalizer list with a patch: the cleanup is then skipped (measured).

After everything else is deleted, a **cleanup Job** (a Helm `post-delete` / Argo CD `PostDelete` hook, `cleanup.enabled`) removes what COO leaves behind that is safe to remove. It runs in `cleanup.namespace` (default: the release's namespace), which must survive the uninstall; the chart refuses COO's own namespace there. It removes nothing while a COO CSV is still installed anywhere. Measured both ways ([evidence 13](../../docs/evidence/crc/13-uninstall-cleanup.txt)):

| Removed | By | Left on the cluster, on purpose |
|---|---|---|
| The namespace and everything in it: Subscription, **CSV**, operator, Perses; the UIPlugin; the chart's ClusterRoleBindings | the uninstall | The **18 COO CRDs**, their 5 APIServices and the 84 ClusterRoles they own. Deleting the CRDs would delete **every application's** Perses dashboards and data sources; OLM leaves CRDs by design |
| COO's 6 Perses team roles (`perses*-editor-role`, `perses*-viewer-role`), which nothing owns | the cleanup Job: by name, only while they carry COO's labels; its `delete` is limited to these six names | |
| The `monitoring-console-plugin` entry in `console.operator.openshift.io/cluster` `.spec.plugins`, once its ConsolePlugin is gone | the cleanup Job (`cleanup.consolePlugin`), with a JSON patch that tests the entry before removing it. Measured: removed after `helm uninstall`; after the Argo CD deletion COO had removed it itself | The other plugins in the list (measured: unchanged) |

The Job's ServiceAccount and RBAC are hooks too, removed when it succeeds (measured: nothing left). A reinstall re-creates the team roles and the console entry (measured).

To remove COO's CRDs as well, deliberately, after the uninstall (this deletes every application's Perses objects):

```bash
oc get crd -o name | grep -E '\.monitoring\.rhobs$|\.perses\.dev$|\.observability\.openshift\.io$' | xargs oc delete
```

## Known issues

### COO deletes its own scrape grant (fixed by this chart)

**What happens.** COO creates a Role and RoleBinding `prometheus-k8s` in its namespace, so the platform Prometheus may discover and scrape it. COO itself deletes them:
- on every UIPlugin reconcile, when the monitoring UIPlugin enables **neither** `clusterHealthAnalyzer` nor `incidents` (measured with Perses on: evidence 03, 06; reproduced by this chart, evidence 11 §2; the source condition does not involve Perses);
- when the UIPlugin is deleted (evidence 10, step 1). With the analyzer on, the UIPlugin is their controller owner (read on CRC, [evidence 12](../../docs/evidence/crc/12-review-reads.txt): `ownerReferences` UIPlugin `monitoring`, `controller: true`), so the garbage collector removes them with it; that deletion itself was not re-measured.

**Why.** In `rhobs/observability-operator`, two controllers own objects with these names: the operator's self-monitoring and the UIPlugin's health analyzer. `pkg/controllers/uiplugin/components.go:133,145-146` registers the health analyzer's copies as optional, deleted when it is off ([findings §5](../../docs/manual-install-findings.md#5-a-defect-in-coo-the-uiplugin-deletes-coos-own-monitoring-rbac-03-06)).

**The effect.** `prometheus-k8s` may no longer list endpoints, pods, services or endpointslices in COO's namespace (measured: `oc auth can-i ... --as system:serviceaccount:openshift-monitoring:prometheus-k8s` → `no`). Observed twice: on a fresh install, with the grant deleted 54 s after COO created it, COO was not scraped (evidence 03: 0 series); on an install already being scraped, scraping continued at every sample from 05:08:54 to 05:12:38Z (evidence 11 §3), and was not watched longer. Why it continued is not known; it was not investigated.

**The fix: `platformScrapeRBAC` (on by default).** The chart ships the same rules as its own Role and RoleBinding, `<release>-openshift-coo-prometheus-k8s`. COO never touches them. Measured with `clusterHealthAnalyzer=false`: COO's `prometheus-k8s` gone, the chart's present, `observability-operator` scraped (`up` = 1) throughout (with neither grant, scraping also continued for the 3 min 44 s watched, so this run does not show the grant is needed; it shows the grant survives). The gate checks the grant the platform actually relies on, so turning both off fails the install, measured with `wait.waitSeconds=60`: `FAILED: Role and RoleBinding prometheus-k8s for the platform Prometheus: not within 60s`.

**Upstream:** a bug report is drafted, not filed ([#4](https://github.com/ephico2real2/openshift-coo-helm/issues/4)): [docs/upstream/observability-operator-prometheus-k8s-rbac.md](../../docs/upstream/observability-operator-prometheus-k8s-rbac.md). The cited source lines are the same at `v1.5.2`, both 1.5 release branches and `main` (read 2026-10-04).

### Why OpenShift 4.19 or later

**What Red Hat says.** Incident detection (`spec.monitoring.clusterHealthAnalyzer`) is GA on OpenShift 4.19 and later ([COO release notes](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/html/red_hat_openshift_cluster_observability_operator_release_notes/cluster-observability-operator-release-notes)). COO 1.4 deprecated the older field `incidents` in its favour; `incidents` still works during the deprecation period. Perses needs COO 1.5 or later on OpenShift 4.15 or later ([UI plugins](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/html-single/ui_plugins_for_red_hat_openshift_cluster_observability_operator/index)).

**So:** the chart turns incident detection on by default, which also avoids the defect above, and requires Kubernetes 1.32, OpenShift 4.19 ([4.19 release notes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html-single/release_notes/index)). Helm refuses to render it for an older version: `tests/test-chart.sh` checks that Kubernetes 1.31 (OpenShift 4.18) is refused and 1.32 renders. No cluster older than 4.22.7 was used.

### Others

- **The Subscription's state is not readiness.** After an approval the Subscription read `AtLatestKnown` while the new CSV was still `Pending`. The gate waits for the CSV's phase.
- **Scraping starts after the gate.** Measured: at 05:03:05Z `up` showed 0 series, the platform Prometheus's last configuration reload (05:01:55Z) predating COO's ServiceMonitors; `health-analyzer` first showed at the 05:03:23Z sample and `observability-operator` at the 05:03:38Z sample, 62 s after the gate passed at 05:02:36Z. The gate checks what scraping needs, not the first scrape.
- **A UIPlugin made by hand blocks a Helm install** (Helm does not adopt an object without its release annotations; not measured here). The UIPlugin's name is fixed (the CRD: "UIPlugin name must be 'monitoring' if type is Monitoring"). Delete the hand-made one first, or adopt it into the release.
- **Argo CD does not put back what you delete by hand** unless the Application has `selfHeal`. Deleting COO's CRDs deletes every application's Perses objects; sync those applications again afterwards (measured with openshift-ipsec-nas).

## Limitations

What this release does **not** cover, stated so nobody relies on it:

| Limitation | Detail |
|---|---|
| **OpenShift 4.19 or later only** | The chart refuses Kubernetes below 1.32. 4.18 is not supported. |
| **One test cluster** | Every run was on OpenShift Local: single node, OpenShift 4.22.7. Behaviour that needs several nodes was not observed. Other 4.19+ versions were not run. |
| **COO 1.5.2 and 1.5.3 measured** | `crds/` holds 1.5.3's UIPlugin CRD. Red Hat's COO release notes end at 1.5.2, although 1.5.3 is the catalog head (read 2026-10-04). A later COO version stays unapproved until `operator.version` changes. Moving the chart to it means changing `appVersion` and `operator.version` together, then `scripts/refresh-uiplugin-crd.sh` (it reads `appVersion`), the tests and a cluster run. |
| **Waiting on upstream** ([#4](https://github.com/ephico2real2/openshift-coo-helm/issues/4)) | The COO defect that deletes COO's own scrape grant. The chart works around it (`platformScrapeRBAC`); it is not fixed here. Two of COO's three uninstall leftovers are cleaned by the chart since 0.3.0 (the team roles and the console entry); the third behaviour, the UIPlugin's deletion taking COO's grant with it, needs no cleanup at uninstall |
| **What the scrape grant proves** | With `clusterHealthAnalyzer` off, COO stayed scraped with the chart's grant. With neither grant, scraping also continued for the 3 min 44 s watched, so the scrape data alone does not show the grant is needed; the `can-i` check does show Prometheus loses the permission. |
| **Not measured** | A hand-made UIPlugin blocking a Helm install; Argo CD deleting a CRD it tracks; a `PUT` query checked as `update`; the deprecated `incidents` field alone; the approver refusing a version OLM offers other than `operator.version`; port 9092 for a reader holding `cluster-monitoring-view`; the UIPlugin's deletion since the owner read ([evidence 12](../../docs/evidence/crc/12-review-reads.txt)). |
| **No converter page yet** | The Grafana-to-Perses page ([#2](https://github.com/ephico2real2/openshift-coo-helm/issues/2)) is not built. `percli` by hand: [docs/percli.md](../../docs/percli.md). |

## Tests

```bash
tests/test-chart.sh            # helm lint, renderings, schema, bash -n and shellcheck on the three Jobs' scripts
scripts/refresh-uiplugin-crd.sh  # after changing appVersion: refresh crds/ from a cluster running that version
```
