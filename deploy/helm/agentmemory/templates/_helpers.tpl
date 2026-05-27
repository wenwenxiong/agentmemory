{{- define "agentmemory.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "agentmemory.labels" -}}
app.kubernetes.io/name: {{ include "agentmemory.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "agentmemory.selectorLabels" -}}
app.kubernetes.io/name: {{ include "agentmemory.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "agentmemory.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "agentmemory.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "agentmemory.serviceUrl" -}}
{{- printf "http://%s:%d" (include "agentmemory.fullname" .) (int .Values.service.port) }}
{{- end }}
