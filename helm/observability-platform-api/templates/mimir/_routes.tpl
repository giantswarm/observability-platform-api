{{/* vim: set filetype=mustache: */}}

{{/*
Mimir route bodies, shared by the JWT routes (mimir/route-*.yaml) and the Basic
Auth routes (basicauth/routes.yaml) so the two hostnames serve the same paths,
rewrites and backends.

Each template takes a dict:
  root:         the chart's root context
  name:         the route's metadata.name
  hostname:     the hostname (Helm template string); no hostnames when empty
  parentRefs:   the route's parentRefs
  headersCheck: the name of the HTTPRouteFilter returning 401 when X-Scope-OrgID is missing
*/}}

{{/*
Mimir read HTTPRoute.
  Rule 1: matches path + X-Scope-OrgID header (regex ^.+$) → forwards to backend.
  Rule 2: matches path only (no header) → returns 401 via HTTPRouteFilter.
*/}}
{{- define "mimir.route.read" -}}
{{- $root := .root -}}
{{- $mimir := $root.Values.mimir -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .name }}
  namespace: {{ $mimir.namespace }}
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
    - name: {{ $mimir.read.backendService }}
      namespace: {{ $mimir.namespace }}
      port: {{ $mimir.read.backendPort }}
    matches:
    {{- range $mimir.read.paths }}
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
    - name: {{ $mimir.read.backendService }}
      namespace: {{ $mimir.namespace }}
      port: {{ $mimir.read.backendPort }}
    filters:
    - type: ExtensionRef
      extensionRef:
        group: gateway.envoyproxy.io
        kind: HTTPRouteFilter
        name: {{ .headersCheck }}
    matches:
    {{- range $mimir.read.paths }}
    - path:
        type: PathPrefix
        value: {{ . }}
    {{- end }}
{{- end -}}

{{/*
Mimir write HTTPRoute.
  For each path in mimir.write.stripPrefixPaths:
    Rule (with header): matches path + X-Scope-OrgID header → strips the /prometheus
                        prefix (mimir-rewrite filter) and forwards to backend.
    Rule (no header):   matches path only → returns 401 via HTTPRouteFilter.
  For each path in mimir.write.paths:
    Rule (with header): matches path + X-Scope-OrgID header → forwards to backend as-is.
    Rule (no header):   matches path only → returns 401 via HTTPRouteFilter.
*/}}
{{- define "mimir.route.write" -}}
{{- $root := .root -}}
{{- $mimir := $root.Values.mimir -}}
{{- $headersCheck := .headersCheck -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .name }}
  namespace: {{ $mimir.namespace }}
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
  {{- range $mimir.write.stripPrefixPaths }}
  - backendRefs:
    - name: {{ $mimir.write.backendService }}
      namespace: {{ $mimir.namespace }}
      port: {{ $mimir.write.backendPort }}
    matches:
    - path:
        type: PathPrefix
        value: {{ . }}
      headers:
      - name: X-Scope-OrgID
        value: "^.+$"
        type: RegularExpression
    filters:
    - type: ExtensionRef
      extensionRef:
        group: gateway.envoyproxy.io
        kind: HTTPRouteFilter
        name: {{ include "resource.default.name" $root }}-mimir-rewrite
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
        - name: X-Scope-OrgID
          value: "%REQ(X-Scope-OrgID)%"
  - backendRefs:
    - name: {{ $mimir.write.backendService }}
      namespace: {{ $mimir.namespace }}
      port: {{ $mimir.write.backendPort }}
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
  {{- range $mimir.write.paths }}
  - backendRefs:
    - name: {{ $mimir.write.backendService }}
      namespace: {{ $mimir.namespace }}
      port: {{ $mimir.write.backendPort }}
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
  - backendRefs:
    - name: {{ $mimir.write.backendService }}
      namespace: {{ $mimir.namespace }}
      port: {{ $mimir.write.backendPort }}
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
