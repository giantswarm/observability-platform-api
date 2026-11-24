{{/* vim: set filetype=mustache: */}}

{{/*
The Basic Auth hostname serves two independent route sets. Both need
basicAuth.enabled and basicAuth.hostname; each then has its own users:

  read:  the Mimir and Loki read routes, checked against the single
         hand-managed basicAuth.usersSecret. Rendered when its name and
         namespace are set (the defaults).
  write: the Mimir, Loki and Tempo write routes, each backend checked against
         its own AgentCredential Secret from basicAuth.agentCredential.usersSecrets.
         Rendered when basicAuth.agentCredential.enabled is set (off by default).

A read user is never accepted on a write route and an AgentCredential never on
a read route: each route carries exactly one SecurityPolicy, which reads exactly
one Secret.

This follows the same convention as the JWT routes, which render nothing when
auth.jwt.providers is empty: an incomplete configuration produces no resources
rather than failing the release. In particular it avoids shipping a
SecurityPolicy pointing at a Secret that does not exist, which would leave the
routes rejecting every request.
*/}}

{{/*
"true" when the hand-managed read routes render.
*/}}
{{- define "basicauth.configured" -}}
{{- $ba := .Values.basicAuth -}}
{{- if and $ba.enabled $ba.hostname $ba.usersSecret.name $ba.usersSecret.namespace -}}
true
{{- end -}}
{{- end -}}

{{/*
The backends with AgentCredential write routes, as a JSON list of
  {name, namespace, secretName, secretNamespace}
where name is the service (mimir, loki, tempo), namespace is its namespace, and
secretName/secretNamespace is the users Secret its write SecurityPolicy reads.
An empty Secret namespace means the backend's namespace. Only enabled services
whose Secret name is set are listed.
*/}}
{{- define "basicauth.write.backends" -}}
{{- $ba := .Values.basicAuth -}}
{{- $backends := list -}}
{{- if and $ba.enabled $ba.hostname $ba.agentCredential.enabled -}}
{{- $kinds := dict "mimir" "metrics" "loki" "logs" "tempo" "traces" -}}
{{- range $name := list "mimir" "loki" "tempo" -}}
{{- $service := index $.Values $name -}}
{{- $secret := index $ba.agentCredential.usersSecrets (index $kinds $name) | default dict -}}
{{- if and $service.enabled $secret.name -}}
{{- $backends = append $backends (dict "name" $name "namespace" $service.namespace "secretName" $secret.name "secretNamespace" ($secret.namespace | default $service.namespace)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toJson $backends -}}
{{- end -}}

{{/*
The AgentCredential write routes of one backend, as a JSON list of
{kind, name, template}. Each reuses the body of the matching JWT write route
(template, from <service>/_routes.tpl), so the paths, rewrites and backends
stay identical.
*/}}
{{- define "basicauth.write.routes" -}}
{{- $prefix := printf "%s-%s" (include "resource.default.name" .root) .backend -}}
{{- $routes := list -}}
{{- if eq .backend "tempo" -}}
{{- $routes = append $routes (dict "kind" "HTTPRoute" "name" (printf "%s-otlp-write-api-basicauth" $prefix) "template" "tempo.route.write") -}}
{{- $routes = append $routes (dict "kind" "GRPCRoute" "name" (printf "%s-write-api-grpc-basicauth" $prefix) "template" "tempo.route.grpc.write") -}}
{{- else -}}
{{- $routes = append $routes (dict "kind" "HTTPRoute" "name" (printf "%s-write-api-basicauth" $prefix) "template" (printf "%s.route.write" .backend)) -}}
{{- end -}}
{{- toJson $routes -}}
{{- end -}}
