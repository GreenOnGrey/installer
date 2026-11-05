{{- define "core.labels" -}}
app.kubernetes.io/name: hammurapi
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: hammurapi
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- define "core.selector" -}}
app.kubernetes.io/name: hammurapi
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "core.image" -}}
{{- $tag := required "image.tag is required (set by the rollout)" .Values.image.tag -}}
{{ printf "%s:%s" .Values.image.repository $tag }}
{{- end }}

{{- define "core.domain" -}}
{{ required "publicBaseDomain is required" .Values.publicBaseDomain }}
{{- end }}

{{- define "core.webHost" -}}
{{ printf "%s.%s" .Values.hosts.web (include "core.domain" .) }}
{{- end }}

{{- define "core.apiHost" -}}
{{ printf "%s.%s" .Values.hosts.api (include "core.domain" .) }}
{{- end }}

{{/* Environment of all modes: configuration from GitHub, public addresses, storages. */}}
{{- define "core.env" -}}
{{- $d := include "core.domain" . -}}
envFrom:
  - configMapRef: { name: {{ .Values.existingSecrets.configMap }} }
  - secretRef: { name: {{ .Values.existingSecrets.config }} }
env:
  - { name: PUBLIC_URL, value: "https://{{ include "core.webHost" . }}" }
  - { name: PUBLIC_WEB_URL, value: "https://{{ include "core.webHost" . }}" }
  - { name: PUBLIC_API_URL, value: "https://{{ include "core.apiHost" . }}" }
  - { name: CORS_ALLOWED_ORIGINS, value: "https://{{ include "core.webHost" . }}" }
  - { name: COOKIE_DOMAIN, value: {{ $d | quote }} }
  - { name: HTTP_ADDR, value: ":8080" }
  - { name: SERVICE_ADDR, value: ":9100" }
  # Code tasks run in a Nabu sandbox (FTR.HMR.CMN-0007): there is no agent or runner here.
  - { name: CODE_MAX_PARALLEL, value: {{ .Values.code.maxParallel | quote }} }
  - { name: WORKER_MCP_ADDR, value: ":8083" }
  - { name: WORKER_MCP_URL, value: "http://worker-mcp.{{ .Release.Namespace }}.svc:8083" }
  {{- with .Values.nabu.webUrl }}
  - { name: NABU_WEB_URL, value: {{ . | quote }} }
  {{- end }}
  - { name: DATABASE_URL, valueFrom: { secretKeyRef: { name: {{ .Values.existingSecrets.postgres }}, key: uri } } }
  - { name: KAFKA_BROKERS, valueFrom: { secretKeyRef: { name: {{ .Values.existingSecrets.kafka }}, key: bootstrap_servers } } }
  - { name: S3_ENDPOINT, valueFrom: { secretKeyRef: { name: {{ .Values.existingSecrets.s3 }}, key: endpoint_host } } }
  - { name: S3_USE_SSL, valueFrom: { secretKeyRef: { name: {{ .Values.existingSecrets.s3 }}, key: use_ssl } } }
  - { name: S3_BUCKET, valueFrom: { secretKeyRef: { name: {{ .Values.existingSecrets.s3 }}, key: bucket } } }
  - { name: S3_ACCESS_KEY, valueFrom: { secretKeyRef: { name: {{ .Values.existingSecrets.s3 }}, key: access_key } } }
  - { name: S3_SECRET_KEY, valueFrom: { secretKeyRef: { name: {{ .Values.existingSecrets.s3 }}, key: secret_key } } }
  {{- range $k, $v := .Values.config }}
  - { name: {{ $k }}, value: {{ $v | quote }} }
  {{- end }}
{{- end }}

{{- define "core.podSecurity" -}}
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile: { type: RuntimeDefault }
{{- end }}

{{- define "core.containerSecurity" -}}
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: [ALL] }
{{- end }}

{{/* Writable directories under a read-only root: /tmp and HOME. */}}
{{- define "core.volumeMounts" -}}
volumeMounts:
  - { name: tmp, mountPath: /tmp }
  - { name: home, mountPath: /home/node }
{{- end }}

{{- define "core.volumes" -}}
volumes:
  - { name: tmp, emptyDir: {} }
  - { name: home, emptyDir: {} }
{{- end }}
