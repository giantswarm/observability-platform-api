{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "labels.selector" -}}
app.kubernetes.io/name: {{ include "name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "labels.common" -}}
{{ include "labels.selector" . }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
application.giantswarm.io/team: {{ index .Chart.Annotations "io.giantswarm.application.team" | quote }}
giantswarm.io/managed-by: {{ .Release.Name | quote }}
giantswarm.io/service-type: {{ .Values.serviceType }}
helm.sh/chart: {{ include "chart" . | quote }}
{{- end -}}

{{/*
Generate TLS secret name based on host and namespace to enable sharing between ingresses
If ingress.tls.secretName is specified, use that instead for custom secret sharing
*/}}
{{- define "ingress.tls.secretName" -}}
{{- $context := .context -}}
{{- $ingress := .ingress -}}
{{- if and $ingress.tls $ingress.tls.secretName -}}
{{- $ingress.tls.secretName -}}
{{- else -}}
{{- $firstHost := (index $ingress.hosts 0).host -}}
{{- $hostHash := $firstHost | replace "." "-" | trunc 20 -}}
{{- printf "%s-%s-%s-tls" (include "resource.default.name" $context) $ingress.namespace $hostHash -}}
{{- end -}}
{{- end -}}
