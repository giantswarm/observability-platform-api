{{/*
SecurityPolicy `authorization` block shared by the Loki, Mimir and Tempo JWT policies.

One Allow rule per tenant and provider: the request's X-Scope-OrgID must equal the
tenant name exactly AND the token, validated by that provider, must carry one of the
listed values in its claim. Everything else is denied, including a missing header,
a header naming several tenants, and a valid token without a matching claim.
*/}}
{{- define "auth.authorization" -}}
authorization:
  defaultAction: Deny
  {{- if .Values.auth.tenants }}
  rules:
  {{- range $tenant := .Values.auth.tenants }}
  {{- range $access := $tenant.access }}
  - name: {{ printf "%s-%s" $tenant.name $access.provider | quote }}
    action: Allow
    principal:
      headers:
      - name: X-Scope-OrgID
        values:
        - {{ $tenant.name | quote }}
      jwt:
        provider: {{ $access.provider | quote }}
        claims:
        - name: {{ $access.claim | default "groups" | quote }}
          valueType: StringArray
          values:
          {{- range $access.values }}
          - {{ . | quote }}
          {{- end }}
  {{- end }}
  {{- end }}
  {{- end }}
{{- end -}}
