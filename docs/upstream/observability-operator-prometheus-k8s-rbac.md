# Draft: upstream bug report for rhobs/observability-operator

**Status: draft, not filed.** For https://github.com/rhobs/observability-operator/issues. Everything below is observed on one
cluster or read in the source; the limits are listed at the end. Evidence files are in this repository (`docs/evidence/crc/`).

---

## Title

UIPlugin controller deletes the operator's own `prometheus-k8s` Role/RoleBinding when the health analyzer is disabled

## Summary

The operator controller creates a Role and RoleBinding named `prometheus-k8s` in the operator's namespace so the platform
Prometheus can discover and scrape the operator. The UIPlugin controller registers objects with the **same names, in the same
namespace**, for the health analyzer, as *optional*. When a monitoring UIPlugin exists with `clusterHealthAnalyzer` (and
`incidents`) disabled, each UIPlugin reconcile **deletes** the operator's Role and RoleBinding. After that,
`openshift-monitoring/prometheus-k8s` may not list endpoints, pods, services or endpointslices in that namespace, and
the operator is not scraped.

## Environment

- OpenShift 4.22.7 (Kubernetes v1.35.6), OpenShift Local (CRC), single node
- Cluster Observability Operator 1.5.3 from `redhat-operators`, channel `stable`, namespace `openshift-cluster-observability-operator`
  (labelled `openshift.io/cluster-monitoring: "true"`)

## Steps to reproduce

1. Install COO 1.5.3. Observe Role and RoleBinding `prometheus-k8s` in the operator namespace; the platform Prometheus scrapes
   the operator (`up{namespace="openshift-cluster-observability-operator", job="observability-operator"}` = 1).
2. Create:
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
   ```
3. List the Role: `oc -n openshift-cluster-observability-operator get role,rolebinding prometheus-k8s`.

**Expected:** the Role and RoleBinding stay; the operator stays scraped.

**Actual:** both are deleted, in the same second the UIPlugin is created, and stay deleted.

## Observations

- **API server audit log** (user `system:serviceaccount:openshift-cluster-observability-operator:observability-operator-sa`):
  `2026-10-03T21:11:56Z` patch (create) of `roles/rolebindings prometheus-k8s` at operator start; `2026-10-03T21:12:50Z`
  **delete** of both, the second the UIPlugin was created. Operator log at that second: `Reconciling observability UI plugin`.
- **Repeats on every reconcile.** Deleting the operator pod re-created them (`21:14:45Z` → `~21:15:01Z`); annotating the
  UIPlugin (one reconcile, `21:16:36Z`) deleted them again by `21:16:46Z`.
- **Effect on authorization:** `oc auth can-i list endpoints|pods|services|endpointslices.discovery.k8s.io
  -n openshift-cluster-observability-operator --as system:serviceaccount:openshift-monitoring:prometheus-k8s` → `no` for all four.
- **Effect on scraping, observed twice:** on a fresh install, with the objects deleted 54 s after the operator created them,
  the operator was not scraped (`up{namespace="openshift-cluster-observability-operator"}`: 0 series; the time of that query
  was not recorded). On an install that was already being scraped, with both grants gone, scraping continued at every sample
  from 05:08:54 to 05:12:38Z (3 min 44 s; not watched longer; why is not verified).
- **Not affected with the health analyzer on:** with `clusterHealthAnalyzer.enabled: true` the Role was present after two
  further reconciles (21:48:57Z).

## Cause, from the source

At `main` [`d53f293`](https://github.com/rhobs/observability-operator/tree/d53f293c4f293932e9d3e1a2817123f306b46ca4) (the same lines at
`v1.5.2`, `release-1.5` and `release-coo-1.5`):

- The operator controller registers its copy with a plain updater:
  [`pkg/controllers/operator/components.go:22-23`](https://github.com/rhobs/observability-operator/blob/d53f293c4f293932e9d3e1a2817123f306b46ca4/pkg/controllers/operator/components.go#L22-L23),
  objects named `prometheus-k8s` at [`:82`](https://github.com/rhobs/observability-operator/blob/d53f293c4f293932e9d3e1a2817123f306b46ca4/pkg/controllers/operator/components.go#L82) and [`:104`](https://github.com/rhobs/observability-operator/blob/d53f293c4f293932e9d3e1a2817123f306b46ca4/pkg/controllers/operator/components.go#L104).
- The health analyzer defines objects with the same names:
  [`pkg/controllers/uiplugin/health_analyzer.go:35`](https://github.com/rhobs/observability-operator/blob/d53f293c4f293932e9d3e1a2817123f306b46ca4/pkg/controllers/uiplugin/health_analyzer.go#L35) and [`:61`](https://github.com/rhobs/observability-operator/blob/d53f293c4f293932e9d3e1a2817123f306b46ca4/pkg/controllers/uiplugin/health_analyzer.go#L61).
- The UIPlugin controller registers them as optional:
  [`pkg/controllers/uiplugin/components.go:133`](https://github.com/rhobs/observability-operator/blob/d53f293c4f293932e9d3e1a2817123f306b46ca4/pkg/controllers/uiplugin/components.go#L133) `deployHealthAnalyzer := incidentsEnabled || healthAnalyzerEnabled`;
  [`:145-146`](https://github.com/rhobs/observability-operator/blob/d53f293c4f293932e9d3e1a2817123f306b46ca4/pkg/controllers/uiplugin/components.go#L145-L146) `reconciler.NewOptionalUpdater(newHealthAnalyzerPrometheusRole(namespace), plugin, deployHealthAnalyzer)` (and the RoleBinding).
- With the condition false, `NewOptionalUpdater` returns a `Deleter`
  ([`pkg/reconciler/reconciler.go:97-101`](https://github.com/rhobs/observability-operator/blob/d53f293c4f293932e9d3e1a2817123f306b46ca4/pkg/reconciler/reconciler.go#L97-L101)),
  which deletes the object by namespace and name, whoever owns it
  ([`:83-90`](https://github.com/rhobs/observability-operator/blob/d53f293c4f293932e9d3e1a2817123f306b46ca4/pkg/reconciler/reconciler.go#L83-L90)).

So the two controllers manage one object; the UIPlugin controller deletes the operator controller's copy.

## Possible fixes (for the maintainers to choose)

- Give the health analyzer's Role and RoleBinding their own names; or
- have the health analyzer use the operator's existing `prometheus-k8s` objects instead of managing its own; or
- make the deleter skip an object it does not own.

## Workarounds we use

- Enable `spec.monitoring.clusterHealthAnalyzer` (observed: the Role then survives). Red Hat lists incident detection as GA from
  OpenShift 4.19.
- Or create a Role and RoleBinding with the same rules under another name; the UIPlugin controller does not touch it. Observed with
  `clusterHealthAnalyzer` off: the operator's copy deleted, ours present, the operator scraped (`up` = 1) at every sample from 05:04:10 to 05:06:54Z (2 min 44 s).

## Limits of this report

- One cluster: single-node CRC, OpenShift 4.22.7, COO 1.5.3. Not run on other versions or on multi-node clusters.
- The source was read upstream at the refs above. Upstream has no `v1.5.3` tag; `release-1.5` carries the release commit
  `chore(release): 1.5.3 (#1266)` (`25ccb9e`), where the lines are the same. Whether Red Hat built 1.5.3 from it was not
  verified. The lines are identical on `v1.5.2`, both 1.5 release branches and `main`; on `v1.5.0` and `v1.5.1` the same
  code is there, but `NewOptionalUpdater` is at `pkg/reconciler/reconciler.go:114`, not `:97`.
- **Also observed:** deleting the UIPlugin (health analyzer on) also removed the operator's `prometheus-k8s` Role and
  RoleBinding, which were still absent 34 s later. A later read on the cluster shows why: with the health analyzer on, the
  Role carries `ownerReferences` UIPlugin `monitoring`, `controller: true`, `blockOwnerDeletion: true`, so the garbage
  collector deletes it with the UIPlugin. That deletion was not re-run after the read.
- Searched this repository's issues and pull requests on 2026-10-04 ("prometheus-k8s", "health analyzer RBAC", "self-monitoring
  uiplugin", "clusterHealthAnalyzer"): no report of this found.
