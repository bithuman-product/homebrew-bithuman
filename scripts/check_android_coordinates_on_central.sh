#!/usr/bin/env bash
# The Android half of the plugin claims, in its own header, that a stranger's clone
# resolves BOTH engines "from mavenCentral() alone". That claim was TRUE when written,
# went false-then-true again as pins moved, and for three minors it was simply dead:
# expression2-android carried `com.google.ai.edge.litert:litert` (404 on Central) in
# 0.3.0 and in 0.3.0 only, and the note survived every bump after.
#
# A prose claim nothing grades rots. This grades it, against the registry:
#
#   1. every coordinate this build.gradle PINS is served by Maven Central, and
#   2. every transitive dependency those pinned POMs declare is served by Central too —
#      which is what "resolves from Central alone" actually means.
#
# google() may stay in the repository list for AGP's own tooling; this says nothing
# about that. It says only that no ENGINE resolution depends on it.
#
# Exit 1 = a claim is false. Exit 2 = Central was unreachable (no verdict, not a pass).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRADLE="${1:-packages/flutter-plugin/android/build.gradle}"
CENTRAL="https://repo1.maven.org/maven2"
[ -r "$GRADLE" ] || { echo "cannot read $GRADLE"; exit 2; }

# HTTP status for a Central POM, retried; prints the code, or "ERR" if never reached.
pom_status() {
  local g="$1" a="$2" v="$3" url code
  url="$CENTRAL/${g//.//}/$a/$v/$a-$v.pom"
  for _ in 1 2 3; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$url" 2>/dev/null) || code=000
    case "$code" in 200|404) printf '%s' "$code"; return 0 ;; esac
    sleep 2
  done
  printf 'ERR'
}

pom_body() {
  local g="$1" a="$2" v="$3"
  curl -fsS --max-time 25 "$CENTRAL/${g//.//}/$a/$v/$a-$v.pom" 2>/dev/null
}

# The PINNED coordinates — real dependency lines only, never a comment.
mapfile -t PINS < <(
  grep -E "^[[:space:]]*(implementation|api|runtimeOnly|compileOnly)[[:space:]]+'[^']+:[^']+:[^']+'" "$GRADLE" \
  | grep -oE "'[^']+:[^']+:[^']+'" | tr -d "'" | sort -u
)
[ "${#PINS[@]}" -gt 0 ] || { echo "no pinned coordinates found in $GRADLE — the parser is blind"; exit 2; }

fail=0; unreachable=0
declare -A SEEN=()

grade() {                     # grade <coord> <why>
  local coord="$1" why="$2" g a v code
  IFS=: read -r g a v <<< "$coord"
  if [ -n "${SEEN[$coord]:-}" ]; then
    code="${SEEN[$coord]}"      # cache the CALL, never the row: every edge stays visible
  else
    code=$(pom_status "$g" "$a" "$v")
    SEEN[$coord]="$code"
  fi
  case "$code" in
    200) printf '  ok      %-52s %s\n' "$coord" "$why" ;;
    404) printf '  NOT ON CENTRAL  %-44s %s\n' "$coord" "$why"; fail=1 ;;
    *)   printf '  unreachable     %-44s %s\n' "$coord" "$why"; unreachable=1 ;;
  esac
}

echo "Pinned coordinates in $GRADLE:"
for coord in "${PINS[@]}"; do grade "$coord" "pinned"; done

echo
echo "Transitive dependencies those POMs declare:"
any_transitive=0
for coord in "${PINS[@]}"; do
  IFS=: read -r g a v <<< "$coord"
  body=$(pom_body "$g" "$a" "$v") || continue
  # <dependency> blocks only; strip whitespace so the triple is one token.
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    any_transitive=1
    grade "$dep" "via $a:$v"
  done < <(printf '%s' "$body" | python3 "$HERE/pom_dependencies.py")
done
[ "$any_transitive" = 1 ] || echo "  (none declared)"

echo
if [ "$fail" = 1 ]; then
  echo "FAIL — a coordinate this build resolves is NOT on Maven Central."
  echo "       Either pick a pin that is, or add the repository AND correct the header"
  echo "       comment, which tells a stranger the clone builds from Central alone."
  exit 1
fi
if [ "$unreachable" = 1 ]; then
  echo "NO VERDICT — Central was unreachable. This is not a pass."
  exit 2
fi
echo "PASS — every pinned coordinate and every transitive dependency is on Maven Central."
