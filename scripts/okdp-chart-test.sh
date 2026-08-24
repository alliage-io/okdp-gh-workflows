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
# okdp-chart-test.sh: build, lint, render and validate OKDP charts.
#
# For each chart:
#   1. helm dependency build, file:// dependencies first (depth first), after
#      adding every http(s) dependency repository;
#   2. application chart: for each ci/*-values.yaml, helm lint and helm template
#      with the base values then that file, and kubeconform on the output;
#      library chart: helm lint, then the same as above for each test chart
#      in <chart>/tests/*/ (a test chart without ci/ renders its defaults).
#
# Rendered manifests are written to <out>/<chart path>/<values name>.yaml.
# A failing chart does not stop the others; every failure is reported.
#
# Usage:
#   okdp-chart-test.sh [--base-values "FILE..."] [--kube-version X.Y.Z]
#                      [--out DIR] [--no-kubeconform] [--strict] <chart-dir>...
#
#   --base-values   values files layered before each ci file (e.g. a
#                   platform-values fixture), in order
#   --kube-version  Kubernetes version for helm template and kubeconform (default 1.31.0)
#   --out           where rendered manifests go (default ./.okdp-rendered)
#   --no-kubeconform  skip kubeconform (it is skipped with a warning when absent)
#   --strict        kubeconform -strict (reject unknown fields)

set -uo pipefail

BASE_VALUES=""
KUBE_VERSION="1.31.0"
OUT=".okdp-rendered"
KUBECONFORM=true
STRICT=false
RELEASE="ci-test"
NAMESPACE="ci-test"
CHARTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-values)    BASE_VALUES="$2"; shift 2 ;;
    --kube-version)   KUBE_VERSION="${2#v}"; shift 2 ;;
    --out)            OUT="$2"; shift 2 ;;
    --no-kubeconform) KUBECONFORM=false; shift ;;
    --strict)         STRICT=true; shift ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  CHARTS+=("${1%/}"); shift ;;
  esac
done
if [[ ${#CHARTS[@]} -eq 0 ]]; then
  echo "usage: $(basename "$0") [--base-values FILES] [--kube-version X.Y.Z] [--out DIR] [--no-kubeconform] [--strict] <chart-dir>..." >&2
  exit 2
fi

if ${KUBECONFORM} && ! command -v kubeconform >/dev/null; then
  echo "::warning title=kubeconform missing::kubeconform is not installed, rendered manifests are not validated"
  KUBECONFORM=false
fi

BASE_ARGS=()
for f in ${BASE_VALUES}; do
  [[ -f "$f" ]] || { echo "::error title=Base values missing::$f does not exist"; exit 1; }
  BASE_ARGS+=(-f "$f")
done

FAILED=()
fail() { echo "::error title=$1::$2"; FAILED+=("$2"); }

group()    { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

# --- dependencies
declare -A REPO_ADDED=()
declare -A BUILT=()

add_repos() {    # add_repos <chart>: helm repo add every http(s) dependency repository
  local url name added=false
  while IFS= read -r url; do
    [[ -n "$url" && -z "${REPO_ADDED[$url]:-}" ]] || continue
    name="okdp-$(printf '%s' "$url" | sha1sum | cut -c1-10)"
    helm repo add --force-update "$name" "$url" >/dev/null && added=true
    REPO_ADDED[$url]=1
  done < <(yq -r '.dependencies[]?.repository // "" | select(test("^https?://"))' "$1/Chart.yaml")
  if ${added}; then helm repo update >/dev/null; fi
}

dep_build() {    # dep_build <chart>: build file:// dependencies first, then the chart
  local chart path
  chart=$(realpath -m "$1")
  [[ -n "${BUILT[$chart]:-}" ]] && return 0
  BUILT[$chart]=1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    dep_build "${chart}/${path#file://}" || return 1
  done < <(yq -r '.dependencies[]?.repository // "" | select(test("^file://"))' "${chart}/Chart.yaml")
  add_repos "${chart}"
  if [[ "$(yq -r '.dependencies | length' "${chart}/Chart.yaml")" != "0" ]]; then
    helm dependency build "${chart}" --skip-refresh
  fi
}

# --- rendering
render() {       # render <chart> <label>: lint + template + kubeconform with each ci values file
  local chart="$1" label="$2" values name out
  local -a files=()
  if compgen -G "${chart}/ci/*-values.yaml" >/dev/null; then
    files=("${chart}"/ci/*-values.yaml)
  else
    files=("")                         # a test chart without ci/: its defaults
  fi
  for values in "${files[@]}"; do
    local -a args=("${BASE_ARGS[@]}")
    if [[ -n "$values" ]]; then
      args+=(-f "$values"); name=$(basename "$values" .yaml)
    else
      name="default"
    fi
    out="${OUT}/${chart}/${name}.yaml"
    mkdir -p "$(dirname "$out")"

    group "${label}: helm lint (${name})"
    helm lint "$chart" "${args[@]}" || fail "helm lint" "${chart} (${name})"
    endgroup

    group "${label}: helm template (${name}) -> ${out}"
    if helm template "$RELEASE" "$chart" --namespace "$NAMESPACE" \
         --kube-version "$KUBE_VERSION" "${args[@]}" > "$out"; then
      echo "$(grep -c '^kind:' "$out") object(s) rendered"
    else
      fail "helm template" "${chart} (${name})"
      endgroup
      continue
    fi
    endgroup

    if ${KUBECONFORM}; then
      group "${label}: kubeconform (${name})"
      local -a kc=(-kubernetes-version "$KUBE_VERSION" -summary -ignore-missing-schemas
                   -schema-location default
                   -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')
      ${STRICT} && kc+=(-strict)
      kubeconform "${kc[@]}" "$out" || fail "kubeconform" "${chart} (${name})"
      endgroup
    fi
  done
}

for chart in "${CHARTS[@]}"; do
  if [[ ! -f "${chart}/Chart.yaml" ]]; then
    fail "Not a chart" "${chart}: no Chart.yaml"
    continue
  fi

  group "${chart}: helm dependency build"
  if ! dep_build "$chart"; then
    endgroup
    fail "helm dependency build" "${chart}"
    continue
  fi
  endgroup

  if [[ "$(yq -r '.type // "application"' "${chart}/Chart.yaml")" == "library" ]]; then
    group "${chart}: helm lint (library)"
    helm lint "$chart" || fail "helm lint" "${chart}"
    endgroup
    for t in "${chart}"/tests/*/; do
      t="${t%/}"
      [[ -f "${t}/Chart.yaml" ]] || continue
      group "${t}: helm dependency build"
      if ! dep_build "$t"; then
        endgroup
        fail "helm dependency build" "${t}"
        continue
      fi
      endgroup
      render "$t" "$t"
    done
  else
    render "$chart" "$chart"
  fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "::error title=Chart tests failed::${#FAILED[@]} failure(s): ${FAILED[*]}"
  exit 1
fi
echo "okdp-chart-test: ${#CHARTS[@]} chart(s) OK"
