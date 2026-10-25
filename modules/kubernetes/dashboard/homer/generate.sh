#!/usr/bin/env bash
set -euo pipefail

TEMPLATE=/template/template.json
OUT=/www/assets

zero=$(kubectl get deployments,statefulsets -A -o json \
  | jq -c '[.items[] | select((.spec.replicas // 0) == 0) | "\(.metadata.namespace)/\(.metadata.name)"]')

render() {
  jq --argjson zero "$zero" "$1" "$TEMPLATE" > "$OUT/$2.tmp"
  mv "$OUT/$2.tmp" "$OUT/$2"
}

render '
  def paused: .workload != null and (.workload as $w | $zero | index($w) != null);
  .services |= (map(.items |= map(select(paused | not))) | map(select((.items | length) > 0)))
  | del(.services[].items[].workload)
  | .links = [{"name": "Mostrar apagados", "icon": "fas fa-eye", "url": "#all"}]
' config.yml

render '
  def paused: .workload != null and (.workload as $w | $zero | index($w) != null);
  (.services[].items[] | select(paused)) |= (
    .tag = "apagado" | .tagstyle = "is-dark" | del(.type, .endpoint, .apikey, .apiurl)
  )
  | del(.services[].items[].workload)
  | .links = [{"name": "Ocultar apagados", "icon": "fas fa-eye-slash", "url": "#"}]
' all.yml

echo "dashboard rendered: $(echo "$zero" | jq length) workloads paused"
