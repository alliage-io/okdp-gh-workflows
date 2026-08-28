{{- define "common.capabilities.ingress" -}}
{{- if .Capabilities.APIVersions.Has "networking.k8s.io/v1/Ingress" -}}networking.k8s.io/v1{{- end -}}
{{- end -}}
{{- define "common.render" -}}{{ tpl .text (dict "Capabilities" .ctx.Capabilities) }}{{- end -}}
