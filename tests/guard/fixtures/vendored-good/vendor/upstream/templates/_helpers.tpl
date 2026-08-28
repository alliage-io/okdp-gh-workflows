{{- define "upstream.pdbApi" -}}
{{- if .Capabilities.APIVersions.Has "policy/v1" -}}policy/v1{{- else -}}policy/v1beta1{{- end -}}
{{- end -}}
