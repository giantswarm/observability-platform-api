{{/* vim: set filetype=mustache: */}}

{{/*
Basic Auth read routes are rendered only when the feature is enabled *and*
fully configured. This follows the same convention as the JWT routes, which
render nothing when auth.jwt.providers is empty: an incomplete configuration
produces no resources rather than failing the release. In particular it avoids
shipping a SecurityPolicy pointing at a Secret that does not exist, which would
leave the routes rejecting every request.
*/}}
{{- define "basicauth.configured" -}}
{{- $ba := .Values.basicAuth -}}
{{- if and $ba.enabled $ba.hostname $ba.usersSecret.name $ba.usersSecret.namespace -}}
true
{{- end -}}
{{- end -}}
