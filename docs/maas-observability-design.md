# MaaS usage observability and telemetry: design

Status: design only, 2026-11-09. Nothing here is enabled. The cluster was read, not changed.
The policy names, labels and file paths below are proposals.

How to read it: lines tagged **[fact]** carry a citation (document and section, Jira key, or
**[live]** for something observed on the `rhoai` cluster today). **[rec]** marks a recommendation.
**[unverified]** marks an inference that the live test plan has to confirm.

Sources, cited by short name:

| Short name | Document |
|---|---|
| MaaS-3.5 | *Govern LLM access with Models-as-a-Service*, RHOAI Self-Managed 3.5 (access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/govern_llm_access_with_models-as-a-service) |
| MgmtAI-3.5 | *Administer OpenShift AI platform access, apps, and operations*, RHOAI 3.5, ch. 12 "Managing observability" |
| RN-3.5 | *3.5 Release notes*, RHOAI 3.5 |
| KB-7146363 | Red Hat article 7146363, "Enabling the MaaS observability dashboard on RHOAI 3" (updated 29 Sept 2026) |
| RHCL-Obs-1.5 | *Observe*, Red Hat Connectivity Link 1.5 |
| UWM-4.22 | *Configuring user workload monitoring*, Monitoring stack for Red Hat OpenShift 4.22 |

---

## 1. Summary and recommendation

The MaaS "observability dashboard" is really two separate things, and they cost very different
amounts:

1. **MaaS telemetry**: per-request labels (subscription, model, optionally user and group) on the
   Limitador counters. You turn it on with one field on the MaaS tenant resource. It needs no new
   operator and adds almost no load. It makes the token, request and 429 counts queryable per
   subscription in **Observe → Metrics** straight away.
2. **The Usage tab** (the dashboard, filters and CSV export) in the OpenShift AI console. This is a
   Perses dashboard. It needs the RHOAI observability stack, which means three more operators
   (Cluster Observability Operator, Tempo, Red Hat build of OpenTelemetry), a populated
   `DSCInitialization.spec.monitoring`, and a dashboard flag. That adds a second Prometheus, a
   Thanos Querier, Alertmanager, a Tempo instance, an OTel collector and Perses to a hub that is
   already loaded.

**[rec] Do it in two stages, both as opt-in policies:**

- **Stage 1, now:** the new policy `policy-maas-telemetry` sets
  `MaasTenantConfig.spec.telemetry`, and an inform policy `policy-maas-telemetry-ready` checks it.
  `captureUser` defaults to `false` and is controlled by a label. This gives per-subscription token
  accounting from PromQL at close to zero cost, and it is the prerequisite for stage 2 anyway.
- **Stage 2, after the FIPS rebuild settles:** a new `policy-openshift-ai-observability` in the
  `openshift-ai` directory. It populates DSCI metrics and traces, depends on the existing `coo`,
  `tempo` and `opentelemetry` install policies, and sets
  `OdhDashboardConfig.spec.dashboardConfig.observabilityDashboard: true`. Enable it alone, then
  measure etcd and worker requests, as `running-under-autoshift.md` requires.

Do **not** turn on the existing `uwm` label to "own" user workload monitoring yet. See §4.2: on
this hub it would fight the HyperShift operator over the same ConfigMap.

Everything in this design is **Technology Preview**: the dashboard (MaaS-3.5 §1.1, §1.8) and the
RHOAI observability stack it sits on (RN-3.5 §3.6, "Centralized platform observability"). The
dashboard is for showback and is "not suitable for billing-grade metering or external invoicing"
(MaaS-3.5 §1.18.4).

---

## 2. Findings, with citations

### 2.1 What has to be enabled

| # | Setting | Where | Status in docs | Source |
|---|---|---|---|---|
| 1 | User workload monitoring (`enableUserWorkload: true` in `openshift-monitoring/cluster-monitoring-config`) | cluster | **Required.** Without it "the MaaS installation shows a Degraded status" | MaaS-3.5 §1.2, §1.9; UWM-4.22 §1.2.1; KB-7146363 step 0 |
| 2 | `Kuadrant.spec.observability.enable: true` | `kuadrant-system/kuadrant` | Creates PodMonitor `kuadrant-limitador-monitor` | MaaS-3.5 §1.18.2; RHCL-Obs-1.5 §1.3 |
| 3 | MaaS telemetry: `spec.telemetry.enabled: true` plus `metrics.{captureOrganization,captureUser,captureGroup,captureModelUsage}` | **3.5: `MaasTenantConfig` `models-as-a-service/default-tenant`** (the 3.5 docs say `Tenant`, see 2.4) | "Activates TelemetryPolicy and Istio Telemetry to collect MaaS usage metrics" | MaaS-3.5 §1.18.3; KB-7146363 step 4 |
| 4 | `DSCInitialization.spec.monitoring.metrics` (and `traces`) populated | `default-dsci` | Starts the RHOAI observability stack (MonitoringStack, Thanos Querier, Tempo, collector) in `redhat-ods-monitoring` | MaaS-3.5 §1.8; MgmtAI-3.5 §12.1; KB-7146363 step 2 |
| 5 | Operators: Cluster Observability Operator, Tempo Operator, Red Hat build of OpenTelemetry | cluster | Prerequisites of #4. The CSV export procedure names COO explicitly | MgmtAI-3.5 §12.1; MaaS-3.5 §1.18.5; KB-7146363 step 1 |
| 6 | `OdhDashboardConfig.spec.dashboardConfig.observabilityDashboard: true` | `redhat-ods-applications/odh-dashboard-config` | Without it "the Usage tab doesn't render in the console navigation at all" | MaaS-3.5 §1.8; KB-7146363 step 5 |

**[fact]** No ServiceMonitors or PodMonitors have to be created by hand. Kuadrant creates the
Limitador and Istio gateway monitors (RHCL-Obs-1.5 §1.3, §4.3). maas-controller creates the
TelemetryPolicy `maas-telemetry` and the Istio `Telemetry` `latency-per-subscription` in the
gateway namespace once telemetry is on (KB-7146363 step 4 and its verification block).

**[fact]** COO versions: KB-7146363 says COO up to 1.4.0 was pinned because later CSVs broke the
dashboard, and that "for RHOAI 3.4.2 or higher it is possible to set COO 1.5.1 or higher". The hub
values file already comments `coo-version: cluster-observability-operator.v1.5.3`.
RHOAIENG-96473 (COO × RHOAI support matrix, in Review, fix 3.6 GA) records that no tested matrix
exists yet, and links RHOAIENG-69213 "COO v1.5.0 broken RHOAI 3.4 Observability Dashboard".

### 2.2 The metrics the dashboard queries (MaaS-3.5 §1.18.1, Table 1.5)

| Metric (as documented) | Meaning | Labels (documented) | Comes from | Live name on rhoai |
|---|---|---|---|---|
| `authorized_hits_total` | tokens consumed by successful requests | subscription, model, limitador_namespace | Limitador (via Kuadrant PodMonitor) | **`authorized_hits`** (no `_total`), `limitador_namespace` only |
| `authorized_calls_total` | requests that passed auth and rate limiting | subscription, limitador_namespace | Limitador | **`authorized_calls`**, `limitador_namespace` only |
| `limited_calls_total` | requests rejected with 429 | subscription and user (per §1.18.2 verification text) | Limitador | absent. No 429 has happened yet |
| Istio request and latency metrics "tagged with subscription dimension" | performance by subscription | subscription | gateway Envoy (Istio `Telemetry` `latency-per-subscription`) | `istio_requests_total` present, no subscription label |
| `auth_server_authconfig_duration_seconds` | time spent in Authorino | authorization policy | Authorino ServiceMonitor | present |
| `maas_api_http_requests_total`, `maas_api_token_mint_total` (and others) | maas-api requests and API-key minting | `tenant_name`, `result`, `status` | maas-api PodMonitor | **absent** (see 3.4) |
| vLLM success and latency counters | "Success Rate" overview tile | per model | vLLM PodMonitors in the model namespace | present (`kserve_vllm:*` in UWM) |

**[fact]** The user label is off by default: "The user label is disabled by default in MaaS metrics
(captureUser: false). To enable per-user metrics collection, configure the captureUser setting in
your MaasTenantConfig" (MaaS-3.5 §1.18.1 note).

**[fact]** Overview tiles: Total Tokens, Total Requests, Total Errors, Success Rate (computed from
vLLM counters, with 429s excluded) and Active Users. The table "Token Consumption by User" has the
columns User, Subscription, Model (`<endpoint-name>/<model-id>`), Tokens, Requests and Rate Limited
(MaaS-3.5 §1.18.1, Tables 1.3 and 1.4).

**[unverified]** Whether the Perses dashboard queries `authorized_hits` or `authorized_hits_total`.
Limitador on this cluster exposes the names without `_total`. If the dashboard asks for `_total`, it
shows zeros. Test plan T2.4 checks this.

**[unverified]** The User column and the Active Users tile almost certainly need `captureUser: true`.
With the default, expect one row per subscription and model with an empty or aggregate user.

### 2.3 Where the dashboard lives, who sees it, and CSV export

- **[fact]** OpenShift AI console → **Observe & monitor → Dashboard → Usage** tab. It is embedded
  through Perses and queries Prometheus (MaaS-3.5 §1.18.1, §1.18.4). This is not Gen AI studio.
  Gen AI studio holds the API keys page (§1.16.1).
- **[fact]** "Access to the dashboard is restricted to cluster administrators" (§1.18.1). The
  §1.18.4 and §1.18.5 prerequisites say cluster-admin.
- **[fact]** RN-3.5 §3.1 (3.5 GA Technology Preview) adds a **Loki-based showback pipeline** with
  30-day retention on object storage, and **user-scoped read-only dashboards** where users see only
  their own usage. That needs a LokiStack and object storage. It is out of scope here and is a
  candidate stage 3.
- **[fact]** Known issue: RHOAIENG-99814 ("Perses dashboards lack authentication, user token
  forwarding, and namespace isolation"). Perses runs with `enable_auth: false`, a NetworkPolicy lets
  only `rhods-dashboard` reach it, and its Prometheus datasource is the internal Thanos Querier on
  port 10902 with cluster-wide privileges. The fix was **reverted** (status Closed, title
  "REVERTED"). Isolation therefore depends on the dashboard's own cluster-admin gate.
- **[fact]** CSV export (MaaS-3.5 §1.18.5): on the Usage tab, set Time period (5 min to 14 days, or
  a custom range) and optionally the User, Subscription and Model filters. Hover over the table and
  choose **Export as CSV**. The file holds "subscription-level usage data for the selected time
  period and filters". For chargeback, Red Hat says to read the Limitador metrics endpoint directly
  rather than Prometheus or the CSV (§1.18.1).
- **[rec]** The CSV export is a browser download. No API or schedule is documented, so it cannot be
  a policy. A scheduled export would be a PromQL job against Thanos, built outside AutoShift.

### 2.4 Documentation defects that affect the design

- **[fact]** MaaS-3.5 §1.18.3 tells you to patch `tenants.maas.opendatahub.io default-tenant`.
  **[live]** On 3.5.2 that CRD exists but has **no instances**. The live object is
  `maastenantconfigs.maas.opendatahub.io/default-tenant` in `models-as-a-service`. KB-7146363 step 4
  confirms that 3.5+ uses `MaasTenantConfig`. A policy written from §1.18.3 would *create* an
  orphan `Tenant` that nothing reads, and would report Compliant. This is exactly the trap from
  CLAUDE.md.
- **[live]** The CRD schema gives `spec.telemetry.enabled` a default of `true`. The live object is
  `spec: {}`, and no TelemetryPolicy exists. A default inside an absent parent object is never
  applied, so telemetry is **effectively off** until `spec.telemetry` is written. Write it
  explicitly. Do not rely on the default.
- **[fact]** MaaS-3.5 §1.2 calls UWM required. RHOAIENG-95098 (Review, fix 3.7 EA) says that in 3.5
  "UWM is not required ... observability relies solely on the COO stack", and that the Cluster and
  Models dashboards wrongly still read UWM. Practical reading: keep UWM on, because the MaaS
  readiness check and the Models tab both use it, **and** run the COO stack for the Usage tab.

---

## 3. Current cluster state (rhoai, read-only, 2026-11-09)

OpenShift 4.22.18, `rhods-operator.3.5.2`, `rhcl-operator.v1.5.0`. **No** COO, Tempo or OpenTelemetry
CSV is installed. No `perses`, `monitoringstack` or `tempostack` CRDs exist.

### 3.1 User workload monitoring: on, but owned by HyperShift

- **[live]** `cluster-monitoring-config` contains `enableUserWorkload: true`. UWM pods are running
  (2× prometheus-user-workload, 2× thanos-ruler).
- **[live]** Both `cluster-monitoring-config` and `user-workload-monitoring-config` list a single
  field manager, **`hypershift-operator-manager`**. The MCE HyperShift add-on turned UWM on and
  writes a `remoteWrite` to `infogw.api.openshift.com` with a telemetry allowlist. No MaaS metric is
  in that allowlist, so usage data does not leave the cluster.
- **[live]** The AutoShift `uwm` label is `'false'` in `hub.yaml`. No UWM PVC exists (storage is
  emptyDir, retention is the 24h default per UWM-4.22 §3.2.1). UWM Prometheus holds only about 970
  head series.
- **[live]** The MaaS tenant reports `Ready=True` and `Degraded=False`, so the UWM prerequisite is
  currently met. That is by accident, not by policy.

### 3.2 Kuadrant and Limitador

- **[live]** `Kuadrant.spec.observability.enable: true`, set by
  `policies/stable/connectivity-link/manifests/kuadrant/kuadrant.yaml`. **Stage requirement #2 is
  already met.**
- **[live]** PodMonitor `kuadrant-system/kuadrant-limitador-monitor` and ServiceMonitor
  `kuadrant-authorino-monitor` exist. `istio-pod-monitor` exists in `openshift-ingress`.
- **[live]** `kuadrant-system` and `openshift-ingress` carry `openshift.io/cluster-monitoring: "true"`
  (the former from the connectivity-link namespace manifest). The **platform** Prometheus therefore
  scrapes Limitador, not UWM. `up{job="kuadrant-system/kuadrant-limitador-monitor"} == 1`.
- **[live]** Limitador uses in-memory storage and a single replica. A pod restart resets the
  counters. `increase()` handles that, but any reading of the raw counter does not.

### 3.3 The metrics today (read-only PromQL against prometheus-k8s)

```
authorized_hits{limitador_namespace="llm/granite-4-tiny-gpu-kserve-route"}  332788
authorized_calls{limitador_namespace="llm/granite-4-tiny-gpu-kserve-route"} 117
limited_calls                                                                (no series)
```

- **[live]** No `subscription`, `model` or `user` label. This confirms that MaaS telemetry is off.
  The data is per-route only.
- **[live]** The `kuadrant-system` namespace contributes about 1,300 series, mostly Authorino
  histograms. Platform Prometheus holds **about 857,000 head series** at about 5.1 GiB RSS per
  replica, with no PVC (emptyDir, so history is lost on restart).

### 3.4 MaaS's own monitors are aimed at a stack that does not exist yet

- **[live]** maas-controller created `redhat-ods-monitoring/limitador-metrics` (ServiceMonitor,
  label `monitoring.opendatahub.io/scrape: "true"`, `namespaceSelector: any`). It also created the
  PodMonitors `maas-api-metrics` (in `redhat-ai-gateway-infra`) and `maas-controller-metrics`
  (in `redhat-ods-applications`), and odh-model-controller created `maas-default-gateway-metrics`.
  All of them carry the same `monitoring.opendatahub.io/scrape` label, which is the selector of the
  RHOAI MonitoringStack (MgmtAI-3.5 §12.3).
- **[live]** NetworkPolicies `maas-api-allow-monitoring` (port 9090) and
  `maas-controller-allow-monitoring` (port 8080) admit scrapes **only from `redhat-ods-monitoring`**.
  UWM's maas-controller target is down (`context deadline exceeded`).
- **[live]** `maas-api-metrics` selects port name `metrics`, but the maas-api container declares only
  `https:8443` (with `METRICS_PORT=9090` in its environment). Prometheus drops every maas-api target.
  **[unverified]** The same PodMonitor under the COO stack would drop them too, so
  `maas_api_http_requests_total` and `maas_api_token_mint_total` are probably unavailable on 3.5.2
  whichever stack you run. RHOAIENG-103285 (New, fix 3.7 EA) notes that 3.5.x maas-api PodMonitors
  are scraped by nothing, and that the 3.5.2 maas-controller PodMonitor is plain HTTP.
- **[live]** Two vLLM PodMonitors (`kserve-llm-isvc-vllm-engine` and `...-default`) select the same
  pods. Every vLLM series is scraped twice (462 + 462) under different `job` labels. Ratios such as
  Success Rate are unaffected. A plain `sum()` doubles.

### 3.5 RHOAI dashboard and DSCI

- **[live]** `OdhDashboardConfig.spec.dashboardConfig` = `{mcpCatalog: true}`. There is no
  `observabilityDashboard`.
- **[live]** DSCI `spec.monitoring` = `{managementState: Managed, metrics: {}, namespace:
  redhat-ods-monitoring}`, phase Ready. `redhat-ods-monitoring` contains only the `limitador-metrics`
  ServiceMonitor. No MonitoringStack runs.
- **[fact]** `policies/stable/openshift-ai/manifests/dsc/dscinitialization.yaml` leaves out metrics
  and traces on purpose, until COO, Tempo and OTel are installed.

---

## 4. Privacy, cardinality, retention and cost

### 4.1 Per-user labels

- **[fact]** `captureUser` "adds a 'user' dimension ... containing the authenticated user ID ...
  Enabling this may have GDPR / privacy implications" (live CRD description). The default is false
  "due to privacy and cardinality considerations. Enabling this option with a large number of users
  can significantly increase Prometheus database size" (MaaS-3.5 §1.18.3). `captureGroup` is off by
  default for cardinality.
- **[fact]** User identity is the API-key owner or the OIDC identity (§1.18.1 Table 1.4). For
  Hermes keys that is a ServiceAccount, so the "user" can be a workload.
- Cardinality: Limitador series grow roughly as metrics × subscriptions × models × users (× groups
  when `captureGroup` is on). This lab has 1 subscription, 1 model and a handful of users
  (`maas-users` plus the `hermes` ServiceAccounts), so tens of series. That is negligible next to
  857k. The concern is a real tenant population.
- **[rec]** Policy default `captureUser: 'false'`, flipped by a cluster label. On this lab cluster,
  turning it on is defensible and makes the User column work. Record the decision in `hub.yaml`
  next to the label.

### 4.2 Retention

- **[fact]** The Usage tab offers at most 14 days (§1.18.1). The suggested DSCI starting point is
  `metrics.storage {size: 5Gi, retention: 90d}`, `traces {sampleRatio: '0.1', storage {backend: pv,
  retention: 2160h}}`, and these are "starting values ... not hard requirements" (KB-7146363 step 2;
  MgmtAI-3.5 example).
- **[live]** Platform Prometheus (where Limitador lands today) and UWM both run on emptyDir. Monthly
  showback from either is not reliable. The DSCI MonitoringStack uses a PV.
- **[rec]** For showback beyond 14 days, use the CSV per period, or later the Loki pipeline
  (RN-3.5 §3.1, 30 days).

### 4.3 Resource cost on this hub

- Stage 1: one TelemetryPolicy and one Istio Telemetry object, plus wasm-filter label work per
  request on the gateway. **[unverified]** The latency cost per request is not quantified in any
  source found.
- Stage 2 adds the following (pods per MgmtAI-3.5 §12.1 verification): `prometheus-data-science-
  monitoringstack`, `alertmanager-data-science-monitoringstack` (shown ×2 in §3.1), `thanos-querier-
  data-science-thanos-querier`, `tempo-data-science-tempomonolithic`, `data-science-collector-
  collector`, `data-science-perses-0`, plus three operator pods. Add two PVs (5 Gi metrics, Tempo
  PV). The DSCI example requests 100m CPU / 256Mi for Prometheus with a 512Mi limit, which is low
  for a Prometheus that scrapes every `monitoring.opendatahub.io/scrape` target, including vLLM.
  **[rec]** Set `metrics.resources` explicitly (start at 500m / 2Gi request) and measure.
- **[fact]** `running-under-autoshift.md`: overload shows up as API timeouts and NotReady nodes, not
  as "too small". Enable stage 2 on its own and re-measure etcd and worker CPU requests.

### 4.4 The `uwm` policy would conflict on this hub

**[live + rec]** `policy-uwm-enable` writes all of `user-workload-monitoring-config` `data.config.yaml`
as a single string with `musthave`. HyperShift owns that same string (its `remoteWrite`). Enforcing
the policy would drop the `remoteWrite`, HyperShift would put it back, and the two would flap.
`cluster-monitoring-config` is safe, because the policy merges `enableUserWorkload` into the
existing YAML. **Do not enable `uwm` on this hub** until the policy merges the UWM config the same
way. That is a candidate upstream fix. Until then, assert UWM in the inform readiness check below.

---

## 5. FIPS and Preview caveats

- **[fact]** Technology Preview: the MaaS observability dashboard (MaaS-3.5 §1.1, §1.8), the
  centralized platform observability stack (RN-3.5 §3.6), the Loki showback and user-scoped
  dashboards (RN-3.5 §3.1), and external-model usage tracking (RN-3.5 §3.4).
- **[fact]** Showback only, not billing-grade (§1.18.1, §1.18.4, §1.18.5).
- **[unverified]** FIPS. No source found states FIPS support for COO, Perses, the Tempo Operator or
  the Red Hat build of OpenTelemetry on 4.22, or for the Limitador wasm telemetry path. The FIPS
  rebuild plan (`docs/rebuild-fips-plan.md`) does not mention observability. **[rec]** Before
  enabling stage 2 on the FIPS cluster, check each operator's FIPS statement on its product page or
  through a support case. Treat stage 2 as not FIPS-validated until then. Stage 1 adds no new image,
  so it inherits the FIPS posture of RHCL and RHOAI.
- **[fact]** Do not confuse this with RHOAI "usage data collection" (Segment telemetry to Red Hat,
  *Configure user access, storage, and telemetry*, RHOAI 3.5 ch. 9). That is a different feature.
  MaaS telemetry stays in-cluster.

---

## 6. Proposed AutoShift design

Everything lives in `$AUTOSHIFT_DIR` (`rhoai-maas` branch). Every name below is at most 40
characters.

### 6.1 Stage 1: additions to `policies/stable/openshift-ai-maas`

Follow the agents-catalog pattern: extra policies in the existing directory with their own
placement file, because they configure an object that MaaS already owns.

```
openshift-ai-maas/
  placement-openshift-ai-maas-telemetry.yaml   # openshift-ai-maas=true AND openshift-ai-maas-telemetry=true
  manifests/telemetry/maastenantconfig.yaml
  test/telemetry-ready.yaml
```

`policy-generator-config.yaml` additions:

```yaml
  # MaaS telemetry: per-subscription labels on the Limitador counters.
  # Depends on -db, not on the install: maas-controller creates the
  # MaasTenantConfig only once maas-api is up, and musthave would otherwise
  # create a default-tenant ahead of it. The 3.5 docs name tenants.maas...;
  # on 3.5.2 that CRD has no instances - MaasTenantConfig is the live object.
  - name: policy-maas-telemetry                 # 21 chars
    placement:
      placementPath: placement-openshift-ai-maas-telemetry.yaml
    consolidateManifests: false
    dependencies:
      - name: policy-openshift-ai-maas-db
    manifests:
      - path: manifests/telemetry
  - name: policy-maas-telemetry-ready           # 27 chars
    remediationAction: inform
    placement:
      placementPath: placement-openshift-ai-maas-telemetry.yaml
    dependencies:
      - name: policy-maas-telemetry
    manifests:
      - path: test/telemetry-ready.yaml
```

`manifests/telemetry/maastenantconfig.yaml`. Plain YAML, not `object-templates-raw`, so it cannot
render empty. Booleans come from labels and are compared as strings (CLAUDE.md: no `toInt`):

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaasTenantConfig
metadata:
  name: default-tenant
  namespace: models-as-a-service
spec:
  telemetry:
    enabled: true
    metrics:
      captureOrganization: true
      captureModelUsage: true
      captureUser: '{{hub eq (index .ManagedClusterLabels "autoshift.io/openshift-ai-maas-telemetry-capture-user" | default "false") "true" hub}}'
      captureGroup: '{{hub eq (index .ManagedClusterLabels "autoshift.io/openshift-ai-maas-telemetry-capture-group" | default "false") "true" hub}}'
```

**[unverified]** Whether a quoted hub-template boolean is coerced to a JSON boolean by the config
policy controller. If not, use the `object-templates-raw` form, emit unquoted `true`/`false`, and let
`make test` check that it does not render empty.

`test/telemetry-ready.yaml` (inform). Every object asserted here is one that maas-controller or
Kuadrant creates, so a pass shows that the chain reacted, not only that the spec was written:

- `MaasTenantConfig default-tenant` with `spec.telemetry.enabled: true` and `status.conditions`
  Ready=True.
- `TelemetryPolicy maas-telemetry` in `openshift-ingress`, `extensions.kuadrant.io/v1alpha1`
  (KB-7146363). **[unverified]** its status condition type, to be read off the live object after
  stage 1 (expect `Accepted` and `Enforced` like other Kuadrant policies), then asserted.
- `Telemetry latency-per-subscription` in `openshift-ingress` (`telemetry.istio.io`).
- `PodMonitor kuadrant-limitador-monitor` in `kuadrant-system`.
- `StatefulSet prometheus-user-workload` with `readyReplicas` equal to `spec.replicas`, the same
  pattern as `user-workload-monitoring/test/uwm-enable-ready.yaml`. This makes the UWM dependency
  visible without the conflicting `uwm` policy.

The CRD-absent trap: `MaasTenantConfig`, `TelemetryPolicy` and `Telemetry` CRDs all exist only after
RHOAI MaaS and RHCL are installed. The dependency on `policy-openshift-ai-maas-db` (whose
`maas-api-ready` check implies the controller reconciled) keeps the enforce policy from reporting a
vacuous Compliant. For the inform policy, a missing CRD would also read Compliant, so it depends on
the enforce policy.

`customMessage.noncompliant` for the ready policy should name the 3.5 doc trap ("`Tenant` in the
docs is `MaasTenantConfig` on 3.5.2") and the check (`oc get telemetrypolicies.extensions.kuadrant.io
-n openshift-ingress`).

A policy cannot prove that metrics actually flow, because a ConfigurationPolicy cannot run PromQL.
That proof belongs in `checkup.sh` (§6.4).

### 6.2 Stage 2: `policies/stable/openshift-ai`, a new observability policy

This is RHOAI-wide (the Cluster and Models tabs use it too), so it belongs with the DSCI owner, not
in MaaS. It is a separate policy merging fields into `default-dsci`, the same way
`policy-openshift-ai-maas-dsc` merges into the DSC.

```
openshift-ai/
  placement-openshift-ai-observability.yaml    # openshift-ai=true AND openshift-ai-observability=true
  manifests/observability/dsci-monitoring.yaml
  manifests/observability/dashboard-observability.yaml   # OdhDashboardConfig observabilityDashboard: true
  test/observability-ready.yaml
```

```yaml
  - name: policy-openshift-ai-observability      # 33 chars
    placement:
      placementPath: placement-openshift-ai-observability.yaml
    consolidateManifests: false
    dependencies:
      - name: policy-openshift-ai-dsc
      - name: policy-coo-operator-install
      - name: policy-tempo-operator-install
      - name: policy-opentelemetry-operator-install
    manifests:
      - path: manifests/observability
  - name: policy-openshift-ai-obs-ready          # 29 chars
    remediationAction: inform
    placement:
      placementPath: placement-openshift-ai-observability.yaml
    dependencies:
      - name: policy-openshift-ai-observability
    manifests:
      - path: test/observability-ready.yaml
```

- `dsci-monitoring.yaml`: `spec.monitoring.metrics {replicas, resources, storage {size, retention}}`
  and `traces {sampleRatio, storage {backend: pv, retention}}`, read from rendered-config
  `config.openshiftAiObservability` with literal defaults (5Gi, 90d, '0.1', 2160h). Use the `toJson`
  form for the nested `resources` (CLAUDE.md `toYaml | nindent` trap).
- **Cross-directory dependencies** (`policy-coo-operator-install` and the others) need those
  policies placed, otherwise the dependency is never satisfied and this policy sits Pending. Document
  in `hub.yaml` that `openshift-ai-observability: 'true'` requires `coo`, `tempo` and
  `opentelemetry: 'true'`. Add a group to `scripts/autoshift-feature.sh` (`enable maas-observability`
  requires `maas`) that refuses partial enablement, the same way the MaaS chain does.
- Pin COO with `coo-version: 'cluster-observability-operator.v1.5.3'` (KB-7146363: 1.5.1+ is fine
  on 3.4.2+). Run `scripts/check-operator-install-modes.sh` against the three new CSVs before
  enabling (CLAUDE.md: six AllNamespaces=false failures so far).
- `observability-ready.yaml` (inform): the five pods named in MgmtAI-3.5 §12.1 Ready in
  `redhat-ods-monitoring`, `data-science-perses-0` Ready, and the flag set.

### 6.3 Labels and config keys

Declare these in **both** `autoshift/values/clustersets/_example.yaml` and `clusters/_example.yaml`,
with non-empty sample values so CI exercises them:

| Label | `hub.yaml` value (proposed) | `_example` sample |
|---|---|---|
| `openshift-ai-maas-telemetry` | `'true'` (stage 1) | `'true'` |
| `openshift-ai-maas-telemetry-capture-user` | `'false'` (decision, see §7) | `'false'` |
| `openshift-ai-maas-telemetry-capture-group` | `'false'` | `'false'` |
| `openshift-ai-observability` | `'false'` until stage 2 | `'true'` |
| `coo`, `tempo`, `opentelemetry` | `'false'` until stage 2 | existing |

Config (stage 2), `config.openshiftAiObservability`: `metrics.{replicas, storage.size,
storage.retention, resources}` and `traces.{sampleRatio, storage.backend, storage.retention}`.

Gate: `GOTOOLCHAIN=auto make test` (check the skipped count) and `vale --minAlertLevel=error` over
`policies/`. The new YAML comments are prose. Do not open sentences with "So", "And" or "But".

### 6.4 `scripts/checkup.sh` additions (rhoai-mass-aws)

Add a `maas-usage` sub-block at the end of the `maas` section. All checks are read-only.

1. UWM: `enableUserWorkload: true` and both prometheus-user-workload pods Ready. Report
   **who manages** `cluster-monitoring-config` (managedFields). If it is `hypershift-operator-manager`,
   print an informational note that UWM exists by side effect.
2. `kuadrants.kuadrant.io kuadrant -n kuadrant-system` `.spec.observability.enable == true`, and
   PodMonitor `kuadrant-limitador-monitor` present.
3. `maastenantconfigs.maas.opendatahub.io default-tenant` `.spec.telemetry.enabled`. If unset, report
   "telemetry off (`spec: {}` does not apply the CRD default)". Warn if any
   `tenants.maas.opendatahub.io` object exists (the doc trap).
4. `telemetrypolicies.extensions.kuadrant.io maas-telemetry -n openshift-ingress` and
   `telemetries.telemetry.istio.io latency-per-subscription -n openshift-ingress` present.
5. **The flow check.** Run a PromQL instant query
   `count by (subscription) (authorized_hits)` against the platform Prometheus. It is the platform
   instance because `kuadrant-system` carries the cluster-monitoring label. Use the same method
   this design used:
   `oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- curl -s --get
   http://localhost:9090/api/v1/query --data-urlencode query=...`. Pass when there is at least one
   series with a non-empty `subscription`. If series exist without the label, report "telemetry not
   applied". If there are no series, report "no MaaS traffic yet, run 35-smoke-test".
6. Stage 2 only, when `observabilityDashboard` is true: pods in `redhat-ods-monitoring`, and the
   same query against the MonitoringStack Prometheus (`prometheus-data-science-monitoringstack-0`),
   because that is what Perses reads (RHOAIENG-99814).
7. Informational warnings: duplicate vLLM PodMonitors on the same pods, and maas-api PodMonitor
   port `metrics` not declared on the container (both §3.4).

---

## 7. Live test plan

Run in order. Each step names the expected result. "Pass" means exactly that output.

**Before enabling (baseline, already captured in §3).**

**Stage 1**, after `openshift-ai-maas-telemetry: 'true'`, bootstrap/refresh and policy Compliant:

| # | Command | Expected |
|---|---|---|
| T1.1 | `oc get maastenantconfigs.maas.opendatahub.io default-tenant -n models-as-a-service -o jsonpath='{.spec.telemetry}'` | `{"enabled":true,"metrics":{...captureUser:false...}}` |
| T1.2 | `oc get tenants.maas.opendatahub.io -A` | `No resources found` (the policy did not create the doc's orphan) |
| T1.3 | `oc get telemetrypolicies.extensions.kuadrant.io -n openshift-ingress` | `maas-telemetry`. Record its condition types for the ready policy |
| T1.4 | `oc get telemetries.telemetry.istio.io -n openshift-ingress` | `latency-per-subscription` |
| T1.5 | `scripts/35-smoke-test.sh` (one request as maas-user) | 200 with tokens |
| T1.6 | PromQL `authorized_hits` (platform Prometheus, §6.4 item 5) | new series carry `subscription="granite-4-tiny-gpu-default"` and a model label. The old label-less series goes stale |
| T1.7 | PromQL `istio_requests_total{subscription!=""}` | at least one series (per-subscription latency tagging) **[unverified label name]** |
| T1.8 | Burst past 300000 tokens/min with one key (loop of large `max_tokens` requests) | 429s, then `limited_calls{subscription=...}` appears |
| T1.9 | MaaS tenant conditions | still `Ready=True`, `Degraded=False` |
| T1.10 | Gateway latency (p50 of 20 identical requests before and after) | difference within noise. Record the numbers |

Optionally, only if the user approves `captureUser`: flip the label, then expect
`authorized_hits{user="maas-user"}` after T1.5, and hermes ServiceAccount users after a Hermes
request.

**Stage 2**, after `coo`, `tempo`, `opentelemetry`, `openshift-ai-observability` = `'true'`:

| # | Command | Expected |
|---|---|---|
| T2.1 | `oc get csv.operators.coreos.com -A \| grep -E 'cluster-observability\|tempo\|opentelemetry'` | all `Succeeded`. COO at 1.5.3 |
| T2.2 | `oc get pods -n redhat-ods-monitoring` | the 5 pods from MgmtAI-3.5 §12.1 plus `data-science-perses-0`, all Running |
| T2.3 | PromQL `authorized_hits` on `prometheus-data-science-monitoringstack-0` | same series as T1.6 (via the `limitador-metrics` ServiceMonitor) |
| T2.4 | Console: Observe & monitor → Dashboard → **Usage** | Total Tokens > 0 for the last hour. **If zero while T2.3 has data, suspect the `_total` name mismatch** (§2.2) |
| T2.5 | Filter Subscription = granite-4-tiny-gpu-default, Export as CSV | a CSV with Subscription, Model, Tokens, Requests and Rate Limited columns. Compare Tokens with `increase(authorized_hits[1h])` (expect agreement within scrape granularity) |
| T2.6 | Log in as `maas-user` (not cluster-admin) | no Usage tab (§1.18.1 cluster-admin restriction) |
| T2.7 | Success Rate tile against a hand computation from one vLLM job | equal (the duplicate PodMonitors must not distort it) |
| T2.8 | maas-api metrics: PromQL `maas_api_http_requests_total` | **expected absent** on 3.5.2 (§3.4). Confirms the port-name defect |
| T2.9 | Load: `checkup.sh --section load`, etcd high-water, worker CPU requests | recorded before and after, within the headroom in `running-under-autoshift.md` |

---

## 8. Open questions and risks

Decisions for the user:

1. `captureUser` on this lab cluster: a) keep `false` (recommended policy default) b) `true` here
   only, accepting the GDPR note for a lab with known users.
2. Stage 2 timing: a) after the FIPS rebuild and an operator FIPS check (recommended) b) on the
   current non-FIPS cluster first, as a dry run.

Risks and unknowns:

- **Doc says `Tenant`, product uses `MaasTenantConfig`** (§2.4). Mitigated by the design. Worth a
  docs bug against MaaS-3.5 §1.18.3.
- **UWM depends on HyperShift's side effect.** If the HyperShift add-on is removed, UWM may go
  away and MaaS goes Degraded (MaaS-3.5 §1.2). The `uwm` policy cannot safely take over until it
  merges `user-workload-monitoring-config` (§4.4). This is a candidate AutoShift upstream issue.
- **Metric-name mismatch** (`authorized_hits` live and `authorized_hits_total` in the docs) could
  make the Usage tab read zero. **[unverified]** until T2.4.
- **maas-api metrics are unscrapeable on 3.5.2** (port-name mismatch; RHOAIENG-103285). The
  `maas_api_*` per-tenant metrics in §1.18.1 will be missing. **[unverified]** under COO. Candidate
  Jira if T2.8 confirms it.
- **Duplicate vLLM PodMonitors** double plain sums. Worth a Jira if the Models tab shows doubled
  counts.
- **COO compatibility** has broken the dashboard before (RHOAIENG-69213). There is no published
  matrix (RHOAIENG-96473). Pin the version and validate the Usage tab before any COO upgrade.
- **Perses has no auth of its own** (RHOAIENG-99814, fix reverted). This is acceptable while access
  is cluster-admin only. Revisit for the 3.5 user-scoped dashboards.
- **Hub load:** stage 2 adds roughly eight pods and two PVs. Platform Prometheus is already at
  857k series and 5 GiB per replica. The DSCI example Prometheus limits (512Mi) are too small for a
  stack that also scrapes vLLM. Set them explicitly.
- **Retention:** the platform and UWM Prometheus run on emptyDir here. Usage history before
  stage 2 is not durable.
- **Not billing-grade** (MaaS-3.5 §1.18.4). Chargeback should read Limitador directly or wait for
  the Loki pipeline.
- **FIPS** status of COO, Perses, Tempo and OTel was not verified (§5).
