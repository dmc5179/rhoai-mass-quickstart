# RHOKP and an MCP server for Red Hat docs, as AutoShift policies: plan

Researched 2026-11-10. Read-only: no repository, branch or cluster was changed.
Sections 1 to 4 are **facts**, each with its source. Sections 5 to 10 are **recommendations**.
**Unverified** marks anything not confirmed by a document, by Jira or on the cluster.
Jira items are plans. They are not support statements.

Sources used:

- `okp-mcp`: `~/workspace/okp-mcp` (fork of `rhel-lightspeed/okp-mcp`): `AGENTS.md`, `CLAUDE.md`,
  `openshift/`, `docs/DISCONNECTED.md`, `src/okp_mcp/`.
- AutoShift fork `~/workspace/autoshiftv2-mine`: branch `rhoai-maas` and prototype commit `1bc18c39`
  (branch `wip/mcp-gateway-instance`).
- The live cluster `rhoai`: OCP 4.22.18, `lightspeed-operator.v2.0.0`, `rhcl-operator.v1.5.0`,
  `rhods-operator.3.5.2`. All commands were read-only `get`, `explain` or `exec curl`.
- Red Hat documentation, read through the okp portal.
- Jira (redhat.atlassian.net).

---

## 1. What the okp-mcp repository deploys

### 1.1 Components

| Piece | Image (pinned in the fork) | Provenance | Support status |
|---|---|---|---|
| RHOKP: Solr index and HTML mirror | `registry.redhat.io/offline-knowledge-portal/rhokp-rhel9:1.3.0-1793303796@sha256:1ac156d3…` | Red Hat product image | A supported product, but the access key requires a **Satellite Infrastructure subscription (SKU MCT3718)** ([RHOKP FAQ, access.redhat.com/articles/7125624](https://access.redhat.com/articles/7125624)) |
| MCP server ("RHEL Knowledge Bridge", the code in this repository) | `registry.redhat.io/rhel-cla/rhel-knowledge-bridge-rhel10:v1.0.2-1793868366@sha256:99fd47d0…` | Product build of `rhel-lightspeed/okp-mcp` from the RHEL CLA pipeline. Same digests as `quay.io/redhat-services-prod/rhel-lightspeed-tenant/rhel-knowledge-bridge` (`AGENTS.md` Fork Additions; `docs/DISCONNECTED.md`) | **Developer Preview, as part of the RHEL command-line assistant for disconnected environments.** See §2.1. The fork's claim that it carries "Red Hat support" is not backed by any document found |

The manifests are in `openshift/01-rhokp.yaml` and `02-rhokp-mcp-server.yaml`, with optional extras
in `03` (HPA), `04` (VPA, `updateMode: Off`) and `05` (PDB, `maxUnavailable: 0`). The same stack
is also a kustomize base, `openshift/kustomize/`, in namespace `rhokp-server`.
`openshift/okp-mcp.yml` is the upstream template. It defaults to `quay.io/...:latest` and is not
used for customer deployments.

### 1.2 How RHOKP is deployed (`openshift/01-rhokp.yaml`)

- One replica, non-root with `RuntimeDefault` seccomp. Requests 500m CPU and 2Gi memory, limits
  2 CPU and 4Gi.
- **No volume.** The index lives in the container's writable layer. `quadlet/okp-solr.container`
  says the first start "pulls ~10 GB and takes several minutes to index". The FAQ gives the image as
  7.1 GB.
- `ACCESS_KEY` comes from Secret `access-credentials`. `01-rhokp.yaml` creates that Secret by
  `envsubst` from `$RHOKP_KEY`. The kustomize base expects it to be created out of band.
- Ports: 8080 for HTTP (the HTML mirror, which `get_document` uses for section anchors), 8443 for
  HTTPS, and 8983 for Solr.
- The Service exposes 8080 and 8983. The Route exposes the 8080 web UI with edge TLS.
- No probes.

### 1.3 How the MCP server is deployed (`openshift/02-rhokp-mcp-server.yaml`)

- `MCP_TRANSPORT=streamable-http` on port 8000, path `/mcp`. Stateless by default
  (`MCP_STATELESS_HTTP`, `src/okp_mcp/config.py`).
- `MCP_SOLR_URL=http://rhokp-server.rhokp-server.svc.cluster.local:8983`. It queries
  `{solr_url}/solr/portal/select`, so the core name `portal` is hard-coded (`config.py`
  `solr_endpoint`). It reads HTML anchors from `{solr host}:8080`.
- **Tools**: `search_portal(query, max_results)`, `get_document(doc_id, query)`, and `run_code`, a
  **placeholder** that only logs a warning (`src/okp_mcp/tools/run_code.py`). The tools declare no
  MCP `ToolAnnotations`, such as `readOnlyHint`.
- **No authentication and no TLS.** The Route `rhokp-mcp` has no `tls:` block, so it exposes an
  unauthenticated plain-HTTP MCP endpoint outside the cluster.
- Probes are commented out. `GET /metrics` exists (`server.py`) and is a usable HTTP probe target.
- Requests 100m CPU and 128Mi memory, limits 500m and 256Mi.
- `MCP_EXCLUDE_KBASE=true` exists for content sets without solutions or articles.
  `MCP_MAX_RESPONSE_CHARS` defaults to 30000.
- FIPS: the code does no hashing of its own (no `hashlib` or `md5` in `src/`). It is built on
  `registry.access.redhat.com/hi/python:3.12` (Hardened Images) (`Containerfile`). The image has not
  been tested on a FIPS cluster (**unverified**).

### 1.4 Disconnected

- `docs/DISCONNECTED.md` gives an `ImageSetConfiguration` `additionalImages` entry for both images
  by manifest-list digest. Renovate (`.github/workflows/renovate-fork.yml`) keeps the pins current.
- The pins have already drifted. `rhel-knowledge-bridge-rhel10` has `v1.0.2-1794226597`, which is
  newer than the pin (`skopeo list-tags`, 2026-11-10).
- This repository's `disconnected/imageset-config-rhoai-3.5.2-ocp4.22.yaml` mirrors
  `rhokp-rhel9:latest` and `quay.io/redhat-services-prod/.../rhel-knowledge-bridge:latest` **by
  tag**. That disagrees with the fork's digest-pinned `registry.redhat.io` guidance. The same file's
  comment says `lightspeed-operator` `stable` heads at 1.1.5, but the cluster runs 2.0.0 from
  `stable`.

---

## 2. Official Red Hat methods: what exists

### 2.1 The RHEL Knowledge Bridge is documented only inside a Developer Preview

*Interacting with the command-line assistant*, RHEL 10, Chapter 6, "Using a containerized
command-line assistant for disconnected environments"
([link](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/10/html-single/interacting_with_the_command-line_assistant/index#containerized-command-line-assistant-for-disconnected-environments)):

> "The command-line assistant for disconnected environments is available as a Developer Preview."

Its components include "The RHEL Knowledge Bridge container to bridge offline knowledge components"
and "The Red Hat Offline Knowledge Portal container". It "is intended for local, disconnected use on
a single system. It is not designed for multi-system deployments". The §6.1 prerequisites are
Satellite registration and an RHOKP key.

**Correction to `okp-mcp/openshift/README.md`:** its link, `#using-the-mcp-server-for-rhel-in-air-gapped-environments`,
points at Chapter 12. That chapter covers the **linux-mcp-server**, which runs commands over SSH. It
is not about RHOKP or the knowledge bridge.

At-scale OpenShift manifests for `okp`, `rhel_knowledge_bridge` and `lightspeed_stack` were added to
`rhel-cla-installer` as reference content only: **RSPEED-3789** (Closed). Its parent epic is
**RSPEED-3199**, "Refactor RHEL CLA installer ... with OpenShift deployment support", In Progress.

### 2.2 RHOKP licensing

- "At this time, RHOKP access requires a Satellite Infrastructure subscription (SKU - MCT3718)". The
  image is 7.1 GB. "A new image with updated content is intended to be released weekly"
  ([FAQ 7125624](https://access.redhat.com/articles/7125624)). The update guide says the same,
  "usually weekly" ([Update RHOKP](https://access.redhat.com/documentation/en-us/red_hat_offline_knowledge_portal/1/install-proc_updating_rhokp)).
- **Without a key, search does not work**:

  > "Without an access key, you can browse documentation, product lifecycle pages, CVEs, and the
  > Security Data API, but knowledgebase solutions, articles, and the search function are not
  > available."

  ([Customize your RHOKP deployment](https://access.redhat.com/documentation/en-us/red_hat_offline_knowledge_portal/1/install-customize_your_red_hat_offline_knowledge_portal_deployment)).
  The key "gates access to encrypted content and the search index only"
  ([Launch without an access key](https://access.redhat.com/documentation/en-us/red_hat_offline_knowledge_portal/1/install-launch_the_red_hat_offline_knowledge_portal_without_an_access_key)).
- RHOKP is "for your internal use only and contains Red Hat proprietary, licensed content ...
  [do] not publicly share the image, its content, or your access key"
  ([Make Red Hat expert knowledge available offline](https://access.redhat.com/documentation/en-us/red_hat_offline_knowledge_portal/1/install-make_red_hat_expert_knowledge_available_in_offline_environments)).
  An unauthenticated external Route to the portal or to the MCP endpoint conflicts with this.
- The RHOKP 1.x docs say nothing about MCP or AI integration.

### 2.3 The "built-in" OpenShift MCP server is three related things

1. **MCP server for Red Hat OpenShift**, OCP 4.22, **Technology Preview**.
   - Release notes §1.3.1 ([link](https://access.redhat.com/documentation/en-us/openshift_container_platform/4.22/html-single/release_notes/index)).
     The guide is *AI applications*, OCP 4.22, §1.1
     ([link](https://access.redhat.com/documentation/en-us/openshift_container_platform/4.22/html-single/ai_applications/index)).
   - It is **not part of the core payload**. It is installed from the Helm chart
     `openshift-helm-charts/redhat-openshift-mcp-server` into namespace `openshift-mcp-server`
     (§1.1.6.1).
   - The documented procedure then installs the **MCP gateway (Red Hat Connectivity Link)** in front
     of it, with `HTTPRoute` plus `MCPServerRegistration`, OAuth or JWT `AuthPolicy`, and tool-level
     authorization (§1.1.6.3–1.1.6.9). §1.1.1.4 says: "Ensure that authorization is enabled via
     OAuth or MCP gateway."
   - Errata **RHBA-2026:88380** shipped "Model Context Protocol server for Red Hat OpenShift 1.1"
     on 2026-10-22.
   - Jira: OCPSTRAT-2465 (TP, openshift-4.22, Closed) and OCPSTRAT-3786 (1.1 GA enhancements, In
     Progress).
   - **Doc defect:** §1.1.6.5 uses `mcp.kuadrant.io/v1alpha1` for `MCPServerRegistration`.
     RHCL 1.5 does not serve that version. This is the same class of defect as
     `docs/jira-drafts/bug-rhoai-docs-mcp-v1alpha1.md`.
2. **Lightspeed's embedded copy.** Operator 2.0.0 deploys `openshift-mcp-server`, from image
   `registry.redhat.io/openshift-mcp/openshift-mcp-server-rhel9@sha256:a551fd58…` (a CSV related
   image), in `openshift-lightspeed`.
   - The rendered `olsconfig.yaml` registers it as MCP server `openshift`, at
     `https://openshift-mcp-server.openshift-lightspeed.svc:8443/mcp`, with
     `Authorization: kubernetes` and `timeout: 60`.
   - Its `config.toml` sets `read_only = false` and the toolsets `core`, `config`, `helm`,
     `observability/*`, `kubevirt` and `netobserv`. It denies `Secret` and all of
     `rbac.authorization.k8s.io` (live cluster).
   - The OLS 1.1.4 release notes say: "OpenShift Lightspeed uses the image published by the OpenShift
     MCP team to deliver the OpenShift Container Platform Model Context Protocol (MCP) server"
     ([OLS release notes](https://access.redhat.com/documentation/en-us/red_hat_openshift_lightspeed/1.0/html-single/release_notes/index)).
3. **Plan: OLS-2520** "OLS move to 'MCP server for Red Hat OpenShift'", fixVersion **ols-3.0**,
   New: "With the release of 'MCP server for Red Hat OpenShift' OLS will no longer package and
   deliver any MCP server ... OLS able to talk to external".
   OLS-4861 moved the image to the native Go FIPS provider, targeting OCP 5.1.

### 2.4 Lightspeed with RHOKP: shipped and documented, for OCP docs only

- OLS 1.1.2 "replaces the custom RAG implementation with the Offline Knowledge Portal (OKP)". OLS
  1.1.4 ships RHOKP 1.2.12 covering "the most recent seven OpenShift Container Platform versions"
  (OLS release notes §1.2.1, §1.4.1).
- *Configure*, "How the Offline Knowledge portal retrieves documentation": "The OKP corpus includes
  only OpenShift Container Platform documentation, plus ... ROSA documentation on ROSA clusters". The
  same section tells you to use BYO Knowledge for layered products
  ([Configure](https://access.redhat.com/documentation/en-us/red_hat_openshift_lightspeed/1.0/html-single/configure/index)).
- Operator 2.0.0 CRD text (`oc explain olsconfigs.ols.openshift.io.spec.ols`): OKP "is
  operator-managed, not configured on this CR"; "OCP documentation is retrieved via the
  search_openshift_documentation tool (Solr hybrid)"; `byokRAGOnly` disables it.

### 2.5 Lightspeed custom MCP servers: documented, Technology Preview

*Configure* §1.12.2, "Enabling a custom MCP server", says: "The MCP server feature is a Technology
Preview feature only." The schema:

```yaml
spec:
  featureGates: [MCPServer]
  mcpServers:
    - name: <name>
      url: https://...
      timeout: 30
      headers:
        - name: Authorization
          valueFrom: {type: kubernetes}          # forwards the user's bearer token
        - name: X-Special
          valueFrom: {type: secret, secretRef: {name: <secret>}}
```

- The operator 2.0.0 CRD matches (`oc explain`): `name`, `url` (HTTP or HTTPS only), `timeout`
  (seconds, **default 5**), and `headers[].valueFrom.type` ∈ {`secret`, `kubernetes`, `client`}.
  "The secret must exist in the operator's namespace." `featureGates` takes `MCPServer` and
  `ToolFiltering`.
- Solution [7139435](https://access.redhat.com/solutions/7139435) covers the schema change at
  1.0.10: `url` and `timeout` moved to the top level and `streamableHTTP` was removed.
- No document describes pointing OLS at an MCP **gateway**. RHACM 2.17 *MCP* §1.2 documents adding
  another product's MCP server to OLS
  ([link](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/mcp/index)),
  which is the closest precedent.
- `spec.ols.toolsApprovalConfig.approvalType` defaults to `tool_annotations` (OLS release notes
  §1.6.1; live config `tools_approval.approval_type: tool_annotations`).

### 2.6 Documentation MCP: the official state, and the plans

| What | Status | Source |
|---|---|---|
| Hosted "MCP server for Red Hat Documentation" (`https://docs-mcp.api.redhat.com/mcp`, tools `redhat_docs_search`, `redhat_docs_fetch`, Red Hat SSO per user, IDE-oriented) | **Shipped**; not usable offline or as a service identity | [docs](https://access.redhat.com/documentation/en-us/mcp_server_for_red_hat_documentation/current/get_started-configure_mcp_server_for_docs_in_claude_code) |
| **RHOKP's own MCP server**, `<rhokp_url>/mcp`: "Hybrid lexical+semantic search of Red Hat products, CVEs, errata, and product documentation". Stateless, "does not have built-in authentication" | Doc ticket in **Review**; not yet published | **UIECCP-1648** (Emily Murphy). Implementation in `Offline-Program/MEL` (`mimcp`) |
| Same server, gated by `MCP_ENABLED=true` on the RHOKP 1.3 image, served through Apache `/mcp` | Engineering statement | **OLS-4714** (description) |
| OLS adopts OKP's MCP for its own OCP doc retrieval: a built-in `rhokp` MCP server at `https://lightspeed-rhokp.<ns>.svc:8443/mcp`, replacing the direct Solr path | **Plan, fixVersion ols-2.1** (release date 2026-12-31), Review (Boris Lublinsky) | OLS-4714 |
| RHOKP RAG replaced by a hybrid-search MCP tool; LCORE integration | Closed | UIESTRAT-238, UIECCP-1405 (Michael Clayton) |
| Official RHOKP MCP for Documentation, packaged in RHOKP, delivered by CCS | **Plan**, New | UIESTRAT-158 |
| Product and Security MCP via RHOKP | Plan, In Progress | UIESTRAT-157 |
| Launch comms for "the official, supported RHOKP MCP interface", with an explicit migration message for teams "building unofficial MCP servers against RHOKP data (e.g., RHEL Lightspeed)" | **Plan, [CY2027]** | UIESTRAT-382 |
| MCP Risk and Compliance Framework review of the RHOKP MCP server | In Progress | UIECCP-1674 |
| Known gap: zero results for vulnerability nicknames and natural-language questions | New | UIECCP-526 |
| LCORE `OkpKnowledgeSource` over the OKP MCP | Plan, 0.8.0 | LCORE-4586 |

**Conclusion: no official, supported method yet** serves offline Red Hat docs to Lightspeed over
MCP.

- What exists is Lightspeed's built-in RHOKP retrieval, scoped to OCP docs, plus custom MCP servers
  as a Technology Preview.
- The direction in Jira is clear. RHOKP will ship its own MCP endpoint (`/mcp`), OLS 2.1 will
  consume it internally, and the knowledge bridge (okp-mcp) is the "unofficial" server that
  UIESTRAT-382 expects to migrate.
- Treat the knowledge bridge as an interim backend, and build so that it can be swapped.

### 2.7 MCP gateway and RHOAI MCP pieces (from earlier research)

- RHCL 1.5 ships the MCP gateway controller and serves `mcp.kuadrant.io/v1` only. See
  `docs/jira-drafts/mcp-gateway-on-rhcl-1.5-findings.md` (CONNLINK-1973, OSDOCS-24091,
  OSDOCS-24039).
- RHCL is included in RHOAI SKUs "for Models as a Service (MaaS) use cases only" (same file).
  Gateway use for docs MCP may need its own RHCL entitlement (**unverified**).
- The RHOAI 3.5 MCP Lifecycle Operator (`mcpservers.mcp.x-k8s.io`) creates an `MCPServer` with a
  Deployment and a Service ([Working with the MCP catalog §3.1](https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/working_with_the_mcp_catalog/index)).
  Errata RHEA-2026:10853 was the 0.1.0 Developer Preview. GA is planned for RHOAI 3.7
  (RHAISTRAT-2984) and openshift-5.1 (OCPSTRAT-2879).
- RHAISTRAT-2790 (3.6 GA, Release Pending): the dashboard will block deploying the OpenShift MCP
  server without an MCP gateway with guardrails. That signals the gateway is the intended front
  door.

---

## 3. Live cluster facts relevant to reuse (2026-11-10)

| Fact | Evidence |
|---|---|
| `lightspeed-rhokp` runs image `rhokp-rhel9@sha256:adbe5135…`, label `release` 1787721408. That is older than the okp-mcp pin (1.3.0-1793303796) | `oc get deploy`, `skopeo inspect --config` |
| Only HTTPS 8443 is exposed (httpd with a service-ca certificate). Solr 8983 is not on the Service | `svc/lightspeed-rhokp` |
| Index on `emptyDir` with `sizeLimit: 75Gi`. Requests 2 CPU, 2Gi memory, 75Gi ephemeral storage. Re-indexes on every restart | Deployment spec |
| `ACCESS_KEY` comes from Secret `rhokp-access-key`, key `ACCESS_KEY`, `optional: true`. **The Secret does not exist** | Deployment spec, `oc get secret` |
| Core `portal-rag` has **760,046 chunk docs, all products** (OCP 153k, RHEL 11k, …), documentation, errata and CVE chunks, **no solutions** (2 articles), index `lastModified` 2026-08-26. Its schema is chunk-based (`chunk`, `chunk_vector`, `parent_id`, `product`, `product_version`), not okp-mcp's | Solr cores and schema API, read in-pod |
| Core **`portal` has 0 docs**. It is the core okp-mcp queries. This matches "without an access key ... the search function [is] not available" | Solr cores API |
| `/mcp` returns 404, and nothing in httpd config mentions MCP. This image predates the MCP-enabled RHOKP | in-pod curl and grep |
| NetworkPolicy `lightspeed-rhokp` admits only pods **in `openshift-lightspeed`** and Prometheus. `lightspeed-rhokp-egress` denies all egress. Both are operator-owned | `oc get networkpolicies` |
| The app server has **no egress restriction**, so OLS can reach an MCP server in another namespace or the gateway | NetworkPolicy `lightspeed-app-server` is Ingress-only |
| Rendered `olsconfig.yaml`: `mcp_servers` holds only `openshift`. `guardrails.tool_result_inspection.enabled: true`. `max_iterations: 5`. `solr_hybrid` points at `lightspeed-rhokp:8443`. `extra_ca` includes `/etc/certs/ols-additional-ca/ca.crt` | ConfigMap `olsconfig` |
| The live OLSConfig carries `models[].parameters.toolBudgetRatio: 0.5` and annotation `rhoai-mass-aws/reconcile-after-key`. **Neither is in `policy-ols-config`**: drift set out of band | `oc get olsconfigs.ols.openshift.io cluster` |
| The MCP gateway CRDs exist (`mcpgatewayextensions`, `mcpserverregistrations`, `mcpvirtualservers.mcp.kuadrant.io`). `mcpservers.mcp.x-k8s.io` exists with none deployed | `oc get crd` |
| The cluster is **not FIPS**: no `fips` in install-config. The next rebuild is (`docs/rebuild-fips-plan.md`) | `cm/cluster-config-v1` |

---

## 4. Tool-result inspection: what is known

- OLS 1.1.5 known issue: "Tool-result inspection might fail at the tool call step for certain
  models ... Workaround: Disable the tool-result inspection flag" (OLS release notes §1.1.3).
- **OLS-4416** (fixed in ols-2.0, Closed): the classifier errors masqueraded as "Lightspeed stopped
  the operation because a tool result failed the safety inspection". The workaround was
  `spec.ols.guardrails.toolResultInspection.enabled=false`.
- CRD 2.0.0: `spec.ols.guardrails.toolResultInspection.enabled`, "Defaults to true when omitted".
  There is no field to choose the judge model. Which model judges is **unverified**: the CRD and the
  rendered config name none, so it is probably the default provider and model,
  `granite-4-tiny-gpu`.
- No inspection lines were found in the last 3000 app-server log lines. The user reports that answers
  have been stopped, and that is not reproduced here.
- OLS-3939 (ols-2.1, To Do) and OCPSTRAT-3922 (ols-2.1) plan further tool-output redaction and
  safety controls. Expect this area to keep changing.

---

## 5. Recommendation: separate RHOKP, do not reuse `lightspeed-rhokp`

| | Reuse `lightspeed-rhokp` | Separate RHOKP (recommended) |
|---|---|---|
| Works with okp-mcp today | **No.** Core `portal` is empty without a key, and the `portal-rag` schema is different | Yes, with an access key |
| Reachability | Blocked from other namespaces by an operator-owned NetworkPolicy. You would have to run the MCP pod inside `openshift-lightspeed`, or add your own allow-policy there. Both tamper with an operator namespace | Our namespace, our NetworkPolicies |
| Ownership and lifecycle | Lightspeed operator: image pinned per OLS release (currently ~Aug 2026 content), restarts and re-indexes when it likes, may change shape in 2.1 (OLS-4714) | Ours: weekly content by bumping a digest |
| Content scope | OLS uses it for OCP docs only. The index holds more, but no solutions | Full RHOKP: docs, solutions, articles, CVEs, errata |
| Licensing | Covered by OLS without a key | Needs an MCT3718-derived access key; internal use only |
| Cost | Free | ~2 CPU, 2–4Gi memory, tens of GiB of ephemeral storage, and a 7–10 GB image pull per node it lands on |

Supplying `rhokp-access-key` to the Lightspeed instance may populate its `portal` core: the
operator wires the Secret as optional. That is **unverified and undocumented**, and it still leaves
the NetworkPolicy and ownership problems. Do not build on it.

Keep the boundary clean:

- **OCP questions** stay on Lightspeed's built-in `search_openshift_documentation`, which OLS 2.1
  will move to OKP MCP itself.
- **Everything else** goes through our MCP server: RHEL, Satellite, AAP, RHOAI, solutions, CVEs and
  errata.

---

## 6. AutoShift design

### 6.1 Where it lives and why

- **Tier: `policies/community/`**, as `openshell` is: the MCP image is Developer Preview (§2.1) and
  RHOKP needs a separately licensed key.
- **Shape:** a plain RHACM policy with config-driven Deployments, the same pattern as
  `hermes-agent`. It is a shaped workload that varies by a handful of fields (images, sizes, key
  Secret name), so it passes the "can I template this as a shaped CR?" test in
  `docs/what-belongs-in-autoshift.md`.
- **Not a vendored Helm chart:** the stack is two Deployments, and there is no upstream chart worth
  tracking.
- **Not a GitOps workload:** it runs on the hub, which is the documented exception.

### 6.2 New directory `policies/community/rhokp-mcp`

| Policy (≤40 chars) | Mode | Depends on | Does |
|---|---|---|---|
| `policy-rhokp-mcp-prereqs` (24) | inform | none | Secret `<accessKeySecret>` exists in `<namespace>` with key `ACCESS_KEY`. Message names the `oc create secret` command. Also fails when `config.rhokpMcp` is missing |
| `policy-rhokp-mcp-ns` (19) | enforce | none | Namespace (`openshift.io/cluster-monitoring: "true"`), ServiceAccounts with `automountServiceAccountToken: false`, NetworkPolicies (see 6.6) |
| `policy-rhokp-server` (19) | enforce | `-prereqs`, `-ns` | RHOKP Deployment and Service (8080, 8983; **no Route by default**). See 6.4 |
| `policy-rhokp-server-ready` (25) | inform | `-server` | RHOKP Deployment `Available`. Readiness is wired to "core has documents", see 6.4 |
| `policy-rhokp-mcp` (16) | enforce | `-server-ready` | Knowledge-bridge Deployment and Service (8000), `/metrics` probes |
| `policy-rhokp-mcp-ready` (22) | inform | `-mcp` | MCP Deployment `Available` |

- `placementBindingDefaults.name: binding-policy-rhokp-mcp`, because several policies share one
  placement.
- `pruneObjectBehavior: None`.
- No `cluster-type: spoke` predicate.
- Abbreviation `rhokp` follows `acs`, `virt`, `nfd`.

### 6.3 Labels and config

Labels, declared in **both** `autoshift/values/clustersets/_example.yaml` and
`clusters/_example.yaml`:

| Label | Sample | Meaning |
|---|---|---|
| `rhokp-mcp` | `'false'` (as `openshell` and `openshift-lightspeed` do) | Places the policies |
| `rhokp-mcp-route` | `'false'` | Optional. Adds a TLS Route for the RHOKP web UI only, never for `/mcp` or Solr |

Images cannot be labels: `@`, `:` and `/` are not allowed in label values. They go in config,
following `hermes-agent`:

```yaml
config:
  rhokpMcp:
    namespace: 'rhokp'                        # default rhokp
    accessKeySecret: 'rhokp-access-key'      # same name and key (ACCESS_KEY) Lightspeed uses
    rhokpImage: 'registry.redhat.io/offline-knowledge-portal/rhokp-rhel9@sha256:1ac156d3…'   # default: the verified pin
    mcpImage: 'registry.redhat.io/rhel-cla/rhel-knowledge-bridge-rhel10@sha256:99fd47d0…'    # default: the verified pin
    excludeKbase: false
    maxResponseChars: 12000                   # see 7.3; okp-mcp default 30000
    solrStorageLimit: '75Gi'                  # emptyDir sizeLimit (matches lightspeed-rhokp)
    mcpReplicas: 2
```

- Check the **skipped** count in `make test`. The harness builds its synthetic cluster from the
  first non-empty declaration. Confirm that the `rhokp-mcp` policies are actually rendered, as the
  `openshell` precedent suggests they will be (**unverified**).
- Every hub template that reads `config.rhokpMcp` uses `dig` with defaults, and `fail`s by name on
  required fields. This avoids the empty `object-templates-raw` trap.

### 6.4 Avoiding "Compliant while broken"

The traps from `CLAUDE.md` apply here as follows:

- **RHOKP without a valid key starts, serves HTTP 200, and has an empty `portal` core.** Every
  `Available` check would pass. Use an **exec readiness probe** in the RHOKP container that requires
  documents:

  ```sh
  curl -sf 'http://localhost:8983/solr/portal/select?q=*:*&rows=0&wt=json' | grep -q '"numFound":[1-9]'
  ```

  Add a `startupProbe` with a long budget (indexing takes minutes; allow about 30 min). Then
  `policy-rhokp-server-ready` (Deployment `Available`) really means "search works". Confirm that
  `curl` and `grep` exist in the 1.3 image: they exist in the image Lightspeed ships (**unverified**
  for 1.3).
- **The access key is out of band**, so `-prereqs` asserts the Secret before anything deploys. The
  RHOKP Deployment does **not** mark the key `optional` (Lightspeed does), so a missing Secret fails
  visibly at pod creation.
- **The MCP server starts fine with Solr unreachable.** That is why `policy-rhokp-mcp` depends on
  `-server-ready`, not on `-server`.
- **Deployment manifests use `mustonlyhave`**, because `musthave` merges into `containers[]` and can
  silently never apply an image change. See the `hermes-agent` comment at line 22.
- The access key never reaches git, values or logs.

### 6.5 The OLSConfig change: extend `openshift-lightspeed`, do not add a second owner

`policy-ols-config` already owns `OLSConfig cluster`. Add optional, generic fields to
`config.openshiftLightspeed`. They are not specific to RHOKP, so any MCP server can be listed:

```yaml
config:
  openshiftLightspeed:
    model: ...
    secretName: maas-api-key
    mcpServers:                     # optional; rendered with featureGates: [MCPServer]
      - name: 'redhat-docs'         # must not be 'openshift' (the built-in server's name)
        url: 'http://rhokp-mcp.rhokp.svc:8000/mcp'      # phase 1; the gateway URL in phase 2
        timeout: 60                 # CRD default is 5 s; get_document routinely needs more
        headers: []                 # phase 2: [{name: Authorization, valueFrom: {type: kubernetes}}]
    toolResultInspection: true      # optional; renders spec.ols.guardrails.toolResultInspection.enabled
```

Template notes, following the hub template traps:

- Render the list with `{{hub $mcp | toJson hub}}`, not `toYaml | nindent`.
- `fail` when an entry lacks `name` or `url`, when a name is `openshift`, or when a `secret` header
  has no `secretRef.name`.
- Compare `toolResultInspection` as a string (`eq (toString …) "false"`); `toInt` and boolean
  coercion fail on hub-resolved values.
- Render nothing, and leave the field to the operator default, when it is unset.
- **`musthave` on a list never removes an entry.** Deleting an MCP server from config leaves it in
  `OLSConfig`. Document a manual `oc patch` for removal. Switching the OLSConfig template to
  `mustonlyhave` is not an option, because it would fight the operator's defaulted `spec.ols.deployment.*`.
- Do not add a dependency from `policy-ols-config` to `policy-rhokp-mcp-ready`, because the fields
  are generic. A wrong URL degrades only that tool; the `rhokp-mcp` README says to enable the two
  together. OLS loads MCP servers at startup, and whether a down server blocks startup is
  **unverified**. Test this in phase 1.
- Separately, fold the out-of-band `toolBudgetRatio: 0.5` into config
  (`openshiftLightspeed.toolBudgetRatio`) so that git describes the cluster.

### 6.6 Network and TLS

- NetworkPolicies in `rhokp`:
  - Solr 8983 and the mirror on 8080: only from pods labelled `app: rhokp-mcp`, plus the optional
    Route's router.
  - MCP 8000: only from namespaces `openshift-lightspeed`, the gateway namespaces
    (`openshift-ingress`, `mcp-gateway`), and an opt-in list (for example `hermes`).
  - The RHOKP pod denies all egress, as Lightspeed's does.
- Phase 1 uses in-cluster `http://` from OLS to the MCP Service. OLS accepts HTTP URLs (CRD). The
  traffic never leaves the SDN.
- If HTTPS is preferred, serve TLS from a service-ca certificate. That needs a TLS-terminating proxy
  or a knowledge-bridge TLS option, which is **unverified**: okp-mcp has no TLS setting in
  `config.py`. OLS would trust the certificate through `spec.ols.additionalCAConfigMapRef`.
- Phase 2: OLS calls the gateway's public HTTPS host. OLS must trust the ingress certificate, which
  may also need `additionalCAConfigMapRef`, depending on the ingress certificate setup
  (`docs/letsencrypt-plan.md`).

### 6.7 Images, mirroring and weekly updates

- Pin both images by manifest-list digest in the policy defaults. Override them in `hub.yaml`
  `config.rhokpMcp.*Image`.
- Replace the two `:latest` entries in `disconnected/imageset-config-rhoai-3.5.2-ocp4.2{1,2}.yaml`
  with the **same** `registry.redhat.io` digests, using the `# ..., tag <tag>` comment convention
  that the fork's Renovate keys on. This also drops the quay.io source and the
  `ImageTagMirrorSet` caveat.
- Fix the stale "head 1.1.5" comment, because `stable` now delivers 2.0.0.
- Weekly cadence:
  - RHOKP content changes weekly. The knowledge bridge changes rarely.
  - Bump the RHOKP digest on a cadence you choose, not weekly by default. Each bump is a 7–10 GB
    pull and a re-index.
  - Disconnected sites must re-mirror for every bump, and the digest in values must match the
    mirror. Otherwise `ImagePullBackOff` is the only symptom.
  - The fork's Renovate job already produces the digest. Copy it into `hub.yaml` and the imageset in
    one commit.

### 6.8 Gateway: reuse the prototype, add one server entry

Reuse `wip/mcp-gateway-instance` (`policies/stable/mcp-gateway`, untested) unchanged:

```yaml
config:
  mcpGateway:
    servers:
      - name: 'redhat-docs'
        namespace: 'rhokp'
        service: 'rhokp-mcp'
        port: 8000
        path: '/mcp'
        prefix: 'rhdocs_'
        category: ['documentation']
        hint: 'Offline Red Hat documentation, solutions, CVEs and errata (RHOKP)'
        access:
          - groups: ['system:authenticated']     # or a narrower group
            tools: ['search_portal', 'get_document']   # never run_code (placeholder)
```

- The gateway's tool authorization **hides `run_code`**. That is a concrete reason to put the
  gateway in front even for one server.
- Phase 2 OLS entry:
  `url: https://mcp.<ingress domain>/mcp`, `headers: [{name: Authorization, valueFrom: {type: kubernetes}}]`.
  The user's token goes to the gateway, `auth.type: kubernetes` does a TokenReview, and access is
  granted per group.
- A **virtual server** limited to `rhdocs_*` keeps OLS from seeing other servers' tools as more are
  registered. Whether OLS can send the `X-Mcp-Virtualserver` header as a static `secret`-type header
  is **unverified**: that header type reads from a Secret.
- **Keep `openshift` direct.** It is operator-managed, and routing it through the gateway is
  unsupported until OLS-2520 (ols-3.0).
- When RHOKP's own `/mcp` ships (UIECCP-1648, OLS-4714), change only `servers[].service`, `port`
  and `path` to point at RHOKP with `MCP_ENABLED=true`. Remove the knowledge-bridge Deployment.
  **OLS does not change**, because the prefix and URL stay the same. This decoupling is the main
  argument for the gateway.

### 6.9 Hermes and Open WebUI (optional)

- With the gateway in place, Hermes (ServiceAccount `hermes`) can call it with its ServiceAccount
  token. Add `system:serviceaccounts:hermes` to the `access` groups.
- Whether Hermes and Open WebUI accept a streamable-HTTP MCP server with a bearer token is
  **unverified**. Check their versions before planning on it.

---

## 7. Phased plan

### Phase 0: decisions and checks (no cluster change)

1. Confirm that an RHOKP access key is available from an MCT3718 subscription. The `okp-mcp`
   functional CI uses one. Decide where the key lives: `secrets/rhokp.env`, with a script that
   creates the Secret, in the style of `maas-user.sh`.
2. Accept the support posture: knowledge bridge as Developer Preview, OLS custom MCP and the MCP
   gateway in RHOAI as Technology Preview, RHOKP needing a separate subscription.
3. Pull and inspect `rhokp-rhel9:1.3.0-1793303796` locally. Confirm:
   - `curl` and `grep` exist, for the probe;
   - the size of the indexed `portal` core, to set ephemeral-storage requests;
   - whether `/mcp` appears with `MCP_ENABLED=true`, which would make knowledge-bridge-free
     operation possible (OLS-4714 says it does).

### Phase 1: the smallest useful step (direct, no gateway)

1. Add `policies/community/rhokp-mcp` as in §6.2–6.4, with RHOKP and the knowledge bridge in
   namespace `rhokp`.
2. Extend `openshift-lightspeed` with `config.openshiftLightspeed.mcpServers` and
   `toolResultInspection` (§6.5).
3. In `hub.yaml`, set `rhokp-mcp: 'true'` and
   `mcpServers: [{name: redhat-docs, url: http://rhokp-mcp.rhokp.svc:8000/mcp, timeout: 60}]`.
4. Gate everything with `GOTOOLCHAIN=auto make test`, check the skipped count, run Vale on the new
   README and comments, and push.
5. Create the key Secret, run `scripts/50-autoshift.sh refresh`, and wait for
   `policy-rhokp-server-ready` (indexing takes minutes).

### Phase 2: the gateway

1. Test the prototype `mcp-gateway` on its own first. Check the listener-split `tools/call` risk
   (OSDOCS-24039, RHAIENG-8114), using `tools/list` **and** `tools/call`.
2. Add the `redhat-docs` server entry (§6.8) and move the OLS `url` to the gateway with the
   `kubernetes` header.
3. Confirm that `run_code` is absent from `tools/list` for a normal user.

### Phase 3: hardening

- MCP: two or more replicas, a PDB and topology spread. RHOKP: one replica, a PDB, and decide
  whether a restart (and re-index) is acceptable or whether to use two replicas.
- A `ServiceMonitor` for knowledge-bridge `/metrics`. The fork has Grafana dashboards in
  `openshift/dashboards/`.
- A Renovate-driven digest bump procedure for values and the imageset.
- Swap the backend to RHOKP's native `/mcp` once it is documented (UIECCP-1648).
- Re-evaluate the custom server when OLS 2.1 ships OKP MCP internally (OLS-4714).
- Upstream to `rhel-lightspeed/okp-mcp`: `ToolAnnotations(readOnlyHint=True)` on `search_portal`
  and `get_document`, and drop or flag `run_code`. See 7.3.

### 7.1 Live test plan

Pre-checks, run from a debug pod in `rhokp`, read-only:

```bash
# Solr has content (the same check the readiness probe makes)
curl -s 'http://rhokp-server.rhokp.svc:8983/solr/portal/select?q=*:*&rows=0' | jq .response.numFound
# MCP lists its tools
curl -s -X POST http://rhokp-mcp.rhokp.svc:8000/mcp -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Phase 2 adds the same call through `https://mcp.<domain>/mcp`, with `Authorization: Bearer $(oc whoami -t)`,
followed by a `tools/call` of `rhdocs_search_portal`.

Questions to ask in the Lightspeed console. Pick ones whose answer is **not** in OCP docs, so the
custom tool must be used:

| Question | Expected tool calls | Expected citation |
|---|---|---|
| "How do I enable FIPS mode on a RHEL 9 host?" | `search_portal` (or `rhdocs_search_portal`), maybe `get_document` | `access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/...` |
| "What is CVE-2024-6387 and which RHEL 9 erratum fixes it?" | `search_portal` | `/security/cve/CVE-2024-6387`, an RHSA errata URL |
| "How do I add a Capsule server to Satellite 6.17?" | `search_portal`, `get_document` | Satellite 6.17 guide with a `#section` anchor |
| "How do I set up the MaaS gateway in RHOAI 3.5?" | `search_portal` | RHOAI 3.5 *Govern LLM access with Models-as-a-Service* |
| Control: "How do I add a worker node in OpenShift 4.22?" | `search_openshift_documentation`, the built-in one, **not** ours | OCP 4.22 docs |

Confirm:

- the tool calls appear in the OLS response or audit stream (OTEL collector, `audit.logging: Enabled`);
- the `rhokp-mcp` pod log shows the request with `X-Request-ID`;
- the knowledge-bridge `/metrics` tool-call counter increases;
- the answer's referenced documents are `access.redhat.com` URLs that match the tool output.

The exact field names for OLS tool-call and referenced-document reporting in 2.0 are
**unverified**. Check them through `/v1/query` against `lightspeed-app-server` with a user token.

### 7.2 Tool approval

`approval_type: tool_annotations` is the default. The knowledge-bridge tools declare no
annotations, so OLS may treat them as non-read-only and ask the user to approve every docs search
(**unverified**).

- Test this in phase 1.
- If it happens, do not set `approvalType: never`. That would also stop approvals for the built-in
  server's **write** tools (`read_only = false`).
- Fix it upstream with annotations instead, as listed in phase 3.

### 7.3 Tool-result inspection

1. Start with inspection **on** (the default). Collect the outcomes from the app-server and audit
   logs. OLS-4416 distinguishes `inspection.outcome=classifier_error` from a genuine unsafe verdict.
2. Lower `maxResponseChars` (okp-mcp `MCP_MAX_RESPONSE_CHARS`) from 30000 to about 8–12k. This
   keeps one tool result within what the small judge model handles well.
   - This is a hypothesis: no source ties the stops to result size (**unverified**).
   - It also helps `toolBudgetRatio: 0.5` on a small context.
3. If stops persist with `classifier_error`, or with false positives on plain docs, set
   `config.openshiftLightspeed.toolResultInspection: false`. This is the documented workaround (OLS
   1.1.5 known issue, OLS-4416). Record it as a deliberate, values-visible decision. It disables
   inspection for the built-in `openshift` server too.
4. The longer-term fix is a stronger default model for OLS, or the per-tool safety controls planned
   in OCPSTRAT-3922 (ols-2.1).

---

## 8. FIPS and disconnected

| Piece | FIPS | Disconnected |
|---|---|---|
| RHOKP (`rhokp-rhel9`, RHEL 9 httpd + Solr 10 on OpenJDK, `ENCRYPT=true`) | No FIPS statement found. Whether its content decryption works under FIPS crypto policy is **unverified**. Test on the FIPS rebuild. PRODSECRM-350 shows a standing Solr CVE exception | Designed for it. One image by digest, about 7–10 GB, re-mirrored per content bump |
| Knowledge bridge (`rhel-knowledge-bridge-rhel10`, Hardened Images Python) | Does no hashing of its own. Not tested on FIPS (**unverified**) | One image by digest. Needs nothing at runtime except Solr and the mirror |
| OLS custom MCP | OLS is a Red Hat build that works under FIPS (`docs/rebuild-fips-plan.md` §6) | Nothing extra |
| MCP gateway (RHCL 1.5) | Not tested here | Images ride the `rhcl-operator` `stable-1.5` bundle (prototype README) |
| openshift-mcp-server | Native Go FIPS provider planned for OCP 5.1 (OLS-4861) | CSV related image |

Add to `docs/rebuild-fips-plan.md` §6: "RHOKP indexes with the key on a FIPS node; a knowledge-bridge
`tools/call` returns results."

---

## 9. Support status summary

| Piece | Status |
|---|---|
| RHOKP image | Supported product; key requires the Satellite Infrastructure subscription (MCT3718) |
| RHEL Knowledge Bridge (okp-mcp) | Developer Preview, inside the RHEL CLA disconnected bundle; no OpenShift deployment is documented |
| RHOKP native `/mcp` | Not yet documented (UIECCP-1648 in Review). The "official RHOKP MCP interface" is planned for CY2027 (UIESTRAT-382) |
| OLS custom MCP servers (`spec.mcpServers`) | Technology Preview (OLS *Configure* §1.12.2) |
| OLS built-in RHOKP (OCP docs) | GA with OLS |
| MCP server for Red Hat OpenShift | Technology Preview in 4.22; Helm add-on; 1.1 errata 2026-10-22 |
| MCP gateway on RHCL 1.5 | GA per second-hand release-note quotes. RHOAI integration Technology Preview. RHCL entitlement in RHOAI covers MaaS only. The prototype README says "Technology Preview" and should be reconciled |
| AutoShift `rhokp-mcp` and `mcp-gateway` policies | Ours; community tier |

## 10. Risks

1. **Official RHOKP MCP lands soon** (OLS 2.1, end of 2026; RHOKP docs in review). A
   knowledge-bridge build may become throwaway work. Mitigation: the gateway indirection (§6.8)
   and a thin policy.
2. **Licensing.** Without an MCT3718-derived key, search does not work at all. An external
   unauthenticated Route would breach the EULA's "internal use only".
3. **Prototype gateway untested**, with a known listener-split `tools/call` risk and a coexistence
   risk with MaaS on one Kuadrant (RHOAIENG-103137).
4. **Tool approvals and inspection** may make the docs tool unusable in the console until
   annotations or settings are adjusted (§7.2, §7.3).
5. **Capacity.** A second RHOKP adds about 2 CPU, 2–4Gi memory and tens of GiB of ephemeral storage
   to a hub that `CLAUDE.md` already warns about. Measure etcd and worker CPU requests after
   enabling it.
6. **`musthave` list drift** in `OLSConfig`: removed MCP servers linger. The out-of-band
   `toolBudgetRatio` already shows drift.
