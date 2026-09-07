#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
for test_file in "$ROOT"/tests/*_test.sh; do
  printf '\n== %s ==\n' "${test_file##*/}"
  /bin/sh "$test_file"
done

printf '\n== Python v2 tests ==\n'
PYTHONPATH="$ROOT/src" python3 -m unittest discover -s "$ROOT/tests_v2" -p 'test_*.py' -v
