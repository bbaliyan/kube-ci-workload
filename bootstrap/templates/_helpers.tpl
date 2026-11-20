{{- /* The scheme, host name and port of an address. The port comes from the address, or from the scheme. */ -}}
{{- define "prAgent.endpoint" -}}
{{- $url := urlParse . -}}
{{- $port := (regexFind ":[0-9]+$" $url.host) | trimPrefix ":" -}}
{{- if not $port }}{{ $port = ternary "443" "80" (eq $url.scheme "https") }}{{ end -}}
{{- toJson (dict "protocol" $url.scheme "host" $url.hostname "port" ($port | atoi)) -}}
{{- end -}}

{{- /* The actor list that the actor chart and the registration chart share, as JSON. */ -}}
{{- define "prAgent.actors" -}}
{{- $p := .Values.prAgent -}}
{{- if not $p.ollamaUrl }}{{ fail "prAgent.enabled needs prAgent.ollamaUrl, for example http://host:11434" }}{{ end -}}
{{- if not .Values.substrate.enabled }}{{ fail "prAgent.enabled needs substrate.enabled" }}{{ end -}}
{{- $ollama := include "prAgent.endpoint" $p.ollamaUrl | fromJson -}}
{{- $gitlab := include "prAgent.endpoint" $p.gitlabUrl | fromJson -}}
{{- $actor := dict
  "name" "pr-agent"
  "atespace" $p.atespace
  "image" $p.image
  "env" (dict
    "PORT" "3000"
    "CONFIG__GIT_PROVIDER" "gitlab"
    "CONFIG__MODEL" $p.model
    "CONFIG__FALLBACK_MODELS" "[]"
    "CONFIG__CUSTOM_MODEL_MAX_TOKENS" ($p.contextLength | toString)
    "CONFIG__DUPLICATE_PROMPT_EXAMPLES" "true"
    "OLLAMA__API_BASE" $p.ollamaUrl
    "GITLAB__URL" $p.gitlabUrl
    "GITLAB__AUTH_TYPE" "oauth_token"
    "GITLAB__PERSONAL_ACCESS_TOKEN" "replaced-by-the-egress-proxy"
    "GITLAB__SHARED_SECRET" $p.sharedSecret)
  "resources" (dict "cpuMillicores" $p.cpuMillicores "memoryBytes" $p.memoryBytes)
  "wakeupProbe" (dict "path" "/" "port" 3000)
  "egress" (list
    (dict
      "protocol" $gitlab.protocol
      "hostnames" (list $gitlab.host)
      "ports" (list $gitlab.port)
      "credential" (dict
        "header" "Authorization"
        "prefix" "Bearer "
        "credentialUri" (printf "ate-secret://k8s.io/default/%s/gitlab-pr-agent/token" $p.namespace)))
    (dict
      "protocol" $ollama.protocol
      "hostnames" (list $ollama.host)
      "ports" (list $ollama.port))) -}}
{{- if $p.webhook }}
{{- $_ := set $actor "webhook" (mergeOverwrite (dict "secret" (dict "name" "gitlab-pr-agent")) $p.webhook) -}}
{{- end -}}
{{- toJson (list $actor) -}}
{{- end -}}
