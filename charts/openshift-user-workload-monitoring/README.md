# openshift-user-workload-monitoring Helm chart

The settings of OpenShift's **user workload monitoring**, in values instead of a hand edit: the chart renders one object, the ConfigMap `user-workload-monitoring-config` in `openshift-user-workload-monitoring`. Nothing in `openshift-monitoring` is created or changed (measured: all 16 ConfigMaps there kept their resourceVersions through install, upgrade and uninstall, [evidence 14](../../docs/evidence/crc/14-user-workload-monitoring-chart.txt)).

> [!IMPORTANT]
> **The chart owns the whole ConfigMap.** Every user workload monitoring setting of the cluster, other teams' included, goes through its `config` value. A setting edited by hand is overwritten at the next upgrade.

## Why a chart can own it

The cluster-monitoring-operator creates this ConfigMap empty, only when it is missing, and never updates it; it only reads it (cluster-monitoring-operator release-4.18: `assets/prometheus-user-workload/config-map.yaml`, `CreateIfNotExistConfigMap` in `pkg/client/client.go`, `loadUserWorkloadConfig` in `pkg/operator/operator.go`). So the chart takes it over once, and the operator never fights it.

## Install

OpenShift 4.18 or later. A `cluster-admin`, or a user with `user-workload-monitoring-config-edit` in `openshift-user-workload-monitoring`.

```bash
helm install uwm charts/openshift-user-workload-monitoring -n openshift-user-workload-monitoring \
  -f my-values.yaml --take-ownership --force-conflicts
```

Both flags are needed once, because the operator has already created the ConfigMap (measured with Helm 4.3.0):

- without `--take-ownership`, Helm refuses: *"invalid ownership metadata; label validation error: key "app.kubernetes.io/managed-by" must equal "Helm": current value is "cluster-monitoring-operator""*;
- without `--force-conflicts`, Helm 4's server-side apply stops on the fields other managers own: *"Apply failed with 2 conflicts: conflicts with "kubectl-patch" … conflicts with "operator""* (a hand edit, and the operator that created the object). The release is then `failed` and the ConfigMap unchanged; run the same command as `helm upgrade` with both flags. Do **not** `helm uninstall` a failed release: it deletes the ConfigMap.

Later upgrades need neither flag.

## Values

`config` is `config.yaml`, as YAML: the keys of `UserWorkloadConfiguration` in the [cluster-monitoring-operator API reference](https://github.com/openshift/cluster-monitoring-operator/blob/release-4.18/Documentation/api.md): `alertmanager`, `prometheus`, `prometheusOperator`, `thanosRuler`, `namespacesWithoutLabelEnforcement`. They are the same five from release-4.18 to `main`; the schema refuses any other top-level key and leaves the contents of each to the operator. Empty `config` renders the operator's own default.

`examples/values-ipsec-nas.yaml` holds the settings [openshift-ipsec-nas](https://github.com/ephico2real2/openshift-ipsec-nas) needs (its doc 60, *The cluster settings*):

```yaml
config:
  namespacesWithoutLabelEnforcement: [kcs-ipsec]
  alertmanager:
    enabled: true
    enableAlertmanagerConfig: true
```

Add other stanzas beside them as needed.

## Install with Argo CD

`examples/argocd-application.yaml`.

## Upgrade, uninstall

`helm upgrade` with new values: the operator applies them (measured: `thanosRuler.logLevel: debug` reached the ThanosRuler in 6 seconds, and left it 19 seconds after it was removed).

`helm uninstall` deletes the ConfigMap. The operator recreates it empty within seconds (measured: 5 seconds) and user workload monitoring returns to its defaults: no separate Alertmanager, no namespace exempt from label enforcement.

## Test

```bash
tests/test-uwm-chart.sh
```
