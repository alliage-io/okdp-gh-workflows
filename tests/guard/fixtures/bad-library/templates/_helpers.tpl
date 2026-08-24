{{- define "lib.secret" -}}
{{- $s := (lookup "v1" "Secret" .Release.Namespace "x") -}}
{{- end -}}
