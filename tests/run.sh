#!/usr/bin/env sh
# Run every Lua test suite. Hermetic: no TeX distribution and no SVG
# converter are needed — the suites exercise the pure helpers and the
# failure paths, and the one case that needs an executable uses `sh`.
#
#   sh tests/run.sh          # from the repo root
#
# Exits non-zero if any suite fails, so it can be a CI gate.
set -eu

cd "$(dirname "$0")/.."

if ! command -v pandoc >/dev/null 2>&1; then
  echo "pandoc not found on PATH; the suites run under 'pandoc lua'." >&2
  exit 127
fi

status=0
for suite in tests/test_*.lua; do
  printf '%-32s' "$suite"
  # Warnings on stderr are expected: several suites deliberately drive the
  # diagnostic paths. Only the exit status decides.
  if out=$(pandoc lua "$suite" 2>/dev/null); then
    echo "$out"
  else
    echo "FAILED"
    pandoc lua "$suite" || true
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "all suites passed"
fi
exit "$status"
