{{- define "storages.labels" -}}
app.kubernetes.io/part-of: installer
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/*
storages.service — the stable service of a storage (R11).
internal: ClusterIP with a selector on pods of the operator or chart;
external: ExternalName for a DNS name, or a service without a selector with an EndpointSlice for an IP.
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
    endpointslice.kubernetes.io/managed-by: installer
addressType: IPv4
ports:
  - { name: {{ .portName }}, port: {{ $v.external.port }}, protocol: TCP }
endpoints:
  - addresses: [{{ required (printf "%s.external.host is required" .name) $v.external.host | quote }}]
{{- else }}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  labels: {{- include "storages.labels" $root | nindent 4 }}
spec:
  type: ExternalName
  externalName: {{ required (printf "%s.external.host is required" .name) $v.external.host | quote }}
  ports:
    - { name: {{ .portName }}, port: {{ $v.external.port }}, protocol: TCP }
{{- end }}
{{- end }}
