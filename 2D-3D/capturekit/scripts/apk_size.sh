#!/usr/bin/env bash
# Report APK sizes (report-only). Usage: scripts/apk_size.sh [SEARCH_ROOT]  (default: android; finds */build/outputs/apk/**/*.apk)
# Reports whatever APKs exist, normally debug builds: debug sizes are NOT representative of release.
# APK_SIZE_LIMIT_BYTES unset = limit "TBD owner" (ADR 0018 item 17): never fails on size. When the
# owner sets a limit, it is still only reported here; enforcement is a separate decision.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="${1:-android}"
LIMIT="${APK_SIZE_LIMIT_BYTES:-}"
if [ -n "$LIMIT" ] && ! [[ $LIMIT =~ ^[0-9]+$ ]]; then
  echo "apk_size: warning: APK_SIZE_LIMIT_BYTES='$LIMIT' is not numeric; treating limit as TBD owner"
  LIMIT=""
fi
mapfile -t APKS < <(find "$DIR" -path '*/build/outputs/apk/*' -name '*.apk' 2>/dev/null | sort)
if [ "${#APKS[@]}" -eq 0 ]; then
  echo "apk_size: no APKs found under $DIR (build first: ./gradlew assembleDebug)"
  exit 0
fi
out="| flavour/buildType | APK | bytes | MiB | limit |
|---|---|---|---|---|"
for f in "${APKS[@]}"; do
  b=$(wc -c <"$f" | tr -d ' ')
  mib=$(awk -v b="$b" 'BEGIN{printf "%.2f", b/1048576}')
  lim="TBD owner"
  if [ -n "$LIMIT" ]; then
    lim="$LIMIT"
    [ "$b" -gt "$LIMIT" ] && lim="$LIMIT (OVER, report-only)"
  fi
  # path is .../build/outputs/apk/<flavour>/<buildType>/x.apk (or apk/<buildType>/x.apk without flavours)
  variant="${f#*/build/outputs/apk/}"; variant="${variant%/*}"
  out+=$'\n'"| $variant | ${f#"$DIR"/} | $b | $mib | $lim |"
done
echo "$out"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '### APK size\n\n%s\n' "$out" >>"$GITHUB_STEP_SUMMARY"
exit 0
