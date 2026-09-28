[![License Apache2](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](http://www.apache.org/licenses/LICENSE-2.0)
[![release-please](https://github.com/okdp/gh-workflows/actions/workflows/release-please.yml/badge.svg)](https://github.com/okdp/gh-workflows/actions/workflows/release-please.yml)
<p align="center">
    <img width="400px" height=auto src="https://okdp.io/logos/okdp-inverted.png" />
</p>

Collection of github actions [reusable workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows) and [actions](https://docs.github.com/en/actions/creating-actions/about-custom-actions#about-custom-actions) shared by the OKDP platform components (helm charts, docker images, etc)

# Using the reusable workflows

The example below shows how to reuse the workflow ```helm-lint.yml``` with the version ```main``` in your github repository:

```console
name: ci 
on:
  push:
jobs:
  ci:
    name: ci
    uses: okdp/workflows/.github/gh-workflows/helm-lint-template.yml@v1
```

# OKDP chart CI (`okdp-chart-ci.yml`)

Reusable workflow that tests and publishes the OKDP Helm charts of a chart repository
(`platform-packages`, `community-packages`, `sandbox-dependencies`). It replaces the KuboCD
package template those repositories carried, with the same inputs where they still make
sense, so the callers change little more than the `uses:` line.

For every selected chart it runs:

1. for a chart with a `vendor.yaml`: the calling repository's
   `scripts/vendor-charts.sh <chart>`, which downloads the pinned upstream charts under
   `vendor/` (not committed), so the steps below and `helm package` see them. On a push or a
   pull request that changes a `vendor.yaml`, the diff of `vendor/` against the base commit
   is printed in the job log (and summarised in the job summary) for the review;
2. `scripts/okdp-chart-guard.sh`: the OKDP chart rules `helm lint` cannot see (below);
3. `check-jsonschema --check-metaschema` on `values.schema.json`;
4. `scripts/okdp-chart-test.sh`: `helm dependency build`, then `helm lint` and
   `helm template` with each `ci/*-values.yaml` (layered over `base_values`), then
   `kubeconform` on the rendered output. A library chart is linted, and its test charts
   in `<chart>/tests/*/` are rendered and validated. Every render is also done with
   Helm 3 and Helm 4 and must give the same objects (see "Helm 3 / Helm 4 compare");
5. when every check passed, `helm package` + `helm push`:

| Mode | `publish_to_registry` | Charts | Pushed to | Version |
| --- | --- | --- | --- | --- |
| CI | `"false"` | changed by the push / pull request | `oci://<ci_registry>/<owner>/<repo>/charts` | `0.0.0-ci.<branch>.g<sha7>` |
| Release | `"true"` | `package_paths`, or every chart when empty | `oci://<registry>/<owner>/<oci_package_prefix>` | `Chart.yaml` `version` |

A chart is *changed* when a file under it changed, or under one of its `file://`
dependencies (so changing `charts/okdp-lib` re-tests every chart that embeds it). A change
under `.github/workflows/` or `.github/actions/`, a new branch, or `workflow_dispatch`
selects every chart.

On release, a version already on the registry is never overwritten (`on_existing_tag`), and
a `Chart.yaml` version that does not end with the release-please version of its path in
`.release-please-manifest.json` fails the job.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `publish_to_registry` | `"false"` | `"false"`: CI run, push to `ci_registry`. `"true"`: release, push to `registry`. |
| `registry` | `quay.io` | Release registry. |
| `ci_registry` | `ghcr.io` | CI registry. |
| `oci_package_prefix` | `""` | Release repository under the owner: `platform-charts`, `community-charts` or `sandbox-charts`. Required to publish a release. |
| `on_existing_tag` | `skip` | Release only. `skip` leaves a published version alone and publishes the rest; `fail` stops the job. |
| `package_paths` | `""` | JSON array of chart directories (release-please `paths_released`). Empty or `[]`: changed charts (CI) or every chart (release). |
| `all_charts` | `false` | Process every chart, not only the changed ones. |
| `chart_roots` | `packages charts` | Directories searched for charts (`Chart.yaml`, nested charts excluded). |
| `descriptor_optional` | `""` | Helper (sub)charts (names or directories, comma or space separated), tested through their parent chart: no `okdp.descriptor`, no `ci/*-values.yaml`, no root `global`/`connections` required (a `values.schema.json` they ship must still be draft-07). Library charts are exempt on their own. |
| `base_values` | `""` | Values files layered before each `ci/*-values.yaml`, e.g. a platform-values fixture providing `global.okdp`. |
| `kubernetes_version` | `1.31.0` | `helm template --kube-version` and `kubeconform -kubernetes-version`. |
| `kubeconform_strict` | `false` | `kubeconform -strict` (reject unknown fields). |
| `push` | `true` | `false` validates only (e.g. pull requests from forks). |
| `sibling_repositories` | `""` | `owner/repo@ref` list cloned as `../<repo>`, for `file://` dependencies on another repository during the migration, e.g. `OKDP/platform-packages@no-kubocd`. |
| `helm_version` | `v3.21.4` | Helm version of dependency build, lint, template and package. |
| `helm_compare` | `true` | Render every ci values file with Helm 3 and Helm 4 too and fail when the objects differ. |
| `helm3_version` | `v3.19.4` | Helm 3 of the compare: the Helm Argo CD 3.4 embeds (`hack/tool-versions.sh`, `helm3_version=3.19.4`, v3.4.0 to v3.4.9). |
| `helm4_version` | `v4.2.4` | Helm 4 of the compare: the Helm SDK of Flux helm-controller v1.6.4 (Flux v2.9, `helm.sh/helm/v4 v4.2.4` in its `go.mod`). |
| `tools_repository` | `OKDP/gh-workflows` | Where the `scripts/okdp-chart-*.sh` come from. |
| `tools_ref` | `v1` | Ref of `tools_repository` for the scripts. Keep it equal to the ref in `uses:`. |
| `runs-on` | `ubuntu-latest` | Runner. |

Secrets: `REGISTRY_USERNAME` and `REGISTRY_ROBOT_TOKEN` (release registry, release only;
`secrets: inherit` works). The calling job must grant `contents: read` and
`packages: write` (the CI registry is written with `GITHUB_TOKEN`).

Outputs: `charts` (directories processed), `version` (CI version), `repository`
(`oci://…` pushed to).

## Callers

CI, on push and pull request (`.github/workflows/ci.yml`):

```yaml
jobs:
  charts:
    permissions:
      contents: read
      packages: write
    uses: OKDP/gh-workflows/.github/workflows/okdp-chart-ci.yml@v1
    with:
      publish_to_registry: "false"
      # pull requests from forks cannot write packages: validate only
      push: ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository }}
      descriptor_optional: "oidc-client internal-secrets"
```

Release, after release-please (`.github/workflows/release-please.yml`):

```yaml
  publish:
    needs: [release-please]
    if: needs.release-please.outputs.paths_released != '[]'
    permissions:
      contents: read
      packages: write
    uses: OKDP/gh-workflows/.github/workflows/okdp-chart-ci.yml@v1
    with:
      publish_to_registry: "true"
      oci_package_prefix: platform-charts      # community-charts, sandbox-charts
      on_existing_tag: "fail"
      package_paths: ${{ needs.release-please.outputs.paths_released }}
      descriptor_optional: "oidc-client internal-secrets"
    secrets: inherit
```

Manual republish (`.github/workflows/publish.yml`, `workflow_dispatch`): same as the
release job without `package_paths` and with `on_existing_tag: "skip"`; add
`packages: write` to the job permissions.

To keep taking `oci_package_prefix` from the repository's values file through its
`oci-package-prefix` action, set `packageRepository` to the release repository
(e.g. `quay.io/okdp/platform-charts`).

Notes for the chart repositories:

- **Composite version.** The chart `version` is `<upstream>-<okdp semver>`. release-please
  owns the OKDP half in `.release-please-manifest.json`; the repository's
  `compose-oci-tag.sh` must now rewrite `version:` in `<path>/Chart.yaml` (instead of
  `tag:` in the KuboCD manifest). The release job refuses a `Chart.yaml` whose version does
  not end with `-<manifest version>`.
- **Charts outside release-please.** A chart under `charts/` (e.g. `okdp-lib`) is released
  only if it has its own entry in `release-please-config.json`. Its consumers are
  re-tested by CI when it changes, but not re-released: keep the `shared-chart-consumers`
  check, or bump the consumers.

## OKDP chart rules (`scripts/okdp-chart-guard.sh`)

Every OKDP chart is rendered by Helm under Flux and by `helm template` under Argo CD. The
guard fails on what behaves differently between the two, in the chart's own `templates/`
and in the vendored upstream charts (template comments are ignored). Each rule has an id,
used by `okdp-guard-allow.yaml` (below):

- `lookup` (`lookup`);
- non-deterministic functions: `rand*`, `uuidv4`, `now`, `ago`, `shuffle`, `genCA`,
  `genPrivateKey`, `gen*Cert`, `htpasswd`, `bcrypt`, `encryptAES` (`non-deterministic`);
- `.Release.IsInstall`, `.Release.IsUpgrade` (`release-flags`);
- `.Capabilities` other than `.Capabilities.KubeVersion` (`capabilities`). A library chart
  may pass the whole `.Capabilities` object on (`okdp-lib`'s `okdp.vendor.render` does);
  any field or method access is still refused;
- `helm.sh/hook` other than `pre-install`, `pre-upgrade`, `post-install`, `post-upgrade`
  (`hook`); a templated hook value is refused too (`templated-hook`).

For application charts, it also requires:

- a template including `okdp.descriptor` (unless listed in `descriptor_optional`);
- `values.schema.json` with `$schema` draft-07, `global` and `connections` declared in the
  root `properties`, and no `x-kubocd-*` keyword left (a KuboCD title DSL `A | B | C` is a
  warning);
- at least one `ci/*-values.yaml`.

Helper (sub)charts listed in `descriptor_optional` (`--descriptor-optional`) are tested
through their parent chart: they need no descriptor, no `ci/*-values.yaml`, and no root
`global`/`connections`. A `values.schema.json` they ship must still be draft-07 (and free of
`x-kubocd-*`), and the forbidden-pattern checks apply to them as to every chart. Without
`ci/`, `okdp-chart-test.sh` renders a helper chart with its default values.

### Vendored upstream charts

A wrapper chart that renders upstream charts with `okdp.vendor.render` lists them in
`vendor.yaml`; `scripts/vendor-charts.sh` downloads them unpacked under `vendor/<name>/`,
which is not committed (the workflow downloads them before the guard). The guard:

- checks `vendor/` against `vendor.yaml`, offline: each listed chart is under
  `vendor/<name>/` with the listed `Chart.yaml` name (`chart`, default `name`) and
  `version`, nothing unlisted is under `vendor/`, and `vendor/` without `vendor.yaml` is an
  error. Entries take only `name`, `repository`, `version`, `chart` and `drop`. `drop` is a
  list of paths relative to `vendor/<name>/` (e.g. `[charts/postgresql]`, no `..`, not
  absolute) that must be absent; a bare subchart name (`[postgresql]`) is reported with the
  `charts/` path to write. `vendor/` must not be tracked by git (in a git work tree).
  (`scripts/vendor-charts.sh`, canonical copy in `platform-packages`, is what the workflow
  runs to download it.) Packed (`charts/*.tgz`) and application subcharts under
  `vendor/<name>/charts/` are refused, as the render refuses them (`drop` the ones the
  wrapper never enables);
- scans `vendor/<name>/templates/` and the templates of its library subcharts
  (`vendor/<name>/charts/*/templates/`), except `templates/tests/` and `NOTES.txt`, which
  the render skips. A finding fails unless the chart's `okdp-guard-allow.yaml` allows it.

`okdp-guard-allow.yaml`, at the chart root, is a list of exceptions:

```yaml
- file: vendor/opa-kube-mgmt/templates/servicemonitor.yaml   # shell pattern, relative to
  pattern: capabilities                                      # the chart (* matches /)
  reason: guarded by serviceMonitor.enabled, false upstream and never set by the wrapper
- file: vendor/opa-kube-mgmt/templates/webhookconfiguration.yaml
  pattern: non-deterministic
  reason: genCA/genSignedCert are only emitted with the admission controller
  disabledBy: admissionController.enabled=false
```

- `file` must be under `vendor/`: the chart's own templates cannot be allowed.
- `pattern` is a rule id; `reason` is required.
- `lookup`, `non-deterministic` and `release-flags` change what is rendered between Helm and
  `helm template`: they are allowed only with `disabledBy`, the value of the vendored
  chart that disables that code path (the wrapper must keep it so). The guard warns when
  that key is not in `vendor/<name>/values.yaml`. `capabilities`, `hook` and
  `templated-hook` need a reason only.
- An entry that allows nothing is a warning (remove it).

## Helm 3 / Helm 4 compare

Argo CD renders a chart with the `helm` binary it embeds (Helm 3: v3.19.4 in Argo CD 3.4);
Flux helm-controller renders it with the Helm 4 SDK (v4.2.4 in helm-controller v1.6.4). The
same chart and values must give the same objects under both engines (shared contract,
requirement 3), so `okdp-chart-test.sh` renders each ci values file again with both
binaries (`--helm3`, `--helm4`, same arguments) and fails the chart when the objects
differ, printing a diff (`helm3 (Argo CD)` / `helm4 (Flux)`). Raw renders go to
`<out>/<chart>/helm-compare/<values>.helm{3,4}.yaml`, the compared objects to
`<values>.helm{3,4}.objects.yaml`.

The outputs are parsed and compared as objects, not as text. Normalised, because it
cannot reach the cluster (both engines apply the parsed objects):

- comments (`# Source: …`), document separators, empty documents;
- whitespace outside values, key order, quoting style;
- the order of the documents: Helm sorts the manifests by kind before installing them,
  Argo CD orders them by sync wave and kind.

Nothing else: every value is compared as parsed, trailing blanks and newlines of strings
included. Known cause of a difference: Helm 3 trims the blanks at the end of every
document, Helm 4 only at the end of a template's output. A value that ends a document
followed by another document of the same template, such as a block scalar ending with a
trailing space or a `|+` block, then differs (sandbox-dependencies dns-server, whose
vendored ConfigMap ended with `no-hosts `: the wrapper strips trailing blanks from the
vendored output). Fix the chart so both render the same object; `--no-helm-compare`
(`helm_compare: false`) skips the compare.

## Running the checks locally

From the chart repository root, with `helm`, `yq`, `jq`, `perl`, a Helm 3 and a Helm 4
binary for the compare (`helm3` / `helm4` on the `PATH`, or `$HELM3` / `$HELM4`, or
`--helm3` / `--helm4`; see `helm3_version` / `helm4_version`), and optionally
`kubeconform`:

```console
GHW=../gh-workflows   # a checkout of this repository
$GHW/scripts/okdp-chart-list.sh --base origin/main          # charts changed on this branch
$GHW/scripts/okdp-chart-guard.sh --descriptor-optional oidc-client packages/services/trino
$GHW/scripts/okdp-chart-test.sh packages/services/trino     # rendered into ./.okdp-rendered
```

This repository's own tests: `tests/guard/run.sh` (guard against the fixture charts in
`tests/guard/fixtures/`), `tests/list/run.sh` (chart selection) and
`tests/compare/run.sh` (the Helm 3 / Helm 4 compare; needs `helm3` and `helm4`).
