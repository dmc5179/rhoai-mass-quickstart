# Working in this repository

Push-button OpenShift on AWS with RHOAI Models-as-a-Service. Plain shell
scripts for the cluster, AutoShift policies for everything on it.

Read [docs/running-under-autoshift.md](docs/running-under-autoshift.md) before
changing anything policy-related. It is the expensive knowledge.

## Two repositories

| | |
|---|---|
| this repo | scripts, CloudFormation, docs. Branch `main`. |
| `$AUTOSHIFT_DIR` (`~/workspace/autoshiftv2-mine`) | fork of `auto-shift/autoshiftv2`, branch `rhoai-maas`. All policies live here. |

**Policies are read from Git, never from the working copy.** An edit in
`$AUTOSHIFT_DIR` does nothing until it is committed and pushed. Values files
are the opposite — read locally by helm at install time, so they need a
`bootstrap`, not a push.

## Resource names ACM shadows

Once ACM is installed it brings in Cluster API and `app.k8s.io`, which serve
resources with the same short names. `oc` resolves the ambiguous name to the
wrong one and reports "No resources found" or silently does nothing. Always
fully qualify:

```bash
oc get machines.machine.openshift.io -n openshift-machine-api
oc get machinesets.machine.openshift.io -n openshift-machine-api
oc annotate applications.argoproj.io <app> -n openshift-gitops ...
```

This has caused real bugs three times. AutoShift's own hub templates spell out
`lookup "machine.openshift.io/v1beta1" "MachineSet"` for the same reason;
that explicitness is load-bearing, not stylistic.

## Phase order

```
00-init            fetch oc, openshift-install, helm
10-deploy-cluster  CloudFormation VPC + installer
20-deploy-maas     imperative MaaS (superseded by policies; kept for non-AutoShift use)
35-smoke-test
40-lightspeed
45-autoshift-values   per-cluster values. BEFORE 50 — helm reads values at install time
50-autoshift       bootstrap | adopt | status | refresh | uninstall
90-destroy-cluster
```

`adopt` is the irreversible step, not `bootstrap`. It activates every enabled
policy at once, and `pruneObjectBehavior: None` means turning a label back off
stops reconciliation without uninstalling anything.

## Diagnostics before ad-hoc `oc`

```bash
scripts/checkup.sh                        # whole chain, names the first break
scripts/check-operator-install-modes.sh   # OperatorGroup scope vs each CSV
scripts/autoshift-feature.sh status       # which capabilities are on
scripts/50-autoshift.sh refresh           # pull policy changes from Git now
```

## Failures that report success

The recurring shape in this stack. Each of these was found on a cluster, not
by a test:

- **An unplaced policy has no status at all.** It appears in no list of
  NonCompliant policies. `checkup.sh` reports Placements where every
  enablement label matches and one other predicate does not.
- **A `ConfigurationPolicy` naming a CRD that does not exist yet reports
  Compliant.** This is why the policy graph uses `dependencies` rather than
  waits.
- **An `object-templates-raw` block that resolves to an empty string applies
  nothing and reports Compliant.** `make test` fails the build on this.
- **An operator whose CSV declares `AllNamespaces=false`** cannot install with
  the shared chart's default OperatorGroup. The CSV sits in `Failed` with
  `UnsupportedOperatorGroup` while the policy reports only that the CSV was not
  found. Six instances so far.
- **A GPU node with no driver is Ready and schedulable and reports no GPU.**

## Policy conventions

Work in `$AUTOSHIFT_DIR`, scaffold with `./scripts/generate-operator-policy.sh`,
then expect to fix what the scaffolder leaves out:

- Policy names are capped at 40 characters. Abbreviate the component, not the
  directory, following `acs` / `virt` / `nfd` / `rhtas`.
- Add `placementBindingDefaults.name`; the scaffolder omits it and rendering
  breaks as soon as a second policy shares the placement.
- Declare every `autoshift.io/` label consumed, in **both**
  `autoshift/values/clustersets/_example.yaml` and `clusters/_example.yaml`.
- Drop the `cluster-type: spoke` predicate the scaffolder emits unless the
  policy really is spoke-only. It never matches a self-managed hub.
- `--dependency` already prepends `policy-`; do not pass it yourself.
- A sample value of `''` in `_example.yaml` leaves the policy unexercised in
  CI, because the harness builds its synthetic cluster from the first
  non-empty declaration.

Gate everything. **`make test` is not the whole gate** — CI also runs a prose
linter as a separate job, and a docs or comment change can pass `make test`
and still fail CI:

```bash
cd $AUTOSHIFT_DIR && GOTOOLCHAIN=auto make test

# Vale is a Go binary CI fetches by curl; it is not in the Python docs
# requirements and is not installed by anything else here.
#   curl -sfL https://github.com/errata-ai/vale/releases/download/v3.17.1/vale_3.17.1_Linux_64-bit.tar.gz \
#     | tar -xz -C ~/.local/bin vale
vale sync
vale --minAlertLevel=error README.md AGENTS.md CLAUDE.md CONTRIBUTING.md docs/ policies/
```

Note the lint covers `policies/` as well as `docs/`, so a policy comment is
prose too. `rhoai-maas` currently has **14 Vale errors**, all in our own
policies — clean those before cutting the RHOAI PR series or every one of
them fails CI.

`RedHat.Conjunctions` is the rule to expect: it rejects sentences opening with
`So`, `And`, `But`. That one cost a round trip on upstream PR #293.

`GOTOOLCHAIN=auto` is required; the pinned Go toolchain will not download
without it. Check the **skipped** count, not just pass/fail — a block
containing any `{{` is treated as still-templated and its YAML is never
validated.

## Hub template traps

- `toYaml | nindent N` writes an absolute indent, but PolicyGenerator
  re-indents the block afterwards. Use `toJson` for nested structures.
- `toInt` on a quoted hub-resolved value fails resolution outright, and
  surfaces only as the policy applying nothing. Compare strings instead.
- A nil `lookup` renders as `%!s(<nil>)` through `printf`, which is a valid
  YAML string, so `make test` passes and the API server rejects it. Prefer
  fields that are always populated — the cluster `Ingress` config over
  `IngressController.spec.domain`, for instance.

## Sizing

An ACM hub is not a lightly loaded cluster. `cluster.env` defaults to
`m6i.2xlarge` control plane and `m6i.4xlarge` workers deliberately; the
4 vCPU / 16 GiB minimum is documented as sufficient only for etcd under
~250 MiB and low load. Overload does not present as overload — it presents as
API timeouts, a crash-looping `ovnkube-controller`, and NotReady nodes with no
CNI config.

## Prior research worth reading before debugging

Several defects were found by reading these rather than by hitting them:

- `~/workspace/redhat-research/rhoai-mass-aws/FINDINGS.md` — gateway 404
  causes, namespace labelling, the ClusterIP question
- `~/workspace/offline-models/CLAUDE.md` — `LLMInferenceService` versions,
  tool-calling parsers per model, ModelCar sourcing
- `docs/autoshift-upstream-issues.md` — twelve defects found in AutoShift,
  nine filed as #276–#285

## Conventions

- Credentials never in git. `.gitignore` lists `.example` exceptions
  file-by-file, deliberately; do not generalise it to a glob.
- Binaries are addressed by explicit path via `bin/ocp-env.sh`. PATH is never
  modified.
- Scripts log to `logs/` through `lib-logging.sh` so a failure can be read back
  without re-running.
