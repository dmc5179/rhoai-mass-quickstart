# Proposed issues for auto-shift/autoshiftv2

Found while adding the RHOAI MaaS policies on the `rhoai-maas` branch. Each is
reproducible from a clean clone and verified against the source, not inferred.
Ordered by how early a new contributor hits them.

**Status (2026-11-11).** Live state is on GitHub; this table is a snapshot.

Issues filed:

| Issue | Subject | State | Fixed by |
|---|---|---|---|
| #276 | `GOTOOLCHAIN=local` blocks the validation suite | Closed | PR #294 (merged) |
| #277 | Scaffolders omit `placementBindingDefaults` | Closed | PR #310 (merged) |
| #278 | Scaffolded policy names over 40 characters | Closed | PR #311 (merged) |
| #279 | `--dependency` doubles the `policy-` prefix | Closed | PR #312 (merged) |
| #280 | `generate-policy.sh` creates no README | Closed | PR #313 (merged) |
| #281 | MultiClusterHub hook races the operator webhook | Open | PR #326 (open; needs one fresh ACM install to confirm) |
| #282 | AWS node policies reconstruct the subnet | Open | PR #325 (open) |
| #283 | GPU operator OperatorGroup | Closed, not planned | Not an upstream bug: the policy was not upstream. Folded into PR #323 |
| #284 | infra-nodes reads an AWS-only field | Open | PR #309 (open, review changes pushed) |
| #285 | ACM shadows the machine short names | Closed | PR #308 (merged) |
| #287 | NFD labels PCI devices by class | Closed 2026-11-18 (by us, citing #303) | Fixed by the maintainer in #303 (vendor labels by default); PR #324 adds rules keyed by name. Our PR #291 was closed as superseded |
| #288 | disconnected-mirror `musthave` on lists | Closed | PR #292 (merged) |
| #289 | `mustonlyhave` does not strip metadata on adoption | Closed | PR #293 (merged) |
| #290 | `adopt` activates every policy at once | Open | Design request, no PR |
| #321 | Harness: synthetic config overrides leak into the hub config | Closed | PR #322 (merged) |
| #336 | `generate-imageset-config.sh` mirrors only channel heads, so pinned operators cannot install disconnected | Open (filed 2026-11-13) | `pr/imageset-version-pins` 74516b60 (rebased on main 2026-11-19), not pushed; asks the maintainer whether release mode honours pins (815 to 1455 images) |
| #337 | Disconnected mirrors miss the Service Mesh 3 version the ingress operator installs for Gateway API | Open (filed 2026-11-13; premise corrected 2026-11-19: the ingress operator runs istiod itself, the image is in the bundle `GATEWAY_API_OPERATOR_VERSION` names) | `pr/imageset-gateway-api-mesh` 3c6be75d, rebased on main and reworded, stacked on #336's branch, not pushed |
| #349 | `_example.yaml` pins `trident-operator.v25.06.0`, absent from the v4.22 certified catalog | Open (filed 2026-11-19; correction comment added) | PR #350 pins v26.6.2. The scheduled channel-update script never lists trident; separately it exits silently when pointed at `_example.yaml` alone (greedy colon parse of `openshift-version`) |

Policy PRs for the RHOAI MaaS stack, reshaped to the maintainer's conventions (a `config.<component>`
section merged over a base spec; applicability in placement predicates; readiness checks that call
`fail` rather than render empty and report Compliant):

| PR | Policy | State |
|---|---|---|
| #315 | leader-worker-set | Open, review changes pushed |
| #316 | connectivity-link | Open, review changes pushed |
| #317 | gpu-nodes | Open, review changes pushed |
| #323 | nvidia-gpu-operator (replaces #83 at the maintainer's request) | Open |
| #324 | node-feature-discovery: `nodeFeatureRules` keyed by name | Open |

Opened since: #327 (cluster-autoscaler). openshift-lightspeed is upstream as the maintainer's own
#331, so our `pr/openshift-lightspeed` is superseded.

Still to come, in dependency order: openshift-ai, openshift-ai-maas, openshift-ai-models (branches
pushed to the fork, no upstream PR yet), then model-egress, the OpenShell operators, gitops-workloads,
htpasswd-users and mcp-gateway. The #327 follow-up (worker and infra node policies release
`spec.replicas` once a MachineAutoscaler manages the MachineSet, using the annotation check proved
live on gpu-nodes on 2026-11-19) waits for #309 and #325.

**2026-11-26 updates.** Opened #366 (mcp-gateway), stacked on #316 because it needs the
connectivity-link policy; it adds `gateway.authorinoTLS` (default true) for clusters where Authorino
serves plain gRPC. Review rounds answered with new commits and a plain push:

| PR | Change | Reply |
|---|---|---|
| #325 | mismatch check fails only on security groups the worker lacks or a different subnet; `customMessage`; quoted tags; `TestAWSNodePolicies_ExistingMachineSet` | posted |
| #315 | cert-manager prerequisite in README, example and readiness | posted; readiness rework (LeaderWorkerSetOperator status, `lws-controller-manager`) committed locally, to confirm on a live cluster before pushing |
| #364 | README rollback order | none needed |
| #347 | truncated catalog fails; lowest pin by semver; pins stay with their channel | posted |
| #348 | three Service Mesh discovery fixes; merged #347 (pin scoping changes one fallback expectation) | posted |
| #327 | unplacement wait, scoped cleanup, GPU and infra examples active; storage MachineSets lose their MachineAutoscaler (`mustnothave`) | drafted |

Merges of `main` into #315, #327 and #366 (one `_example.yaml` conflict each, both blocks kept)
are committed locally.

**mcp-gateway, before its PR (2026-11-25).** The policy was cherry-picked onto `rhoai-maas` from
`wip/mcp-gateway-instance` (`dcc83176`, `b7cb50df`) and enabled on the lab (`e217688e`). Its first
run on a cluster needed three fixes, which the PR must carry:

| Commit | Fix | Why |
|---|---|---|
| `0b3ac91f` | Both listeners plain HTTP on one port; public endpoint through an edge Route | The controller matches a registration to the extension by the listener port its route attaches to. A public 443 listener and server routes on 8080 left every `MCPServerRegistration` NotReady. The install docs mix listener ports without saying so |
| `4ea23a95` | `EnvoyFilter <name>-authn-ssl`: TLS from the gateway to Authorino | RHOAI turns on TLS for Authorino's gRPC port and patches only the MaaS gateway, so every authenticated request on any other gateway returned 500 (reported in Jira) |
| `3194709e` | `publicHost` on the `MCPGatewayExtension` | With a hostname-less listener the extension is not Ready, no router EnvoyFilter is written, and every `tools/call` fails at the broker |

The controller bug seen on the way (the router EnvoyFilter kept the old port 443) is filed in Jira.
The Wasm load race was also seen on a newly created gateway, not only after a resume (reported to the existing Jira issue).
Still open: the broker lists none of the RHOKP server's tools (`rhokp-mcp` README).

How these PRs are updated: review changes go on top as new signed commits and a plain push, never a
rebase and force-push. The maintainer merges `main` into PR branches from GitHub, and a force-push
would discard that.

`policies/stable/ztwim` is **excluded from the split**. Upstream
[PR #246](https://github.com/auto-shift/autoshiftv2/pull/246) implements the
same operator in 44 files and ~4,900 lines — SPIRE config, CNPG datastore,
federation, nested hub/spoke, 8 placements, 7 test policies. Ours is 5 files
that install the Subscription and nothing else: no instance CR, so on a real
cluster it installs an operator that does nothing. We never enabled it, and
nothing else references it. Commented on #246 to say we are standing down,
noting that our subscription block came out byte-identical to theirs
independently.

**Issue 10 is NOT filable as written**, and neither was
[#283](https://github.com/auto-shift/autoshiftv2/issues/283): both are against
`policies/certified/nvidia-gpu-operator`, a directory that does not exist
upstream. They are findings about a policy we are contributing, not bugs in
upstream code, and belong in that PR's description. #283 needs withdrawing.

Issues 2–5 are all in the two scaffolders, and all share a shape: the generator
produces a directory that the repository's own validators then reject, so the
first signal is a failing `make test` rather than anything at generation time.

---

## 1. `GOTOOLCHAIN=local` stops a fresh clone building the validation suite

**Type:** docs · **Fix ready:** yes

`tools/go.mod` pins an exact Go version. If the installed Go is older and
`GOTOOLCHAIN=local` is set, Go refuses to fetch the pinned toolchain and
nothing can run:

```
go: go.mod requires go >= 1.26.9 (running go 1.26.8; GOTOOLCHAIN=local)
```

Go's own default is `auto`, which downloads exactly the pinned version and
leaves the system installation alone. Some distributions and corporate images
set `local`. The developer guide says the Go version "comes from
`tools/go.mod`", which is true but does not warn that an environment setting
can prevent Go acting on it — so the failure reads as a missing dependency.

It blocks `make install-policy-generator` too, since that shells out to
`go install`.

**Suggested fix:** note it in the developer guide prerequisites and in the
`AGENTS.md` toolchain table. A patch doing exactly that is available and fits
inside the existing `AGENTS.md` 200-line budget.

---

## 2. Scaffolder omits `placementBindingDefaults`, so adding a second policy breaks rendering

**Type:** bug · **File:** `scripts/generate-operator-policy.sh`, `scripts/generate-policy.sh`

Neither generator emits `placementBindingDefaults`, and neither does any
template under `scripts/templates/`. That is fine for the single-policy
directory they produce. It stops being fine as soon as a second policy shares
`placement.yaml` — which the generated README explicitly tells you to do
("Add further CRs as new `policies[]` entries"):

```
error generating policies from the PolicyGenerator file '...':
placementBindingDefaults.name must be set but is empty
(multiple policies or policy sets were found for the PlacementBinding to
placement placement-policy-<name>-operator-install)
```

`policies/stable/cert-manager` sets it by hand
(`name: binding-policy-cert-manager`), so the convention exists — the
scaffolder just does not follow it.

**Reproduce:** scaffold any operator policy, add a second entry under
`policies:` reusing the same placement, run `make test`.

**Suggested fix:** emit `placementBindingDefaults.name: binding-<component>`
in the generated `policy-generator-config.yaml`. It is harmless with one
policy and correct with several.

---

## 3. Scaffolder generates policy names that fail the repository's own 40-character limit

**Type:** bug · **File:** `scripts/generate-operator-policy.sh`

The generator composes `policy-<component>-operator-install` with no length
check — `grep -ci '40\|length\|too long'` over the script returns 0. Any
component name of 18 characters or more therefore produces a policy the
validator rejects:

```
policy-leader-worker-set-operator-install      41
policy-nvidia-gpu-operator-operator-install    43
policy-openshift-lightspeed-operator-install   44
```

```
policy names: 227 checked across 64 files, 4 over 40 characters
```

The repository already solves this by abbreviating — `acs`, `virt`, `nfd`,
`rhtas` — but nothing surfaces that convention until the gate fails, and the
abbreviation has to be applied by hand across
`policy-generator-config.yaml`, `placement.yaml` and the README.

Note `nvidia-gpu-operator` also shows a second-order bug: the generator
appends `-operator-install` to a component name already ending in `-operator`,
yielding `policy-nvidia-gpu-operator-operator-install`.

**Suggested fix:** fail at generation time with the measured length and a
pointer to the abbreviation convention. Optionally accept an explicit
`--policy-name` so the directory can stay descriptive while the policy name
stays short.

---

## 4. `--dependency` prepends `policy-` unconditionally, so the obvious input is wrong

**Type:** bug · **File:** `scripts/generate-policy.sh:350`

```bash
echo "      - name: policy-${dep}"
```

Passing the dependency's actual name — which is what the `--dependency` flag
reads as asking for, and what you have in front of you from the policy you are
depending on — produces a name that cannot resolve:

```bash
./scripts/generate-policy.sh foo --dependency policy-openshift-ai-maas
#   dependencies:
#     - name: policy-policy-openshift-ai-maas
```

Nothing rejects this at generation time, and the dangling dependency is easy
to miss in review.

**Suggested fix:** strip a leading `policy-` if present, or validate and error.
`--help` currently gives no indication which form is expected.

---

## 5. `generate-policy.sh` creates no README, but a ratchet requires one

**Type:** bug · **Files:** `scripts/generate-policy.sh`, `tools/internal/resolver/policy_structure_test.go`

`generate-operator-policy.sh` writes a `README.md`. `generate-policy.sh` does
not — it contains no reference to README at all. But `policy_structure_test`
enforces a ratchet on directories lacking one:

```
policy structure: 0 evaluationInterval violations,
30 directories without a README (limit 28)
```

So scaffolding two configuration policies with the supported tool breaks the
build, and the error names every pre-existing offender rather than the two you
just added. `AGENTS.md` does say "New policy directories need a `README.md`",
but the generator that should implement that is the one that does not.

**Suggested fix:** have `generate-policy.sh` emit the same README skeleton as
the operator generator. Separately, consider having the ratchet report only
directories added since the baseline — the current message buries the two
relevant paths in a list of 30.

---

# Not yet filed

Three defects in the GPU path, all found on a live OpenShift 4.22 cluster
rather than by reading source. They share a shape worth stating once: **each
leaves a cluster that looks healthy and reports Compliant while doing
nothing.** No policy fails, no operator reports an error, and the only visible
symptom is the absence of something.

Taken together they mean the GPU path could not have worked on any cluster.
Fixing one only exposes the next.

## 10. NVIDIA ClusterPolicy sets fields the installed CRD does not define

**Type:** bug · **File:** `policies/certified/nvidia-gpu-operator/manifests/cluster-policy/cluster-policy.yaml` · **Fix ready:** yes

The manifest sets five fields that do not exist in the ClusterPolicy CRD
shipped by `gpu-operator-certified` v25.3 — the channel this policy's own
`manifests/operator-install/kustomization.yaml` defaults to. The API server
rejects the whole object on the first unknown field:

```
ClusterPolicy in version "v1" cannot be handled as a ClusterPolicy:
strict decoding error: unknown field "spec.cdi.nriPluginEnabled",
unknown field "spec.driver.licensingConfig.secretName",
unknown field "spec.kataSandboxDevicePlugin", unknown field "spec.mps",
unknown field "spec.sandboxWorkloads.mode"
```

The policy surfaces this as:

```
clusterpolicies [gpu-cluster-policy] is missing, and cannot be created
```

which reads as an ordering or permissions problem rather than a schema
mismatch against the operator version the policy just installed.

All five fields were inert: two were set to their defaults, one sat under
`sandboxWorkloads.enabled: false`, and `mps` and `kataSandboxDevicePlugin`
have no equivalent in the installed CRD at all. Removing them changes no
behaviour.

**Reproduce:** enable `nvidia-gpu-operator` on any cluster and look for the
ClusterPolicy. Verified with a server-side dry run on 4.22 against v25.3.4.

**Suggested fix:** remove the five fields, or pin a channel whose CRD defines
them. Worth a check that the manifest and the default channel are tested
together, since nothing currently catches the pair drifting apart.

## 11. NFD labels PCI devices by class, so the GPU operator never sees a GPU node

**Type:** bug · **File:** `policies/stable/node-feature-discovery/manifests/node-feature-discovery-instance.yaml` · **Fix ready:** yes

The NodeFeatureDiscovery instance sets:

```yaml
        pci:
          deviceLabelFields:
            - "class"
```

That produces `feature.node.kubernetes.io/pci-0300.present` and
`pci-0302.present`. The NVIDIA GPU operator gates every one of its operands on
`feature.node.kubernetes.io/pci-10de.present`, where `10de` is NVIDIA's PCI
vendor ID, and class labelling never produces it.

The result is a GPU operator that installs cleanly, reports no error, and
creates no daemonsets at all — no driver, no container toolkit, no device
plugin. The node is Ready, the MachineSet is satisfied, the operator pod is
Running, and the node advertises no `nvidia.com/gpu`.

Red Hat documents `"vendor"` for exactly this
([solution 7128119](https://access.redhat.com/solutions/7128119)).

This is the more serious of the two, because it spans policies: the
`node-feature-discovery` policy makes the `nvidia-gpu-operator` policy
unusable, and the two are shipped together in the same repository.

**Reproduce:** enable both policies on a cluster with an NVIDIA GPU node.
Observed with 67 NFD labels present and `pci-10de.present` absent.

**Suggested fix:** set `deviceLabelFields: ["vendor"]`. Note the same Red Hat
solution warns against adding `"device"` alongside it — that switches the
label to `pci-10de-<deviceid>.present`, which terminates an in-flight driver
rollout and zeroes `nvidia.com/gpu`. A `NodeFeatureRule` is the supported way
to get device IDs.

## 12. Adopting a cluster activates every enabled policy at once, irreversibly

**Type:** enhancement · **Fix ready:** no

Adding a cluster to a clusterset activates every policy enabled in that
clusterset's values file simultaneously. The shipped `hub.yaml` has 59 labels
set to `true`, so adoption installs ACS, AAP, Quay, GitLab, compliance, the
full logging and tracing stack, service mesh, dev-hub, dev-spaces and
pipelines in parallel.

On a three-worker cluster that produced 99% of allocatable CPU requested on
every worker, roughly 270 running pods, and an etcd database at a 545 MB
high-water mark against a 4 vCPU / 16 GiB control plane — whose
[documented baseline](https://access.redhat.com/articles/7132959) covers "up
to approximately 250 MiB and low load".

The cluster then failed in a way that named none of this: API server
timeouts, a crash-looping `ovnkube-controller` unable to write a node
annotation, nodes NotReady reporting no CNI configuration, and a stalled
MachineConfig roll.

Because policies use `pruneObjectBehavior: None`, **this cannot be undone by
editing values.** Setting a label back to `false` stops reconciliation without
uninstalling the operator, its namespace, its CRDs or its webhooks. One
orphaned validating webhook whose pods could no longer be scheduled failed
closed and blocked `oc exec` cluster-wide. The cluster was rebuilt; repairing
it by hand was judged slower and less certain.

**Suggested fix:** no strong opinion on the mechanism, but some combination of:
ship a smaller default `hub.yaml`; have `adopt` print what it is about to
activate and require confirmation; document that adoption is effectively
one-way; or support staged activation so capability can be added in batches.

The underlying behaviour is reasonable. What is missing is that nothing warns
the operator of the cluster that a single label change is about to install
twenty operators, and that there is no path back.

---

## 13. Shipped policies use `musthave` on configurable object lists, which the project's own docs say is wrong

**Type:** bug · **Fix ready:** for our policy, yes — upstream instance not fixed

`docs/policy-behavior.md` states the rule plainly:

> **`musthave` merges into lists, it never replaces them.** Changing the value
> of an entry in an object list leaves both the old entry and the new one in
> place, and the policy still reports Compliant. This silently defeats
> configuration changes that look correct in git. When the desired state has to
> override an existing list entry, use `mustonlyhave`.

Shipped policies do not follow it. We hit this in our own policy first —
raising a rate limit from 100 to 50000 produced a live object carrying both
values while the policy reported Compliant — and fixed it with
`mustonlyhave`. Then the same shape turned up upstream.

**`policies/stable/disconnected-mirror/manifests/image-digest-mirror-set.yaml`**
builds `spec.imageDigestMirrors` by ranging over a configured list of mirrors,
under `complianceType: musthave`:

```yaml
  - complianceType: musthave
    objectDefinition:
      kind: ImageDigestMirrorSet
      metadata:
        name: autoshift-disconnected-mirrors
      spec:
        imageDigestMirrors:
        {{hub range $_, $entry := $mirrors hub}}
          - source: {{hub $source hub}}
            mirrors:
              - '{{hub $mirrorLoc hub}}'
        {{hub end hub}}
```

The `ImageContentSourcePolicy` branch in the same file has the identical
shape, as does `workload-partitioning/manifests/performance-profile.yaml` for
its hugepages list.

**Why this one matters more than ours.** Changing a mirror host, correcting a
path, or removing a decommissioned mirror leaves the old entry in the live
`ImageDigestMirrorSet` permanently. On a disconnected cluster that means pulls
keep being redirected to a registry that may no longer exist, and the only
signal is the pull failure — the policy reports Compliant, `oc get policy`
is clean, and the git history shows the mirror was removed. Combined with
`pruneObjectBehavior: None`, nothing ever removes it.

**Reproduce:**
1. Configure one mirror, let it reconcile, confirm the `ImageDigestMirrorSet`.
2. Change the mirror's `source` or `mirror` value in the values file.
3. Re-render and sync. The live object has both entries; the policy is
   Compliant.

**Suggested fix:** `mustonlyhave` on any object template whose body writes a
templated list. A lint for it is plausible — the validation suite already
parses these files, and "`complianceType: musthave` on an object containing a
`range` that emits list entries" is a mechanical check. That would turn a
documented footgun into a build failure, which is the pattern the repo already
uses for policy names and the label contract.

---

## Context

These came out of adding seven policies for RHOAI Models-as-a-Service
(`leader-worker-set`, `nvidia-gpu-operator`, `connectivity-link`,
`openshift-ai`, `openshift-ai-maas`, `openshift-ai-models`,
`openshift-lightspeed`). Every one was scaffolded with the supported
generators per `AGENTS.md`, and every one hit at least two of the issues
above before `make test` would pass.

Nothing here is a disagreement with the design. The validators are strict in
the right ways — the gate caught a real would-be-silent bug in our own work,
where a `ConfigurationPolicy` naming a not-yet-installed CRD reports Compliant
while doing nothing. The gap is that the scaffolders do not yet know what the
validators know.
