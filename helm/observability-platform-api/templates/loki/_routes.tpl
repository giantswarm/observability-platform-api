{{/* vim: set filetype=mustache: */}}

{{/*
Loki route bodies, shared by the JWT routes (loki/route-*.yaml) and the Basic
Auth routes (basicauth/routes.yaml) so the two hostnames serve the same paths
and backends.

Each template takes a dict:
  root:         the chart's root context
  name:         the route's metadata.name
  hostname:     the hostname (Helm template string); no hostnames when empty
  parentRefs:   the route's parentRefs
  headersCheck: the name of the HTTPRouteFilter returning 401 when X-Scope-OrgID is missing
*/}}

{{/*
Loki read HTTPRoute.
  Rule 1: matches path + X-Scope-OrgID header (regex ^.+$) → forwards to backend.
  Rule 2: matches path only (no header) → returns 401 via HTTPRouteFilter.
*/}}
{{- define "loki.route.read" -}}
{{- $root := .root -}}
{{- $loki := $root.Values.loki -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .name }}
  namespace: {{ $loki.namespace }}
  labels:
    {{- include "labels.common" $root | nindent 4 }}
spec:
  {{- with .parentRefs }}
  parentRefs:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .hostname }}
  hostnames:
  - {{ tpl . $root | quote }}
  {{- end }}
  rules:
  - backendRefs:
    - name: {{ $loki.read.backendService }}
      namespace: {{ $loki.namespace }}
      port: {{ $loki.read.backendPort }}
    matches:
    {{- range $loki.read.paths }}
    - path:
        type: PathPrefix
        value: {{ . }}
      headers:
      - name: X-Scope-OrgID
        value: "^.+$"
        type: RegularExpression
    {{- end }}
    filters:
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
        - name: X-Scope-OrgID
          value: "%REQ(X-Scope-OrgID)%"
  - backendRefs:
    - name: {{ $loki.read.backendService }}
      namespace: {{ $loki.namespace }}
      port: {{ $loki.read.backendPort }}
    filters:
    - type: ExtensionRef
      extensionRef:
        group: gateway.envoyproxy.io
        kind: HTTPRouteFilter
        name: {{ .headersCheck }}
    matches:
    {{- range $loki.read.paths }}
    - path:
        type: PathPrefix
        value: {{ . }}
    {{- end }}
{{- end -}}

{{/*
Loki write HTTPRoute.
  For each path in loki.write.paths:
    Rule (with header): matches path + X-Scope-OrgID header → forwards to backend
                        (and to loki.write.requestMirror when enabled).
    Rule (no header):   matches path only → returns 401 via HTTPRouteFilter.
*/}}
{{- define "loki.route.write" -}}
{{- $root := .root -}}
{{- $loki := $root.Values.loki -}}
{{- $headersCheck := .headersCheck -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .name }}
  namespace: {{ $loki.namespace }}
  labels:
    {{- include "labels.common" $root | nindent 4 }}
spec:
  {{- with .parentRefs }}
  parentRefs:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .hostname }}
  hostnames:
  - {{ tpl . $root | quote }}
  {{- end }}
  rules:
  {{- range $loki.write.paths }}
  - backendRefs:
    - name: {{ $loki.write.backendService }}
      namespace: {{ $loki.namespace }}
      port: {{ $loki.write.backendPort }}
    matches:
    - path:
        type: PathPrefix
        value: {{ . }}
      headers:
      - name: X-Scope-OrgID
        value: "^.+$"
        type: RegularExpression
    filters:
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
        - name: X-Scope-OrgID
          value: "%REQ(X-Scope-OrgID)%"
    {{- with $loki.write.requestMirror }}
    {{- if .enabled }}
    {{- /* This rule only: the one below returns 401 for requests without an
           X-Scope-OrgID header, so mirroring it would copy only rejections. */}}
    - type: RequestMirror
      requestMirror:
        backendRef:
          {{- toYaml .backendRef | nindent 10 }}
    {{- end }}
    {{- end }}
  - backendRefs:
    - name: {{ $loki.write.backendService }}
      namespace: {{ $loki.namespace }}
      port: {{ $loki.write.backendPort }}
    filters:
    - type: ExtensionRef
      extensionRef:
        group: gateway.envoyproxy.io
        kind: HTTPRouteFilter
        name: {{ $headersCheck }}
    matches:
    - path:
        type: PathPrefix
        value: {{ . }}
  {{- end }}
{{- end -}}
