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
# Library charts (`type: library`) only get the forbidden-pattern checks, and
# may pass the whole .Capabilities object on (okdp.vendor.render does).
# Helper charts listed in --descriptor-optional are tested through their
# parent chart: they need no descriptor, no ci values, and their schema, if
# any, need not declare global/connections, but it must still be draft-07.
#
# Vendored upstream charts (vendor/<name>/, rendered by okdp.vendor.render)
# are scanned too: their templates/ and those of their library subcharts
# (templates/tests/ and NOTES.txt excepted, the render skips them). A finding
# there fails unless the chart's okdp-guard-allow.yaml allows it (see
# load_allow). vendor/ must match vendor.yaml (name and version of each
# listed chart, nothing unlisted): the offline half of
# platform-packages' `scripts/vendor-charts.sh --check`.
# Dependencies packed under charts/*.tgz are not scanned.
#
# Usage:
#   okdp-chart-guard.sh [--descriptor-optional NAMES] <chart-dir>...
#
#   NAMES   comma or space separated chart names (Chart.yaml `name`) or chart
#           directories that are helper (sub)charts: no descriptor, no ci
#           values, no root global/connections required.
#
# Rule ids, for okdp-guard-allow.yaml: lookup, non-deterministic,
# release-flags, capabilities, hook, templated-hook.
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

# Scan one template file for forbidden constructs. Prints
# "line<TAB>rule<TAB>message" per finding, rule being one of RULES below.
# Template comments ({{/* ... */}}) are removed first, keeping line numbers,
# so documenting a forbidden function is not a finding.
#
#   scan_template <file> [library]
#
# In a library chart, passing the whole .Capabilities object on (as
# okdp.vendor.render does to the vendored templates it renders) is not a
# finding: only a method or field access (.Capabilities.APIVersions...) is.
scan_template() {
  LIBRARY="${2:-}" perl -0777 -ne '
    my $src = $_;
    my $library = $ENV{LIBRARY} ne "";
    # Blank out comments, keep newlines so line numbers stay right.
    $src =~ s{\{\{-?\s*/\*.*?\*/\s*-?\}\}}{ (my $c = $&) =~ s/[^\n]//g; $c }gse;

    my @rules = (
      [ "lookup", qr/(?<![\w.\$])lookup\b/,
        "lookup is forbidden: it returns nothing under helm template (Argo CD)" ],
      [ "non-deterministic", qr/(?<![\w.\$])(rand(?:Alpha(?:Num)?|Ascii|Numeric|Int|Bytes)|uuidv4|now|ago|shuffle|genPrivateKey|genCA(?:WithKey)?|genSelfSignedCert(?:WithKey)?|genSignedCert(?:WithKey)?|htpasswd|bcrypt|encryptAES)\b/,
        "non-deterministic function %s is forbidden: Argo CD would see a diff on every sync (generate secrets with an ESO Password generator + ExternalSecret)" ],
      [ "release-flags", qr/\.Release\.(IsInstall|IsUpgrade)\b/,
        ".Release.%s is forbidden: helm template always reports an install" ],
      [ "capabilities", qr/\.Capabilities\b(?!\.KubeVersion\b)(\.\w+)?/,
        ".Capabilities%s is forbidden: only .Capabilities.KubeVersion is allowed" ],
    );

    # Template actions: {{ ... }}, possibly spanning lines.
    while ($src =~ /\{\{(.*?)\}\}/gs) {
      my ($action, $start) = ($1, $-[0]);
      for my $r (@rules) {
        my ($id, $re, $msg) = @$r;
        while ($action =~ /$re/g) {
          next if $library && $id eq "capabilities" && !defined $1;
          my $off  = $start + 2 + $-[0];
          my $line = 1 + (substr($src, 0, $off) =~ tr/\n//);
          my $arg  = defined $1 ? $1 : "";
          printf "%d\t%s\t%s\n", $line, $id, sprintf($msg, $arg);
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
        print "$n\ttemplated-hook\thelm.sh/hook value is templated and cannot be verified; write the hook names literally\n";
        next;
      }
      for my $h (split /\s*,\s*/, $v) {
        next if $ok{$h};
        print "$n\thook\thook \"$h\" is forbidden: only pre-install, pre-upgrade, post-install and post-upgrade map to Argo CD\n";
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

# --- vendored upstream charts ------------------------------------------------
#
# A wrapper chart renders the upstream charts unpacked under vendor/<name>/
# with okdp.vendor.render (okdp-lib), so their templates are rendered by Argo CD
# too and get the same forbidden-pattern checks. A justified exception goes in
# the wrapper's okdp-guard-allow.yaml:
#
#   - file: vendor/opa-kube-mgmt/templates/_helpers.tpl   # shell pattern, relative
#     pattern: capabilities                               # to the chart; * matches /
#     reason: only used when certManager.enabled, which the wrapper never sets
#   - file: vendor/opa-kube-mgmt/templates/webhookconfiguration.yaml
#     pattern: non-deterministic
#     reason: self-signed webhook certificate, emitted only with the admission controller
#     disabledBy: admissionController.enabled
#
# pattern is a rule id. The rules in STRICT_RULES change the rendered objects
# between Helm and helm template (or between two renders): they can only be
# allowed when the entry names, in disabledBy, the value of the vendored chart
# that disables the code path (and the wrapper must keep it disabled).

RULES="lookup non-deterministic release-flags capabilities hook templated-hook"
STRICT_RULES="lookup non-deterministic release-flags"
US=$'\x1f'   # field separator that `read` does not collapse, unlike a tab

# The valid entries of the current chart's okdp-guard-allow.yaml.
A_FILE=(); A_RULE=(); A_LINE=(); A_USED=()

load_allow() {     # load_allow <chart dir>
  local chart="$1" allow="$1/okdp-guard-allow.yaml" tag
  A_FILE=(); A_RULE=(); A_LINE=(); A_USED=()
  [[ -f "$allow" ]] || return 0
  if ! tag=$(yq -r 'tag' "$allow" 2>/dev/null); then
    report error "$allow" "" "not valid YAML"
    return
  fi
  case "$tag" in
    '!!null') return ;;
    '!!seq')  ;;
    *) report error "$allow" "" "must be a list of {file, pattern, reason[, disabledBy]} entries"; return ;;
  esac
  local line kind extra file rule reason disabled vname
  while IFS="$US" read -r line kind extra file rule reason disabled; do
    if [[ "$kind" != "!!map" ]]; then
      report error "$allow" "$line" "entry must be a map {file, pattern, reason[, disabledBy]}"
      continue
    fi
    local ok=true
    if [[ -n "$extra" ]]; then
      report error "$allow" "$line" "unknown key(s): $extra (allowed: file, pattern, reason, disabledBy)"; ok=false
    fi
    if [[ -z "$file" ]]; then
      report error "$allow" "$line" "file is required (a pattern relative to the chart, e.g. vendor/<name>/templates/x.yaml)"; ok=false
    elif [[ "$file" != vendor/* ]]; then
      report error "$allow" "$line" "file '$file' is not under vendor/: only vendored upstream templates can be allowed, fix the chart's own templates"; ok=false
    fi
    if ! in_list "$rule" "$RULES"; then
      report error "$allow" "$line" "pattern '${rule}' is not a rule id (one of: ${RULES// /, })"; ok=false
    fi
    if [[ -z "${reason//[[:space:]]/}" ]]; then
      report error "$allow" "$line" "reason is required"; ok=false
    fi
    if in_list "$rule" "$STRICT_RULES" && [[ -z "${disabled//[[:space:]]/}" ]]; then
      report error "$allow" "$line" "'$rule' cannot be allowed with a reason alone: disable the code path through the vendored chart's values and name that value in disabledBy"; ok=false
    fi
    ${ok} || continue
    # disabledBy documents a value of the vendored chart: warn when its
    # values.yaml does not know it (typo, or renamed upstream).
    if [[ -n "$disabled" && "$file" =~ ^vendor/([^/*?[]+)/ ]]; then
      vname="${BASH_REMATCH[1]}"
      local vpath="${disabled%%[=[:space:]]*}"
      vpath="${vpath#.Values.}"; vpath="${vpath#.}"
      if [[ -f "$chart/vendor/$vname/values.yaml" ]] && [[ $(yq -o=json '.' "$chart/vendor/$vname/values.yaml" \
          | jq --arg p "$vpath" '[paths | map(tostring) | join(".")] | index($p) != null') != "true" ]]; then
        report warning "$allow" "$line" "disabledBy '$vpath' is not a key of vendor/$vname/values.yaml"
      fi
    fi
    A_FILE+=("$file"); A_RULE+=("$rule"); A_LINE+=("$line"); A_USED+=("")
  done < <(yq -o=json '[.[] | {"line": line, "kind": tag,
             "extra": ((select(tag == "!!map") | keys | map(select(. != "file" and . != "pattern" and . != "reason" and . != "disabledBy")) | join(", ")) // ""),
             "file": ((select(tag == "!!map") | .file) // ""), "pattern": ((select(tag == "!!map") | .pattern) // ""),
             "reason": ((select(tag == "!!map") | .reason) // ""), "disabledBy": ((select(tag == "!!map") | .disabledBy) // "")}]' "$allow" \
           | jq -r --arg us "$US" '.[] | [.line, .kind, .extra, .file, .pattern, .reason, .disabledBy] | map(tostring | gsub("[\n\t]"; " ")) | join($us)')
}

report_unused_allow() {   # report_unused_allow <chart dir>
  local i
  for i in "${!A_FILE[@]}"; do
    [[ -n "${A_USED[$i]}" ]] && continue
    report warning "$1/okdp-guard-allow.yaml" "${A_LINE[$i]}" "unused entry: no '${A_RULE[$i]}' finding in ${A_FILE[$i]}; remove it"
  done
}

# vendored_finding <chart dir> <file> <line> <rule> <message>: an error unless allowed.
vendored_finding() {
  local chart="$1" file="$2" line="$3" rule="$4" msg="$5" rel i allowed=false
  rel="${file#"$chart"/}"
  for i in "${!A_FILE[@]}"; do
    # shellcheck disable=SC2053 # the allow entry's file is a pattern
    if [[ "${A_RULE[$i]}" == "$rule" && "$rel" == ${A_FILE[$i]} ]]; then
      A_USED[i]=1; allowed=true
    fi
  done
  ${allowed} && return
  if in_list "$rule" "$STRICT_RULES"; then
    msg+=" (vendored chart: disable this code path through its values, then add an okdp-guard-allow.yaml entry with pattern '$rule', a reason and disabledBy)"
  else
    msg+=" (vendored chart: if justified, add an okdp-guard-allow.yaml entry with pattern '$rule' and a reason)"
  fi
  report error "$file" "$line" "$msg"
}

# scan_vendored_dir <chart dir> <vendored chart dir> [library]: the templates
# okdp.vendor.render renders (templates/tests/ and NOTES.txt are skipped).
scan_vendored_dir() {
  local chart="$1" dir="$2" lib="${3:-}" f line rule msg
  [[ -d "$dir/templates" ]] || return 0
  while IFS= read -r -d '' f; do
    while IFS=$'\t' read -r line rule msg; do
      [[ -n "$line" ]] && vendored_finding "$chart" "$f" "$line" "$rule" "$msg"
    done < <(scan_template "$f" "$lib")
  done < <(find "$dir/templates" -type f -not -path "$dir/templates/tests/*" -not -name NOTES.txt -print0 | sort -z)
}

guard_vendored() {   # guard_vendored <chart dir>
  local chart="$1" d sub type
  [[ -d "$chart/vendor" ]] || return 0
  for d in "$chart"/vendor/*/; do
    d="${d%/}"
    [[ -f "$d/Chart.yaml" ]] || continue     # reported by check_vendor_manifest
    type=$(yq -r '.type // "application"' "$d/Chart.yaml")
    scan_vendored_dir "$chart" "$d" "$([[ "$type" == library ]] && echo library)"
    for sub in "$d"/charts/*; do
      [[ -e "$sub" ]] || continue
      if [[ -f "$sub" && "$sub" == *.tgz ]]; then
        report error "$sub" "" "packed subchart: okdp.vendor.render only loads unpacked library subcharts (scripts/vendor-charts.sh unpacks them)"
        continue
      fi
      [[ -f "$sub/Chart.yaml" ]] || continue
      if [[ "$(yq -r '.type // "application"' "$sub/Chart.yaml")" != "library" ]]; then
        report error "$sub" "" "vendored chart bundles an application subchart, which okdp.vendor.render refuses: vendor it as a chart of its own"
        continue
      fi
      scan_vendored_dir "$chart" "$sub" library
    done
  done
}

# check_vendor_manifest <chart dir>: vendor/ matches vendor.yaml, offline (the
# semantics of platform-packages' `scripts/vendor-charts.sh --check`, minus the
# download: each listed chart is unpacked under vendor/<name>/ with the listed
# chart name and version, and nothing else is under vendor/).
check_vendor_manifest() {
  local chart="$1" manifest="$1/vendor.yaml" count i name version repo upstream got_name got_version d n
  local -a listed=()
  if [[ ! -f "$manifest" ]]; then
    if compgen -G "$chart/vendor/*/" >/dev/null; then
      report error "$chart/vendor" "" "vendor/ without vendor.yaml: list the vendored charts (name, repository, version) so scripts/vendor-charts.sh can refresh and check them"
    fi
    return 0
  fi
  if [[ "$(yq -r '.charts | tag' "$manifest" 2>/dev/null)" != "!!seq" ]]; then
    report error "$manifest" "" "must have a 'charts' list of {name, repository, version[, chart]}"
    return
  fi
  count=$(yq -r '.charts | length' "$manifest")
  for ((i = 0; i < count; i++)); do
    name=$(yq -r ".charts[$i].name // \"\"" "$manifest")
    version=$(yq -r ".charts[$i].version // \"\"" "$manifest")
    repo=$(yq -r ".charts[$i].repository // \"\"" "$manifest")
    upstream=$(yq -r ".charts[$i].chart // .charts[$i].name // \"\"" "$manifest")
    if [[ -z "$name" || -z "$version" || -z "$repo" ]]; then
      report error "$manifest" "" "charts[$i]: name, repository and version are required"
      continue
    fi
    if [[ " ${listed[*]} " == *" $name "* ]]; then
      report error "$manifest" "" "charts[$i]: '$name' is listed twice"
      continue
    fi
    listed+=("$name")
    if [[ ! -f "$chart/vendor/$name/Chart.yaml" ]]; then
      report error "$manifest" "" "$name $version is listed but $chart/vendor/$name/Chart.yaml is missing: run scripts/vendor-charts.sh $chart"
      continue
    fi
    got_name=$(yq -r '.name // ""' "$chart/vendor/$name/Chart.yaml")
    got_version=$(yq -r '.version // ""' "$chart/vendor/$name/Chart.yaml")
    if [[ "$got_name" != "$upstream" || "$got_version" != "$version" ]]; then
      report error "$chart/vendor/$name/Chart.yaml" "" "is $got_name $got_version, vendor.yaml lists $upstream $version: run scripts/vendor-charts.sh $chart"
    fi
  done
  for d in "$chart"/vendor/*/; do
    [[ -d "$d" ]] || continue
    n=$(basename "$d")
    if [[ " ${listed[*]} " != *" $n "* ]]; then
      report error "$chart/vendor/$n" "" "not listed in vendor.yaml: list it or remove it"
    fi
  done
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

  local f line rule msg lib=""
  [[ "$type" == "library" ]] && lib=library
  if [[ -d "$chart/templates" ]]; then
    while IFS= read -r -d '' f; do
      while IFS=$'\t' read -r line rule msg; do
        [[ -n "$line" ]] && report error "$f" "$line" "$msg"
      done < <(scan_template "$f" "$lib")
    done < <(find "$chart/templates" -type f -print0 | sort -z)
  fi

  # Vendored upstream charts: vendor.yaml consistency, then their templates,
  # with the exceptions of okdp-guard-allow.yaml.
  check_vendor_manifest "$chart"
  load_allow "$chart"
  guard_vendored "$chart"
  report_unused_allow "$chart"

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
