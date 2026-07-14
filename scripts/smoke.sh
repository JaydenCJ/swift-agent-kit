#!/usr/bin/env bash
# Smoke test for swift-agent-kit.
#
# Requires a Swift 6.0+ toolchain on PATH (swift.org tarball, Xcode 16.2+,
# or the official container). No network is used: the package has zero
# dependencies and the offline demo runs a scripted provider.
#
# Without a local toolchain, run it inside the official image:
#   docker run --rm -v "$PWD":/src -w /src swift:6.0.3 bash scripts/smoke.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null 2>&1; then
  echo "smoke: FAIL — no Swift toolchain on PATH (need Swift 6.0+)." >&2
  echo "smoke: see the header of this script for the container invocation." >&2
  exit 1
fi

echo "== toolchain =="
swift --version

echo "== swift test =="
# Full suite; pipefail propagates a test failure through the tail.
swift test 2>&1 | tail -n 5

echo "== offline demo =="
demo_output="$(swift run swiftagentkit-demo --offline "What's on my calendar tomorrow?")"
printf '%s\n' "$demo_output"

# Assert the deterministic transcript documented in the READMEs.
case "$demo_output" in
  *'get_calendar_events({"day":"tomorrow"})'*'10:30 Dentist, 19:00 Dinner with Yuki'*) ;;
  *)
    echo "smoke: FAIL — offline demo transcript did not match the documented output." >&2
    exit 1
    ;;
esac

echo "== usage text =="
usage_output="$(swift run swiftagentkit-demo)"
case "$usage_output" in
  *Usage:*) ;;
  *)
    echo "smoke: FAIL — running the demo without arguments did not print usage help." >&2
    exit 1
    ;;
esac

echo "SMOKE OK"
