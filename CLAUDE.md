# Working in this repository

Push-button OpenShift on AWS with RHOAI Models-as-a-Service. Plain shell
scripts for the cluster, AutoShift policies for everything on it.

Read [docs/running-under-autoshift.md](docs/running-under-autoshift.md) before
changing anything policy-related. It is the expensive knowledge.

Where to start, by task:

| Task | Read first |
|---|---|
| A new network template or VPC deploy script | [docs/aws-vpc-and-cloudformation.md](docs/aws-vpc-and-cloudformation.md) - the template-to-script contract |
| Anything policy-related | [docs/running-under-autoshift.md](docs/running-under-autoshift.md) |
| Building a fresh cluster end to end | [docs/aws.md](docs/aws.md), [docs/prerequisites.md](docs/prerequisites.md) |
| Mirroring for a disconnected install | `disconnected/imageset-config-rhoai-3.5.2-ocp4.2{1,2}.yaml` (header comments) |
| Every script and setting | [docs/reference.md](docs/reference.md) |

## Two repositories

| | |
|---|---|
| this repo | scripts, CloudFormation, docs. Branch `main`. |
| `$AUTOSHIFT_DIR` (`~/workspace/autoshiftv2-mine`) | fork of `auto-shift/autoshiftv2`, branch `rhoai-maas`. All policies live here. |

**Policies are read from Git, never from the working copy.** An edit in
`$AUTOSHIFT_DIR` does nothing until it is committed and pushed. Values files
are the opposite — read locally by helm at install time, so they need a
`bootstrap`, not a push.

## The AWS network is its own CloudFormation stack

`scripts/10-deploy-cluster.sh` creates `cloudformation/01_vpc.yaml` as stack
`VPC_STACK_NAME` (or reuses it if it exists), then
`scripts/generate-install-config.sh` reads the stack's **outputs** to render
`install-config.yaml`, then the installer builds the cluster **into** that VPC.
The stack carries no `kubernetes.io/cluster/*: owned` tags, so destroying the
cluster leaves the VPC standing; `90-destroy-cluster.sh --with-vpc` removes it.

**The stack outputs are the interface.** A new template that exposes the same
output names - `InstallConfigSubnets` (a paste-ready `platform.aws.vpc.subnets`
block with all five subnet roles), `AvailabilityZone`, `VpcId`,
`PrivateSubnetId` - works with every downstream script unchanged.

Traps for anyone changing the network:

- `templates/install-config.yaml.aws` hardcodes `machineNetwork: 10.0.0.0/16`,
  and nothing patches it. A VPC on another CIDR must change it too.
- `publish: External` and `credentialsMode: Mint` are also fixed in the template.
- With `BASE_DOMAIN=""` the domain is auto-detected from **public** Route 53
  zones only, and must be exactly one. A private zone needs it set explicitly.
- `--dry-run` cannot test install-config rendering: that needs the outputs of a
  stack the dry run does not create.
- `maas-database.sh` adds a subnet, security group and DB subnet group to the
  VPC **outside** the stack, and nothing fully removes them, so
  `--with-vpc` then fails on a dependency violation.

Details, the disconnected-AWS requirements from the 4.22 docs, and the script
conventions to follow: [docs/aws-vpc-and-cloudformation.md](docs/aws-vpc-and-cloudformation.md).

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
00-init               fetch oc, openshift-install-fips, kubectl, helm into bin/
10-deploy-cluster     CloudFormation VPC (create or reuse), then the installer.
                      Calls generate-install-config.sh. Refuses to run while
                      clusters/<CLUSTER_NAME>/ is non-empty.
20-deploy-maas        imperative MaaS (superseded by policies; kept for non-AutoShift use)
45-autoshift-values   per-cluster values. BEFORE 50 — helm reads values at install time
50-autoshift          bootstrap | adopt | status | refresh | uninstall
maas-database.sh      create | status | secret | destroy. AWS RDS PostgreSQL,
                      which maas-api will not start without. After RHOAI exists.
maas-user.sh          create | status. The htpasswd user that mints MaaS keys.
35-smoke-test         a real prompt end to end; mints as maas-user if it exists
40-lightspeed
90-destroy-cluster    [--with-vpc]. The VPC survives without the flag.
cluster-power.sh      park or resume a cluster to stop the bill
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
prose too. `rhoai-maas` is at **0 Vale errors** (cleared 2026-11-05); keep it
there, because every upstream PR branch is cut from it.

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
- `docs/autoshift-upstream-issues.md` — defects found in AutoShift: fourteen
  filed (#276–#285, #287–#290; #283 withdrawn), PRs #292–#294 merged, #291 open

## Conventions

- Credentials never in git. `.gitignore` lists `.example` exceptions
  file-by-file, deliberately; do not generalise it to a glob.
- Binaries are addressed by explicit path via `bin/ocp-env.sh`. PATH is never
  modified.
- Scripts log to `logs/` through `lib-logging.sh` so a failure can be read back
  without re-running. Call `start_logging` before any real work.
- Source order in a script: set `ROOT`, then `cluster.env` (it requires `ROOT`),
  then `bin/ocp-env.sh`, then `scripts/lib-logging.sh`.
- AWS credentials and region come from `secrets/aws.env`. Anything a script
  generates (passwords, connection URLs) goes under `secrets/` with `umask 077`.
- Long or billable scripts take `--dry-run`, and reuse existing resources rather
  than failing or duplicating them.
- `yq` means **Go yq v4** (mikefarah, Fedora's `yq` RPM), not the Python yq.
  It has no `--arg`: pass values via the environment with `strenv(V)` for strings
  and `env(V)` for lists and numbers. It preserves comments, so a check that
  greps its output must skip comment lines.
- Local tool binaries in `~/.local/bin` (Vale, for instance) do not survive an
  OS reinstall, and a missing binary whose output goes to `/dev/null` reads as a
  clean result. Check the tool ran before trusting a zero.
