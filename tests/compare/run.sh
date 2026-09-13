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
# Tests for the Helm 3 / Helm 4 compare of scripts/okdp-chart-test.sh, on
# charts written to a scratch directory:
#
#   same             formatting differences only (comments, blanks outside
#                    values, a plain scalar with a trailing blank): passes
#   trailing-space   a block scalar ending a document with a trailing space,
#                    another document following in the same template (the
#                    dns-server case): Helm 3 trims every document, Helm 4
#                    keeps it, fails
#   kept-newlines    the same with a keep-chomping block scalar (|+): Helm 3
#                    trims its trailing newlines, fails
#
# Needs helm (lint), yq, and the Helm 3 and Helm 4 binaries in $HELM3 and
# $HELM4 (default helm3 and helm4 on the PATH).
#
# Usage: tests/compare/run.sh

set -uo pipefail

TEST="$(cd "$(dirname "$0")/../../scripts" && pwd)/okdp-chart-test.sh"
HELM3="${HELM3:-helm3}"
HELM4="${HELM4:-helm4}"
export HELM3 HELM4
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}" || exit 1

chart() {  # chart <name> <configmap.yaml content>
  mkdir -p "$1/templates" "$1/ci"
  printf 'apiVersion: v2\nname: %s\nversion: 1.0.0\n' "$1" > "$1/Chart.yaml"
  printf 'x: 1\n' > "$1/ci/default-values.yaml"
  printf '%s' "$2" > "$1/templates/configmap.yaml"
}

chart same 'apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-a{{ "   " }}
  # a comment
data:
  conf: |
    line 1

    line 2


---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-b
'
chart trailing-space 'apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}
data:
  dnsmasq.conf: |
    log-queries
    no-hosts{{ " " }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-next
'
chart kept-newlines 'apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}
data:
  conf: |+
    line


---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-next
'

FAILED=0
RUN=0
check() {  # check <name> <expected exit code> <expected output regex> <args>...
  local name="$1" want="$2" pattern="$3" out rc
  shift 3
  RUN=$(( RUN + 1 ))
  out=$(bash "${TEST}" --no-kubeconform --out "${WORK}/out" "$@" 2>&1)
  rc=$?
  if [[ "${rc}" == "${want}" ]] && grep -qE -- "${pattern}" <<<"${out}"; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: exit ${rc} (want ${want}), output:"
    while IFS= read -r line; do echo "     ${line}"; done <<<"${out}"
    FAILED=$(( FAILED + 1 ))
  fi
}

check "same objects"                 0 "same objects under Helm 3 and Helm 4" same
check "trailing space in a value"    1 "Helm 3 and Helm 4 render different objects::trailing-space" trailing-space
check "diff shows the value"         1 "no-hosts \\\\n" trailing-space
check "kept trailing newlines"       1 "Helm 3 and Helm 4 render different objects::kept-newlines" kept-newlines
check "--no-helm-compare"            0 "1 chart\\(s\\) OK" --no-helm-compare trailing-space
check "missing Helm 3"               2 "Helm 3 missing" --helm3 "${WORK}/no-such-helm" same
check "Helm 4 given as Helm 3"       2 "Helm 3 expected" --helm3 "${HELM4}" same
check "Helm 3 given as Helm 4"       2 "Helm 4 expected" --helm4 "${HELM3}" same

echo "${RUN} test(s), ${FAILED} failure(s)"
[[ ${FAILED} -eq 0 ]]
