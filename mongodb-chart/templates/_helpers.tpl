{{/*
Expand the name of the chart.
*/}}
{{- define "mongodb-chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because many Kubernetes name fields are limited to 63 chars.
*/}}
{{- define "mongodb-chart.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mongodb-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mongodb-chart.labels" -}}
helm.sh/chart: {{ include "mongodb-chart.chart" . }}
{{ include "mongodb-chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mongodb-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mongodb-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Comma-separated DNS seeds for MongoDB tools. */}}
{{- define "mongodb-chart.memberHosts" -}}
{{- $root := . -}}
{{- range $i := until (int .Values.replicaSet.members) -}}
{{- if gt $i 0 }},{{ end -}}
{{ printf "%s-%d.%s-headless.%s.svc.cluster.local:27017" (include "mongodb-chart.fullname" $root) $i (include "mongodb-chart.fullname" $root) $root.Release.Namespace }}
{{- end -}}
{{- end }}

{{/*
Configure Vault Agent injection for the admin password without creating a Kubernetes Secret.
*/}}
{{- define "mongodb-chart.vaultAgentAnnotations" -}}
{{- $root := .root -}}
{{- $path := required "auth.vaultPath muss auf den KV-v2-Admin-Passwortpfad in Vault zeigen" $root.Values.auth.vaultPath -}}
{{- $role := required "auth.vaultRole muss auf eine Vault-Kubernetes-Auth-Rolle zeigen" $root.Values.auth.vaultRole -}}
{{- $serviceAccount := required "auth.serviceAccountName muss auf ein für Vault berechtigtes ServiceAccount zeigen" $root.Values.auth.serviceAccountName -}}
{{- $annotations := mergeOverwrite (deepCopy (.extra | default dict)) (dict
  "vault.hashicorp.com/agent-inject" "true"
  "vault.hashicorp.com/role" $role
  "vault.hashicorp.com/agent-pre-populate-only" "true"
  "vault.hashicorp.com/agent-inject-containers" .container
  "vault.hashicorp.com/agent-inject-secret-admin-password" $path
  "vault.hashicorp.com/agent-inject-file-admin-password" "admin-password"
  "vault.hashicorp.com/agent-inject-perms-admin-password" "0444"
  "vault.hashicorp.com/agent-inject-template-admin-password" (printf "{{- with secret \"%s\" -}}\n{{ .Data.data.password }}\n{{- end }}" $path)
) -}}
{{- toYaml $annotations -}}
{{- end }}

{{/*
Create the name of the service account to use.
*/}}
{{- define "mongodb-chart.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mongodb-chart.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
