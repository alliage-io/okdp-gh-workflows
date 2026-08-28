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
# Fixture tests for scripts/okdp-chart-guard.sh.
#
# Each case runs the guard on one fixture chart and checks the exit status and
# that every expected finding ("file:line: level: message" fragments) is in the
# output. Passing fixtures are also rendered with `helm template` when helm is
# installed, to prove they are real charts and not just text the guard likes.
#
# Usage: tests/guard/run.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="${HERE}/../../scripts/okdp-chart-guard.sh"
cd "${HERE}/fixtures" || exit 1

# The guard must print local-format findings here, even when this runs in CI.
unset GITHUB_ACTIONS

FAILED=0
RUN=0

indent() { while IFS= read -r l; do echo "     | ${l}"; done <<<"$1"; }

# expect <fixture> <exit status> "<guard args>" [expected fragment]...
expect() {
  local fixture="$1" want="$2" args="$3" out rc=0 frag
  shift 3
  RUN=$(( RUN + 1 ))
  # shellcheck disable=SC2086 # args is a word list on purpose
  out=$("${GUARD}" ${args} "${fixture}" 2>&1) || rc=$?
  if [[ "${rc}" != "${want}" ]]; then
    echo "FAIL ${fixture} ${args}: exit ${rc}, want ${want}"
    indent "${out}"
    FAILED=$(( FAILED + 1 ))
    return
  fi
  for frag in "$@"; do
    if ! grep -qF -- "${frag}" <<<"${out}"; then
      echo "FAIL ${fixture} ${args}: missing '${frag}'"
      indent "${out}"
      FAILED=$(( FAILED + 1 ))
      return
    fi
  done
  echo "ok   ${fixture} ${args}"
}

# Forbidden names in comments and plain text, allowed hooks, KubeVersion: clean.
expect good-service 0 ""
expect good-library 0 ""

# A library may pass the whole .Capabilities object on (okdp.vendor.render
# does); a method call on it is still an error, and so is a pass-through in an
# application chart.
expect bad-library 1 "" \
  "bad-library/templates/_helpers.tpl:2: error: lookup is forbidden" \
  "bad-library/templates/_render.tpl:3: error: .Capabilities.APIVersions is forbidden"

expect bad-lookup 1 "" \
  "bad-lookup/templates/secret.yaml:1: error: lookup is forbidden"

expect bad-rand 1 "" \
  "bad-rand/templates/secret.yaml:6: error: non-deterministic function now is forbidden" \
  "bad-rand/templates/secret.yaml:8: error: non-deterministic function randAlphaNum is forbidden" \
  "bad-rand/templates/secret.yaml:9: error: non-deterministic function uuidv4 is forbidden" \
  "bad-rand/templates/secret.yaml:10: error: non-deterministic function randAscii is forbidden" \
  "bad-rand/templates/secret.yaml:11: error: non-deterministic function genCA is forbidden"

expect bad-release-flags 1 "" \
  "bad-release-flags/templates/cm.yaml:1: error: .Release.IsInstall is forbidden" \
  "bad-release-flags/templates/cm.yaml:7: error: .Release.IsUpgrade is forbidden"

expect bad-capabilities 1 "" \
  "bad-capabilities/templates/cm.yaml:1: error: .Capabilities.APIVersions is forbidden" \
  "bad-capabilities/templates/cm.yaml:7: error: .Capabilities.HelmVersion is forbidden" \
  "bad-capabilities/templates/cm.yaml:10: error: .Capabilities is forbidden"

expect bad-hook 1 "" \
  "bad-hook/templates/hooks.yaml:6: error: hook \"pre-delete\" is forbidden" \
  "bad-hook/templates/hooks.yaml:13: error: hook \"test\" is forbidden" \
  "bad-hook/templates/hooks.yaml:20: error: helm.sh/hook value is templated"

expect missing-descriptor 1 "" \
  "missing-descriptor/Chart.yaml: error: service chart 'missing-descriptor' does not render the instance descriptor"
# The opt-out, by chart name and by directory.
expect missing-descriptor 0 "--descriptor-optional other,missing-descriptor"
expect missing-descriptor 0 "--descriptor-optional=missing-descriptor/"
expect missing-descriptor 0 "--descriptor-optional missing-descriptor"

# Helper (sub)charts listed in --descriptor-optional: tested through their parent,
# so no descriptor, no ci values, no root global/connections. Without the opt-out
# the same chart fails.
expect helper-chart 0 "--descriptor-optional helper-chart"
expect helper-no-schema 0 "--descriptor-optional helper-no-schema"
expect helper-chart 1 "" \
  "helper-chart/Chart.yaml: error: service chart 'helper-chart' does not render the instance descriptor" \
  "helper-chart/values.schema.json: error: root properties must declare 'global'" \
  "helper-chart/values.schema.json: error: root properties must declare 'connections'" \
  "helper-chart: error: no ci/*-values.yaml test values file"
expect helper-no-schema 1 "" \
  "helper-no-schema/values.schema.json: error: missing values.schema.json"
# ...but a schema it ships must be draft-07, and the forbidden patterns still apply.
expect helper-bad 1 "--descriptor-optional helper-bad" \
  "helper-bad/templates/cm.yaml:7: error: non-deterministic function randAlphaNum is forbidden" \
  "helper-bad/values.schema.json: error: \$schema must be http://json-schema.org/draft-07/schema#"

expect bad-schema 1 "" \
  "bad-schema/values.schema.json: error: \$schema must be http://json-schema.org/draft-07/schema#" \
  "bad-schema/values.schema.json: error: root properties must declare 'connections'" \
  "bad-schema/values.schema.json: error: KuboCD keywords left: x-kubocd-connection-ref" \
  "bad-schema/values.schema.json: warning: title 'Storage | Hive | select' looks like the KuboCD title DSL" \
  "bad-schema: error: no ci/*-values.yaml test values file"

# Vendored upstream charts (vendor/<name>/, rendered by okdp.vendor.render):
# scanned too, templates/tests/ and NOTES.txt excepted; findings allowed by
# okdp-guard-allow.yaml pass, an unused entry is a warning; vendor.yaml checked.
expect vendored-good 0 "" \
  "vendored-good/okdp-guard-allow.yaml:15: warning: unused entry: no 'hook' finding in vendor/renamed/templates/*"
expect vendored-bad 1 "" \
  "vendored-bad/vendor/upstream/templates/secret.yaml:1: error: lookup is forbidden" \
  "vendored-bad/vendor/upstream/templates/secret.yaml:7: error: hook \"pre-delete\" is forbidden" \
  "vendored-bad/vendor/upstream/templates/secret.yaml:8: error: .Release.IsInstall is forbidden" \
  "vendored-bad/vendor/upstream/templates/secret.yaml:10: error: non-deterministic function randAlphaNum is forbidden" \
  "vendored-bad/vendor/upstream/templates/secret.yaml:11: error: .Capabilities.APIVersions is forbidden" \
  "add an okdp-guard-allow.yaml entry with pattern 'lookup', a reason and disabledBy" \
  "add an okdp-guard-allow.yaml entry with pattern 'capabilities' and a reason" \
  "vendored-bad/vendor/upstream/charts/app: error: vendored chart bundles an application subchart" \
  "vendored-bad/vendor/upstream/charts/packed-1.0.0.tgz: error: packed subchart" \
  "vendored-bad/vendor/upstream/Chart.yaml: error: is upstream 2.1.0, vendor.yaml lists upstream 2.0.0" \
  "vendored-bad/vendor.yaml: error: missing 1.0.0 is listed but vendored-bad/vendor/missing/Chart.yaml is missing" \
  "vendored-bad/vendor.yaml: error: charts[2]: name, repository and version are required" \
  "vendored-bad/vendor.yaml: error: charts[3]: 'upstream' is listed twice" \
  "vendored-bad/vendor/stale: error: not listed in vendor.yaml"
# lookup/rand/IsInstall/IsUpgrade need disabledBy; the entry's other checks.
expect vendored-bad-allow 1 "" \
  "vendored-bad-allow/okdp-guard-allow.yaml:1: error: 'non-deterministic' cannot be allowed with a reason alone" \
  "vendored-bad-allow/okdp-guard-allow.yaml:4: warning: disabledBy 'auth.generat' is not a key of vendor/upstream/values.yaml" \
  "vendored-bad-allow/okdp-guard-allow.yaml:8: error: file 'templates/descriptor.yaml' is not under vendor/" \
  "vendored-bad-allow/okdp-guard-allow.yaml:11: error: unknown key(s): owner" \
  "vendored-bad-allow/okdp-guard-allow.yaml:11: error: pattern 'rand' is not a rule id" \
  "vendored-bad-allow/okdp-guard-allow.yaml:11: error: reason is required" \
  "vendored-bad-allow/okdp-guard-allow.yaml:15: error: entry must be a map" \
  "vendored-bad-allow/vendor/upstream/templates/secret.yaml:7: error: non-deterministic function randAlphaNum is forbidden"
RUN=$(( RUN + 1 ))
if "${GUARD}" vendored-bad-allow 2>&1 | grep -q "secret.yaml:8: error: lookup"; then
  echo "FAIL vendored-bad-allow: the lookup entry with disabledBy must allow the lookup"; FAILED=$(( FAILED + 1 ))
else
  echo "ok   vendored-bad-allow: disabledBy allows lookup"
fi
expect vendor-no-manifest 1 "" \
  "vendor-no-manifest/vendor: error: vendor/ without vendor.yaml"
expect bad-allow-file 1 "" \
  "bad-allow-file/okdp-guard-allow.yaml: error: must be a list of {file, pattern, reason[, disabledBy]} entries" \
  "bad-allow-file/vendor.yaml: error: must have a 'charts' list"

expect missing-schema 1 "" \
  "missing-schema/values.schema.json: error: missing values.schema.json"

expect does-not-exist 1 "" "does-not-exist: error: not a chart: no Chart.yaml"

# Several charts in one call: one bad chart fails the whole run, every finding is reported.
RUN=$(( RUN + 1 ))
out=$("${GUARD}" good-service bad-lookup bad-hook 2>&1); rc=$?
if [[ ${rc} -eq 1 ]] && grep -q "okdp-chart-guard: 4 error(s) in 3 chart(s)" <<<"${out}"; then
  echo "ok   multiple charts"
else
  echo "FAIL multiple charts: exit ${rc}"; indent "${out}"; FAILED=$(( FAILED + 1 ))
fi

# GitHub annotation format.
RUN=$(( RUN + 1 ))
out=$(GITHUB_ACTIONS=true "${GUARD}" bad-lookup 2>&1)
if grep -qF "::error file=bad-lookup/templates/secret.yaml,line=1,title=okdp-chart-guard::lookup is forbidden" <<<"${out}"; then
  echo "ok   github annotations"
else
  echo "FAIL github annotations"; indent "${out}"; FAILED=$(( FAILED + 1 ))
fi

# Usage error.
RUN=$(( RUN + 1 ))
if "${GUARD}" >/dev/null 2>&1; [[ $? -eq 2 ]]; then echo "ok   usage"; else echo "FAIL usage"; FAILED=$(( FAILED + 1 )); fi

# Passing fixtures are real, renderable charts.
if command -v helm >/dev/null; then
  for chart in good-service missing-descriptor vendored-good; do
    RUN=$(( RUN + 1 ))
    if helm template ci-test "${chart}" -f "${chart}/ci/default-values.yaml" >/dev/null 2>&1; then
      echo "ok   helm template ${chart}"
    else
      echo "FAIL helm template ${chart}"; helm template ci-test "${chart}" 2>&1 | sed 's/^/     | /'
      FAILED=$(( FAILED + 1 ))
    fi
  done
fi

echo "${RUN} test(s), ${FAILED} failure(s)"
[[ ${FAILED} -eq 0 ]]
