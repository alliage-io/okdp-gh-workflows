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
# okdp-chart-guard.sh: enforce the OKDP chart rules that `helm lint` cannot see.
#
# Every OKDP chart is rendered by Helm under Flux and by `helm template` under
# Argo CD. Anything that behaves differently between the two is forbidden:
#
#   - `lookup`                                   (always empty under helm template)
#   - rand*/uuidv4/now/gen*Cert/htpasswd/...     (non-deterministic: Argo diffs forever)
#   - .Release.IsInstall / .Release.IsUpgrade    (always install under helm template)
#   - .Capabilities other than .KubeVersion      (not the cluster's under helm template)
#   - helm.sh/hook other than pre/post-install and pre/post-upgrade
#
# It also checks, for application charts:
#   - a template includes "okdp.descriptor"      (unless --descriptor-optional)
#   - values.schema.json is draft-07 and declares `global` and `connections`
#     at its root, with no KuboCD-era keywords left
#   - at least one ci/*-values.yaml
#
# Library charts (`type: library`) only get the forbidden-pattern checks.
# Helper charts listed in --descriptor-optional are tested through their
# parent chart: they need no descriptor, no ci values, and their schema, if
# any, need not declare global/connections, but it must still be draft-07.
# Only the chart's own templates/ are scanned: vendored upstream subcharts
# (charts/*.tgz) are not OKDP code.
#
# Usage:
#   okdp-chart-guard.sh [--descriptor-optional NAMES] <chart-dir>...
#
#   NAMES   comma or space separated chart names (Chart.yaml `name`) or chart
#           directories that are helper (sub)charts: no descriptor, no ci
#           values, no root global/connections required.
#
# Exit status: 0 when every chart passes, 1 when any check fails, 2 on usage error.
# Inside GitHub Actions, findings are emitted as ::error/::warning annotations.

set -uo pipefail

usage() {
  echo "usage: $(basename "$0") [--descriptor-optional NAMES] <chart-dir>..." >&2
  exit 2
}

DESCRIPTOR_OPTIONAL=""
CHARTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --descriptor-optional)   [[ $# -ge 2 ]] || usage; DESCRIPTOR_OPTIONAL="$2"; shift 2 ;;
    --descriptor-optional=*) DESCRIPTOR_OPTIONAL="${1#*=}"; shift ;;
    -h|--help)               usage ;;
    --)                      shift; CHARTS+=("$@"); break ;;
    -*)                      echo "unknown option: $1" >&2; usage ;;
    *)                       CHARTS+=("$1"); shift ;;
  esac
done
[[ ${#CHARTS[@]} -gt 0 ]] || usage

for tool in perl jq yq; do
  command -v "$tool" >/dev/null || { echo "okdp-chart-guard: '$tool' is required" >&2; exit 2; }
done

ERRORS=0

# report <error|warning> <file> <line|""> <message>
report() {
  local level="$1" file="$2" line="$3" msg="$4"
  [[ "$level" == "error" ]] && ERRORS=$(( ERRORS + 1 ))
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::${level} file=${file}${line:+,line=${line}},title=okdp-chart-guard::${msg}"
  else
    echo "${file}${line:+:${line}}: ${level}: ${msg}"
  fi
}

# Scan one template file for forbidden constructs. Prints "line<TAB>message"
# per finding. Template comments ({{/* ... */}}) are removed first, keeping
# line numbers, so documenting a forbidden function is not a finding.
scan_template() {
  perl -0777 -ne '
    my $src = $_;
    # Blank out comments, keep newlines so line numbers stay right.
    $src =~ s{\{\{-?\s*/\*.*?\*/\s*-?\}\}}{ (my $c = $&) =~ s/[^\n]//g; $c }gse;

    my @rules = (
      [ qr/(?<![\w.\$])lookup\b/,
        "lookup is forbidden: it returns nothing under helm template (Argo CD)" ],
      [ qr/(?<![\w.\$])(rand(?:Alpha(?:Num)?|Ascii|Numeric|Int|Bytes)|uuidv4|now|ago|shuffle|genPrivateKey|genCA(?:WithKey)?|genSelfSignedCert(?:WithKey)?|genSignedCert(?:WithKey)?|htpasswd|bcrypt|encryptAES)\b/,
        "non-deterministic function %s is forbidden: Argo CD would see a diff on every sync (generate secrets with an ESO Password generator + ExternalSecret)" ],
      [ qr/\.Release\.(IsInstall|IsUpgrade)\b/,
        ".Release.%s is forbidden: helm template always reports an install" ],
      [ qr/\.Capabilities\b(?!\.KubeVersion\b)(\.\w+)?/,
        ".Capabilities%s is forbidden: only .Capabilities.KubeVersion is allowed" ],
    );

    # Template actions: {{ ... }}, possibly spanning lines.
    while ($src =~ /\{\{(.*?)\}\}/gs) {
      my ($action, $start) = ($1, $-[0]);
      for my $r (@rules) {
        my ($re, $msg) = @$r;
        while ($action =~ /$re/g) {
          my $off  = $start + 2 + $-[0];
          my $line = 1 + (substr($src, 0, $off) =~ tr/\n//);
          my $arg  = defined $1 ? $1 : "";
          printf "%d\t%s\n", $line, sprintf($msg, $arg);
        }
      }
    }

    # Hooks, in the literal text of the manifest.
    my %ok = map { $_ => 1 } qw(pre-install pre-upgrade post-install post-upgrade);
    my $n = 0;
    for my $l (split /\n/, $src, -1) {
      $n++;
      next unless $l =~ /["\x27]?helm\.sh\/hook["\x27]?\s*:\s*(.*)$/;
      my $v = $1;
      $v =~ s/\s+#.*$//;
      $v =~ s/^\s*["\x27]?|["\x27]?\s*$//g;
      if ($v =~ /\{\{/) {
        print "$n\thelm.sh/hook value is templated and cannot be verified; write the hook names literally\n";
        next;
      }
      for my $h (split /\s*,\s*/, $v) {
        next if $ok{$h};
        print "$n\thook \"$h\" is forbidden: only pre-install, pre-upgrade, post-install and post-upgrade map to Argo CD\n";
      }
    }
  ' "$1"
}

in_list() {        # in_list <needle> <comma/space separated list>
  local needle="$1" item
  for item in ${2//,/ }; do
    [[ "${item%/}" == "${needle%/}" ]] && return 0
  done
  return 1
}

has_descriptor() {  # has_descriptor <chart dir>: a template includes okdp.descriptor
  [[ -d "$1/templates" ]] || return 1
  local found
  found=$(find "$1/templates" -type f -print0 \
    | xargs -0 -r perl -0777 -ne 's{\{\{-?\s*/\*.*?\*/\s*-?\}\}}{}gs; print "found\n" if /\{\{-?\s*(?:include|template)\s+"okdp\.descriptor"/')
  [[ -n "$found" ]]
}

check_schema() {   # check_schema <chart dir> [helper]
  local chart="$1" schema="$1/values.schema.json" s helper="${2:-}"
  if [[ ! -f "$schema" ]]; then
    report error "$schema" "" "missing values.schema.json (JSON Schema draft-07)"
    return
  fi
  if ! jq empty "$schema" 2>/dev/null; then
    report error "$schema" "" "not valid JSON"
    return
  fi
  s=$(jq -r '."$schema" // ""' "$schema")
  if [[ ! "$s" =~ ^https?://json-schema\.org/draft-07/schema#?$ ]]; then
    report error "$schema" "" "\$schema must be http://json-schema.org/draft-07/schema# (found '${s:-none}')"
  fi
  local key
  [[ -n "$helper" ]] || for key in global connections; do
    if [[ $(jq --arg k "$key" '(.properties // {}) | has($k)' "$schema") != "true" ]]; then
      report error "$schema" "" "root properties must declare '$key' (do not rely on additionalProperties)"
    fi
  done
  local kubocd
  kubocd=$(jq -r '[paths | map(tostring) | last | select(startswith("x-kubocd"))] | unique | join(", ")' "$schema")
  if [[ -n "$kubocd" ]]; then
    report error "$schema" "" "KuboCD keywords left: $kubocd (use x-okdp-connection-ref / x-ui-*)"
  fi
  local dsl
  dsl=$(jq -r '[.. | objects | .title? | strings | select(test("\\|.*\\|"))] | first // empty' "$schema")
  if [[ -n "$dsl" ]]; then
    report warning "$schema" "" "title '$dsl' looks like the KuboCD title DSL; translate it to title + x-ui-* keywords"
  fi
}

guard_chart() {    # guard_chart <chart dir>
  local chart="${1%/}" chartfile="${1%/}/Chart.yaml"
  if [[ ! -f "$chartfile" ]]; then
    report error "$chart" "" "not a chart: no Chart.yaml"
    return
  fi
  local name type
  name=$(yq -r '.name // ""' "$chartfile")
  type=$(yq -r '.type // "application"' "$chartfile")

  local f line msg
  if [[ -d "$chart/templates" ]]; then
    while IFS= read -r -d '' f; do
      while IFS=$'\t' read -r line msg; do
        [[ -n "$line" ]] && report error "$f" "$line" "$msg"
      done < <(scan_template "$f")
    done < <(find "$chart/templates" -type f -print0 | sort -z)
  fi

  [[ "$type" == "library" ]] && return

  # Helper (sub)charts are tested through their parent chart: no descriptor,
  # no root global/connections, no ci values of their own. A schema they
  # ship must still be draft-07.
  if in_list "$name" "$DESCRIPTOR_OPTIONAL" || in_list "$chart" "$DESCRIPTOR_OPTIONAL"; then
    [[ -f "$chart/values.schema.json" ]] && check_schema "$chart" helper
    return
  fi

  if ! has_descriptor "$chart"; then
    report error "$chartfile" "" "service chart '$name' does not render the instance descriptor: add {{ include \"okdp.descriptor\" . }} (or list it in descriptor-optional if it is a helper chart)"
  fi

  check_schema "$chart"

  if ! compgen -G "$chart/ci/*-values.yaml" >/dev/null; then
    report error "$chart" "" "no ci/*-values.yaml test values file"
  fi
}

for c in "${CHARTS[@]}"; do
  guard_chart "$c"
done

if [[ $ERRORS -gt 0 ]]; then
  echo "okdp-chart-guard: ${ERRORS} error(s) in ${#CHARTS[@]} chart(s)" >&2
  exit 1
fi
echo "okdp-chart-guard: ${#CHARTS[@]} chart(s) OK"
