{{- define "openshift-coo.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.operator.version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- /* COO's namespace: every namespaced object of this chart lives there, whatever the release's namespace. */ -}}
{{- define "openshift-coo.namespace" -}}
{{ .Values.namespace.name }}
{{- end -}}

{{- /* The one CSV the approver approves and the gate waits for: <package>.v<version>. */ -}}
{{- define "openshift-coo.csv" -}}
{{ printf "%s.v%s" .Values.operator.package .Values.operator.version }}
{{- end -}}

{{- /* Prefix for the chart's own objects (Jobs, their RBAC, the metrics binding). */ -}}
{{- define "openshift-coo.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{ .Release.Name | trunc 50 | trimSuffix "-" }}
{{- else -}}
{{ printf "%s-%s" .Release.Name .Chart.Name | trunc 50 | trimSuffix "-" }}
{{- end -}}
{{- end -}}

{{- /* The pod spec shared by the three Jobs: restricted-v2 compliant, a shell and oc. */ -}}
{{- define "openshift-coo.jobPod" -}}
restartPolicy: Never
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{- define "openshift-coo.jobContainer" -}}
image: "{{ .Values.jobs.image.repository }}:{{ .Values.jobs.image.tag }}"
resources:
  {{- toYaml .Values.jobs.resources | nindent 2 }}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
command: ["/bin/bash", "-c"]
{{- end -}}
