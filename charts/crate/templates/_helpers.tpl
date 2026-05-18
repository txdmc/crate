{{/*
Expand the name of the chart.
*/}}
{{- define "crate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this
(including DNS names that respect RFC 1123).
*/}}
{{- define "crate.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart label (name + version).
*/}}
{{- define "crate.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "crate.labels" -}}
helm.sh/chart: {{ include "crate.chart" . }}
{{ include "crate.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels — used by Deployments and Services.
*/}}
{{- define "crate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "crate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Resolve the ServiceAccount name to use.
*/}}
{{- define "crate.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "crate.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Derive the PostgreSQL host for the in-cluster subchart.
*/}}
{{- define "crate.postgresHost" -}}
{{- printf "%s-postgresql" .Release.Name }}
{{- end }}

{{/*
Derive the MinIO endpoint for the in-cluster subchart.
*/}}
{{- define "crate.minioEndpoint" -}}
{{- printf "http://%s-minio:9000" .Release.Name }}
{{- end }}
