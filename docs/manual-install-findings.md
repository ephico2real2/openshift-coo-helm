# COO Installed by Hand: What It Does, Measured

Before writing a chart, the Cluster Observability Operator (COO) was installed by hand on OpenShift Local (CRC 4.22.7, one node), step by step, to learn what a hands-free install must do. Every statement below is from the saved output in [`evidence/crc/`](evidence/crc/), recorded on 2026-10-03.

## 1. What the catalog says

| | Value |
|---|---|
| Package / catalog | `cluster-observability-operator` in `redhat-operators` |
| Channels | `stable` (default) and `fast`, both at `cluster-observability-operator.v1.5.3` |
| Install modes | **AllNamespaces only** (OwnNamespace, SingleNamespace and MultiNamespace: not supported) |
| Suggested namespace | `openshift-cluster-observability-operator` |
| `operatorframework.io/cluster-monitoring` | `true`: the namespace should carry `openshift.io/cluster-monitoring: "true"` |

Red Hat documents only the web-console install: channel `stable`, *All namespaces*, that namespace, *"Enable Operator recommended cluster monitoring on this Namespace"* ticked, and approval *Automatic* ([Installing COO](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/html-single/installing_red_hat_openshift_cluster_observability_operator/index)). It has no CLI or YAML procedure, and says nothing about monitoring COO itself.

## 2. The install, by hand ([01](evidence/crc/01-manual-install.txt))

The same three objects the console creates, with **Manual** approval so that nothing installs until it is approved:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cluster-observability-operator
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-operator
  namespace: openshift-cluster-observability-operator
spec: {}                       # no targetNamespaces: AllNamespaces, the only mode COO supports
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: openshift-cluster-observability-operator
spec:
  channel: stable
  installPlanApproval: Manual
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

1. **OLM staged an InstallPlan and installed nothing.** `install-mrfrp` was `RequiresApproval`, its CSV list only `cluster-observability-operator.v1.5.3`, and the Subscription state `UpgradePending`.
2. **The namespace already showed five other CSVs:** cert-manager, Custom Metrics Autoscaler, MetalLB, Namespace Configuration and OpenShift GitOps. They are OLM's copies of operators installed for all namespaces; OLM places them in every namespace. **An approver must match its own package exactly (`cluster-observability-operator.v…`) and never act on a copy.**
3. **Approved by hand:** `oc patch installplan install-mrfrp --type merge -p '{"spec":{"approved":true}}'`. From approval: plan `Complete` in **25 s**, CSV `Succeeded` in **25 s**, all Deployments `Available` in **26 s**. Subscription: `AtLatestKnown`.
4. **It runs four Deployments:** `observability-operator`, `perses-operator`, `obo-prometheus-operator`, and `obo-prometheus-operator-admission-webhook` (2 replicas).

## 3. What the install adds to the cluster ([01](evidence/crc/01-manual-install.txt), [diff](evidence/crc/01-install-added.txt))

Cluster-scoped objects and the two platform monitoring namespaces, before vs after:

| Kind | Added |
|---|---|
| CustomResourceDefinition | 18 |
| ClusterRole | 94 |
| ClusterRoleBinding | 6 |
| APIService | 5 (local, the CRDs' own) |
| ValidatingWebhookConfiguration | 2 (`alertmanagerconfigs` and `prometheusrules` in `monitoring.rhobs`) |
| **Removed** | **0** |
| Changed in `openshift-monitoring`, `openshift-user-workload-monitoring`, console plugins | **none** |

- **COO's Prometheus kinds have their own API group, `monitoring.rhobs`.** They are separate from the platform's `monitoring.coreos.com`, so a team's `ServiceMonitor` (`monitoring.coreos.com`) still goes to the platform Prometheus.
- **The Perses kinds:** `perses`, `persesdashboards`, `persesdatasources` (`v1alpha1` and `v1alpha2`), and `persesglobaldatasources` (**`v1alpha2` only**).
- **COO's own kinds:** `uiplugins` and `observabilityinstallers` (`observability.openshift.io`).
- **Roles for teams:** `persesdashboard-viewer-role`, `persesdashboard-editor-role`, `persesdatasource-viewer-role`, `persesdatasource-editor-role`, `persesglobaldatasource-viewer-role` and `persesglobaldatasource-editor-role`, besides the usual admin/edit/view roles per kind.

## 4. Enabling Perses: the `UIPlugin` ([02](evidence/crc/02-uiplugin-perses.txt))

```yaml
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
    clusterHealthAnalyzer:
      enabled: true      # see section 5: without it, COO deletes its own monitoring RBAC
```

- `Available` 5 s after it was applied.
- It creates the **Perses server** (StatefulSet `perses`, the `Perses` resource), the **console plugin** (Deployment `monitoring`, ConsolePlugin `monitoring-console-plugin`), and an automatic `PersesDatasource` `accelerators-thanos-querier-datasource`.
- **COO enables the console plugin itself.** `monitoring-console-plugin` was appended to `console.operator.openshift.io/cluster` `.spec.plugins`; the four plugins already there were untouched. A chart only has to *check* it is there; no Job is needed.

## 5. A defect in COO: the UIPlugin deletes COO's own monitoring RBAC ([03](evidence/crc/03-uiplugin-deletes-self-monitoring-rbac.txt), [06](evidence/crc/06-uiplugin-all-features.txt))

**What happens:**
- COO's self-monitoring creates a Role and RoleBinding `prometheus-k8s` in its namespace, so the platform Prometheus can scrape the operator.
- With a UIPlugin that enables **Perses only**, every UIPlugin reconcile **deletes** them.
- The platform then did not scrape COO (`up{namespace="openshift-cluster-observability-operator"}`: 0 series), so the rules of COO's PrometheusRule `observability-operator` had none of COO's metrics to evaluate (inferred, not observed as an alert). On an install already being scraped, scraping continued for the 3 min 44 s watched ([11](evidence/crc/11-chart-on-crc.txt) §3).

**The evidence:**
- **API server audit log**, all by `system:serviceaccount:openshift-cluster-observability-operator:observability-operator-sa`:
  - 21:11:56Z: created;
  - 21:12:50Z: deleted, in the same second the UIPlugin was created.
- **Reproduced:** an operator restart re-creates them; the next UIPlugin reconcile deletes them again.

**The cause, in `rhobs/observability-operator`:**
- Two controllers own objects with the same names: `pkg/controllers/operator/components.go` (self-monitoring) and `pkg/controllers/uiplugin/health_analyzer.go` (the health analyzer).
- `pkg/controllers/uiplugin/components.go:133`: `deployHealthAnalyzer := incidentsEnabled || healthAnalyzerEnabled`.
- Lines 145–146 register the health analyzer's `prometheus-k8s` Role and RoleBinding as optional on that condition, so they are deleted when it is false.
- No public bug report was found.

**The fix, measured: `clusterHealthAnalyzer: enabled: true`.**
- **It is the documented setting.** Red Hat documents it as *incident detection*, GA on OpenShift 4.19 and later ([UI plugins](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/html-single/ui_plugins_for_red_hat_openshift_cluster_observability_operator/index)). The older field `incidents` still exists: COO 1.4 deprecated it in favour of `clusterHealthAnalyzer` ([release notes](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/html/red_hat_openshift_cluster_observability_operator_release_notes/cluster-observability-operator-release-notes)). Measured: `clusterHealthAnalyzer` alone is enough ([06](evidence/crc/06-uiplugin-all-features.txt), with `incidents` off). `incidents` alone was not measured; by the source (`incidentsEnabled || healthAnalyzerEnabled`) it would be too.
- **The two definitions are identical** (same rules, same subject `openshift-monitoring/prometheus-k8s`). With the analyzer on, both controllers want the same object.
- **No flapping:**
  - the Role survived three forced reconciles and an operator restart;
  - the audit log showed **no writes** to it afterwards;
  - the platform scrapes COO again.
- `acm` is the fourth feature. It needs an Advanced Cluster Management hub's Alertmanager and Thanos URLs, and is not used.

**What `clusterHealthAnalyzer` adds:**
- **In COO's namespace:** a `health-analyzer` Deployment, Service, ServiceMonitor and ConfigMap.
- **ClusterRoleBindings for COO's `monitoring-sa`:**
  - `cluster-monitoring-view`: read all cluster metrics;
  - `system:auth-delegator`: review other users' tokens;
  - `components-health-view`: read nodes, ClusterOperators, MachineConfigPools and KubeVirt.
- **One RoleBinding in `openshift-monitoring`:** `alertmanager-view-rolebinding`, binding the existing Role `monitoring-alertmanager-view` (read access to the platform Alertmanager).

## 6. How Perses authenticates, and reaches Thanos ([04](evidence/crc/04-perses-identity-and-datasources.txt))

**How it is configured, as read from the cluster:**
- **The console sends each user's own token.** The ConsolePlugin proxies Perses with `authorization: UserToken`.
- **Logins and permissions are Kubernetes'.** Perses runs with the `kubernetes` authentication and authorization providers, its own login off, and `client.kubernetesAuth.enable: true`. It serves HTTPS on 8080.
- **No stored credentials.** The automatic datasource's `secret` is a *Perses* secret holding only a CA file.

**Measured, with a ServiceAccount that has only `view` and the Perses viewer roles in `kcs-ipsec`:**

| Request | Result |
|---|---|
| Perses API, no token | 401 |
| List projects | only `kcs-ipsec` |
| A datasource in COO's project | 403 |
| Query via a datasource on Thanos **9091** | **403 from Thanos, naming this user**: Perses forwards the caller's token |
| The same as kubeadmin | 200 |
| Via Thanos **9092** (tenancy), `namespace=kcs-ipsec` | **200** |
| 9092, `namespace=openshift-monitoring` | 403 |
| 9092, no `namespace` | 400: the backend proxy does not add `queryParams` |

What follows for teams' dashboards:
- **No shared credential exists anywhere.** Every viewer sees exactly what OpenShift lets them see.
- **A 9091 datasource works only for holders of `cluster-monitoring-view`.** These `GET` queries suggested a 9092 datasource with `queryParams: {namespace: <ns>}` for readers with only `view`; the Perses UI's `POST` queries ruled it out. **Dashboards use 9091**: decision 6a.
- **Platform metrics** (for example `node_nfs_requests_total`) are not visible through a namespace.
- **A datasource must name the Perses secret the operator derives from `client.tls`** (`<datasource>-secret`) in `proxy.spec.secret`. Without it: `x509: certificate signed by unknown authority`.
- **A namespace becomes a Perses project** as soon as a Perses resource exists in it.

## 6a. Decision: dashboards query Thanos 9091; viewers hold `cluster-monitoring-view`

**Decided 2026-10-03.** Metrics carry no PHI or PII, and namespace owners must see their own metrics without technical gymnastics. Measured with a real dashboard ([openshift-ipsec-nas doc 61](https://github.com/ephico2real2/openshift-ipsec-nas/blob/main/docs/61-perses-dashboard-review.md)):

| | Port 9092 (per namespace) | Port 9091 (cluster) |
|---|---|---|
| A `POST` query is checked as | `create` on **pods** in the namespace: the right to run workloads | `create` on **`prometheuses/api`** |
| The Perses UI sends its data queries as | `POST`; there is no `GET` setting | `POST` |
| Namespace-only reader | **Forbidden on every panel** | Forbidden (no `cluster-monitoring-view`) |
| Reader holding `cluster-monitoring-view` | Forbidden | **every panel answers**, platform metrics included |

`cluster-monitoring-view` holds exactly two rules: `get` on `namespaces`, and `get`/`create`/`update` on `prometheuses/api`. The last three are how Thanos's proxy names `GET`, `POST` and `PUT` queries. It is read access to metrics, nothing else.

**So:**
- Application dashboards use a `PersesDatasource` on **9091**.
- Their viewers hold `cluster-monitoring-view`.
- Who holds it is a platform setting of the chart, `metricsAccess.groups`. It is one binding for everyone, so no team files a request per namespace.

## 7. Versions ([07](evidence/crc/07-percli-install.txt))

COO 1.5 builds on Perses **v0.54.0**: `release-1.5`'s `go.mod` lists `github.com/perses/perses v0.54.0`, Prometheus plugin v0.58.0, and table and time-series plugins v0.13.0. The server image does not report a version. Use `percli` 0.54.0: [percli.md](percli.md).

## 8. What a hands-free chart must do (derived from the above)

1. **Install.**
   - The Namespace with `openshift.io/cluster-monitoring: "true"`, and an OperatorGroup with **no** `targetNamespaces`. OLM allows one OperatorGroup per namespace, so reuse one that exists.
   - A Subscription with `installPlanApproval: Manual`.
2. **Approve.** A Job that:
   - approves only an InstallPlan whose CSV list names `cluster-observability-operator.v…`;
   - ignores OLM's copied CSVs;
   - waits for the plan to be `Complete` and the CSV to be `Succeeded`.

   This is the approver pattern of the `openshift-grafana` chart.
3. **Configure.** The `UIPlugin` with `perses` **and** `clusterHealthAnalyzer`, applied only after the CSV is `Succeeded` (its CRD must exist).
4. **Verify.** Wait for the UIPlugin to be `Available`, `monitoring-console-plugin` to be in `console.spec.plugins`, Perses to be ready, and the platform to scrape COO.
5. **Grant metrics access (decision 6a).** A ClusterRoleBinding of `cluster-monitoring-view` to the groups in a value, for example `system:authenticated` (everyone logged in) or named groups. With none listed, nothing is bound.
6. **Measured since, and built into the chart** ([charts/openshift-coo](../charts/openshift-coo/README.md)):
   - **Uninstall** ([10](evidence/crc/10-lifecycle-uninstall-reinstall-upgrade.txt)): deleting the UIPlugin removes all it made but leaves the console's plugin entry; deleting the Subscription leaves the CSV `Succeeded` and unowned; the CRDs, their roles and COO's six Perses team roles always stay.
   - **Reinstall over a left-over CSV** ([10](evidence/crc/10-lifecycle-uninstall-reinstall-upgrade.txt) step 3-4): `ResolutionFailed` within 20 s and no InstallPlan; deleting the CSV stages one in 5 s. The chart's reclaim Job does it ([11](evidence/crc/11-chart-on-crc.txt) section 8).
   - **Upgrades within `stable`** ([10](evidence/crc/10-lifecycle-uninstall-reinstall-upgrade.txt) step 6): with 1.5.2 installed, the 1.5.3 plan was staged by the first sample, 5 s after 1.5.2 Succeeded, and it waits; approved, 47 s to `Succeeded`. The chart approves only `operator.version`.
   - **A second fix for section 5:** the chart's own copy of the scrape grant, which COO never deletes, keeps COO scraped with `clusterHealthAnalyzer` off ([11](evidence/crc/11-chart-on-crc.txt) sections 2-3). The chart keeps `clusterHealthAnalyzer` on as well, and requires OpenShift 4.19, where Red Hat lists it as GA.
   - **Whether the console adds a datasource's `queryParams`:** no longer needed. It mattered only for per-namespace data sources on port 9092, which decision 6a replaced (a `POST` there is checked as `create pods` whatever the parameters).
