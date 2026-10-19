# What belongs in AutoShift, and how to add the rest

Plan, not yet implemented. The question this answers: as more capability is
delivered through AutoShift, does the repository have to absorb every workload
that runs on the cluster? No — and the mechanism to avoid it already exists in
the repository.

## The growth is real, and it is measurable

Our branch alone adds **14 new policy directories, 107 files, 4,596 lines** on
top of the 65 that `policies/stable/` already had:

```
agent-sandbox      leader-worker-set     openshift-ai-maas      osc
connectivity-link  mcp-gateway           openshift-ai-models    rhbk
gpu-nodes          model-egress          openshift-lightspeed   ztwim
openshift-ai       nvidia-gpu-operator (certified)
```

Every one of those is a *platform capability* — an operator, a
DataScienceCluster component, a gateway, a MachineSet shape. That is what
AutoShift is for, and that growth is healthy.

The unhealthy version is the next step: vendoring a tenant workload's
manifests because AutoShift is where deployment happens. Do that three times
and the repository is a monorepo for things that have nothing to do with each
other, each on its own release cadence, each a merge conflict.

## The dividing line

| | Goes in AutoShift | Gets pointed at |
|---|---|---|
| **What** | Operators, OperatorGroups, Subscriptions, DSC components, gateways, MachineSets, cluster-scoped config | Applications with their own repo, release cadence and team |
| **Why** | Needs ACM placement and per-cluster compliance; reusable across every tenant | Lifecycle is independent of the platform's |
| **Test** | "Would a second, unrelated tenant want this?" | "Does this have its own version number?" |

Hermes is the clean example of the right-hand column. The peer session building
it reached the same conclusion independently and named two things that fit
badly in a PolicyGenerator + Helm flow: a runtime-minted `sk-` key that cannot
be declared in Git, and an initContainer that renders config onto a PVC.

### Three mechanisms, not two

The two-column table is the first cut. The useful rule has a middle:

| Shape | Mechanism | Example |
|---|---|---|
| Operators, cluster config, node pools | Plain policy | `connectivity-link`, `gpu-nodes` |
| A **shaped CR** that varies by a handful of fields | **Config-driven** policy, ranged over a list in rendered-config | `openshift-ai-models` |
| **Arbitrary manifests** with their own repo and cadence | **Pointer** policy → ArgoCD Application | Hermes |

The middle row matters because it solves the same growth problem by a
different route. `openshift-ai-models` deploys real serving workloads — which
is tenant-shaped by the test above — yet the repository does not grow per
model, because the model list lives in `config.openshiftAiModels` and the
policy ranges over it. Adding a model is a values change.

So the question to ask is not only "is this platform or workload", it is **"can
I template this as a shaped CR?"** If yes, config-driven keeps it in-repo at
zero marginal cost. Reach for the pointer only when the content is arbitrary.

### Why the RHOAI MaaS policies stay

Applying this to our own work, on the grounds that it is the obvious thing to
reconsider: they stay, and the reasons are worth recording so the question is
not reopened from scratch.

- They are **ACM Policies, not Argo applications.** A pointer policy creates an
  `Application`; it is not a route for delivering `Policy` objects.
- They pass both tests in the first table — every operator here is wanted by
  any tenant of an RHOAI cluster, and none carries its own version.
- **Ten of the fourteen directories render the shared chart by relative path**
  (`chartHome: ../../../../../components/`, `helmCharts: [operator-install]`).
  That resolves only inside this tree. Extracting them breaks all ten.
- Extraction forfeits `make test` — the label contract, the 40-character cap,
  empty-policy detection, the OperatorGroup install-mode check that found six
  real failures — and the upstream contribution path.

**The one contingency.** If upstream declines the RHOAI MaaS policies as too
product-specific, the fallback is a separate *policy collection* repo with the
same layout, distributed by the `managed-autoshift` mechanism rather than by a
workload pointer. That is a response to a rejection, not a plan.

## Why not a submodule

It is the obvious idea and it is the wrong tool here, for four reasons:

1. **It does not actually decouple.** PolicyGenerator and kustomize render the
   whole tree. A submodule moves the bytes out of your history but the content
   is still present at render time, and still yours to break.
2. **Every workload bump becomes an AutoShift commit.** The pointer has to be
   advanced in this repo, reviewed in this repo, and released with this repo.
   That is tighter coupling than a plain Git URL, not looser.
3. **It poisons the upstream story.** This is a fork being prepared for
   contribution to `auto-shift/autoshiftv2`. Upstream will not accept a
   submodule per tenant workload, so anything built that way can never go home.
4. **ArgoCD submodule support is a configuration surface.** It works, but it
   adds repo-server behaviour and failure modes for no gain over a URL.

## The mechanism that already exists

`policies/stable/managed-autoshift/manifests/deployment.yaml` is an ACM policy
whose entire job is to **create an ArgoCD `Application` pointing at an
arbitrary repository**. It is config-driven from a *list*, so one policy
produces N Applications:

```yaml
{{hub $autoshiftConfigs := (index $rcConfig "managedAutoshift" | default list) hub}}
{{hub range $autoshiftConfig := $autoshiftConfigs hub}}
```

and it already supports everything a generic version needs — `repoUrl`,
`targetRevision`, `path`, `argoProject`, `argoServer`, `gitopsNamespace`,
Helm `valueFiles` and inline `values`, Argo **multi-source** (a `$values` ref
to a second repo), and an **OCI mode** (`ociRepo` / `ociVersion`) as an
alternative to Git.

Today it is hardcoded to deploy AutoShift itself — `path: autoshift`,
`chart: autoshift`, AutoShift-specific values, an `appName` capped at 11
characters, and a guard that refuses the name `autoshift`. The work is
generalising it, not inventing it.

## The proposal: one pointer policy, N workloads

A new `policies/stable/gitops-workloads/` driven by `config.gitopsWorkloads`,
a list. Each entry describes one Application:

```yaml
config:
  gitopsWorkloads:
    - name: hermes-agent
      repoUrl: https://github.com/dmc5179/hermes-openshift
      targetRevision: main
      path: gitops/overlays/rhoai-sandbox3587
      destinationNamespace: hermes
      createNamespace: true
```

**The marginal cost of workload N+1 becomes a few lines in a values file, not
a directory in the repository.** That is the whole point: AutoShift grows once,
by about forty lines of policy, and then stops growing.

`policy-gitops-workloads` is 23 characters, well inside the 40-character cap.

It is also a plausible upstream contribution in its own right — generic, no
RHOAI coupling, and it solves a problem any AutoShift adopter will hit.

## The semantic you lose, and how to get it back

This is the part to get right, because it is the familiar failure shape.

An ACM Policy that creates an Argo Application reports compliance on **the
Application object**, not on the workload. The policy goes Compliant the
moment the `Application` CR matches — while the Application itself is
`Degraded`, `OutOfSync`, or pointing at a branch that does not exist. Same
family as a `ConfigurationPolicy` naming a CRD that does not exist yet.

So pair it with an inform policy asserting the Application's own status, the
way `openshift-ai-models` asserts `LLMInferenceService` Ready rather than
trusting that creation succeeded:

```yaml
- complianceType: musthave
  objectDefinition:
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata: {name: ..., namespace: openshift-gitops}
    status:
      health: {status: Healthy}
      sync:   {status: Synced}
```

Note `argoproj.io/v1alpha1` spelled out. ACM installs `app.k8s.io`, which
shadows the `application` short name.

## Decisions to make before building

1. **`mustonlyhave` or `musthave` on the Application?** `managed-autoshift`
   uses `mustonlyhave`, so AutoShift fully owns the object and hand-edits get
   reverted. That is right for a fleet-managed app and wrong for one a team
   iterates on daily.
2. **AppProject.** `default` permits everything. Multiple tenant workloads
   eventually want their own project with namespace and resource restrictions.
   Not blocking, but it is easier to start restricted than to retrofit.
3. **Who owns the Namespace** — AutoShift via `createNamespace`, or the
   workload repo? Both creating it is a conflict.
4. **Secrets stay out of band, always.** A workload's MaaS `sk-` key cannot
   live in Git, same as the RDS connection URL and the Lightspeed API key. The
   pointer policy deploys the app; it does not provision the app's
   credentials.

## For disconnected, prefer the OCI mode

`managed-autoshift` already supports `ociRepo` / `ociVersion`. In a
disconnected environment a chart pushed to the same registry everything else
is mirrored to is a better dependency than a Git URL that has to be reachable
and mirrored separately. Worth carrying into the generic version rather than
bolting on later.
