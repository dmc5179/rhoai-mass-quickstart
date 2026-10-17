# Proposed issues for auto-shift/autoshiftv2

Found while adding the RHOAI MaaS policies on the `rhoai-maas` branch. Each is
reproducible from a clean clone and verified against the source, not inferred.
Ordered by how early a new contributor hits them.

Issue 1 already has a fix committed and can go straight up as a PR. Issues 2–5
are all in the two scaffolders, and all share a shape: the generator produces a
directory that the repository's own validators then reject, so the first signal
is a failing `make test` rather than anything at generation time.

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
