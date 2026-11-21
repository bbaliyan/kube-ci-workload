{{- define "pr-agent-webhook.name" -}}
{{- printf "%s-webhook" .Values.actor.name -}}
{{- end -}}

{{- define "pr-agent-webhook.selector" -}}
app.kubernetes.io/name: {{ include "pr-agent-webhook.name" . }}
{{- end -}}

{{- define "pr-agent-webhook.labels" -}}
{{ include "pr-agent-webhook.selector" . }}
app.kubernetes.io/part-of: pr-agent
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- /* The Envoy config. The Lua filter reads the real secret from a file on every request, so a rotated Secret takes effect at once. LuaJIT has no ~ or | operators, so the compare uses the bit library. The compare checks every byte and does not stop at the first difference. The filter removes trailing white space from the file, so a Secret that ends in a new line still matches. A retry can deliver one webhook twice, and a cold start makes that likely. The actor tolerates that: a second review is a smaller loss than a lost review. */ -}}
{{- define "pr-agent-webhook.envoy" -}}
{{- $v := .Values -}}
{{- $retries := $v.retries | int -}}
{{- $perTry := $v.perTryTimeoutSeconds | int -}}
{{- $total := $v.timeoutSeconds | int -}}
{{- /* Envoy waits at most 5 seconds before a retry, so the tries and the waits must fit in the total: 3 x 60 + 2 x 5 = 190. */ -}}
{{- if lt $total (add (mul (add1 $retries) $perTry) (mul $retries 5)) -}}
{{- fail (printf "timeoutSeconds (%d) is too short for %d tries of %d seconds plus up to 5 seconds of back-off between them" $total (add1 $retries) $perTry) -}}
{{- end -}}
node: {id: webhook-shim, cluster: webhook-shim}
static_resources:
  listeners:
    - name: webhook
      address:
        socket_address: {address: 0.0.0.0, port_value: {{ $v.port }}}
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: webhook
                route_config:
                  virtual_hosts:
                    - name: webhook
                      domains: ["*"]
                      routes:
                        - match: {path: /healthz}
                          direct_response: {status: 200, body: {inline_string: ok}}
{{- if $v.pipeline.enabled }}
                        {{- include "pr-agent-webhook.pipelineRoute" . | nindent 24 }}
{{- end }}
                        - match: {prefix: /}
                          route:
                            {{- include "pr-agent-webhook.routeAction" . | nindent 28 }}
                http_filters:
{{- if $v.pipeline.enabled }}
                  {{- include "pr-agent-webhook.pipelineFilters" . | nindent 18 }}
{{- end }}
                  - name: envoy.filters.http.lua
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
                      default_source_code:
                        inline_string: |
                          local function equal(a, b)
                            local diff = bit.bxor(#a, #b)
                            for i = 1, math.max(#a, #b) do
                              diff = bit.bor(diff, bit.bxor(a:byte(i) or 0, b:byte(i) or 0))
                            end
                            return diff == 0
                          end
                          function envoy_on_request(h)
                            if h:headers():get(":path") == "/healthz" then return end
                            local f = io.open("/secrets/WEBHOOK_SECRET", "rb")
                            local want = f and f:read("*a")
                            if f then f:close() end
                            if want then want = (want:gsub("%s+$", "")) end
                            local got = h:headers():get("x-gitlab-token")
                            if not want or want == "" or not got or not equal(got, want) then
                              h:respond({[":status"] = "401"}, "unauthorized\n")
                              return
                            end
                            h:headers():replace("x-gitlab-token", {{ $v.hopToken | quote }})
                            h:headers():replace("ate-target-actor", {{ printf "%s/%s" $v.actor.atespace $v.actor.name | quote }})
                          end
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
{{- if $v.pipeline.enabled }}
    {{- include "pr-agent-webhook.jwksCluster" . | nindent 4 }}
{{- end }}
    - name: router
      type: STRICT_DNS
      connect_timeout: 5s
      load_assignment:
        cluster_name: router
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: {address: {{ $v.router.host | quote }}, port_value: {{ $v.router.port }}}
      transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
          sni: {{ $v.router.host | quote }}
          common_tls_context:
            tls_certificate_sds_secret_configs:
              - name: router-client
                sds_config:
                  path_config_source: {path: /etc/envoy/sds-client.yaml}
            validation_context_sds_secret_config:
              name: router-ca
              sds_config:
                path_config_source: {path: /etc/envoy/sds-ca.yaml}
{{- end -}}

{{- /* The client certificate and key of the pod identity. watched_directory makes Envoy load the files again when the kubelet rotates them. */ -}}
{{- define "pr-agent-webhook.sdsClient" -}}
resources:
  - "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret
    name: router-client
    tls_certificate:
      certificate_chain: {filename: /run/router-client/credential-bundle.pem}
      private_key: {filename: /run/router-client/credential-bundle.pem}
      watched_directory: {path: /run/router-client}
{{- end -}}

{{- /* The CA that signs the serving certificate of the router. The shim checks the router host name against the certificate. */ -}}
{{- define "pr-agent-webhook.sdsCa" -}}
resources:
  - "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret
    name: router-ca
    validation_context:
      trusted_ca: {filename: /run/router-client/router-ca.pem}
      watched_directory: {path: /run/router-client}
      match_typed_subject_alt_names:
        - san_type: DNS
          matcher: {exact: {{ .Values.router.host | quote }}}
{{- end -}}

{{- /* Where the shim sends an accepted request: the router, with the retry policy. */ -}}
{{- define "pr-agent-webhook.routeAction" -}}
{{- $retries := .Values.retries | int -}}
cluster: router
timeout: {{ .Values.timeoutSeconds | int }}s
{{- if $retries }}
retry_policy:
  retry_on: "connect-failure,refused-stream,reset-before-request,gateway-error"
  num_retries: {{ $retries }}
  per_try_timeout: {{ .Values.perTryTimeoutSeconds | int }}s
  retry_back_off: {base_interval: 0.5s, max_interval: 5s}
{{- end }}
{{- end -}}

{{- /* The host, the port and the scheme of pipeline.jwksUri, for the cluster of the key fetch. */ -}}
{{- define "pr-agent-webhook.jwks" -}}
{{- $uri := required "pipeline.enabled needs pipeline.jwksUri, the key endpoint of GitLab, for example https://gitlab.example.com/oauth/discovery/keys" .Values.pipeline.jwksUri -}}
{{- $u := urlParse $uri -}}
{{- $hostPort := splitList ":" $u.host -}}
{{- $tls := eq $u.scheme "https" -}}
{{- $port := ternary (last $hostPort) (ternary "443" "80" $tls) (eq (len $hostPort) 2) -}}
{{- toJson (dict "host" (first $hostPort) "port" ($port | int) "tls" $tls) -}}
{{- end -}}

{{- /* The pipeline route. jwt_authn checks the ID token, RBAC checks its claims, and the Lua filter of the webhook route is off. The route sets the hop token and the target actor, and the actor gets the path /webhook. */ -}}
{{- define "pr-agent-webhook.pipelineRoute" -}}
{{- $v := .Values -}}
{{- if not $v.pipeline.namespacePaths -}}
{{- fail "pipeline.enabled needs pipeline.namespacePaths, the GitLab groups whose pipelines may ask for a review" -}}
{{- end -}}
- match: {path: {{ $v.pipeline.path | quote }}}
  route:
    {{- include "pr-agent-webhook.routeAction" . | nindent 4 }}
    prefix_rewrite: /webhook
  request_headers_to_add:
    - header: {key: x-gitlab-token, value: {{ $v.hopToken | quote }}}
      append_action: OVERWRITE_IF_EXISTS_OR_ADD
    - header: {key: ate-target-actor, value: {{ printf "%s/%s" $v.actor.atespace $v.actor.name | quote }}}
      append_action: OVERWRITE_IF_EXISTS_OR_ADD
  typed_per_filter_config:
    envoy.filters.http.jwt_authn:
      "@type": type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.PerRouteConfig
      requirement_name: gitlab
    envoy.filters.http.rbac:
      "@type": type.googleapis.com/envoy.extensions.filters.http.rbac.v3.RBACPerRoute
      rbac:
        rules:
          action: ALLOW
          policies:
            gitlab-claims:
              permissions: [{any: true}]
              principals:
                - and_ids:
                    ids:
                      - or_ids:
                          ids:
                            {{- range $v.pipeline.namespacePaths }}
                            - {{ include "pr-agent-webhook.claim" (list "namespace_path" .) | indent 30 | trim }}
                            {{- end }}
                      - {{ include "pr-agent-webhook.claim" (list "pipeline_source" "merge_request_event") | indent 24 | trim }}
    envoy.filters.http.lua:
      "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.LuaPerRoute
      disabled: true
{{- end -}}

{{- /* A principal that matches one claim of the checked token. jwt_authn writes the claims to the dynamic metadata under the key gitlab. */ -}}
{{- define "pr-agent-webhook.claim" -}}
sourced_metadata:
  metadata_matcher:
    filter: envoy.filters.http.jwt_authn
    path: [{key: gitlab}, {key: {{ index . 0 }}}]
    value: {string_match: {exact: {{ index . 1 | quote }}}}
{{- end -}}

{{- /* The filters of the pipeline route. They act only on a route that names them, so the webhook route passes through them as before. With forward false, jwt_authn removes the Authorization header after the check. */ -}}
{{- define "pr-agent-webhook.pipelineFilters" -}}
{{- $p := .Values.pipeline -}}
- name: envoy.filters.http.jwt_authn
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication
    providers:
      gitlab:
        issuer: {{ required "pipeline.enabled needs pipeline.issuer, the external URL of GitLab" $p.issuer | quote }}
        audiences: {{ required "pipeline.enabled needs pipeline.audiences" $p.audiences | toJson }}
        forward: false
        payload_in_metadata: gitlab
        remote_jwks:
          http_uri:
            uri: {{ $p.jwksUri | quote }}
            cluster: gitlab-jwks
            timeout: 5s
          cache_duration: {{ $p.jwksCacheSeconds | int }}s
    requirement_map:
      gitlab: {provider_name: gitlab}
- name: envoy.filters.http.rbac
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.rbac.v3.RBAC
{{- end -}}

{{- /* The cluster of the key fetch. An https endpoint must show a certificate for its host name, signed by the CA of pipeline.jwksCa or by a CA of the image bundle. */ -}}
{{- define "pr-agent-webhook.jwksCluster" -}}
{{- $jwks := include "pr-agent-webhook.jwks" . | fromJson -}}
- name: gitlab-jwks
  type: STRICT_DNS
  connect_timeout: 5s
  load_assignment:
    cluster_name: gitlab-jwks
    endpoints:
      - lb_endpoints:
          - endpoint:
              address:
                socket_address: {address: {{ $jwks.host | quote }}, port_value: {{ $jwks.port }}}
{{- if $jwks.tls }}
  transport_socket:
    name: envoy.transport_sockets.tls
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
      sni: {{ $jwks.host | quote }}
      common_tls_context:
        validation_context:
          trusted_ca: {filename: {{ ternary "/etc/jwks-ca/ca.pem" "/etc/ssl/certs/ca-certificates.crt" (not (empty .Values.pipeline.jwksCa.name)) | quote }}}
          match_typed_subject_alt_names:
            - san_type: DNS
              matcher: {exact: {{ $jwks.host | quote }}}
{{- end }}
{{- end -}}

{{- define "pr-agent-webhook.config" -}}
{{- toJson (dict "envoy.yaml" (include "pr-agent-webhook.envoy" .) "sds-client.yaml" (include "pr-agent-webhook.sdsClient" .) "sds-ca.yaml" (include "pr-agent-webhook.sdsCa" .)) -}}
{{- end -}}
