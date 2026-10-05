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
  - { name: SANDBOX_EXECUTOR, value: {{ ternary "k8s" "none" .Values.sandboxes.enabled | quote }} }
  - { name: SANDBOX_NAMESPACE, value: {{ .Values.sandboxes.namespace | quote }} }
  - { name: SANDBOX_IMAGE, value: {{ include "nabu.image" . | quote }} }
  - { name: SANDBOX_IDLE_TIMEOUT, value: {{ .Values.sandboxes.idleTimeout | quote }} }
  - { name: SANDBOX_CPU, value: {{ .Values.sandboxes.cpu | quote }} }
  - { name: SANDBOX_MEMORY, value: {{ .Values.sandboxes.memory | quote }} }
  - { name: SPACE_QUOTA, value: {{ .Values.sandboxes.spaceQuota | quote }} }
  - { name: PI_VERSION, value: {{ .Values.piVersion | default "" | quote }} }
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
