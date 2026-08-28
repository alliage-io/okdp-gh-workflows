{{- /* Pass the whole .Capabilities object on, like okdp.vendor.render: allowed in a library. */ -}}
{{- define "lib.render" -}}
{{- $root := dict "Values" .values "Release" .ctx.Release "Capabilities" .ctx.Capabilities -}}
{{- tpl .text (dict "Capabilities" $.ctx.Capabilities "Values" .values) -}}
{{- end -}}
