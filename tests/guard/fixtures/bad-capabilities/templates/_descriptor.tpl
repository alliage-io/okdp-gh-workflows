{{- /* Stand-in for okdp-lib-chart's okdp.descriptor, so the fixture renders on its own. */ -}}
{{- define "okdp.descriptor" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-okdp
  labels:
    okdp.io/instance: {{ .Release.Name }}
    okdp.io/service: {{ .Chart.Name }}
data:
  service: {{ .Chart.Name }}
  version: {{ .Chart.Version | quote }}
{{- end -}}
