{{/* Build the existing renderer's values from service declarations.
     owner preserves Argo ownership independently of directory placement.
     A disabled service retains configuration and secrets but emits no workload resources. */}}
{{- define "platform.context" -}}
{{- $values := deepCopy .Values -}}
{{- $components := list -}}
{{- $disabled := list -}}
{{- $extras := dict -}}
{{- $seen := dict -}}
{{- range $path, $_ := .Files.Glob "**/service.yaml" -}}
  {{- $service := $.Files.Get $path | fromYaml -}}
  {{- if not (has $service.owner (list "apps" "infra")) -}}
    {{- fail (printf "%s: owner must be apps or infra" $path) -}}
  {{- end -}}
  {{- if or (not (hasKey $service "enabled")) (not (kindIs "bool" $service.enabled)) -}}
    {{- fail (printf "%s: enabled must be an explicit boolean" $path) -}}
  {{- end -}}
  {{- range $component := $service.components | default (list) -}}
    {{- $name := required (printf "%s: component requires name" $path) $component.name -}}
    {{- if hasKey $seen $name -}}{{- fail (printf "duplicate component: %s" $name) -}}{{- end -}}
    {{- $_ := set $seen $name true -}}
    {{- $file := required (printf "%s: %s requires valuesFile" $path $name) $component.valuesFile -}}
    {{- $file := printf "%s/%s" (dir $path) $file -}}
    {{- if not ($.Files.Get $file) -}}{{- fail (printf "%s: values file missing or empty: %s" $name $file) -}}{{- end -}}
    {{- if eq $service.owner $.Values.owner -}}
      {{- $_ := set $component "valuesFile" (printf "kubernetes/%s" $file) -}}
      {{- $components = append $components $component -}}
      {{- if not $service.enabled -}}{{- $disabled = append $disabled $name -}}{{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if eq $service.owner $.Values.owner -}}
    {{- range $key, $value := $service.extras | default (dict) -}}
      {{- if hasKey $extras $key -}}{{- fail (printf "duplicate resource configuration: %s" $key) -}}{{- end -}}
      {{- if $service.enabled -}}
        {{- $_ := set $extras $key $value -}}
      {{- else -}}
        {{- $_ := set $extras $key false -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $_ := set $values "components" $components -}}
{{- $_ := set $values "disabledComponents" $disabled -}}
{{- $_ := set $values "extras" $extras -}}
{{- toYaml $values -}}
{{- end -}}
