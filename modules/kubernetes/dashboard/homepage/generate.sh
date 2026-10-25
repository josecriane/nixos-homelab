#!/usr/bin/env bash
set -euo pipefail

TEMPLATE=/template
OUT=/app/config

for f in settings.yaml kubernetes.yaml widgets.yaml bookmarks.yaml; do
  cp -f "$TEMPLATE/$f" "$OUT/$f"
done

zero=$(kubectl get deployments,statefulsets -A -o json \
  | jq -c '[.items[] | select((.spec.replicas // 0) == 0) | "\(.metadata.namespace)/\(.metadata.name)"]')

unreachable="[]"
while IFS= read -r url; do
  [ -n "$url" ] || continue
  code=$(curl -s -o /dev/null -I --max-time 3 -w '%{http_code}' "$url" || true)
  if [ "$code" = "000" ]; then
    unreachable=$(jq -c --arg u "$url" '. + [$u]' <<<"$unreachable")
  fi
done < <(jq -r '.groups[].items[].monitor // empty' "$TEMPLATE/template.json")

jq --argjson zero "$zero" --argjson down "$unreachable" '
  def paused:
    (.workload != null and (.workload as $w | $zero | index($w) != null))
    or (.monitor != null and (.monitor as $m | $down | index($m) != null));
  def entry: { (.title): .props };
  (.groups | map({ (.name): (.items | map(select(paused | not) | entry)) }) | map(select((.[] | length) > 0))) as $active
  | [.groups[].items[] | select(paused) | del(.props.widget) | entry] as $off
  | if ($off | length) > 0 then $active + [{ (.paused): $off }] else $active end
' "$TEMPLATE/template.json" > "$OUT/services.yaml.tmp"
mv "$OUT/services.yaml.tmp" "$OUT/services.yaml"

echo "dashboard rendered: $(jq length <<<"$zero") workloads paused, $(jq length <<<"$unreachable") monitors down"
