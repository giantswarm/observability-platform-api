{{/* vim: set filetype=mustache: */}}

{{/*
The source of the Basic Auth users: "handManaged" (default) or "agentCredential".
Fails on any other value.
*/}}
{{- define "basicauth.mode" -}}
{{- $mode := .Values.basicAuth.mode | default "handManaged" -}}
{{- if not (has $mode (list "handManaged" "agentCredential")) -}}
{{- fail (printf "basicAuth.mode is %q. It must be handManaged or agentCredential." $mode) -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{/*
Basic Auth routes are rendered only when the feature is enabled *and* fully
configured. This follows the same convention as the JWT routes, which render
nothing when auth.jwt.providers is empty: an incomplete configuration produces
no resources rather than failing the release. In particular it avoids shipping
a SecurityPolicy pointing at a Secret that does not exist, which would leave
the routes rejecting every request.

In agentCredential mode the per-backend Secrets are checked one by one in
basicauth.backends instead of basicAuth.usersSecret.
*/}}
{{- define "basicauth.configured" -}}
{{- $ba := .Values.basicAuth -}}
{{- if and $ba.enabled $ba.hostname -}}
{{- if eq (include "basicauth.mode" .) "agentCredential" -}}
true
{{- else if and $ba.usersSecret.name $ba.usersSecret.namespace -}}
true
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The backends served on the Basic Auth hostname, as a JSON list of
  {name, namespace, secretName, secretNamespace}
where name is the service (mimir, loki, tempo), namespace is its namespace, and
secretName/secretNamespace is the users Secret its SecurityPolicy reads.

  handManaged:     Mimir and Loki, both reading basicAuth.usersSecret.
  agentCredential: Mimir, Loki and Tempo, each reading its own Secret from
                   basicAuth.agentCredential.usersSecrets.<metrics|logs|traces>.
                   An empty namespace means the backend's namespace. A backend
                   whose Secret name is empty is left out.

Only enabled services are listed, and nothing is listed unless
basicauth.configured holds.
*/}}
{{- define "basicauth.backends" -}}
{{- $ba := .Values.basicAuth -}}
{{- $backends := list -}}
{{- if eq (include "basicauth.configured" .) "true" -}}
{{- $agentCredential := eq (include "basicauth.mode" .) "agentCredential" -}}
{{- $kinds := dict "mimir" "metrics" "loki" "logs" "tempo" "traces" -}}
{{- $services := list "mimir" "loki" -}}
{{- if $agentCredential -}}
{{- $services = append $services "tempo" -}}
{{- end -}}
{{- range $name := $services -}}
{{- $service := index $.Values $name -}}
{{- if $service.enabled -}}
{{- $secretName := $ba.usersSecret.name -}}
{{- $secretNamespace := $ba.usersSecret.namespace -}}
{{- if $agentCredential -}}
{{- $secret := index $ba.agentCredential.usersSecrets (index $kinds $name) | default dict -}}
{{- $secretName = $secret.name -}}
{{- $secretNamespace = $secret.namespace | default $service.namespace -}}
{{- end -}}
{{- if $secretName -}}
{{- $backends = append $backends (dict "name" $name "namespace" $service.namespace "secretName" $secretName "secretNamespace" $secretNamespace) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toJson $backends -}}
{{- end -}}

{{/*
The Basic Auth routes of one backend, as a JSON list of {kind, name, template}.
Takes a dict {root, backend} where backend is the service name.

Each route reuses the body of the matching JWT route (template, from
<service>/_routes.tpl), so the paths, rewrites and backends stay identical.

  handManaged:     the Mimir and Loki read routes only.
  agentCredential: also the Mimir and Loki write routes, and every Tempo route
                   (HTTP and gRPC read, OTLP/HTTP and OTLP/gRPC write).

The write and Tempo routes render only in agentCredential mode, so a
hand-managed read user never gains write access.
*/}}
{{- define "basicauth.routes" -}}
{{- $root := .root -}}
{{- $prefix := printf "%s-%s" (include "resource.default.name" $root) .backend -}}
{{- $agentCredential := eq (include "basicauth.mode" $root) "agentCredential" -}}
{{- $routes := list -}}
{{- if or (eq .backend "mimir") (eq .backend "loki") -}}
{{- $routes = append $routes (dict "kind" "HTTPRoute" "name" (printf "%s-read-api-basicauth" $prefix) "template" (printf "%s.route.read" .backend)) -}}
{{- if $agentCredential -}}
{{- $routes = append $routes (dict "kind" "HTTPRoute" "name" (printf "%s-write-api-basicauth" $prefix) "template" (printf "%s.route.write" .backend)) -}}
{{- end -}}
{{- else if and (eq .backend "tempo") $agentCredential -}}
{{- $routes = append $routes (dict "kind" "HTTPRoute" "name" (printf "%s-read-api-basicauth" $prefix) "template" "tempo.route.read") -}}
{{- $routes = append $routes (dict "kind" "GRPCRoute" "name" (printf "%s-read-api-grpc-basicauth" $prefix) "template" "tempo.route.grpc.read") -}}
{{- $routes = append $routes (dict "kind" "HTTPRoute" "name" (printf "%s-otlp-write-api-basicauth" $prefix) "template" "tempo.route.write") -}}
{{- $routes = append $routes (dict "kind" "GRPCRoute" "name" (printf "%s-write-api-grpc-basicauth" $prefix) "template" "tempo.route.grpc.write") -}}
{{- end -}}
{{- toJson $routes -}}
{{- end -}}
