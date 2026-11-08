# Model egress guardrails: design

Design only. Nothing here is implemented, and no policy has changed. It extends
[model-egress-rollout.md](model-egress-rollout.md), which stays the plan of
record for the network stages; this page decides what else is worth building,
where each piece lives, and what is out of scope.

Source research:
`~/workspace/redhat-research/rhoai-model-guardrails/model-egress-guardrails.md`.
Checked against RHOAI 3.5, Connectivity Link 1.5 (the CRDs in `/tmp/rhcl15/`;
the 1.5 documentation was not in the portal index, so the 1.4 books are cited
for behaviour that did not change), and OpenShift 4.22.

## Summary and recommendation

The research describes four layers: network (L3/L4), L7 egress proxy
(OpenShell), semantic guardrails (NeMo), and adversarial testing (Garak).
On this stack only two of them are deliverable as RHACM policies today, and
both already have a home:

1. **Network egress stays in `model-egress` and grows in the staged order
   already planned:** unify config on `zones`, then baseline, audit, netpol,
   firewall. Each layer gets its own enablement label so a stage can be turned
   on alone. Two defects in the recovered `da9217ca` manifests must be fixed on
   the way (see "Corrections to the existing plan").
2. **NeMo Guardrails is added to `openshift-ai-models`** as an optional
   per-model block, rendered by a new policy in that directory with its own
   label. It is GA in RHOAI 3.5 (NeMo Guardrails 0.9.4), the TrustyAI component
   is already `Managed` in our DSC, and Red Hat documents exactly our topology:
   NeMo in front of the MaaS gateway, using its own MaaS key. It only becomes a
   control, rather than an option, if the raw model's `accessGroups` are
   narrowed so that consumers cannot skip it.
3. **`connectivity-link` does not grow.** Kuadrant is an ingress control plane.
   It already does the gateway-side work (who may call, how much) through the
   `AuthPolicy` and `TokenRateLimitPolicy` that the MaaS controller generates.
   We must not author competing policies on MaaS routes.
4. **Out of scope for policies:** OpenShell L7 egress and credential binding
   (Developer Preview, Helm chart, no operator), Kata (operator installed by
   `osc`, no `KataConfig`, and AWS needs bare metal or peer pods), Garak (a
   test-time activity, Technology Preview through EvalHub), DNS exfiltration
   (CoreDNS forwarding, not pod egress).

One reframing matters more than any single control. **A vLLM pod does not make
the outbound calls that prompt injection causes.** With tool calling on, vLLM
returns a tool call to its client and the client executes it. The namespace
that fetches `https://evil.example/exfil` is the agent's (OpenShell sandbox,
playground/OGX, a notebook, an external app), not `llm`. Fencing `llm` defends
against a compromised runtime or a poisoned model image; it does not stop
prompt-injected fetches. The zones that matter for the research's threat are
agent namespaces, which is why the `rhods-notebooks` question and any future
agent namespace are the real decisions.

## What the products already provide

### RHOAI 3.5

- **NeMo Guardrails, GA.** Deployed per namespace by the TrustyAI operator from
  a `NemoGuardrails` CR (`trustyai.opendatahub.io/v1alpha1`) whose
  `spec.nemoConfigs[]` names ConfigMaps holding `config.yaml` and `rails.co`.
  Prerequisite: TrustyAI `Managed` in the DSC, which `openshift-ai` already
  sets. The operator creates a Deployment, Service and Route. Endpoints:
  `/v1/chat/completions` (guarded inference) and `/v1/guardrail/checks`
  (check only). Built-in detectors run in-pod: regex, Presidio PII; LLM
  self-check and Hugging Face classifier rails are optional. Note the research
  doc's example CR (`v1`, `NeMoGuardrails`, `llmRef`, `config.rails`) is not the
  real API.
- **NeMo in front of MaaS is documented.** Article 7149113 places NeMo between
  the client and the MaaS gateway: NeMo authenticates to MaaS with its own MaaS
  API key, so MaaS quotas and access control still apply to guarded traffic.
  That article stores the key in a ConfigMap in plain text and notes it expires
  after 30 days.
- **NeMo on agent tool calls (Technology Preview).** A `NemoGuardrails` with an
  `mcpGateway` field attaches to an `MCPGatewayExtension`, enforcing rails on
  tool calls at the MCP Gateway. Connectivity Link 1.5 ships the MCP Gateway.
  This is the product's answer to the research's "execution rails".
- **FMS Guardrails Orchestrator is deprecated in 3.5.** Do not build on it.
- **Gen AI Studio playground guardrails (Technology Preview since 3.5 EA1).**
  Input and output toggles backed by NeMo, using another playground model as
  the judge. It is an evaluation aid inside the dashboard, not enforcement on
  the serving path.
- **Garak** appears as the "risk assessment" in EvalHub (Technology Preview).
- **OpenShell** is Developer Preview; its guide covers "controlled network
  egress". `agent-sandbox` and `osc` install its OLM prerequisites only.

### Connectivity Link 1.5 (Kuadrant)

| Policy | What it covers | Here |
|---|---|---|
| `AuthPolicy` | AuthN/AuthZ at the gateway (Authorino) | Generated by the MaaS controller per model namespace, plus `gateway-default-auth` in `openshift-ingress` |
| `TokenRateLimitPolicy` | Token quotas (Limitador) | Generated from `MaaSSubscription`, plus `gateway-default-deny` |
| `RateLimitPolicy` | Request-count limits | Not used; MaaS uses token limits |
| `TLSPolicy` | cert-manager certificates for listeners | Not used; the gateway serves the router certificate |
| `PlanPolicy` (extension) | Tiered request limits keyed by a CEL predicate | Overlaps `MaaSSubscription`; do not use on MaaS routes |
| `OIDCPolicy` (extension) | OIDC login flow at the gateway | Not a guardrail; MaaS uses API keys and OpenShift tokens |
| `TelemetryPolicy` (extension) | CEL-derived labels on metrics and fields on auth decision logs | The one candidate: attributes requests to `auth.identity`. Open question |

Every one of these acts on **requests arriving at the gateway**. None sees a pod
opening an outbound connection. So: identity, quota, request telemetry and
content inspection of the request path belong at or next to the gateway;
outbound connection control belongs in the model and agent namespaces.

### OpenShift 4.22 (OVN-Kubernetes)

- **AdminNetworkPolicy** (`v1alpha1`): cluster-scoped, `Allow`/`Deny`/`Pass`,
  evaluated before NetworkPolicy; an ANP `Allow` cannot be overridden by a
  namespace owner. Peers are namespaces, pods, `nodes` and `networks` (CIDR).
  **No FQDN peer** (Solution 7131736, OCPSTRAT-1575; nothing new in the 4.22
  release notes).
- **BaselineAdminNetworkPolicy**: a cluster singleton named `default`, the
  lowest tier. The docs warn that an empty namespace selector also selects
  OpenShift namespaces. We do not need it, and a careless one is the easiest way
  to cut the RDS path.
- **NetworkPolicy**: namespace default-deny plus `ipBlock`/selector allows. CIDR
  only.
- **EgressFirewall** (`k8s.ovn.org/v1`): the only FQDN option. One per
  namespace, named `default`, up to 8,000 rules, first match wins, governs only
  traffic leaving the cluster. DNS names are re-resolved on TTL (capped at 30
  minutes) by a node-side controller through `DNSNameResolver`; the pod must use
  the same resolvers or the IPs diverge. Host-network pods are unaffected. A
  terminal `Deny 0.0.0.0/0` **blocks the API servers** unless an earlier rule
  allows them (by CIDR or a `nodeSelector` rule). In shared gateway mode,
  return traffic for ingress is also subject to the rules.
- **ACL audit logging**: `/var/log/ovn/acl-audit-log.log` on each node. The
  namespace annotation `k8s.ovn.org/acl-logging` covers **NetworkPolicy and
  EgressFirewall** in that namespace. ANP and BANP are logged only when **the
  policy object itself** carries the annotation. Rate and size limits come from
  `policyAuditConfig` on the cluster Network CR.
- **Egress IP**: a fixed source IP per namespace or pod, supported on AWS. Not a
  control in itself, but it lets an out-of-cluster control (AWS Network
  Firewall, a corporate proxy) recognise model or agent traffic. Not proposed
  now.

## Requirements

"Cluster?" is whether only a live cluster can prove it works. Rendering and
`make test` cannot show that a rule denies anything.

| # | Requirement (from the research) | Covered by | Gap | Proposed mechanism | Cluster? |
|---|---|---|---|---|---|
| 1 | Deny the cloud metadata endpoint | `policy-model-egress-baseline` ANP | Never enabled; denies are not logged | Stage 1: set both gates, add `acl-logging` annotation on the ANP | Yes: `curl` must time out and a deny line appear |
| 2 | Cluster-wide baseline across AI namespaces | Same ANP, subject `autoshift.io/ai-workload` | Namespace list comes from the flat shape | Stage 0: derive the label set from `zones[].namespace` | No |
| 3 | Audit every blocked egress attempt | Nothing | No annotation anywhere | Stage 2: `policy-model-egress-audit`, namespace annotation per zone | Yes |
| 4 | Default-deny egress per namespace | Nothing (recovered `netpol` manifest) | Not applied | Stage 3: `policy-model-egress-netpol` | Yes: smoke test is the oracle |
| 5 | DNS only to cluster DNS | ANP `allow-cluster-dns`; netpol emits it again | None in-cluster | Keep both, unconditional | Yes |
| 6 | CIDR allowlist | Nothing | Not applied | `zones[].allow`, verbatim NetworkPolicy rules | Yes |
| 7 | FQDN allowlist (the CDN case) | Nothing (recovered `firewall` manifest) | Recovered manifest omits API-server allow | Stage 4: `policy-model-egress-firewall` + `-ready`, API-server allow emitted before the terminal deny | Yes |
| 8 | Proof OVN programmed the firewall | Recovered `test/egress-firewall-applied.yaml` | Not applied | Ship with stage 4 | Yes |
| 9 | Input rails: jailbreak, PII, harmful content | NeMo Guardrails (GA), not deployed | No CR, no config | `models[].guardrails` in `openshift-ai-models`, new `-guard` policy | Yes |
| 10 | Output rails: sensitive data | Same | Same | Same | Yes |
| 11 | Guardrails cannot be bypassed | Nothing | A consumer with a MaaS key for the raw model skips NeMo | Narrow `models[].accessGroups` to the guard's identity; consumers use the NeMo route | Yes |
| 12 | Execution rails on tool calls | NeMo + MCP Gateway (Technology Preview) | Not deployed | Later; `NemoGuardrails.spec.mcpGateway`. Not in this round | Yes |
| 13 | Interactive guardrail testing | Playground guardrails (Technology Preview) | Admin enablement step unknown | None from policy; document | Yes |
| 14 | Who may call a model, and how much | `MaaSAuthPolicy`, `MaaSSubscription` → generated `AuthPolicy`, `TokenRateLimitPolicy` | None | Already in `openshift-ai-models` | No (proven) |
| 15 | Attributable request telemetry | Kuadrant observability on | No identity labels | Possibly `TelemetryPolicy` on the gateway. Open question | Yes |
| 16 | L7 egress (host, path, method, process) | Nothing GA | OpenShell is Developer Preview | Out of scope. A forward proxy is a workload, not a platform policy | n/a |
| 17 | Credential isolation | Partial: MaaS external models inject the provider key at the gateway (Technology Preview) | Agents still hold MaaS keys | Out of scope (OpenShell) | n/a |
| 18 | Kernel or VM isolation | `osc` installs the operator | No `KataConfig`; AWS needs bare metal or peer pods | Out of scope | n/a |
| 19 | Adversarial testing | EvalHub risk assessment with Garak (Technology Preview) | Not run | Out of scope for policy; run against the guarded route before stage 3 | n/a |
| 20 | DNS exfiltration | Nothing | Resolution leaves via the node | Out of scope; CoreDNS work | n/a |
| 21 | Stable source IP for external firewalls | Nothing | Not needed yet | Egress IP, if an external control is adopted | n/a |

## Proposed RHACM policy changes

### `model-egress` grows

| Policy | Mode | Label (all also need `model-egress: 'true'`) | Depends on |
|---|---|---|---|
| `policy-model-egress-baseline` | enforce | `model-egress` | none |
| `policy-model-egress-audit` | enforce | `model-egress-audit` | baseline |
| `policy-model-egress-netpol` | enforce | `model-egress-netpol` | audit |
| `policy-model-egress-firewall` | enforce | `model-egress-firewall` | netpol |
| `policy-model-egress-ready` | inform | `model-egress-firewall` | firewall |

Why a label per layer rather than "a layer is on when its config key is
present": a placed policy whose template renders nothing reports Compliant, and
`make test` fails the build on it. Per-layer labels mean each placed policy
always has something to apply, and each stage is switched on and off alone. The
layer policies need their own placement files (two predicates each), so
`placementBindingDefaults.name` stays and each extra placement gets an explicit
binding name. Declare every new label in **both** `clustersets/_example.yaml`
and `clusters/_example.yaml` with a non-empty value (`'false'`); a `''` sample
leaves the policy unexercised in CI.

Config, unified on zones (stage 0, its own change, before any new layer):

```yaml
config:
  modelEgress:
    baseline:
      priority: 50
      aclLogging: {deny: alert}      # annotation on the ANP itself
    zones:
      - namespace: llm
        aclLogging: {deny: alert, allow: notice}
        podSelector: {}
        allowKubeApi: false          # netpol: control-plane nodes on 6443
        allow: []                    # NetworkPolicy egress rules, verbatim
        egressFirewall: []           # EgressFirewall rules, verbatim, in order
```

Template rules, all failing loudly with `fail` and a message naming the key:

- `zones` missing or empty, or a zone without `namespace`: fail (baseline and
  every layer).
- A zone naming a namespace on the never-fence list below, or any
  `openshift-*` or `kube-*` namespace: fail. This turns the README warning into
  a check.
- `model-egress-firewall` placed and no zone has `egressFirewall`: fail.
- `egressFirewall` rules containing a `0.0.0.0/0` deny: fail; the manifest
  appends it.
- The firewall manifest emits, before the terminal deny, an `Allow` with
  `nodeSelector: {matchExpressions: [{key: node-role.kubernetes.io/control-plane, operator: Exists}]}`
  so the API servers stay reachable. Not configurable.

Numbers come from typed YAML config (`priority`), never from labels, and nested
values are rendered with `toJson`, as the recovered manifests already do.

### `openshift-ai-models` grows

| Policy | Mode | Label | Depends on |
|---|---|---|---|
| `policy-openshift-ai-models-guard` | enforce | `openshift-ai-models-guardrails` (plus `openshift-ai-models`) | `policy-openshift-ai-models-maas` |
| `policy-openshift-ai-models-guard-ready` | inform | same | guard |

Both names are under 40 characters. Per model, an optional block:

```yaml
config:
  openshiftAiModels:
    models:
      - name: granite-4-tiny-gpu
        accessGroups: ['maas-guard']           # narrowed, see requirement 11
        guardrails:
          namespace: llm-guard                 # where NeMo runs
          keySecret: nemo-maas-key             # created out of band
          input: [regex, pii]
          output: [pii]
          blockedPatterns: ['password', 'api_key', '\\d{3}-\\d{2}-\\d{4}']
```

It renders a ConfigMap (`config.yaml` pointing `base_url` at the MaaS gateway,
`passthrough: true`, the API key read from an environment variable) and a
`NemoGuardrails` CR with `security.opendatahub.io/enable-auth: 'true'` and
`env` from `keySecret`. The MaaS key is minted at runtime by the MaaS API and
expires, so, like `maas-db-config`, **no policy creates it**: it is created out
of band and `-guard-ready` reports when the Secret is missing or the
`NemoGuardrails` phase is not `Ready`. The policy fails loudly when a model has
`guardrails` but no `namespace` or `keySecret`.

Why here and not a new directory: the rails are per model, read the same
config, and are only meaningful together with that model's `accessGroups`.
Keeping them in one config record is what stops the guard and the bypass from
drifting apart. Why a separate policy: `NemoGuardrails` is a TrustyAI CRD on its
own readiness timeline, and a `ConfigurationPolicy` naming a CRD that does not
exist yet reports Compliant.

No DSC change: TrustyAI is already `Managed` and `mCPGuardrailsOnlyMode` is not
wanted.

### `connectivity-link` does not grow

- Do not author `AuthPolicy`, `TokenRateLimitPolicy`, `RateLimitPolicy` or
  `PlanPolicy` targeting the MaaS Gateway or model HTTPRoutes. The MaaS
  controller owns those; a second writer is the same two-owners fight that
  produced the Authorino TLS deadlock.
- `TelemetryPolicy` on `maas-default-gateway` adds no enforcement and is the
  only 1.5 extension that helps here. Deferred to an open question, because
  whether the MaaS controller tolerates it is unknown.
- MCP Gateway execution rails come later, as a `guardrails.mcpGateway` option,
  once the Technology Preview is worth carrying.

### Order

```
stage 0  unify config on zones (baseline manifest only)
stage 1  baseline on, ANP denies logged                    <- prove metadata deny bites
stage 2  audit annotation + temporary allow-all netpol      <- measure llm and llm-guard
G1       guardrails for one model, accessGroups narrowed    <- needs stage 2 inventory
stage 3  netpol default-deny for llm (and llm-guard)        <- smoke test through NeMo
stage 4  EgressFirewall only where a zone has external FQDNs
```

G1 sits between 2 and 3 because NeMo calls the MaaS gateway, and stage 3 has to
allow that path. Measuring first means the allowlist contains it.

## What must never be fenced

None of these may appear in `zones`, and none may be selected by an ANP or BANP
egress `Deny` that could match their peers. The template enforces the list.

| Namespace | Why |
|---|---|
| `redhat-ai-gateway-infra` | `maas-api` holds a PostgreSQL connection to RDS outside the cluster on 5432. Fenced, it CrashLoops and authenticated requests return `no healthy upstream`. `maas-controller` talks to the API server |
| `kuadrant-system` | Authorino calls the API server (TokenReview, SubjectAccessReview) and `maas-api`; Limitador serves the gateway |
| `openshift-ingress` | The MaaS gateway Envoy reaches model pods, Authorino and Limitador, and for MaaS external models (Technology Preview) it is the pod that calls the provider. The router pods share the namespace |
| `models-as-a-service` | MaaS CR namespace; listed so nobody fences it by analogy |
| `openshift-operators` | `kuadrant-operator-controller-manager` and the operators it deploys |
| `redhat-ods-operator`, `redhat-ods-applications` | RHOAI operator, dashboard, TrustyAI operator |
| `openshift-dns` | Every zone depends on it |
| any `openshift-*`, `kube-*` | Platform |

Two more constraints that are not namespaces:

- **The RDS path is VPC traffic, not internet traffic.** Any future BANP or ANP
  that denies `10.0.0.0/16` or `0.0.0.0/0` must use a label selector, never
  `namespaces: {}`, or it reaches `redhat-ai-gateway-infra`.
- **The API servers.** A default-deny netpol cuts them unless `allowKubeApi`
  is set; a terminal EgressFirewall deny cuts them unless the control-plane
  allow is emitted. The current `llm` model has no `router.scheduler`, so no EPP
  pod watches the API, but adding a scheduler later changes that.

## Corrections to the existing plan

Found while checking the recovered manifests against the 4.22 documentation:

1. **Stage 2's oracle would fail.** The rollout says the stage-1 metadata denies
   will appear in `acl-audit-log.log` once the namespace is annotated. The
   namespace annotation logs NetworkPolicy and EgressFirewall ACLs; ANP denies
   are logged only when the ANP carries the annotation. Fix: annotate the ANP in
   stage 1 (`baseline.aclLogging`).
2. **The recovered firewall manifest blocks the API servers.** It appends
   `Deny 0.0.0.0/0` with no API-server allow, which the 4.22 docs call out
   directly. Harmless for a model pod that never calls the API; fatal for
   anything that does. Fix: emit the control-plane `nodeSelector` allow.
3. **`hf://` URIs make pod egress.** The storage initializer downloads from
   Hugging Face inside the pod, unlike `oci://` modelcars that kubelet pulls.
   The image-pull note in the rollout is correct for our current models only.
   The template could fail when a fenced zone serves an `hf://` model without
   an allow; at minimum document it.
4. **The research's NeMo CR and the "guardrails orchestrator" are stale.** The
   real CR is `NemoGuardrails` `v1alpha1` with `nemoConfigs`; FMS Orchestrator
   is deprecated in 3.5.

## AutoShift rules this design respects

- **Labels only stop management.** Every policy here keeps
  `pruneObjectBehavior: None`. Turning `model-egress-netpol` off leaves the
  NetworkPolicies in place; rollback is `oc delete`, with the command ready
  before the stage is applied. Turning guardrails off leaves NeMo running and,
  worse, leaves `accessGroups` narrowed; reverting the model's access is a
  values change, not a label.
- **`adopt` is the irreversible step.** None of these labels is set before the
  stage that needs it.
- **Fail loudly.** Missing or contradictory config fails with a named key; no
  `| default dict` on a required lookup; never an empty `object-templates-raw`.
- **Readiness lives in `test/` as inform policies** (`-ready`, `-guard-ready`),
  never inside an enforcing one.
- **`musthave` on Namespace patches only the keys it owns** (labels,
  annotation). `openshift-ai-models` owns the Namespace object.
- **No plain Argo CD.** Everything is an RHACM policy. A forward proxy or an
  OpenShell deployment, if ever wanted, is a workload delivered by a
  Placement-driven ApplicationSet under an RHACM policy, per
  [what-belongs-in-autoshift.md](what-belongs-in-autoshift.md).
- **Gate:** `GOTOOLCHAIN=auto make test` (check the skipped count) and Vale on
  `policies/` and `docs/`; policy comments are prose too.

## Open questions

1. **Does `rhods-notebooks` get fenced?** It is where an agent most plausibly
   runs, so it has the strongest case for an EgressFirewall, and data
   scientists installing packages give it the strongest case for being left
   alone. Possibly a separate agent namespace is the better first zone.
2. **Is stage 1 (with stage 0) its own upstream PR?** It touches the one
   manifest already on `main` in the fork. Recommendation: yes, and include the
   ANP logging annotation in it.
3. **Where does NeMo run:** in `llm`, or a separate `llm-guard` namespace that
   is fenced on its own terms? A separate namespace keeps the model zone's
   allowlist free of a gateway egress rule.
4. **How does NeMo reach the gateway once fenced?** `base_url` on
   `maas.<domain>` resolves to the gateway's AWS load balancer, so the traffic
   leaves the cluster and an `ipBlock` would have to track load-balancer IPs.
   The in-cluster Service avoids that but may break SNI against the listener
   hostname. Needs a cluster.
5. **Who mints and rotates the NeMo MaaS key** every 30 days, and is a longer
   expiry acceptable for a service identity?
6. **Is narrowing `accessGroups` acceptable** for every guarded model? It
   means the playground, Lightspeed and agents go through NeMo too, or get a
   separate unguarded subscription by explicit decision.
7. **`TelemetryPolicy` on the MaaS gateway:** worth trying on a cluster to see
   whether the MaaS controller leaves it alone?
8. **How is playground guardrails enablement switched on** by an
   administrator? The guide says only "if your cluster administrator has
   enabled guardrails".
9. **Is per-layer labelling acceptable upstream,** given AutoShift otherwise
   prefers one label per directory?

## Citations

- [RHOAI 3.5: Ensuring AI safety with guardrails](https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/enabling_ai_safety_with_guardrails/index) (NeMo CR, MCP Gateway integration, FMS deprecation)
- [RHOAI 3.5 release notes](https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/release_notes/index) (playground guardrails Technology Preview, OpenShell Developer Preview, FMS deprecation)
- [RHOAI 3.5: Experimenting with models in the gen AI playground](https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/experimenting_with_models_in_the_gen_ai_playground/index)
- [RHOAI 3.5: Govern LLM access with Models-as-a-Service](https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/govern_llm_access_with_models-as-a-service/index) (generated AuthPolicy and TokenRateLimitPolicy, PostgreSQL prerequisite, external models)
- [RHOAI 3.5: Evaluating AI systems](https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/evaluating_ai_systems/index) (Garak risk assessment)
- [Red Hat OpenShift AI: Supported Configurations](https://access.redhat.com/articles/rhoai-supported-configs) (NeMo Guardrails GA 0.9.4, EvalHub Technology Preview)
- [Article 7149113: Securing External LLMs on RHOAI with MaaS and NeMo Guardrails](https://access.redhat.com/articles/7149113)
- [Article 7143091: NeMo Guardrails in RHOAI](https://access.redhat.com/articles/7143091)
- [Connectivity Link 1.4 release notes](https://access.redhat.com/documentation/en-us/red_hat_connectivity_link/1.4/html-single/release_notes/index) and [Deploy Red Hat Connectivity Link 1.4](https://access.redhat.com/documentation/en-us/red_hat_connectivity_link/1.4/html-single/deploy_red_hat_connectivity_link/index) (TokenRateLimitPolicy with AuthPolicy); 1.5 extension behaviour from the CRD schemas
- [Supported Configurations for Red Hat Connectivity Link](https://access.redhat.com/articles/7092611)
- [OpenShift 4.22: Network security](https://access.redhat.com/documentation/en-us/openshift_container_platform/4.22/html-single/network_security/index) (ANP, BANP, EgressFirewall limits and DNS resolution, audit logging)
- [OpenShift 4.22: OVN-Kubernetes network plugin, egress IP](https://access.redhat.com/documentation/en-us/openshift_container_platform/4.22/html-single/ovn-kubernetes_network_plugin/index)
- [OpenShift 4.22 release notes](https://access.redhat.com/documentation/en-us/openshift_container_platform/4.22/html-single/release_notes/index)
- [Solution 7131736: FQDN egress peers in AdminNetworkPolicy](https://access.redhat.com/solutions/7131736)
