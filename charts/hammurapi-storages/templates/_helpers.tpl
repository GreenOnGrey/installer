{{- define "storages.labels" -}}
app.kubernetes.io/part-of: hammurapi-infra
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/*
storages.service — стабильный сервис хранилища (R11).
internal: ClusterIP с селектором на поды оператора или чарта;
external: ExternalName для DNS-имени или сервис без селектора с EndpointSlice для IP.
*/}}
{{- define "storages.service" -}}
{{- $root := .root }}
{{- $v := .values }}
{{- if eq $v.mode "internal" }}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  labels: {{- include "storages.labels" $root | nindent 4 }}
spec:
  type: ClusterIP
  selector: {{- toYaml .selector | nindent 4 }}
  ports:
    - { name: {{ .portName }}, port: {{ .port }}, targetPort: {{ .targetPort }}, protocol: TCP }
{{- else if $v.external.isIP }}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  labels: {{- include "storages.labels" $root | nindent 4 }}
spec:
  type: ClusterIP
  ports:
    - { name: {{ .portName }}, port: {{ .port }}, targetPort: {{ $v.external.port }}, protocol: TCP }
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: {{ .name }}-external
  labels:
    {{- include "storages.labels" $root | nindent 4 }}
    kubernetes.io/service-name: {{ .name }}
    endpointslice.kubernetes.io/managed-by: hammurapi-infra
addressType: IPv4
ports:
  - { name: {{ .portName }}, port: {{ $v.external.port }}, protocol: TCP }
endpoints:
  - addresses: [{{ required (printf "%s.external.host обязателен" .name) $v.external.host | quote }}]
{{- else }}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  labels: {{- include "storages.labels" $root | nindent 4 }}
spec:
  type: ExternalName
  externalName: {{ required (printf "%s.external.host обязателен" .name) $v.external.host | quote }}
  ports:
    - { name: {{ .portName }}, port: {{ $v.external.port }}, protocol: TCP }
{{- end }}
{{- end }}
