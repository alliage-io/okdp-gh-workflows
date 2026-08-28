{{- define "lib.render" -}}
{{- $root := dict "Capabilities" .ctx.Capabilities -}}
{{- if .ctx.Capabilities.APIVersions.Has "v1" }}x{{ end -}}
{{- end -}}
