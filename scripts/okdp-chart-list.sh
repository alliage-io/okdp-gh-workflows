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
# okdp-chart-list.sh: print the chart directories a CI run must process, one per line.
#
# Run from the repository root. Selection, first match wins:
#
#   --paths JSON  a release: the JSON array of directories release-please
#                 released (its paths_released output). Each must hold a
#                 Chart.yaml. "" or "[]" means "not a release", fall through.
#   --all         every chart.
#   --base REF    the charts changed between REF and HEAD. A chart is changed
#                 when a file under it changed, or under one of its file://
#                 dependencies (transitively, within the repository), so a
#                 library change re-tests its consumers. A change under
#                 .github/workflows/ or .github/actions/ selects every chart.
#                 A REF that is empty, all zeros (new branch) or unknown
#                 selects every chart.
#   (nothing)     every chart.
#
# "Every chart" is each directory holding a Chart.yaml under the roots
# (--roots, default "packages charts"), excluding charts nested in another
# chart (vendored subcharts, test charts under <chart>/tests/).

set -euo pipefail

ROOTS="packages charts"
PATHS=""
BASE=""
ALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --roots) ROOTS="$2"; shift 2 ;;
    --paths) PATHS="$2"; shift 2 ;;
    --base)  BASE="$2";  shift 2 ;;
    --all)   ALL=true;   shift ;;
    *) echo "usage: $(basename "$0") [--roots DIRS] [--paths JSON] [--base REF] [--all]" >&2; exit 2 ;;
  esac
done

# --- a release: exactly what release-please released
if [[ -n "${PATHS}" && "${PATHS}" != "[]" ]]; then
  rc=0
  while IFS= read -r dir; do
    dir="${dir%/}"
    if [[ -f "${dir}/Chart.yaml" ]]; then
      echo "${dir}"
    else
      echo "::error title=No chart::${dir} was released but holds no Chart.yaml" >&2
      rc=1
    fi
  done < <(jq -r '.[]' <<<"${PATHS}")
  exit "${rc}"
fi

# --- every top-level chart under the roots
all_charts() {
  local root f dir parent nested
  for root in ${ROOTS}; do
    [[ -d "${root}" ]] || continue
    while IFS= read -r f; do
      dir=$(dirname "${f}")
      nested=false
      parent=$(dirname "${dir}")
      while [[ "${parent}" != "." && "${parent}" != "/" ]]; do
        if [[ -f "${parent}/Chart.yaml" ]]; then nested=true; break; fi
        parent=$(dirname "${parent}")
      done
      ${nested} || echo "${dir}"
    done < <(find "${root}" -name Chart.yaml -not -path '*/.git/*' | sort)
  done | sort -u
}

if ${ALL} || [[ -z "${BASE}" || "${BASE}" =~ ^0+$ ]] || ! git rev-parse -q --verify "${BASE}^{commit}" >/dev/null; then
  all_charts
  exit 0
fi

mapfile -t CHANGED < <(git diff --name-only "${BASE}...HEAD")

for f in "${CHANGED[@]}"; do
  if [[ "${f}" == .github/workflows/* || "${f}" == .github/actions/* ]]; then
    all_charts
    exit 0
  fi
done

TOP=$(pwd -P)

# local_deps <chart dir>: repository-relative dirs of its file:// dependencies, transitively
local_deps() {
  local chart="$1" repo abs rel
  yq -r '.dependencies[]?.repository // "" | select(test("^file://"))' "${chart}/Chart.yaml" 2>/dev/null \
  | while IFS= read -r repo; do
      abs=$(realpath -m "${chart}/${repo#file://}")
      [[ "${abs}" == "${TOP}/"* ]] || continue          # outside the repository: cannot diff it
      rel="${abs#"${TOP}"/}"
      [[ -f "${rel}/Chart.yaml" ]] || continue
      echo "${rel}"
      local_deps "${rel}"
    done
}

changed_under() {  # changed_under <dir>
  local f
  for f in "${CHANGED[@]}"; do
    [[ "${f}" == "$1/"* ]] && return 0
  done
  return 1
}

while IFS= read -r chart; do
  for dir in "${chart}" $(local_deps "${chart}"); do
    if changed_under "${dir}"; then
      echo "${chart}"
      break
    fi
  done
done < <(all_charts)
