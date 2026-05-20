{{/*
Expand the name of the chart.
*/}}
{{- define "config-gen.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "config-gen.fullname" -}}
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
Create chart label.
*/}}
{{- define "config-gen.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "config-gen.labels" -}}
helm.sh/chart: {{ include "config-gen.chart" . }}
{{ include "config-gen.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "config-gen.selectorLabels" -}}
app.kubernetes.io/name: {{ include "config-gen.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Backend component fullname
*/}}
{{- define "config-gen.backend.fullname" -}}
{{- printf "%s-backend" (include "config-gen.fullname" .) }}
{{- end }}

{{/*
Frontend component fullname
*/}}
{{- define "config-gen.frontend.fullname" -}}
{{- printf "%s-frontend" (include "config-gen.fullname" .) }}
{{- end }}

{{/*
Backend selector labels
*/}}
{{- define "config-gen.backend.selectorLabels" -}}
{{ include "config-gen.selectorLabels" . }}
app.kubernetes.io/component: backend
{{- end }}

{{/*
Frontend selector labels
*/}}
{{- define "config-gen.frontend.selectorLabels" -}}
{{ include "config-gen.selectorLabels" . }}
app.kubernetes.io/component: frontend
{{- end }}
