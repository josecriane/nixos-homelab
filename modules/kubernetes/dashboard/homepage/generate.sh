#!/usr/bin/env bash
set -euo pipefail

TEMPLATE=/template
OUT=/app/config

for f in settings.yaml kubernetes.yaml widgets.yaml bookmarks.yaml; do
  cp -f "$TEMPLATE/$f" "$OUT/$f"
done

zero=$(kubectl get deployments,statefulsets -A -o json \
  | jq -c '[.items[] | select((.spec.replicas // 0) == 0) | "\(.metadata.namespace)/\(.metadata.name)"]')

jq --argjson zero "$zero" '
  def paused: .workload != null and (.workload as $w | $zero | index($w) != null);
  def entry: { (.title): .props };
  (.groups | map({ (.name): (.items | map(select(paused | not) | entry)) }) | map(select((.[] | length) > 0))) as $active
  | [.groups[].items[] | select(paused) | del(.props.widget) | entry] as $off
  | if ($off | length) > 0 then $active + [{ (.paused): $off }] else $active end
' "$TEMPLATE/template.json" > "$OUT/services.yaml.tmp"
mv "$OUT/services.yaml.tmp" "$OUT/services.yaml"

echo "dashboard rendered: $(echo "$zero" | jq length) workloads paused"
