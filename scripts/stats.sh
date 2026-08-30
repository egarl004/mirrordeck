#!/bin/bash
# Show what GitHub already records about the project. Needs the gh CLI, signed
# in as someone with push access (traffic data is owner-only).
#
#   ./scripts/stats.sh
#
# GitHub keeps traffic for 14 days only, so run it periodically if you want a
# longer record. Download counts, by contrast, are cumulative and never reset.
set -euo pipefail

REPO="${REPO:-egarl004/mirrordeck}"

bar() { printf '  %s\n' "────────────────────────────────────────────"; }

echo
echo "  MirrorDeck — $REPO"
bar

echo "  DOWNLOADS (cumulative, per release asset)"
total=0
while read -r line; do
    [ -z "$line" ] && continue
    echo "    $line"
done < <(gh api "repos/$REPO/releases" --jq '
    .[] | .tag_name as $t | .assets[] |
    "\($t)  \(.name)  \(.download_count)"' 2>/dev/null)
total="$(gh api "repos/$REPO/releases" --jq '[.[].assets[].download_count] | add // 0' 2>/dev/null)"
echo "    total: ${total:-0}"
echo

bar
echo "  REPOSITORY TRAFFIC (last 14 days)"
gh api "repos/$REPO/traffic/views" \
    --jq '"    page views: \(.count)  (\(.uniques) unique)"' 2>/dev/null || echo "    unavailable"
gh api "repos/$REPO/traffic/clones" \
    --jq '"    clones:     \(.count)  (\(.uniques) unique)"' 2>/dev/null || echo "    unavailable"
echo

bar
echo "  WHERE VISITORS CAME FROM (last 14 days)"
refs="$(gh api "repos/$REPO/traffic/popular/referrers" \
    --jq '.[] | "    \(.referrer)  \(.count) views (\(.uniques) unique)"' 2>/dev/null || true)"
[ -n "$refs" ] && echo "$refs" || echo "    (none recorded yet)"
echo

bar
echo "  STARS / WATCHERS / FORKS"
gh api "repos/$REPO" \
    --jq '"    \(.stargazers_count) stars · \(.subscribers_count) watching · \(.forks_count) forks"' 2>/dev/null
echo

bar
echo "  Note: this covers GitHub only. Visits to the landing page itself are"
echo "  not counted here — see the Analytics section of web/README.md."
echo
