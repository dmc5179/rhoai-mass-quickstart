# What belongs in AutoShift, and how to add the rest

The question this answers: as more capability is delivered through AutoShift,
does the repository have to absorb every workload that runs on the cluster?
No. Platform capability goes in as RHACM policies; workloads with their own
repository are delivered by RHACM's own GitOps integration, still governed by
an RHACM policy.

**Direction, decided 2026-11-06: favour RHACM over plain Argo CD.** RHACM is
the product, and its policies give placement, per-cluster compliance and
reconcile-time discovery of cluster state that a plain Argo CD Application
cannot. Argo CD stays the delivery engine where it fits, but RHACM decides
where things go and reports whether they worked.

## The growth is real, and it is measurable

Our branch adds these policy directories on top of the 65 that
`policies/stable/` already had:

```
agent-sandbox      leader-worker-set     openshift-ai-maas      osc
connectivity-link  model-egress          openshift-ai-models    rhbk
gpu-nodes          htpasswd-users        openshift-lightspeed   openshift-ai
gitops-workloads   nvidia-gpu-operator (certified)
```

`mcp-gateway` was dropped (2026-11-08): Red Hat Connectivity Link 1.5 ships the
MCP Gateway, so `connectivity-link` on channel `stable-1.5` provides it.

Every one of those is a *platform capability*: an operator, a
DataScienceCluster component, a gateway, a MachineSet shape. That is what
AutoShift is for. Three of them are not being submitted upstream, because
upstream already has, or has a pending PR for, the same thing: `ztwim` (merged
as #246, ours removed), `htpasswd-users` (#233) and `nvidia-gpu-operator`
(#83). They stay in our fork only while this hub needs them.

The unhealthy version is the next step: vendoring a tenant workload's
manifests because AutoShift is where deployment happens. Do that three times
and the repository becomes a monorepo of unrelated things, each on its own
release cadence.

## The dividing line

| | Goes in AutoShift as a policy | Delivered from its own repo |
|---|---|---|
| **What** | Operators, OperatorGroups, Subscriptions, DSC components, gateways, MachineSets, cluster-scoped config | Applications with their own repo, release cadence and team |
| **Why** | Needs RHACM placement and per-cluster compliance; reusable across every tenant | Lifecycle is independent of the platform's |
| **Test** | "Would a second, unrelated tenant want this?" | "Does this have its own version number?" |

Hermes is the clean example of the right-hand column: a runtime-minted `sk-`
key that cannot be declared in Git, and an initContainer that renders config
onto a PVC.

### Three mechanisms, all RHACM

| Shape | Mechanism | Example |
|---|---|---|
| Operators, cluster config, node pools | Plain RHACM policy | `connectivity-link`, `gpu-nodes` |
| A **shaped CR** that varies by a handful of fields | **Config-driven** RHACM policy, ranged over a list in rendered-config | `openshift-ai-models` |
| **Arbitrary manifests** with their own repo and cadence | RHACM policy that creates a **Placement and a Placement-driven ApplicationSet** | Hermes (redesign in progress) |

The middle row solves the same growth problem by a different route.
`openshift-ai-models` deploys real serving workloads, yet the repository does
not grow per model, because the model list lives in `config.openshiftAiModels`
and the policy ranges over it. Adding a model is a values change.

So the question is not only "is this platform or workload", it is **"can I
template this as a shaped CR?"** If yes, config-driven keeps it in-repo at zero
marginal cost. Use the third row only when the content is arbitrary.

### Why the RHOAI MaaS policies stay as policies

- They pass both tests above: any tenant of an RHOAI cluster wants these
  operators, and none carries its own version.
- They depend on what only RHACM hub templates can do at reconcile time: the
  gateway hostname from the cluster `Ingress` config, `gpu-nodes` cloning the
  cluster's own worker MachineSet, the Authorino TLS fix reading a Secret.
- Most of them render the shared `operator-install` chart by relative path,
  which resolves only inside this tree.
- They keep `make test`: the label contract, the 40-character cap,
  empty-policy detection and the OperatorGroup install-mode check that found
  six real failures.

## Why not a submodule

1. **It doesn't decouple.** PolicyGenerator and kustomize render the whole
   tree, so the content is still present at render time and still ours to
   break.
2. **Every workload bump becomes an AutoShift commit.** That is tighter
   coupling than a Git URL.
3. **Upstream won't accept a submodule per tenant workload,** so anything built
   that way can never be contributed.
4. **Argo CD submodule support is extra configuration** with no gain over a
   URL.

## Delivering a workload from its own repo: the RHACM way

RHACM 2.17 (the version AutoShift installs) documents multi-cluster application
delivery in *GitOps*, RHACM 2.17, §1.4–§1.12:

- **`GitOpsCluster`** registers the clusters an RHACM **Placement** selects
  with Argo CD.
- **One `ApplicationSet` on the hub** whose generator is that Placement
  (`clusterDecisionResource` with `configMapRef: ocm-placement-generator`).
  RHACM decides which clusters get the workload.
- **Push or pull, with the same ApplicationSet.** Push is the default: the hub
  Argo CD deploys. Pull adds the
  `apps.open-cluster-management.io/ocm-managed-cluster` and
  `pull-to-ocm-managed-cluster` annotations, plus
  `argocd.argoproj.io/skip-reconcile`. RHACM then hands each cluster its
  Application through ManifestWork, and that cluster's Argo CD deploys it.
  Status comes back to the hub in a `MulticlusterApplicationSetReport`.
- Agent mode, progressive rollout and ApplicationSet in any namespace are
  **Technology Preview** in 2.17. Stay on the GA pieces.

AutoShift already uses the first half: `policy-gitops-systems-argocd` and
`gitops-dev` create a `GitOpsCluster` and `ManagedClusterSetBinding` per
clusterset. Upstream **#252** (Argo CD agent modes and the RHACM GitOps
add-on) is the upstream owner of how clusters attach to Argo CD, so any design
here builds on it.

### The plan for `gitops-workloads`

The branch as first built was an RHACM policy that wrote a plain Argo CD
`Application` onto each cluster. That is on hold. The redesign:

1. The policy creates, on the hub, a `Placement` per workload from its config
   and AutoShift labels, plus one Placement-driven `ApplicationSet`.
2. **Pull model by default,** so each cluster's own Argo CD deploys and the hub
   controller isn't loaded with every cluster's resources.
3. A readiness (inform) policy reads the `MulticlusterApplicationSetReport`.
   Creating the ApplicationSet proves nothing about the workload, the same
   failure shape as a policy that names a CRD that doesn't exist yet.
4. **Turning a label off must only stop management.** When a cluster leaves a
   Placement, an ApplicationSet deletes that cluster's Application, which can
   delete the workload. Set `preserveResourcesOnDeletion: true` (or an
   equivalent), and prove it, to keep AutoShift's rule that labels off stop
   reconciling without uninstalling.
5. Raise the design on #252 before writing code.

`config.gitopsWorkloads` stays the shape of the input: one list entry per
workload (`name`, `repoUrl`, `targetRevision`, `path`, `destinationNamespace`).
The marginal cost of workload N+1 stays a few lines of values, not a
directory.

### The hub is an exception (decided 2026-11-08)

The Placement-driven ApplicationSet can't deliver to the hub itself. In the
pull model the hub-side Application and the delivered one would be the same
object, and registering `local-cluster` with `GitOpsCluster` doubles the Argo
CD controller cache, which is why AutoShift excludes it. Hermes, our only
workload today, runs on the hub.

So `gitops-workloads` has two paths, chosen per workload: `target: managed`
uses the RHACM Placement and ApplicationSet; `target: hub` has the RHACM
policy create one Argo CD Application in the hub's own Argo CD, with no
`local-cluster` registration. RHACM still places, enforces and reports on it.

We are not waiting for RHACM's GitOps add-on. Upstream #252 says it is still
in development, it is aimed at managed clusters rather than the hub, and
enabling it through `GitOpsCluster` disables the push model that AutoShift's
own systems Argo CD uses. Revisit the exception if the add-on later handles
the hub without that side effect.

### Risks to settle on a cluster

- **The hub deploying to itself.** AutoShift deliberately excludes
  `local-cluster` from its systems `GitOpsCluster`: registering the hub to
  itself doubled the Argo CD controller cache and OOMKilled it at 4Gi. Hermes
  runs on the hub, so pull-model registration of `local-cluster` has to be
  measured before committing.
- **Per-cluster facts.** Hermes's overlay hardcodes the cluster's base URL, CA,
  route host and storageClass. ApplicationSet template parameters from the
  Placement decision (cluster name, labels) can carry some of them; the rest is
  RHACM hub-template work.
- **Disconnected Git access.** In pull mode each cluster's Argo CD reaches Git
  itself, so a disconnected site needs a reachable Git mirror. Prefer an OCI
  chart in the same registry everything else is mirrored to, as
  `managed-autoshift` already supports with `ociRepo` / `ociVersion`.

## Still true, whatever the delivery mechanism

1. **Secrets stay out of band.** A workload's MaaS `sk-` key cannot live in
   Git, the same as the RDS connection URL and the Lightspeed API key.
2. **Namespace ownership** belongs to one side: the policy or the workload
   repo, never both.
3. **AppProject.** `default` permits everything. Multiple tenant workloads
   eventually want their own project; it's easier to start restricted.
4. **Fully qualify Argo CD kinds** in any lookup (`applications.argoproj.io`),
   because RHACM installs `app.k8s.io`, which shadows the short name.
