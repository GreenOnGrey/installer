{{- define "nabu.labels" -}}
app.kubernetes.io/name: nabu
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: nabu
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- define "nabu.selector" -}}
app.kubernetes.io/name: nabu
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "nabu.image" -}}
{{- $tag := required "image.tag обязателен (задаёт выкатка)" .Values.image.tag -}}
{{ printf "%s:%s" .Values.image.repository $tag }}
{{- end }}

{{- define "nabu.domain" -}}
{{ required "publicBaseDomain обязателен" .Values.publicBaseDomain }}
{{- end }}

{{- define "nabu.web" -}}
{{ printf "%s.%s" .Values.hosts.web (include "nabu.domain" .) }}
{{- end }}

{{- define "nabu.api" -}}
{{ printf "%s.%s" .Values.hosts.api (include "nabu.domain" .) }}
{{- end }}

{{/* Окружение api, worker, relay, migrate и cleaner: конфигурация из GitHub, адреса, хранилища. */}}
{{- define "nabu.env" -}}
envFrom:
  - configMapRef: { name: {{ .Values.existingSecrets.configMap }} }
  - secretRef: { name: {{ .Values.existingSecrets.config }} }
  # FTR.NAB.CHAT-0003 tech §9.4: адреса конвертеров предпросмотра; секрет создаёт
  # стенд при MCP_DOCGEN, без него предпросмотр офисных файлов выключен.
  # В doc-convert сетевая политика пускает только api.
  - secretRef: { name: nabu-docs-preview, optional: true }
env:
  - { name: PUBLIC_WEB_URL, value: "https://{{ include "nabu.web" . }}" }
  - { name: PUBLIC_API_URL, value: "https://{{ include "nabu.api" . }}" }
  - { name: CORS_ALLOWED_ORIGINS, value: "https://{{ include "nabu.web" . }}" }
  - { name: COOKIE_DOMAIN, value: {{ include "nabu.domain" . | quote }} }
  - { name: HTTP_ADDR, value: ":8080" }
  - { name: INTERNAL_ADDR, value: ":8081" }
  - { name: RELAY_ADDR, value: ":8085" }
  - { name: SERVICE_ADDR, value: ":9100" }
  - { name: INTERNAL_URL, value: "http://api-internal.{{ .Release.Namespace }}.svc:8081" }
  - { name: RELAY_INTERNAL_URL, value: "http://relay.{{ .Release.Namespace }}.svc:8085" }
  - { name: RELAY_SANDBOX_WS_URL, value: "ws://relay.{{ .Release.Namespace }}.svc:8085/v1/workspaces/connect" }
  - { name: RELAY_PUBLIC_WS_URL, value: "wss://{{ include "nabu.api" . }}/v1/workspaces/connect" }
  - { name: AGENT_ADDR, value: "http://agent.{{ .Release.Namespace }}.svc:8090" }
  - { name: AGENT_IDLE_TIMEOUT, value: {{ .Values.agent.idleTimeout | quote }} }
  {{- if .Values.memory.pool.enabled }}
  - { name: MEMORY_AGENT_ADDR, value: "http://agent-memory.{{ .Release.Namespace }}.svc:8090" }
  {{- end }}
  - { name: MEMORY_COLLECT_CONCURRENCY, value: {{ .Values.memory.collectConcurrency | quote }} }
  - { name: MEMORY_BATCH_THREADS, value: {{ .Values.memory.batchThreads | quote }} }
  - { name: MEMORY_RUN_TIMEOUT, value: {{ .Values.memory.runTimeout | quote }} }
  - { name: MEMORY_BACKFILL_DAYS, value: {{ .Values.memory.backfillDays | quote }} }
  - { name: MEMORY_BACKFILL_POOL_SHARE, value: {{ .Values.memory.backfillPoolShare | quote }} }
  - { name: MEMORY_GMAIL_OVERLAP, value: {{ .Values.memory.gmailOverlap | quote }} }
  - { name: AGENT_EXECUTOR, value: {{ ternary "k8s" "local" .Values.agents.enabled | quote }} }
  - { name: AGENT_NAMESPACE, value: {{ .Values.agents.namespace | quote }} }
  - { name: AGENT_IMAGE, value: {{ include "nabu.image" . | quote }} }
  - { name: AGENT_POD_CPU_REQUEST, value: {{ .Values.agents.resources.requests.cpu | quote }} }
  - { name: AGENT_POD_CPU, value: {{ .Values.agents.resources.limits.cpu | quote }} }
  - { name: AGENT_POD_MEMORY_REQUEST, value: {{ .Values.agents.resources.requests.memory | quote }} }
  - { name: AGENT_POD_MEMORY, value: {{ .Values.agents.resources.limits.memory | quote }} }
  - { name: AGENT_POD_WORK, value: {{ .Values.agents.workSizeLimit | quote }} }
  - { name: AGENT_POD_MAX_SESSIONS, value: {{ .Values.agents.maxSessions | quote }} }
  - { name: AGENT_POD_IDLE_TIMEOUT, value: {{ .Values.agents.idleTimeout | quote }} }
  - { name: AGENT_POD_MIN_IDLE, value: {{ .Values.agents.minIdle | quote }} }
  - { name: AGENT_PODS_MAX, value: {{ .Values.agents.podsMax | quote }} }
  - { name: AGENT_START_PARALLEL, value: {{ .Values.agents.startParallel | quote }} }
  - { name: AGENT_START_TIMEOUT, value: {{ .Values.agents.startTimeout | quote }} }
  - { name: AGENT_SCHEDULE_TIMEOUT, value: {{ .Values.agents.scheduleTimeout | quote }} }
  - { name: AGENT_QUEUE_TIMEOUT, value: {{ .Values.agents.queueTimeout | quote }} }
  - { name: AGENT_WARM_WINDOW, value: {{ .Values.agents.warm.window | quote }} }
  - { name: AGENT_WARM_SHARE, value: {{ .Values.agents.warm.share | quote }} }
  - { name: AGENT_WARM_MAX, value: {{ .Values.agents.warm.max | quote }} }
  - { name: SANDBOX_EXECUTOR, value: {{ ternary "k8s" "none" .Values.sandboxes.enabled | quote }} }
  - { name: SANDBOX_NAMESPACE, value: {{ .Values.sandboxes.namespace | quote }} }
  - { name: SANDBOX_IMAGE, value: {{ include "nabu.image" . | quote }} }
  - { name: SANDBOX_IDLE_TIMEOUT, value: {{ .Values.sandboxes.idleTimeout | quote }} }
  - { name: SANDBOX_CPU, value: {{ .Values.sandboxes.cpu | quote }} }
  - { name: SANDBOX_MEMORY, value: {{ .Values.sandboxes.memory | quote }} }
  - { name: SPACE_QUOTA, value: {{ .Values.sandboxes.spaceQuota | quote }} }
  {{- with .Values.sandboxes.profiles }}
  {{- $tag := required "image.tag обязателен (задаёт выкатка)" $.Values.image.tag }}
  {{- $pairs := list }}
  {{- range $name, $repo := . }}{{ $pairs = append $pairs (printf "%s=%s:%s" $name $repo $tag) }}{{ end }}
  - { name: SANDBOX_PROFILES, value: {{ join "," $pairs | quote }} }
  {{- end }}
  {{- with .Values.sandboxes.defaults }}
  {{- $pairs := list }}
  {{- range $t, $p := . }}{{ $pairs = append $pairs (printf "%s=%s" $t $p) }}{{ end }}
  - { name: SANDBOX_DEFAULTS, value: {{ join "," $pairs | quote }} }
  {{- end }}
  - { name: SANDBOX_INIT_IMAGE, value: {{ include "nabu.image" . | quote }} }
  - { name: SANDBOX_CUSTOM_IMAGES, value: {{ .Values.sandboxes.customImages.enabled | quote }} }
  - { name: SANDBOX_IMAGE_PREFIXES, value: {{ join "," .Values.sandboxes.customImages.allowedPrefixes | quote }} }
  {{- $secrets := list }}
  {{- range .Values.imagePullSecrets }}{{ $secrets = append $secrets .name }}{{ end }}
  {{- range .Values.sandboxes.customImages.pullSecrets }}{{ $secrets = append $secrets . }}{{ end }}
  - { name: SANDBOX_PULL_SECRETS, value: {{ join "," $secrets | quote }} }
  - { name: SANDBOX_PROBE_TIMEOUT, value: {{ .Values.sandboxes.probeTimeout | quote }} }
  - { name: PI_VERSION, value: {{ .Values.piVersion | default "" | quote }} }
  {{- if .Values.whisper.enabled }}
  - { name: WHISPER_URL, value: "http://whisper.{{ .Release.Namespace }}.svc:9000" }
  {{- end }}
  - { name: POD_IP, valueFrom: { fieldRef: { fieldPath: status.podIP } } }
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

{{- define "nabu.podSecurity" -}}
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile: { type: RuntimeDefault }
{{- end }}

{{- define "nabu.containerSecurity" -}}
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: [ALL] }
{{- end }}

{{/* Записываемые каталоги при read-only корне: /tmp и HOME. */}}
{{- define "nabu.volumeMounts" -}}
volumeMounts:
  - { name: tmp, mountPath: /tmp }
  - { name: home, mountPath: /home/node }
{{- end }}

{{- define "nabu.volumes" -}}
volumes:
  - { name: tmp, emptyDir: {} }
  - { name: home, emptyDir: {} }
{{- end }}

{{/* Deployment одного режима: api, worker, relay. */}}
{{- define "nabu.deployment" -}}
{{- $root := .root -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}
  labels:
    {{- include "nabu.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ .name }}
spec:
  replicas: {{ index $root.Values.replicas .name }}
  selector:
    matchLabels: {{- include "nabu.selector" (dict "root" $root "component" .name) | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "nabu.labels" $root | nindent 8 }}
        app.kubernetes.io/component: {{ .name }}
      annotations:
        {{- toYaml $root.Values.podAnnotations | nindent 8 }}
    spec:
      {{- with $root.Values.imagePullSecrets }}
      imagePullSecrets: {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if .serviceAccount }}
      serviceAccountName: {{ .serviceAccount }}
      automountServiceAccountToken: true
      {{- else }}
      automountServiceAccountToken: false
      {{- end }}
      terminationGracePeriodSeconds: {{ .grace | default 30 }}
      {{- include "nabu.podSecurity" $root | nindent 6 }}
      containers:
        - name: {{ .name }}
          image: {{ include "nabu.image" $root }}
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          args: [{{ .name | quote }}]
          ports:
            {{- range .ports }}
            - { name: {{ .name }}, containerPort: {{ .port }} }
            {{- end }}
            - { name: service, containerPort: 9100 }
          {{- include "nabu.env" $root | nindent 10 }}
          readinessProbe: { httpGet: { path: /readyz, port: service }, periodSeconds: 5 }
          livenessProbe: { httpGet: { path: /healthz, port: service }, initialDelaySeconds: 20, periodSeconds: 10 }
          resources: {{- toYaml (index $root.Values.resources .name) | nindent 12 }}
          {{- include "nabu.containerSecurity" $root | nindent 10 }}
          {{- include "nabu.volumeMounts" $root | nindent 10 }}
      {{- include "nabu.volumes" $root | nindent 6 }}
{{- end }}
