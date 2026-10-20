# Proposed issues for auto-shift/autoshiftv2

Found while adding the RHOAI MaaS policies on the `rhoai-maas` branch. Each is
reproducible from a clean clone and verified against the source, not inferred.
Ordered by how early a new contributor hits them.

**Status:** issues 1–5 are filed as
[#276](https://github.com/auto-shift/autoshiftv2/issues/276)–[#280](https://github.com/auto-shift/autoshiftv2/issues/280).
Issues 6–9 are filed as
[#281](https://github.com/auto-shift/autoshiftv2/issues/281)–
[#285](https://github.com/auto-shift/autoshiftv2/issues/285).
Issues 11–14 are filed as
[#287](https://github.com/auto-shift/autoshiftv2/issues/287),
[#288](https://github.com/auto-shift/autoshiftv2/issues/288),
[#289](https://github.com/auto-shift/autoshiftv2/issues/289) and
[#290](https://github.com/auto-shift/autoshiftv2/issues/290).

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
