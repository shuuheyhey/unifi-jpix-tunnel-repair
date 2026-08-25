#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
for test_file in "$ROOT"/tests/*_test.sh; do
  printf '\n== %s ==\n' "${test_file##*/}"
  /bin/sh "$test_file"
done
