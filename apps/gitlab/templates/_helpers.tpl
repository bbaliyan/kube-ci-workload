{{/* The tailnet host name is the first label of the host in externalUrl: one name, set once. */}}
{{- define "gitlab.tailnetHostname" -}}
{{- $label := (urlParse .Values.externalUrl).host | splitList ":" | first | splitList "." | first -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" $label) -}}
{{- fail (printf "externalUrl %q must start with http:// or https:// and a host name whose first label is a valid tailnet name" .Values.externalUrl) -}}
{{- end -}}
{{- $label -}}
{{- end -}}
