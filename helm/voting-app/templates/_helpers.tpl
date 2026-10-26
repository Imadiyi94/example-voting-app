{{/*
Common template helpers for the voting-app chart.

Everything here is intentionally generic: the templates read structure from
values.yaml and never hard-code a service name, image, port, probe or quota.
*/}}

{{/* Chart name, optionally overridden. */}}
{{- define "voting-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Name of the ConfigMap holding runtime (non-secret) settings. */}}
{{- define "voting-app.configMapName" -}}
{{- printf "%s-config" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Name of the ConfigMap holding the database bootstrap SQL. */}}
{{- define "voting-app.dbInitConfigMapName" -}}
{{- printf "%s-db-init" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Chart-wide labels applied to every object. */}}
{{- define "voting-app.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: voting-app
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Resolve an image reference.

Input: dict "root" $ "image" <image map>
Renders:
  repo:tag            when no digest is set
  repo:tag@sha256:... when a digest is set (Phase 2 digest pinning)
The registry prefix comes from the image itself or images.registry.
The tag falls back to images.tag.
*/}}
{{- define "voting-app.image" -}}
{{- $image := .image -}}
{{- $defaults := .root.Values.images -}}
{{- $registry := $image.registry | default $defaults.registry -}}
{{- $tag := $image.tag | default $defaults.tag -}}
{{- $ref := $image.repository -}}
{{- if $registry -}}
{{- $ref = printf "%s/%s" $registry $image.repository -}}
{{- end -}}
{{- if $image.digest -}}
{{- printf "%s:%s@%s" $ref $tag $image.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref $tag -}}
{{- end -}}
{{- end -}}

{{/*
Render an env list.

Input: dict "root" $ "env" <list> ["secretName" <string>]
Each item supports exactly one of:
  value: <string>            literal value
  configMapKey: <key>        valueFrom -> ConfigMap built by this chart
  secretKey: <key>           valueFrom -> existing Secret (Terraform-managed)
*/}}
{{- define "voting-app.env" -}}
{{- $root := .root -}}
{{- $defaultSecret := .secretName | default $root.Values.secrets.existingSecret -}}
{{- range .env }}
- name: {{ .name }}
{{- if hasKey . "value" }}
  value: {{ .value | quote }}
{{- else if .configMapKey }}
  valueFrom:
    configMapKeyRef:
      name: {{ include "voting-app.configMapName" $root }}
      key: {{ .configMapKey }}
{{- else if .secretKey }}
  valueFrom:
    secretKeyRef:
      name: {{ .secretName | default $defaultSecret }}
      key: {{ .secretKey }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Render a probe.

Input: probe map from values, e.g.
  httpGet: {path: /health, port: http}
  exec: {command: [redis-cli, ping]}
  periodSeconds: 5
Any handler plus the standard probe tuning fields is supported, so all rollout
behaviour is adjustable from values.yaml.
*/}}
{{- define "voting-app.probe" -}}
{{- $probe := . -}}
{{- with $probe.exec }}
exec:
  command:
{{ toYaml .command | indent 4 }}
{{- end }}
{{- with $probe.httpGet }}
httpGet:
  path: {{ .path | quote }}
  port: {{ .port }}
  {{- with .scheme }}
  scheme: {{ . }}
  {{- end }}
  {{- with .host }}
  host: {{ . | quote }}
  {{- end }}
{{- end }}
{{- with $probe.tcpSocket }}
tcpSocket:
  port: {{ .port }}
{{- end }}
{{- range $field := list "initialDelaySeconds" "periodSeconds" "timeoutSeconds" "successThreshold" "failureThreshold" }}
{{- if hasKey $probe $field }}
{{ $field }}: {{ index $probe $field }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Merge global hardening defaults with a per-service override.
Input: dict "global" <global securityContext> "override" <service securityContext or nil>
The service-specific value wins; global defaults fill the gaps.
*/}}
{{- define "voting-app.securityContext" -}}
{{- $override := .override | default dict -}}
{{- $merged := merge (deepCopy $override) (deepCopy (.global | default dict)) -}}
{{- toYaml $merged -}}
{{- end -}}
