#!/usr/bin/env bash
# Create (or reuse) the Forgejo release for $TAG and upload the given files.
# Tags with a suffix (-alpha.N, -beta.N) are marked as prereleases.
# Env: API (…/api/v1/repos/owner/repo), TOKEN, TAG.
set -euo pipefail
: "${API:?}" "${TOKEN:?}" "${TAG:?}"
command -v jq >/dev/null || { apt-get update -qq && apt-get install -y -qq jq >/dev/null; }
auth=(-H "Authorization: token $TOKEN")

if [[ $TAG == *-* ]]; then
  prerelease=true
  prev=$(git describe --tags --abbrev=0 --match 'v*' "$TAG^" 2>/dev/null || true)
else
  # Stable notes cover everything since the previous stable release.
  prerelease=false
  prev=$(git describe --tags --abbrev=0 --match 'v*' --exclude 'v*-*' "$TAG^" 2>/dev/null || true)
fi
notes=$(git log --no-merges --pretty='- %s' "${prev:+$prev..}$TAG")
[[ -n $prev ]] && notes="Changes since $prev:"$'\n\n'"$notes"

id=$(curl -fsS "${auth[@]}" "$API/releases/tags/$TAG" 2>/dev/null | jq -r '.id // empty' || true)
if [[ -z $id ]]; then
  id=$(jq -n --arg t "$TAG" --arg b "$notes" --argjson p "$prerelease" \
        '{tag_name: $t, name: $t, body: $b, prerelease: $p}' |
      curl -fsS "${auth[@]}" -H 'Content-Type: application/json' -d @- "$API/releases" |
      jq -r .id)
  echo "created release $TAG (id $id, prerelease=$prerelease)"
fi

for f in "$@"; do
  name=$(basename "$f")
  # Re-runs replace assets with the same name.
  for old in $(curl -fsS "${auth[@]}" "$API/releases/$id/assets" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id'); do
    curl -fsS "${auth[@]}" -X DELETE "$API/releases/$id/assets/$old"
  done
  curl -fsS "${auth[@]}" -F "attachment=@$f" "$API/releases/$id/assets?name=$name" >/dev/null
  echo "uploaded $name"
done
