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
#      in <chart>/tests/*/ (a test chart without ci/ renders its defaults);
#   3. Helm 3 / Helm 4 compare: each of those renders again with a Helm 3
#      binary (Argo CD renders with the Helm 3 it embeds) and a Helm 4 binary
#      (the Flux helm-controller is built on the Helm 4 SDK), same arguments;
#      the chart fails when the two produce different objects. Known cause:
#      Helm 3 trims the blanks at the end of every document, Helm 4 only at
#      the end of a template's output, so a value ending a document that
#      another document of the same template follows (a block scalar with a
#      trailing space, |+) differs.
#
# The compare parses both outputs and compares the objects, not the text. It
# normalises only what cannot reach the cluster: comments (`# Source:`),
# document separators, empty documents, whitespace outside values, key order
# and quoting style (the engines apply the parsed objects), and the order of
# the documents (Helm sorts the manifests by kind before installing them and
# Argo CD orders them by sync wave and kind). Every value is compared as
# parsed, trailing blanks and newlines of strings included.
#
# Rendered manifests are written to <out>/<chart path>/<values name>.yaml, the
# compare renders to <out>/<chart path>/helm-compare/<values name>.helm{3,4}.yaml.
# A failing chart does not stop the others; every failure is reported.
#
# Usage:
#   okdp-chart-test.sh [--base-values "FILE..."] [--kube-version X.Y.Z]
#                      [--out DIR] [--no-kubeconform] [--strict]
#                      [--helm3 BIN] [--helm4 BIN] [--no-helm-compare] <chart-dir>...
#
#   --base-values   values files layered before each ci file (e.g. a
#                   platform-values fixture), in order
#   --kube-version  Kubernetes version for helm template and kubeconform (default 1.31.0)
#   --out           where rendered manifests go (default ./.okdp-rendered)
#   --no-kubeconform  skip kubeconform (it is skipped with a warning when absent)
#   --strict        kubeconform -strict (reject unknown fields)
#   --helm3, --helm4  the Helm 3 and Helm 4 binaries of the compare (default:
#                   $HELM3 / $HELM4, else helm3 / helm4 on the PATH). Each must
#                   report its major version; a missing one is an error.
#   --no-helm-compare  skip the Helm 3 / Helm 4 compare

set -uo pipefail

BASE_VALUES=""
KUBE_VERSION="1.31.0"
OUT=".okdp-rendered"
KUBECONFORM=true
STRICT=false
COMPARE=true
HELM3="${HELM3:-helm3}"
HELM4="${HELM4:-helm4}"
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
    --helm3)          HELM3="$2"; shift 2 ;;
    --helm4)          HELM4="$2"; shift 2 ;;
    --no-helm-compare) COMPARE=false; shift ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  CHARTS+=("${1%/}"); shift ;;
  esac
done
if [[ ${#CHARTS[@]} -eq 0 ]]; then
  echo "usage: $(basename "$0") [--base-values FILES] [--kube-version X.Y.Z] [--out DIR] [--no-kubeconform] [--strict] [--helm3 BIN] [--helm4 BIN] [--no-helm-compare] <chart-dir>..." >&2
  exit 2
fi

if ${KUBECONFORM} && ! command -v kubeconform >/dev/null; then
  echo "::warning title=kubeconform missing::kubeconform is not installed, rendered manifests are not validated"
  KUBECONFORM=false
fi

if ${COMPARE}; then
  for pair in "3:${HELM3}" "4:${HELM4}"; do
    major="${pair%%:*}"; bin="${pair#*:}"
    if ! command -v "$bin" >/dev/null; then
      echo "::error title=Helm ${major} missing::${bin} not found: pass --helm${major} (or set HELM${major}), or --no-helm-compare"
      exit 2
    fi
    version=$("$bin" version --template '{{.Version}}' 2>/dev/null)
    if [[ "$version" != "v${major}."* ]]; then
      echo "::error title=Helm ${major} expected::${bin} reports '${version}', not Helm ${major}"
      exit 2
    fi
    echo "Helm ${major} compare binary: ${bin} (${version})"
  done
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

# --- Helm 3 / Helm 4 compare
canonical() {    # canonical <manifests>: the objects, keys sorted, ordered by apiVersion/kind/namespace/name
  yq ea -o=json -I=0 '[select(. != null)] | sort_by(.apiVersion, .kind, .metadata.namespace, .metadata.name) | .[]' "$1" \
    | yq -p=json -o=yaml -P 'sort_keys(..)'
}

compare() {      # compare <chart> <name> <helm template args...>: render with Helm 3 and Helm 4, diff the objects
  local chart="$1" name="$2" dir major bin
  shift 2
  dir="${OUT}/${chart}/helm-compare"
  mkdir -p "$dir"
  for major in 3 4; do
    bin=HELM${major}
    if ! "${!bin}" template "$RELEASE" "$chart" --namespace "$NAMESPACE" \
         --kube-version "$KUBE_VERSION" "$@" > "${dir}/${name}.helm${major}.yaml"; then
      fail "helm ${major} template" "${chart} (${name})"
      return
    fi
    if ! canonical "${dir}/${name}.helm${major}.yaml" > "${dir}/${name}.helm${major}.objects.yaml"; then
      fail "helm ${major} output unreadable" "${chart} (${name})"
      return
    fi
  done
  if diff -u --label "helm3 (Argo CD)" --label "helm4 (Flux)" \
       "${dir}/${name}.helm3.objects.yaml" "${dir}/${name}.helm4.objects.yaml"; then
    echo "same objects under Helm 3 and Helm 4"
  else
    fail "Helm 3 and Helm 4 render different objects" "${chart} (${name})"
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

    if ${COMPARE}; then
      group "${label}: Helm 3 / Helm 4 compare (${name})"
      compare "$chart" "$name" "${args[@]}"
      endgroup
    fi

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
