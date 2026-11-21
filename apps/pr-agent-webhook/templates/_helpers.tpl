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
                        - match: {prefix: /}
                          route:
                            cluster: router
                            timeout: {{ $total }}s
{{- if $retries }}
                            retry_policy:
                              retry_on: "connect-failure,refused-stream,reset-before-request,gateway-error"
                              num_retries: {{ $retries }}
                              per_try_timeout: {{ $perTry }}s
                              retry_back_off: {base_interval: 0.5s, max_interval: 5s}
{{- end }}
                http_filters:
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

{{- define "pr-agent-webhook.config" -}}
{{- toJson (dict "envoy.yaml" (include "pr-agent-webhook.envoy" .) "sds-client.yaml" (include "pr-agent-webhook.sdsClient" .) "sds-ca.yaml" (include "pr-agent-webhook.sdsCa" .)) -}}
{{- end -}}
