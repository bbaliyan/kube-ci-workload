{{- /* The scheme, host name and port of an address. The port comes from the address, or from the scheme. */ -}}
{{- define "prAgent.endpoint" -}}
{{- $url := urlParse . -}}
{{- $port := (regexFind ":[0-9]+$" $url.host) | trimPrefix ":" -}}
{{- if not $port }}{{ $port = ternary "443" "80" (eq $url.scheme "https") }}{{ end -}}
{{- toJson (dict "protocol" $url.scheme "host" $url.hostname "port" ($port | atoi)) -}}
{{- end -}}

{{- /* The model endpoint, checked: http or https, and a DNS name, because the egress policy matches host names. */ -}}
{{- define "prAgent.modelEndpoint" -}}
{{- $address := . -}}
{{- if not $address }}{{ fail "prAgent.enabled needs prAgent.modelEndpoint, the base URL of the model server, for example http://model.example.test:11434" }}{{ end -}}
{{- $endpoint := include "prAgent.endpoint" $address | fromJson -}}
{{- if not (has $endpoint.protocol (list "http" "https")) }}{{ fail (printf "prAgent.modelEndpoint must start with http:// or https://, got %q" $address) }}{{ end -}}
{{- if or (regexMatch `^[0-9]{1,3}(\.[0-9]{1,3}){3}$` $endpoint.host) (contains ":" $endpoint.host) }}{{ fail (printf "prAgent.modelEndpoint must use a DNS name, not an IP address, because the egress policy matches host names. Got %q" $address) }}{{ end -}}
{{- toJson $endpoint -}}
{{- end -}}

{{- /* The pr-agent setting that holds the base URL of the model server, and the one that holds its key, by the prefix of the model name. */ -}}
{{- define "prAgent.providerSettings" -}}
{{- $providers := dict "ollama" (dict "base" "OLLAMA__API_BASE" "key" "OLLAMA__API_KEY") "openai" (dict "base" "OPENAI__API_BASE" "key" "OPENAI__KEY") -}}
{{- $prefix := index (splitList "/" .) 0 -}}
{{- if not (hasKey $providers $prefix) }}{{ fail (printf "prAgent.model must start with one of: %s. Got %q" (keys $providers | sortAlpha | join "/, " | printf "%s/") .) }}{{ end -}}
{{- toJson (get $providers $prefix) -}}
{{- end -}}

{{- /* The actor list that the actor chart and the registration chart share, as JSON. */ -}}
{{- define "prAgent.actors" -}}
{{- $p := .Values.prAgent -}}
{{- if not .Values.substrate.enabled }}{{ fail "prAgent.enabled needs substrate.enabled" }}{{ end -}}
{{- $model := include "prAgent.modelEndpoint" $p.modelEndpoint | fromJson -}}
{{- $provider := include "prAgent.providerSettings" $p.model | fromJson -}}
{{- $gitlab := include "prAgent.endpoint" $p.gitlabUrl | fromJson -}}
{{- $modelRule := dict
  "protocol" $model.protocol
  "hostnames" (list $model.host)
  "ports" (list $model.port) -}}
{{- $env := dict
  "PORT" "3000"
  "CONFIG__GIT_PROVIDER" "gitlab"
  "CONFIG__MODEL" $p.model
  "CONFIG__FALLBACK_MODELS" "[]"
  "CONFIG__CUSTOM_MODEL_MAX_TOKENS" ($p.contextLength | toString)
  "CONFIG__DUPLICATE_PROMPT_EXAMPLES" "true"
  "GITLAB__URL" $p.gitlabUrl
  "GITLAB__AUTH_TYPE" "oauth_token"
  "GITLAB__PERSONAL_ACCESS_TOKEN" "replaced-by-the-egress-proxy"
  "GITLAB__SHARED_SECRET" $p.hopToken -}}
{{- $_ := set $env $provider.base $p.modelEndpoint -}}
{{- /* The egress gateway ends TLS and starts it again, so the actor must trust the gateway CA for every https rule. */ -}}
{{- $https := or (eq $gitlab.protocol "https") (eq $model.protocol "https") -}}
{{- if and $https (not $p.egressTrustBundle) }}{{ fail "prAgent uses an https address (prAgent.gitlabUrl or prAgent.modelEndpoint), so the actor must trust the egress gateway CA. The pinned substrate-actor chart cannot mount that trust bundle yet. Use an http address, or pin a substrate.revision whose chart accepts egressTrustBundle and set prAgent.egressTrustBundle to true." }}{{ end -}}
{{- if $https }}
{{- $bundle := "/run/ate/egress-trust-bundle/trust-bundle.pem" -}}
{{- $_ := set $env "SSL_CERT_FILE" $bundle -}}
{{- $_ := set $env "REQUESTS_CA_BUNDLE" $bundle -}}
{{- $_ := set $env "GITLAB__SSL_VERIFY" $bundle -}}
{{- end -}}
{{- if $p.modelApiKeySecret }}
{{- $_ := set $modelRule "credential" (dict
  "header" "Authorization"
  "prefix" "Bearer "
  "credentialUri" (printf "ate-secret://k8s.io/default/%s/%s/%s" $p.namespace $p.modelApiKeySecret.name $p.modelApiKeySecret.key)) -}}
{{- $_ := set $env $provider.key "replaced-by-the-egress-proxy" -}}
{{- end -}}
{{- $actor := dict
  "name" "pr-agent"
  "atespace" $p.atespace
  "image" $p.image
  "env" $env
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
    $modelRule) -}}
{{- if $https }}{{ $_ := set $actor "egressTrustBundle" true }}{{ end -}}
{{- /* The webhook shim checks the real secret and sends the hop token, which is the secret that the actor expects. */ -}}
{{- if $p.webhook }}
{{- $_ := set $actor "webhook" (mergeOverwrite (dict "secret" (dict "name" "gitlab-pr-agent" "key" "WEBHOOK_SECRET") "hopToken" $p.hopToken) $p.webhook) -}}
{{- end -}}
{{- toJson (list $actor) -}}
{{- end -}}
