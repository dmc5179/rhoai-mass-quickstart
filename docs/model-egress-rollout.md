# Rolling out model egress controls

Plan, not yet executed. The `model-egress` policy currently ships one layer —
an `AdminNetworkPolicy` denying the cloud metadata endpoint — and three more
were written, committed at `da9217ca` in the AutoShift fork, then removed in
`71bb2d24` to be staged separately. This page is how the rest lands.

Everything here is checked against the live cluster (`OVNKubernetes`, so
`AdminNetworkPolicy`, `BaselineAdminNetworkPolicy` and `EgressFirewall` are all
served) and against the manifests in `da9217ca`. Recover those rather than
rewriting them; they are close to correct.

## Start from where we actually are

Three things are not what the earlier work assumed.

**1. The layer we shipped is off, and has never run.** There are two
independent gates and neither is set:

| Gate | Where | Current |
|---|---|---|
| `autoshift.io/model-egress: 'true'` | placement predicate | absent from `hub.yaml` |
| `config.modelEgress` | read by the manifest | absent from `local-cluster.yaml` |

So `policy-model-egress-baseline` exists as a root policy, its placement
resolves to zero clusters, and it is replicated nowhere:

```console
$ oc get policies.policy.open-cluster-management.io -n local-cluster | grep egress
  NOT REPLICATED
$ oc get adminnetworkpolicies.policy.networking.k8s.io
No resources found
```

This is the failure mode CLAUDE.md names first: **an unplaced policy has no
status at all.** It appears in no NonCompliant list, and `checkup.sh` is
correct not to flag it, because nothing claims it is enabled. We shipped a
security control and never turned it on. Stage 1 is turning it on, and that
work is real work — not a formality.

**2. RDS changed the blast radius while this was parked.** The manifests carry
a comment saying not to fence `redhat-ai-gateway-infra` because Authorino and
Limitador make outbound calls. That reason is now the weaker one. `maas-api`
holds a PostgreSQL connection to an RDS instance **outside the cluster** on
5432. Fencing that namespace severs the database, and we know exactly what
that looks like because we spent a day on it: `maas-api` CrashLoopBackOff, and
an *authenticated* gateway request answered `no healthy upstream`. Nothing in
the network layer says "egress policy."

Treat `redhat-ai-gateway-infra` and `kuadrant-system` as **out of scope for
fencing, permanently**, and say so in the config comments rather than relying
on whoever edits the values file to remember.

**3. The config shape is inconsistent between the shipped layer and the
removed ones.** The baseline reads a flat
`config.modelEgress.namespaces: ['llm']`. The removed layers read
`config.modelEgress.zones: [{namespace, podSelector, allow, egressFirewall,
aclLogging}]`. Two shapes for one feature is how a zone ends up fenced by one
layer and not another. **Unify on `zones` first**, deriving the baseline's
namespace list from `zones[].namespace`, and do it as its own change before
any new layer — it touches the one manifest that is already live.

## Reorder: measure before enforcing

`da9217ca` ordered the layers baseline → netpol → firewall → audit. Audit last
is the wrong way round for a rollout. ACL logging changes no enforcement
whatsoever, and it is the only instrument that tells you *why* a default-deny
broke something. It belongs before the layers that can break things, not after.

There is a second reason, and it is the useful one. The allowlist in stage 3
should be **derived from observed traffic, not guessed.** OVN's ACL logging
annotation takes separate levels for allowed and denied flows:

```yaml
k8s.ovn.org/acl-logging: '{"deny":"alert","allow":"notice"}'
```

ACLs only exist where a policy exists, so an unfenced namespace logs nothing.
The technique is to apply an allow-everything egress `NetworkPolicy` —
`policyTypes: [Egress]` with `egress: [{}]` — which denies nothing but creates
an ACL that matches every flow and logs it. Run the workload and the smoke
test under that, read the log, and build the allowlist from what the namespace
actually reached:

```bash
oc adm node-logs <node> --path=ovn/acl-audit-log.log
```

Time-box it; `llm` is quiet but this is unbounded in principle.

## The stages

Each is independently revertible, and each has an oracle that is not "the
policy says Compliant."

### Stage 1 — turn on the baseline

Unify the config shape, then set both gates. Blast radius is one link-local
address that no legitimate workload in a model namespace calls.

- **Change:** `model-egress: 'true'` in `hub.yaml`; `config.modelEgress` with
  `zones: [{namespace: llm}]` and `baseline.enabled: true`.
- **Verify:** the ANP exists (`oc get
  adminnetworkpolicies.policy.networking.k8s.io`), the policy is *replicated
  into `local-cluster`* — not merely Compliant at the root — and
  `scripts/35-smoke-test.sh` still passes.
- **Prove it bites:** from a pod in `llm`,
  `curl -m3 http://169.254.169.254/latest/meta-data/` must time out.
  Without this check the stage is untested; the rule denying nothing and the
  rule working look identical from the policy layer.
- **Revert:** set the label back to `'false'`. Note `pruneObjectBehavior:
  None` — this stops reconciliation but leaves the ANP in place. To actually
  remove it, delete the ANP by hand.

### Stage 2 — audit instrumentation, and measure

Recover `manifests/audit/acl-logging.yaml` from `da9217ca`. It patches two
keys on the Namespace with `musthave` — deliberately not the whole spec, so it
does not contest ownership with `openshift-ai-models`, which is what produced
the Authorino TLS deadlock.

- **Change:** the audit layer, plus a temporary allow-all logging
  `NetworkPolicy` for measurement.
- **Verify:** denied metadata calls from stage 1 appear in
  `ovn/acl-audit-log.log`. That single line proves the whole instrument.
- **Produce:** the egress inventory for `llm`. Expect it to be small — the
  model is an OCI modelcar, and **image pulls are made by kubelet, not by the
  pod, so they are not subject to `NetworkPolicy` at all.** Do not add
  registry rules for them; that is a common and invisible mistake. Check
  specifically whether anything reaches the Kubernetes API via
  `kubernetes.default`, which is the rule people most often omit.
- **Revert:** remove the annotation. Nothing enforcing changed.

### Stage 3 — default-deny plus allowlist

The dangerous one. Recover `manifests/netpol/network-policies.yaml`.

- **Scope to `llm` only.** Not `rhods-notebooks` (data scientists install
  packages), not the two gateway namespaces (see RDS, above).
- **DNS is emitted unconditionally** and must stay that way. A default-deny
  without it gives a model that times out on every lookup, which presents as a
  broken model and sends the next person to read vLLM logs.
- **Verify:** `scripts/35-smoke-test.sh` — a real prompt through the gateway
  to the GPU and back is the only oracle that covers the whole path.
- **Revert:** `oc delete networkpolicy default-deny-egress -n llm`. Have the
  command in the terminal before applying, and do this in a window where a
  broken model is acceptable.

### Stage 4 — EgressFirewall, where it earns its place

Recover `manifests/firewall/egress-firewall.yaml` and
`test/egress-firewall-applied.yaml`.

Be honest about where this is worth it. `EgressFirewall` answers the question a
CIDR cannot — an `ipBlock` for a CDN range admits every tenant of that CDN,
including one rented this morning — but **a namespace with no legitimate
external destinations gains nothing from FQDN rules.** If stage 2 shows `llm`
reaches nothing outside the cluster, default-deny alone is the control and an
EgressFirewall there is ceremony. The namespace that likely does want it is
`rhods-notebooks`, and that is a separate decision with its own users.

Three CRD constraints, verified against 4.22 and not negotiable:

- `metadata.name` is pinned to `^default$` — one EgressFirewall per namespace
- `spec.egress[].to` has `maxProperties: 1` — exactly one of `cidrSelector`,
  `dnsName`, `nodeSelector`
- a **terminal `Deny 0.0.0.0/0` is mandatory.** Rules evaluate in order, and
  with no EgressFirewall present the default is Allow — so without it the
  allowlist changes nothing while reporting Compliant. It is appended by the
  manifest, never configured; do not let it be repeated in values.

The readiness assertion ships with this stage and is the reason it is safe: an
EgressFirewall object can exist **unenforced** if OVN rejects a rule, and the
policy that created it still reports Compliant. `status.status` reading
`EgressFirewall Rules applied` is the only signal.

## What none of this closes

- **DNS exfiltration through subdomain labels.** That resolution leaves via
  the node, so neither NetworkPolicy nor EgressFirewall sees it. Needs CoreDNS
  forward-policy work.
- **NeMo Guardrails does not help here.** It filters content on the request
  path and cannot see an outbound call at all.
- **`pruneObjectBehavior: None` applies to every layer.** Disabling the
  feature stops reconciliation; it does not remove an ANP, a NetworkPolicy or
  an EgressFirewall. Rollback means deleting objects, not flipping labels.

## Open decisions

1. Does `rhods-notebooks` get fenced at all? It is the namespace with the
   strongest case for FQDN allowlisting and the strongest case for being left
   alone.
2. Should stage 1 land as its own upstream PR? It is the one change here that
   touches a manifest already on `main` in the fork.
