#!/usr/bin/env bash
#
# Copyright 2026 The OKDP Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Tests for scripts/okdp-chart-list.sh, against a throwaway git repository
# laid out like a chart repository:
#
#   charts/okdp-lib                      library, with a test chart in tests/
#   charts/helper                        depends on okdp-lib (file://)
#   packages/services/a                  depends on helper (file://), so on okdp-lib too
#   packages/services/b                  no local dependency, vendored subchart in charts/
#   packages/services/c                  upstream chart vendored under vendor/ (okdp.vendor.render)
#
# Usage: tests/list/run.sh

set -uo pipefail

LIST="$(cd "$(dirname "$0")/../../scripts" && pwd)/okdp-chart-list.sh"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}" || exit 1

chart() {  # chart <dir> [file:// dependency]
  mkdir -p "$1"
  printf 'apiVersion: v2\nname: %s\nversion: 1.0.0\n' "$(basename "$1")" > "$1/Chart.yaml"
  if [[ -n "${2:-}" ]]; then
    printf 'dependencies:\n  - name: %s\n    version: 1.0.0\n    repository: file://%s\n' "$(basename "$2")" "$2" >> "$1/Chart.yaml"
  fi
}

git init -q . && git config user.email t@t && git config user.name t
chart charts/okdp-lib
chart charts/okdp-lib/tests/helpers ../..
chart charts/helper ../okdp-lib
chart packages/services/a ../../../charts/helper
chart packages/services/b
chart packages/services/b/charts/vendored
chart packages/services/c
chart packages/services/c/vendor/upstream
mkdir -p .github/workflows && touch .github/workflows/ci.yml README.md
git add -A && git commit -qm base
BASE=$(git rev-parse HEAD)

FAILED=0
RUN=0
check() {  # check <name> <expected, space separated> <args>...
  local name="$1" want="$2" got
  shift 2
  RUN=$(( RUN + 1 ))
  got=$("${LIST}" "$@" 2>&1 | tr '\n' ' ' | sed 's/ $//')
  if [[ "${got}" == "${want}" ]]; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: got '${got}', want '${want}'"
    FAILED=$(( FAILED + 1 ))
  fi
}

ALL_CHARTS="charts/helper charts/okdp-lib packages/services/a packages/services/b packages/services/c"

check "no argument: every chart"      "${ALL_CHARTS}"
check "--all"                         "${ALL_CHARTS}" --all --base "${BASE}"
check "empty paths: every chart"      "${ALL_CHARTS}" --paths "[]"
check "zero base (new branch)"        "${ALL_CHARTS}" --base 0000000000000000000000000000000000000000
check "unknown base"                  "${ALL_CHARTS}" --base deadbeefdeadbeef
check "roots"                         "packages/services/a packages/services/b packages/services/c" --roots packages
check "nothing changed"               "" --base "${BASE}"
check "release paths"                 "packages/services/b" --paths '["packages/services/b"]'
check "release path without chart"    "::error title=No chart::packages/services was released but holds no Chart.yaml" \
                                      --paths '["packages/services"]'

git checkout -q -b t1 "${BASE}"
echo x > packages/services/b/values.yaml && git add -A && git commit -qm b
check "one chart changed"             "packages/services/b" --base "${BASE}"

git checkout -q -b t1v "${BASE}"
echo x > packages/services/c/vendor/upstream/values.yaml && git add -A && git commit -qm c
check "vendored chart changed: wrapper" "packages/services/c" --base "${BASE}"

git checkout -q -b t2 "${BASE}"
echo x > charts/okdp-lib/templates.tpl && git add -A && git commit -qm lib
check "library change: consumers too" "charts/helper charts/okdp-lib packages/services/a" --base "${BASE}"

git checkout -q -b t3 "${BASE}"
echo x > charts/helper/values.yaml && git add -A && git commit -qm helper
check "helper change: its consumer"   "charts/helper packages/services/a" --base "${BASE}"

git checkout -q -b t4 "${BASE}"
echo x >> README.md && git add -A && git commit -qm readme
check "unrelated change"              "" --base "${BASE}"

git checkout -q -b t5 "${BASE}"
echo x >> .github/workflows/ci.yml && git add -A && git commit -qm ci
check "workflow change: every chart"  "${ALL_CHARTS}" --base "${BASE}"

echo "${RUN} test(s), ${FAILED} failure(s)"
[[ ${FAILED} -eq 0 ]]
