# MaaS external models through AutoShift: design

Status: draft, 2026-11-09. Nothing here has run on a cluster. No provider key exists yet.
The draft fork patch is in `~/workspace/maas-drafts/external-models/`.

## Summary and recommendation

RHOAI 3.5.2 MaaS can put a model hosted by an outside provider, such as OpenAI or Anthropic,
behind the same gateway, API keys, subscriptions and authorization policies as a model served on
the cluster. Two new custom resources do the routing. An `ExternalProvider` holds the endpoint,
the auth type and a reference to a Secret with the provider key. An `ExternalModel` maps a
client-facing model name to one or more providers, with weights. After that you add the usual
`MaaSModelRef` (`kind: ExternalModel`), `MaaSSubscription` and `MaaSAuthPolicy`. The whole feature
is **Technology Preview**. The native-format passthrough modes are a **second** Technology Preview
on top of it.

**Recommendation:** add it as a new config-driven AutoShift policy directory,
`openshift-ai-external-models`. It gets its own label and its own top-level config block,
`config.openshiftAiExternalModels`, and follows the `openshift-ai-models` pattern. The provider
key stays out of Git. A new helper, `scripts/maas-external-key.sh`, puts it in a Secret, and an
inform policy checks that Secret exists and has the label it needs. Start with
`apiFormat: openai-chat`, which is the only metered format. Turn passthrough on per model only with
an explicit `allowUnmetered: true`.

The biggest finding is in token limits. **MaaS subscription token limits apply only to the OpenAI
Chat Completions format.** Models with `apiFormat: messages` (Anthropic) or `openai-responses` are
not metered at all. So "Anthropic behind MaaS token limits" does not work through the native
Messages format in 3.5. The draft policy refuses that configuration unless the model sets
`allowUnmetered: true`.

## Findings

Sources:

- **[G]**: *Govern LLM access with Models-as-a-Service*, RHOAI Self-Managed 3.5,
  <https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/govern_llm_access_with_models-as-a-service/index>.
  Section numbers below refer to this guide.
- **[RN]**: *3.5 Release notes*, RHOAI Self-Managed 3.5.
- **[A]**: Red Hat article 7149113, *Securing External LLMs on Red Hat OpenShift AI with MaaS
  and NeMo Guardrails* (updated 16 Oct 2026).
- **[CRD]**: live CRD schema on this cluster (rhods-operator 3.5.2), read-only. Used only where
  the documentation is silent.

### Support status

| Piece | Status | Source |
|---|---|---|
| External models (routing, `openai-chat` translation) | Technology Preview | [G] 1.1, 1.21.1; [A] |
| Multi-provider API passthrough (`messages`, `openai-responses`) and body-based model routing | Technology Preview, separately | [G] 1.1, 1.21.3; [RN] 3.1 |
| Dashboard *External models* tab | Technology Preview | [RN] 3.1 |
| Multitenancy | ExternalModel is supported for the **default tenant only**. Other tenants have the controller disabled | [G] 1.21.1 |

[G] 1.21.3 says plainly that routing with the default `openai-chat` format "is not affected by the
Technology Preview scope" of passthrough. It is still under the external-models Technology Preview.

### The resources

All live in one model namespace, for example `llm` or here `external-models`. Only the
subscription and the authorization policy go in `models-as-a-service`.

**Secret** ([G] 1.21.4 step 1; [CRD]): `type: Opaque`, data key **`api-key`**, label
**`inference.llm-d.ai/ipp-managed: "true"`**. It must be in the same namespace as the
`ExternalProvider` ([CRD] `spec.auth.secretRef` description). [A] adds that without the label
"the gateway does not inject the API key, and requests to OpenAI fail with a 401 error".

**ExternalProvider** (`inference.opendatahub.io/v1alpha1`, [G] 1.21.4 step 2; [CRD]):

| Field | Required | Notes |
|---|---|---|
| `spec.provider` | yes, max 63 | Built-in: `openai`, `anthropic`, `azure`, `vertex`, `bedrock`. Any other string is accepted and gets `Authorization: Bearer` ([G] 1.21.3.4, 1.21.4) |
| `spec.endpoint` | yes | FQDN only, no scheme or path ([G] 1.21.4). [CRD] pattern requires at least one dot |
| `spec.auth.type` | yes | `apikey`, `sigv4` (Bedrock), `oauth2` (Vertex AI, a GCP service-account JSON key in the Secret) ([G] 1.21.3.5). [CRD] also lists `simple`, which the docs never mention |
| `spec.auth.secretRef.name` | yes | |
| `spec.config` | no | String map. For Vertex AI: `project`, `location`, `anthropicVersion` ([G] 1.21.3.6) |
| `status.phase` | | `Ready` or `Failed` (missing Secret, or Istio resources it could not create). "Reflects controller reconciliation state, not runtime request health" ([CRD]) |

When it is created, the controller creates a `Service`, `ServiceEntry` and `DestinationRule`
([G] 1.1, 1.21.4).

**ExternalModel** (`inference.opendatahub.io/v1alpha1`, [G] 1.21.4 step 3; [CRD]):

| Field | Notes |
|---|---|
| `spec.modelName` | Optional. The client-facing name, defaulting to `metadata.name` ([CRD]; [G] 1.21.3.7) |
| `spec.externalProviderRefs[]` | 1 to 64 entries ([CRD]) |
| `.ref.name` | An `ExternalProvider` in the same namespace, which must be `Ready` ([G] 1.21.4) |
| `.targetModel` | The provider's model ID |
| `.apiFormat` | `openai-chat`, `messages`, `openai-responses`, `vertex-messages` ([G] 1.21.3.2) |
| `.path` | The outgoing path: `/v1/chat/completions`, `/v1/messages`. [CRD]: must start with `/`, and supports `{key}` placeholders from config |
| `.weight` | 0 to 100. [CRD] default 1, docs say use 100 for a single provider. **0 disables the route** ([G] 1.21.4) |
| `.auth`, `.config` | Per-route overrides of the provider's auth and config ([CRD] only; undocumented) |
| annotations `maas.opendatahub.io/tls` (default `true`) and `maas.opendatahub.io/port` (default `443`) | With `tls: "false"` the provider key travels in plain text ([G] 1.21.4) |

The controller creates an HTTPRoute, named in `status.httpRouteName` ([G] 1.21.4; [CRD]).

**MaaS registration** ([G] 1.21.4 steps 4 and 5): a `MaaSModelRef` in the ExternalModel's
namespace with `spec.modelRef.kind: ExternalModel` (the [CRD] enum is `LLMInferenceService` |
`ExternalModel`). Then a subscription and an authorization policy, "the same way as for internal
models". [A]: the `MaaSModelRef` stays `Pending`, reason `NoPairingFound`, until both exist.

**Name trap** ([A]): "Keep `metadata.name`, `spec.modelName`, and `targetModel` identical. If they
differ ... requests are routed but the gateway injects an empty key, and OpenAI returns
`401 You didn't provide an API key`." This contradicts the docs' own Anthropic example, where
`claude-sonnet` maps to `claude-sonnet-4-20250514` ([G] 1.21.4). It needs a live test (open
question 1).

**Legacy CRD.** `externalmodels.maas.opendatahub.io` (the 3.4 single-resource shape:
`provider`, `endpoint`, `credentialRef`, `targetModel`) is still served alongside the 3.5
`inference.opendatahub.io` pair ([CRD]). [G] 1.9 still verifies the old CRD name, while [G] 1.21
uses only the new pair. Use `inference.opendatahub.io`.

**Who reconciles them** ([CRD], RBAC on the live cluster): the `payload-processing` Deployment in
`openshift-ingress`. Its `payload-processing-reader` ClusterRole grants create/update on
ExternalProvider and ExternalModel, Services, HTTPRoutes, ServiceEntries and DestinationRules, and
**get/list/watch on Secrets cluster-wide**. Whether the binding is cluster-wide was not checked.

### Translation and passthrough ([G] 1.21.3.1 to 1.21.3.3)

The gateway works out the client's format from the request path: `/v1/chat/completions`,
`/v1/messages` or `/v1/responses`. Any other path gets `400`.

| Client sends | ExternalModel `apiFormat` | Behavior |
|---|---|---|
| openai-chat | openai-chat | Translation (path rewriting; never passthrough) |
| openai-chat | messages | Translation, OpenAI to Anthropic |
| openai-chat | vertex-messages | Translation |
| messages | messages | **Passthrough** (Technology Preview) |
| messages | messages, Vertex AI provider / vertex-messages | Translation with Vertex adjustments |
| openai-responses | openai-responses | **Passthrough** (Technology Preview) |
| anything else | | `400` |

Passthrough exists to keep provider-specific features: Anthropic prompt caching, extended
thinking and beta flags, and the Responses API ([G] 1.21.2.1). Clients that use only the OpenAI SDK
do not need it.

**Auth headers to the provider** ([G] 1.21.3.4): `openai` gets `Authorization: Bearer`,
`anthropic` gets `x-api-key`, `azure` gets `api-key`, `vertex` gets a Bearer OAuth2 token, and
`bedrock` gets SigV4 signing. **Auth headers from callers** ([G] 1.21.1, 1.21.4 next steps):
callers send their MaaS key as Bearer, or as `x-api-key` for `messages` models. If any
ExternalModel has `apiFormat: messages`, **`x-api-key` authentication is enabled cluster-wide for
every model**.

### Token limits ([G] 1.21.3.8)

- MaaS subscription token limits "apply only to OpenAI Chat Completions format requests. Models
  configured with `apiFormat: messages` or `apiFormat: openai-responses` are not metered at the
  MaaS subscription level". Rate limiting reads `usage.total_tokens`. "Use provider-level rate
  limits to manage consumption for these models."
- That wording is about the model's `apiFormat`, not the client's format. A client sending OpenAI
  format to an `apiFormat: messages` model is translated, and the docs still put it in the
  unmetered category. That needs a live test (open question 2).
- For `openai-chat` models, token limits are set in the subscription exactly as for local models
  ([G] 1.21.4 step 5). A subscription and an authorization policy are still needed for unmetered
  models: they decide who may mint a key and call the model at all.

### Other limitations ([G] 1.21.3.8, 1.21.2.4)

- **Streaming:** across formats, the gateway buffers the entire provider response before sending
  it. Real-time streaming works only with passthrough in the provider's native format. Docs do not
  say whether `openai-chat` to an `openai` provider streams; by the definition (same format) it
  should (open question 3).
- **Bodies over 16 KB** may be truncated when the Kuadrant wasm shim runs with
  `allow_on_headers_stop_iteration`. Agent frameworks send 14 KB-plus prompts routinely (see the
  hub.yaml comment on granite's 14,208-token turn), so this matters.
- **Unknown model names** are not rejected cleanly. The request may end in a routing error or a
  timeout downstream.
- **NeMo Guardrails** response guards read `choices`, so they do not inspect Messages or Responses
  output. Use `openai-chat` where output guarding matters.
- **Vertex AI** strips `context_management`, `betas`, `mcp_servers`, `service_tier`, `container`
  and `stream_options`, and removes the `anthropic-beta` header ([G] 1.21.3.6).
- [A]: GPT-5 and o-series models reject `max_tokens`, which many clients (including the gen AI
  playground) still send. Prefer `gpt-4o` or `gpt-4o-mini` for a first test.
- [A]: the dashboard flag `OdhDashboardConfig.spec.dashboardConfig.externalModels: true` is
  part of the setup. On this cluster today, `dashboardConfig` holds only `mcpCatalog: true`.

### Egress and TLS

- The gateway Envoy in `openshift-ingress` makes the outbound call. TLS origination is done by
  Istio, with a `DestinationRule` in TLS mode `SIMPLE` and a `ServiceEntry` over HTTPS
  ([G] 1.21.4). That this is the gateway pod is inferred from the Istio resources and from
  `docs/model-guardrails-design.md`, which says the same; the docs never name the pod.
- **The fork's `model-egress` policy does not affect this.** It is one `AdminNetworkPolicy`,
  `ai-workload-egress-baseline`, priority 50. It denies `169.254.169.254/32` and
  `fd00:ec2::254/128` and explicitly allows cluster DNS, for namespaces labeled
  `autoshift.io/ai-workload`. Today only `llm` has that label. `openshift-ingress` is on its
  "never fence" list. The external-models namespace holds no pods, so fencing it would do nothing
  either way.
- Today nothing on this cluster limits which providers can be reached: the cluster-wide proxy is
  empty and there are no `EgressFirewall` objects. FQDN allowlisting of provider endpoints would
  need an `EgressFirewall` in `openshift-ingress`, which the router pods share. That is the
  "deferred" layer in the `model-egress` README, and risky. Out of scope here.
- **Disconnected:** not possible. The guide's own `setup-maas.sh` turns phase 8 off in
  disconnected mode.

### FIPS

The docs say nothing about FIPS for external models. I searched [G] and [RN] and found no mention.
What is known:

- This cluster is **not** in FIPS mode today: `install-config` has no `fips: true`.
  `docs/rebuild-fips-plan.md` plans the rebuild.
- In FIPS mode, TLS origination to the provider happens in the gateway's Envoy. Provider
  endpoints such as api.openai.com and api.anthropic.com normally negotiate TLS 1.2 or 1.3 with
  ECDHE and AES-GCM, which FIPS allows. **Unverified.**
- SigV4 (HMAC-SHA256) and OAuth2 JWT signing use FIPS-approved algorithms. Whether the
  `payload-processing` binary uses a validated module is **unknown**. Compare the FIPS plan's
  finding that OpenShell's vendored Rust crypto ignores the kernel flag.
- Whatever the cluster's FIPS posture, the prompt leaves the cluster and is processed outside any
  FIPS boundary. That is a policy decision, not a cryptographic one.

### What the old imperative path did, and what not to copy

`rhoai-maas-guide/scripts/setup-maas.sh --with-external-models` (phase 8) does the following:

1. Takes `--external-model-api-key` **on argv**, or from `EXTERNAL_MODEL_API_KEY`.
2. Creates the namespace `external-models` (labels `opendatahub.io/generated-namespace`,
   `maas.opendatahub.io/gateway-access`).
3. Creates `<provider>-api-key` with `api-key=` and labels it `ipp-managed` on 3.5
   (`bbr-managed` on 3.4).
4. Applies per-provider kustomizations under `manifests/08-external-models/<provider>/`.
5. Waits for the `MaaSModelRef` to be `Ready`, mints an ephemeral key, sends one chat
   completion, and deletes the key.

Two things not to copy:

- **The key on argv** puts it in the process list and in shell history.
- **The guide's Anthropic manifest** sets `apiFormat: openai-chat` with `path: /v1/messages`.
  [G] 1.21.3.2 says the opposite: `apiFormat` is the provider's output format, so
  `openai-chat` sends an OpenAI body to the Messages endpoint. The docs' Anthropic example uses
  `apiFormat: messages`. The guide's version looks wrong.

The guide also gives each provider a subscription that grants `system:authenticated` 10,000
tokens an hour. Here every ServiceAccount on the cluster could then spend real money.

## Design

### Shape

A new policy directory, **not** an extension of `openshift-ai-models`:

- `openshift-ai-models` fails when `config.openshiftAiModels.models` is empty, which is correct
  for it. A cluster with external models but no GPU could not use it.
- External models have a different risk profile: prompts leave the cluster, a third party bills
  for them, and the feature is Technology Preview. Each of those deserves its own opt-in label, in
  line with "gate everything" and with `adopt` turning on every enabled label at once.
- The template still reads `openshiftAiModels.models` names, to refuse a name that would collide
  with a local model's `<name>-default` and `<name>-access` objects.

| | |
|---|---|
| Directory | `policies/stable/openshift-ai-external-models` |
| Label | `autoshift.io/openshift-ai-external-models`, declared in both `_example.yaml` files. `'false'` in `hub.yaml` |
| Config | `config.openshiftAiExternalModels` (sample in `clustersets/_example.yaml`; absent from `hub.yaml`) |
| Placement | label only, no `cluster-type` predicate (the hub would never match `spoke`) |

### Config

```yaml
openshiftAiExternalModels:
  namespace: 'external-models'          # required
  maasNamespace: 'models-as-a-service'
  providers:                            # required; name, provider, endpoint required
    - name: 'openai'
      provider: 'openai'
      endpoint: 'api.openai.com'
      authType: 'apikey'                # default
      secretName: 'openai-api-key'      # default <name>-api-key
      # config: {project: ..., location: ...}   # string map, Vertex AI
  models:
    - name: 'gpt-4o-mini'
      provider: 'openai'
      targetModel: 'gpt-4o-mini'        # default name; see the name trap
      apiFormat: 'openai-chat'          # default
      accessGroups: ['maas-users']      # REQUIRED, no default
      tokenRateLimit: 20000             # REQUIRED, no default
      tokenRateWindow: '1h'
    - name: 'claude-haiku-4-5'
      routes:                           # multi-provider or explicit path; replaces provider/targetModel/apiFormat/path
        - {provider: 'anthropic', targetModel: 'claude-haiku-4-5', apiFormat: 'messages', path: '/v1/messages', weight: 100}
      allowUnmetered: true              # required for messages / openai-responses
      accessGroups: ['maas-users']
      tokenRateLimit: 20000
```

Ways this differs on purpose from `openshift-ai-models`:

- **No default `accessGroups`.** `system:authenticated` includes every ServiceAccount, and here
  each call is billed.
- **No default `tokenRateLimit`.** A spending ceiling is a site decision. The window defaults to
  `1h`.
- **`allowUnmetered` gate.** A token limit that is silently never enforced is exactly the
  "reports success" shape in CLAUDE.md, so the template fails rather than render it.
- **`modelName` not exposed,** because of the name trap.
- **`tls`/`port` annotations not exposed.** Disabling TLS sends the provider key in plain text.

### Policies

```
policy-openshift-ai-maas
  └─ policy-openshift-ai-ext-models          enforce  Namespace (gateway-access label), ExternalProvider×N,
     │                                                ExternalModel×M, OdhDashboardConfig externalModels:true
     ├─ policy-openshift-ai-ext-models-secret inform  Secret <secretName> exists with ipp-managed=true (content-free)
     └─ policy-openshift-ai-ext-models-maas   enforce MaaSModelRef(kind ExternalModel), MaaSAuthPolicy, MaaSSubscription
        └─ policy-openshift-ai-ext-models-ready inform ExternalProvider, ExternalModel, MaaSModelRef phase Ready
```

All names are at most 37 characters. Every policy has `placementBindingDefaults.name`.

- The routing policy depends on `policy-openshift-ai-maas` because the CRDs arrive with the MaaS
  stack. A policy naming a CRD that does not exist yet reports Compliant.
- The secret check depends on the routing policy, so the namespace exists before it asks about a
  Secret inside it. The routing policy deliberately does **not** wait for the secret check: an
  `ExternalProvider` with no Secret goes `Failed` and should reconcile once the Secret appears.
  That is open question 4. The ready policy and the secret policy then both point at the cause.
- `ExternalModel`, `MaaSAuthPolicy` and `MaaSSubscription` use `mustonlyhave`, because their
  lists carry templated values. `musthave` would append a changed weight or limit next to the old
  one, the bug already hit on `MaaSSubscription`. `ExternalProvider` uses `musthave`: its fields
  are scalars plus one string map, and `config` is rendered with `toJson`.
- The routing template carries the full validation and `fail`s naming the field. The other
  templates repeat only what they need to render at all.

### How a provider key gets into the cluster

The pattern already used for `maas-db-config` and the htpasswd Secret: a script under
`scripts/`, a file under `secrets/` with `umask 077`, and an inform policy that only checks the
Secret exists. Draft: `~/workspace/maas-drafts/external-models/maas-external-key.sh`, not copied
into this repo.

```
scripts/maas-external-key.sh create     --provider openai [--namespace external-models] [--from-file F] [--rotate] [--dry-run]
scripts/maas-external-key.sh status     --provider openai
scripts/maas-external-key.sh leak-check --provider openai [--since 24h]
```

- It reads the key from `/dev/tty` with `read -rs`, or from `--from-file`. **Never from argv**,
  and `/dev/tty` bypasses the `lib-logging.sh` tee into `logs/`. It prints only the byte count.
- It builds the Secret with `--from-file=api-key=<0600 temp file>`, labels it locally, and
  applies through a pipe with oc's output discarded. Even an error message cannot echo the base64
  value.
- It stores `secrets/maas-external-<provider>.key` (0600) so a rebuild, such as the planned FIPS
  rebuild, can restore the same key without asking again. `--rotate` replaces it. `secrets/*` is
  already gitignored.
- It creates the namespace if it is missing. The policy owns the labels; `musthave` merges them.
- `leak-check` greps the logs of payload-processing, payload-pre-processing, the MaaS gateway,
  maas-api, maas-controller, Authorino and Limitador for the stored key. It prints match counts
  only. The Authorino and Limitador Deployment names are from RHCL convention and were not
  confirmed: the API stopped answering mid-session. The script prints `not found` rather than
  failing.
- It follows the source order in CLAUDE.md, calls `start_logging` early, takes `--dry-run`, and
  reuses existing objects.

Follow-ups in this repo, not done: add an `external-models` feature to
`scripts/autoshift-feature.sh` (requires `maas`, config `openshiftAiExternalModels`). Add an
external-models section to `checkup.sh` that reports the secret label and the provider phase.
Document both in `docs/reference.md`.

## Draft patch

`~/workspace/maas-drafts/external-models/0001-openshift-ai-external-models-route-MaaS-to-external-.patch`.
It is one commit, so the label contract holds at every step, on `rhoai-maas` @ `40361a4b`.
`git apply --check` against `~/workspace/autoshiftv2-mine` passes.

| File | |
|---|---|
| `policies/stable/openshift-ai-external-models/{kustomization,placement,policy-generator-config}.yaml` | 4 policies, shared placement |
| `manifests/routing/external-models.yaml` | Namespace, ExternalProvider, ExternalModel. All validation |
| `manifests/routing/dashboard-external-models.yaml` | OdhDashboardConfig `externalModels: true` (musthave merge) |
| `manifests/maas/registration.yaml` | MaaSModelRef, MaaSAuthPolicy, MaaSSubscription |
| `test/secret/provider-secrets.yaml` | inform: Secret and label |
| `test/ready/external-models-ready.yaml` | inform: three `status.phase: Ready` |
| `README.md` | |
| `autoshift/values/clustersets/_example.yaml` | sample `openshiftAiExternalModels`: OpenAI, `openai-chat`, single provider; Anthropic, `messages` with `routes` and `allowUnmetered` (both code paths) + label |
| `autoshift/values/clusters/_example.yaml` | label |
| `autoshift/values/clustersets/hub.yaml` | label `'false'`, no config block |

### Gate results (scratch clone)

- `GOTOOLCHAIN=auto make test`: **pass** (configkeys, labels, resolver, versions).
- `TestObjectTemplatesRaw`: **213 blocks parsed, 0 skipped, 0 failures**. Clean `rhoai-maas` HEAD
  gives 209, so all four new templated blocks resolve and parse.
- Mutation check: deleting `tokenRateLimit` from the sample made resolution of
  `policy-openshift-ai-ext-models` fail, so CI really exercises the new templates.
- Reading the resolved output caught a bug `make test` passes. The default route rendered
  `path: ""`, which the CRD's `^/.*` pattern would reject at the API server. Fixed before commit.
- Vale 3.17.1 at `--minAlertLevel=error` on the new README: **0 errors**, after changing
  "acknowledgement" and "spend". Vale's glob covers Markdown only, so the YAML comments are not
  linted.
- Not done: server-side dry-run against the live CRDs, which the brief rules out. I checked field
  names, patterns and enums against the live schema by hand.

## Live test plan (when a provider key exists)

Use `gpt-4o-mini` with small `max_tokens`. Every request costs money. Run as `maas-user`
(`secrets/maas-user.env`). Use `GW=https://maas.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')`.

1. **Key in:** `scripts/maas-external-key.sh create --provider openai`, then `status`. Expect the
   Secret present, the label `true`, and the provider `absent` until step 2.
2. **Enable:** apply the patch on a test branch, add `openshiftAiExternalModels` with OpenAI only
   to `hub.yaml`, set the label `'true'`, push, run `scripts/50-autoshift.sh refresh`. Expect
   all four `policy-openshift-ai-ext-models*` policies Compliant (`scripts/checkup.sh`).
3. **Resources:**
   `oc get externalproviders.inference.opendatahub.io,externalmodels.inference.opendatahub.io -n external-models`
   shows `Ready`. `oc get serviceentries.networking.istio.io,destinationrules.networking.istio.io,svc -n external-models`
   shows what the controller created. The ExternalModel's `status.httpRouteName` exists.
   `oc get maasmodelrefs.maas.opendatahub.io -n external-models` shows `Ready`, not
   `NoPairingFound`.
4. **Mint:** `POST $GW/maas-api/v1/api-keys` with
   `{"name":"ext-test","subscription":"gpt-4o-mini-default","expiresIn":"1h"}`. Expect `200` and
   an `sk-` key. `GET $GW/v1/models` lists `gpt-4o-mini` with `ready: true`.
5. **Happy path:** `POST $GW/v1/chat/completions` with Bearer, `model: gpt-4o-mini` and
   `max_tokens: 20`. Expect `200` with `choices[0].message.content` and `usage.total_tokens`.
6. **Negative:**
   - No key: `401`.
   - Key of a user outside `accessGroups` (kubeadmin cannot even mint): `invalid_subscription`
     or `403`.
   - Unknown model name: record what happens. The docs warn of a timeout, not a `400`.
   - `targetModel` not equal to `name` (open question 1): expect, per [A], `401` "You didn't
     provide an API key".
7. **MaaS token limit enforced:** temporarily set `tokenRateLimit: 300`, `tokenRateWindow: '1m'`,
   push and refresh. Loop requests with `max_tokens: 100` and record each status. Expect `200`s,
   then `429` once cumulative `usage.total_tokens` passes 300, then `200` again after the window.
   Confirm the 429s on the MaaS observability dashboard's *Rate Limited* column ([G] 1.18.1).
   Restore the limit.
8. **Unmetered confirmation (open question 2):** add `claude-haiku-4-5` with
   `apiFormat: messages` and `allowUnmetered: true` and an Anthropic key. Run the same low-limit
   loop:
   - Via `/v1/messages` (`x-api-key`, `anthropic-version: 2023-06-01`), expect **no** `429`, as
     documented.
   - Via `/v1/chat/completions` (translated), record whether it is metered.
   - Also check that `x-api-key` with a MaaS key now works against `gpt-4o-mini`, which is
     documented cluster-wide behavior.
9. **Streaming (open question 3):** run `curl -N -w '%{time_starttransfer} %{time_total}\n'` with
   `"stream":true`:
   - `openai-chat` to OpenAI: expect incremental SSE, first byte well before total.
   - OpenAI format to the Anthropic `messages` model: expect buffering, first byte close to total.
   - Also check whether streamed requests are metered at all. Usage arrives only in the final
     chunk, and only with `stream_options.include_usage`. Run the step 7 loop with streaming on.
10. **Large body:** send a prompt of about 20 KB (over the 16 KB truncation limit) and check the
    reply is coherent and `usage.prompt_tokens` matches what was sent.
11. **The key stays secret:**
    - `scripts/maas-external-key.sh leak-check --provider openai --since 1h`: expect 0 everywhere.
    - `curl -v` responses contain no provider key in headers or body.
    - `oc get externalproviders.inference.opendatahub.io -o yaml` and ACM policy status show only
      the Secret name.
    - `grep -rF -f secrets/maas-external-openai.key logs/`: expect no match. This covers the
      script's own logs.
    - Repeat the leak-check after raising payload-processing verbosity, if supported (it runs
      `--v=3` today), because request-header dumps are where keys usually appear.
12. **Rotation:** `create --rotate` with a second key. Requests keep working, possibly after a
    short delay, which should be measured. Revoke the old key at the provider. Expect no 401s
    after the switch.
13. **Revoked-key failure shape:** revoke the current key. Every policy stays Compliant (`Ready`
    is not request health). Record the status code the caller sees: the provider's `401` passed
    through, or a gateway error.
14. **Off:** set the label to `'false'`. Policies unplace and nothing is removed
    (`pruneObjectBehavior: None`). Clean up by hand: the ExternalModel, ExternalProvider,
    MaaSModelRef and Secret in `external-models`, and the subscription and authorization policy in
    `models-as-a-service`.

## Open questions and risks

1. **The name trap.** [A] says name, `modelName` and `targetModel` must match or the injected key
   is empty. The docs' Anthropic example does not match them. This decides whether dated model IDs
   such as `claude-haiku-4-5-20251001` and multi-provider `routes` with different target IDs are
   usable. Test step 6.
2. **Is translated OpenAI-to-Anthropic traffic metered?** The docs tie metering to `apiFormat`.
   If it is not metered, the only metered Anthropic route is through an OpenAI-compatible endpoint
   with `apiFormat: openai-chat`, if Anthropic's compatibility endpoint accepts `x-api-key`.
   Untested.
3. **Streaming and metering.** Does an `openai-chat` stream to OpenAI arrive incrementally, and
   is it counted?
4. **Secret-after-provider ordering.** Does a `Failed` `ExternalProvider` recover when the
   Secret appears, or does it need a touch? If it needs a touch, make the routing policy depend on
   the secret policy. That creates a chicken-and-egg with the namespace, which the script resolves
   by creating it.
5. **Cost exposure.** Every member of `accessGroups` can spend up to `tokenRateLimit` per window
   at the provider. For passthrough models, MaaS sets no ceiling at all. Set provider-side spend
   limits for every key.
6. **Data leaving the cluster.** Whether prompts may go to a given provider is a governance
   decision this design cannot make. FIPS mode does not change it.
7. **`x-api-key` widening.** One `messages` model turns on `x-api-key` auth for every model. It
   is harmless functionally, but it changes the auth surface the gateway presents.
8. **`payload-processing` reads Secrets cluster-wide** (ClusterRole). A compromise of that pod
   exposes more than provider keys. That is product behavior, not something AutoShift can narrow.
9. **16 KB body truncation** could silently degrade agent traffic through external models.
10. **Technology Preview churn.** The 3.4 to 3.5 change already replaced the CRD shape. Expect the
    template to need changes on upgrade, and pin RHOAI as `hub.yaml` already does.
11. **FIPS.** TLS interop of the provider endpoints and the crypto module of payload-processing
    are both unverified. Re-test after the FIPS rebuild.
12. **Egress control.** Nothing restricts which hosts the gateway can reach. An FQDN allowlist
    needs an `EgressFirewall` on `openshift-ingress`, shared with the routers.
