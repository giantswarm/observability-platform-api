{{/* vim: set filetype=mustache: */}}

{{/*
Tempo write route bodies, shared by the JWT write routes (tempo/route-write.yaml,
tempo/route-grpc.yaml) and the Basic Auth write routes (basicauth/routes.yaml)
so the two hostnames serve the same paths and backends. The read routes have no
Basic Auth counterpart and stay inline.

Each template takes a dict:
  root:         the chart's root context
  name:         the route's metadata.name
  hostname:     the hostname (Helm template string); no hostnames when empty
  parentRefs:   the route's parentRefs
  headersCheck: the name of the HTTPRouteFilter returning 401 when X-Scope-OrgID is
                missing (HTTPRoutes only: a GRPCRoute cannot reference an HTTPRouteFilter)
*/}}

{{/*
Tempo OTLP/HTTP write HTTPRoute (tempo-distributor:4318).
  For each path in tempo.write.paths:
    Rule (with header): matches path + X-Scope-OrgID header → forwards to backend.
    Rule (no header):   matches path only → returns 401 via HTTPRouteFilter.
*/}}
{{- define "tempo.route.write" -}}
{{- $root := .root -}}
{{- $tempo := $root.Values.tempo -}}
{{- $headersCheck := .headersCheck -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .name }}
  namespace: {{ $tempo.namespace }}
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
  {{- range $tempo.write.paths }}
  - backendRefs:
    - name: tempo-distributor
      namespace: {{ $tempo.namespace }}
      port: 4318
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
    - name: tempo-distributor
      namespace: {{ $tempo.namespace }}
      port: 4318
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

{{/*
Tempo OTLP/gRPC write GRPCRoute (tempo.write.grpc backend, tempo-distributor:4317).
  Single rule: matches opentelemetry.proto.collector.trace.v1.TraceService + X-Scope-OrgID
  header → forwards to backend. Bypasses the nginx gateway, which does not handle gRPC.
*/}}
{{- define "tempo.route.grpc.write" -}}
{{- $root := .root -}}
{{- $tempo := $root.Values.tempo -}}
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: {{ .name }}
  namespace: {{ $tempo.namespace }}
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
    - name: {{ $tempo.write.grpc.backendService }}
      namespace: {{ $tempo.namespace }}
      port: {{ $tempo.write.grpc.backendPort }}
    matches:
    - method:
        service: opentelemetry.proto.collector.trace.v1.TraceService
        type: Exact
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
{{- end -}}
