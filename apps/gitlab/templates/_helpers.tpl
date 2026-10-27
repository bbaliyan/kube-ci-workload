{{/* The tailnet host name is the first label of the host in externalUrl: one name, set once. */}}
{{- define "gitlab.tailnetHostname" -}}
{{- (urlParse .Values.externalUrl).host | splitList "." | first -}}
{{- end -}}
