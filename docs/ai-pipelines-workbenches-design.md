# AI pipelines and workbenches through AutoShift: design

Status, 2026-11-09: design only. Nothing here is implemented. Checked against
RHOAI 3.5.2 (`rhods-operator.3.5.2`) on the live `rhoai` cluster (OpenShift
4.22.18, AWS us-east-2, not FIPS), the `rhoai-maas` branch of the AutoShift
fork, and the RHOAI 3.5 Self-Managed documentation.

Facts carry a citation (doc URL plus section) or say "observed on the
cluster". Recommendations are under their own headings. Anything not verified
is marked **(unverified)**.

## Summary and recommendation

**The platform half is already done.** The fork's `openshift-ai` policy sets
both `aipipelines` and `workbenches` to `Managed` in `default-dsc`. On the
live cluster `AIPipelinesReady` is True, the Data Science Pipelines Operator
and both notebook controllers are running, the embedded Argo Workflows
controller is available, and 11 workbench images plus 14 pipeline runtime
images are installed. No new operator and no new DataScienceCluster component
is needed.

**What is missing is everything per project.** There are no pipeline servers
(`DataSciencePipelinesApplication`, DSPA) and no workbenches on the cluster,
no object storage for pipelines, and no group model for who builds agents.
A customer today has to create a project, find S3 credentials, type them into
the "Configure pipeline server" dialog (which cannot be edited afterwards),
then create a workbench *after* the pipeline server so Elyra gets its runtime
configuration, then mint a MaaS key by hand.

Recommendation:

1. **Keep enablement where it is.** Add only a readiness assertion and a
   small `Auth` / dashboard-flags policy to `openshift-ai`.
2. **Add one config-driven policy directory, `openshift-ai-projects`.** It
   ranges over `config.openshiftAiProjects.projects[]` and creates, per
   entry, a dashboard project, group RoleBindings and a DSPA. This is the
   `openshift-ai-models` pattern from
   [what-belongs-in-autoshift.md](what-belongs-in-autoshift.md): a shaped CR
   that varies by a few fields, so the repository does not grow per project.
   Workbenches stay self-service. A workbench is a person's workspace, not
   platform.
3. **Object storage on AWS: an S3 bucket created by a script, not a policy.**
   This follows the `maas-database.sh` precedent: `scripts/pipelines-s3.sh`
   creates one bucket and one IAM user per project, restricted to the
   project's prefix, and writes the keys into a Secret in the project
   namespace. Nothing goes into git. An inform policy asserts that the Secret
   exists. ODF Multicloud Object Gateway with `ObjectBucketClaim` is the
   declarative alternative for off-AWS or disconnected sites, and is held for
   later.
4. **Database: start with the built-in MariaDB.** Red Hat calls it development
   and test only. Move to RDS MariaDB for anything a customer relies on. The
   CA for RDS has to come in through the DSPA's own `cABundle`, because our
   policy owns `DSCInitialization.spec.trustedCABundle.customCABundle` and
   would revert the documented hand patch.

**Smallest useful first step:** one project, `agent-lab`, created by hand on
the current cluster (or the FIPS rebuild) with an S3-backed DSPA, built-in
MariaDB, and one Standard Data Science workbench. Prove four things there:
Elyra submits a pipeline, Kale is visible, a notebook calls
`granite-4-tiny-gpu` through MaaS with a user-minted key, and the AutoRAG
pipeline registers. Then codify exactly what worked into
`openshift-ai-projects`.

**Main risks:** most of the agent-building surface is Technology or Developer
Preview (Gen AI studio playground, AutoRAG, OGX APIs, Agent Catalog, saved
agents). The docs disagree about OGX's support status. RHOAI has no general
FIPS statement that I could find. TLS trust for the self-signed ingress
certificate affects notebook-to-MaaS calls.

## Findings

### 1. AI pipelines in RHOAI 3.5

**Component and managementState.** The DataScienceCluster component is
`aipipelines`, with a `managementState`. A sub-field
`argoWorkflowsControllers.managementState` controls the embedded Argo
Workflows controller. Set it to `Removed` only to use your own Argo Workflows
instance.
[INST §3.4.1 "Installing Red Hat OpenShift AI components by using the CLI"][inst]

**Support status.** AI Pipelines is GA in 3.5, at version 2.16.0, with Argo
Workflows v3.7.3 GA, on OpenShift 4.19.9+, 4.20, 4.21 and 4.22 (x86_64).
[Supported Configurations][sc]

> Doc discrepancy: the 3.5 install guide §3.1.1 "Platform requirements" still
> says "OpenShift Container Platform 4.19 to 4.20". The Supported
> Configurations article lists 4.22, and the MCP catalog docs require 4.22.
> Treat the article as authoritative.

**The per-project server CR.** It is still `DataSciencePipelinesApplication`,
`datasciencepipelinesapplications.opendatahub.io/v1`, short name `dspa`. The
dashboard calls it a "pipeline server". [PIPE ch. 8 "DSPA component
troubleshooting"][pipe] Observed on the cluster, from the CRD schema:

| Field | Notes |
|---|---|
| `spec.objectStorage` | **The only required field.** `externalStorage` (`host`, `bucket`, `scheme` required; `region`, `port`, `basePath`, `secure`; `s3CredentialsSecret {secretName, accessKey, secretKey}` where the last two are *key names* in the Secret), or `minio`, described in the CRD as "unsupported, primarily for development, and testing" |
| `spec.objectStorage.externalStorage.credentialsMode.fromEnv` | Present in the CRD. Read credentials from the environment, the hook for IRSA. Not in the 3.5 docs **(unverified)** |
| `spec.serviceAccountAnnotations` | "Typically used for IRSA/Workload Identity configurations (e.g., eks.amazonaws.com/role-arn)". Not in the 3.5 docs **(unverified)** |
| `spec.database` | `mariaDB` (default, deployed in the project) or `externalDB {host, port, username, pipelineDBName, passwordSecret}`, plus `customExtraParams`, for example `{"tls":"true"}` |
| `spec.apiServer.pipelineStore` | `database` or `kubernetes`. The CRD defaults to `database`. The **dashboard** defaults new servers to Kubernetes storage (`Pipeline` / `PipelineVersion` CRs) [PIPE §1.1, §1.2.4][pipe] |
| `spec.apiServer.managedPipelines` | `{}` enables the AutoML and AutoRAG pipelines [AutoRAG ch. 3][autorag] |
| `spec.apiServer.cABundle {configMapName, configMapKey}` | Per-DSPA CA for an object store or database "unrecognized by the host cluster" |
| `spec.podToPodTLS` | Defaults to true |
| `spec.mlflow.integrationMode` | `AUTODETECT` (default) or `DISABLED` |

Planned, **not shipped**: RHOAIENG-93742 (Closed, fixVersion 3.6 GA) enables
`managedPipelines` by default for the AutoML/AutoRAG GA. RHAISTRAT-2851
(draft, New) adds IRSA/STS S3 authentication to the pipeline server UI.

**Object storage.** An existing S3-compatible bucket with write access is a
prerequisite. Connection settings cannot be changed later; a wrong setting
means deleting the pipeline server and making another. Imported artifacts
(`kfp.dsl.importer`) must live in the same bucket. [PIPE §1.1 "Configure a
pipeline server"][pipe] AWS S3, MinIO, Ceph and IBM Cloud Object Storage are
all named. [INST §3.1.1 "Platform requirements", Object storage][inst]

**Database.** "Default database on the cluster" deploys MariaDB in the project
and "is intended for development and testing purposes only". For production,
use an external MySQL (5.x minimum, 8.x recommended;
`mysql_native_password` must be enabled on 8.4+) or MariaDB (10.3 minimum,
10.5+ recommended). [PIPE §1.1][pipe] For **Amazon RDS**, the documented
procedure appends the region's RDS CA bundle to
`DSCInitialization.spec.trustedCABundle.customCABundle` with `oc patch`.
[PIPE §1.1.1 "Configure a pipeline server with an external Amazon RDS
database"][pipe] PostgreSQL is not supported, so the MaaS RDS instance cannot
be reused.

**TLS and CA.** The failure for an untrusted object store is
`ObjectStorageAvailable=False`, "x509: certificate signed by unknown
authority". [PIPE ch. 8][pipe] Fix it in the cluster-wide CA bundle or in the
RHOAI custom bundle. [INST ch. 8 "Work with certificates"][inst] Workbenches
point `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `PIP_CERT`, `GIT_SSL_CAINFO` and
`KF_PIPELINES_SSL_SA_CERTS` (which Elyra passes to `kfp`) at
`/etc/pki/tls/custom-certs/ca-bundle.crt`. [DISC §8.5.3 "Configure a
certificate for workbenches"][disc]

**Argo Workflows.** AI pipelines embeds its own Argo Workflows controller.
"You cannot enable both the embedded Argo Workflows instance and your own
Argo Workflows instance on the same cluster." [INST ch. 4 "Configure
pipelines with your own Argo Workflows instance"][inst] KB
[7129369](https://access.redhat.com/solutions/7129369) (RHOAI 2.9–2.23)
describes the conflicts with a cluster-scoped Argo Workflows install.

*No conflict with OpenShift GitOps.* GitOps is Argo **CD** (plus Rollouts and
Promoter CRDs). Observed on the cluster: `workflows.argoproj.io` is labelled
`app.kubernetes.io/part-of: data-science-pipelines-operator`, so RHOAI owns
it, and GitOps 1.22.3 is installed alongside it with `ArgoWorkflowAvailable`
True. The conflict would only arise if someone installed Argo Workflows
separately, for example through a community operator.

**Pipeline runtime images.** The Elyra runtime images are the
`runtime-*` ImageStreams in `redhat-ods-applications`: datascience, minimal,
pytorch, pytorch-llmcompressor, rocm-pytorch, rocm-tensorflow and tensorflow,
each in a current and a `-2025-2` flavour (observed). The pipeline control
plane images (api-server, persistenceagent, scheduledworkflow, driver,
launcher, argoexec, workflowcontroller, mlmd-grpc, `rhel9/mariadb-105`,
pipelines-components, AutoML, AutoRAG) are all `registry.redhat.io/rhoai/*`
or rhel9 images pinned by digest in the DSPO Deployment env (observed).

**Disconnected.** Everything must be mirrored before install
[DISC §3.1.1][disc]. The operator bundle's related images cover the control
plane. The existing
[rhoai-disconnected-additional-images.md](rhoai-disconnected-additional-images.md)
already covers the workbench and runtime image tags. What it does not cover:

- base images that user components name (`@dsl.component(base_image=...)`)
- PyPI packages that components `pip install`. A "Python package index"
  connection type exists for this. [MGR §6.3][mgr]
- the Docling sample pipeline's model downloads **(unverified)**

**FIPS.** One explicit statement: "If your cluster is running in FIPS mode,
any custom container images for data science pipelines must be based on
UBI 9 or RHEL 9 ... prevents errors related to mismatched OpenSSL or GNU C
Library (glibc) versions." [INST §3.1.2 "Component requirements"][inst] I
found no general RHOAI FIPS support statement in the 3.5 docs or the
Supported Configurations article **(unverified, see Risks)**.

**Known issues and limits.**

- RHOAIENG-48753: with Kubernetes pipeline storage, an Elyra pipeline name
  that is not DNS-compliant fails with a misleading endpoint error. Use
  DNS-compliant names. [RN §7.5][rn]
- Elyra is only in JupyterLab images derived from Standard Data Science (not
  Minimal, not CUDA, not code-server). [PIPE §7.9][pipe]
- Switching `pipelineStore` hides pipelines stored the other way.
  [PIPE §1.2.4][pipe]

### 2. Workbenches in RHOAI 3.5

**Component.** `workbenches`, with `workbenchNamespace` (default
`rhods-notebooks`, used for "basic" workbenches). A custom namespace must exist
before the operator is installed. [INST §3.1.2][inst] The Kubeflow Notebook
Controller is GA 1.10.0. [SC][sc]

**Images on the cluster** (observed; each has tags `2025.1`, `2025.2`, `3.4`,
`3.5`):

| Image | Elyra / Kale | Relevance to agent building |
|---|---|---|
| Jupyter \| Data Science \| CPU \| Python 3.12 (`s2i-generic-data-science-notebook`) | yes / yes | **The default for agents**: CPU only, since inference is remote through MaaS, and it has Elyra |
| Jupyter \| Minimal \| CPU | no / no | Lightweight scripting, no pipeline authoring |
| Code Server \| Data Science \| CPU | no / no | Developers who prefer VS Code; author pipelines with the `kfp` SDK |
| Jupyter \| TrustyAI \| CPU | yes / yes | Evaluation and guardrails work |
| Jupyter \| PyTorch / TensorFlow \| CUDA, Minimal \| CUDA, PyTorch LLM Compressor \| CUDA | PyTorch, TensorFlow: yes / yes | Fine-tuning and compression. Needs the single g6.xlarge GPU, which already serves the model |
| ROCm variants | yes | Not relevant on AWS |

RStudio images are gone in 3.5. [RN §5.2][rn] An administrator can hide a
pre-installed image. The setting is the
`opendatahub.io/notebook-image-hidden` annotation on the ImageStream and
survives upgrades. [GS §4.1.1 "Administrator control over image
visibility"][gs] Kale ships pre-installed but disabled in the Data Science,
PyTorch, TensorFlow, TrustyAI and ROCm images. Enable it per workbench with
`jupyter labextension enable jupyterlab-kubeflow-kale`. It needs a DSPA in the
same namespace. It is Developer Preview. [RN §4.2 "3.5 EA2 Developer Preview
features"][rn]

**Connecting a workbench to a pipeline server.** A workbench created in a
project gets an Elyra runtime configuration automatically, **only if the
pipeline server exists first**: "you must create the pipeline server before
you create the workbench". Basic workbenches, started from the "Start basic
workbench" tile, need the runtime configuration made by hand.
[PIPE §7.2, §7.4][pipe] From code, use the `kfp` SDK with the route
`ds-pipeline-<dspa>` and an OpenShift token. [PIPE §1.2.3][pipe]

**Storage.** Each workbench gets a PVC (default 20 GiB, configurable in
Settings → Cluster settings) from the cluster default StorageClass (`gp3-csi`
here, RWO). [MGR §5.1, §7][mgr] S3 data is attached as a "Connection".
[S3 guide][s3]

**Users and groups.** All authenticated users can use RHOAI by default, and
cluster admins are RHOAI admins. Restrict access with user and admin groups,
set in Settings → User management. [MGR ch. 1][mgr], [MGMT §1.1–1.4][mgmt]
Observed: `auth.services.platform.opendatahub.io/auth` has
`allowedGroups: [system:authenticated]`, `adminGroups: [rhods-admins]`, and
`rhods-admins` is empty. Project access comes from standard RoleBindings
(project sharing). The dashboard creates custom roles labelled
`opendatahub.io/dashboard: 'true'`; `roleManagement` is on by default in 3.5.
[RN §2.1][rn] A user's permission change needs a logout of every session,
Jupyter included. [MGMT §1.1.2][mgmt]

### 3. The "build your own agent" path in RHOAI 3.5

| Capability | Status in 3.5 | Source |
|---|---|---|
| AI Pipelines, workbenches, Dashboard, AI Hub, KServe, MaaS (0.2.0), MLflow, TrustyAI, NeMo Guardrails | **GA** | [SC][sc] |
| OGX Operator 0.11.0 / OGX 1.1.2 | **GA** in Supported Configurations, but **excluded from 3.5 EUS**: support ends 2027-03-27 | [SC][sc] note 4 |
| OGX "integration" | **Technology Preview** in the OGX guide itself. Responses, Messages, Tool Runtime, MCP tool runtime and RAG runtime APIs are **Developer Preview**; Chat Completions, Embeddings, Vector Stores and Files are TP | [OGX ch. 2, §4.2, §4.3][ogx] |
| Gen AI studio playground, RAG knowledge sources, prompt management, chat metrics and tracing | Technology Preview | [PLAY ch. 1, §8.2, ch. 13][play], [RN §3.1][rn] |
| Saved playground configurations as named "agents" (`agentConfigManagement`), Agent Ops (`agentOps`) | Developer Preview, flags default false | [RN §4.1][rn], [MGR §2.3][mgr] |
| Agent Catalog (starter kits on LangGraph, CrewAI, LlamaIndex), flag `agentsCatalog` | Developer Preview | [RN §4.1][rn] |
| Claude Code Agentic Starter Kit | Developer Preview | [RN §4.2][rn] |
| MCP Lifecycle Operator and MCP catalog; MCP gateway as an external dependency | Technology Preview | [RN §3.1][rn] |
| AutoRAG, AutoML (pipelines-based) | Technology Preview (1.11.0) | [SC][sc], [AutoRAG §1.5][autorag] |
| RAG stack with OGX | Technology Preview | [RAG ch. 1][rag] |
| Kale (notebook to pipeline) | Developer Preview | [RN §4.2][rn] |
| OpenShell | Developer Preview (Kagenti dropped in its favour) | [RN §4.3][rn] |

> Doc discrepancy: Supported Configurations lists OGX as GA, while the OGX
> guide, published for 3.5, still says "OGX integration is currently available
> in Red Hat OpenShift AI 3.5 as a Technology Preview feature". The per-API
> table is the most specific, and puts the agent-facing APIs at Developer
> Preview. Tell customers that agent APIs through OGX are **not** production
> supported in 3.5.

**Where pipelines and workbenches fit.** Red Hat documents three concrete
links.

- **RAG ingestion runs as a pipeline.** "Ingest domain data into the
  configured vector store by running Docling in an AI pipeline or Jupyter
  notebook." [RAG ch. 1, §1.5][rag]
- **AutoRAG is a pipeline.** It needs a DSPA with `managedPipelines: {}`, an
  OGX connection, a remote Milvus or pgvector, a tool-calling-enabled vLLM
  model, and the `genAiStudio` and `autorag` flags. It generates notebooks
  that you run in a workbench to use the winning RAG pattern.
  [AutoRAG ch. 3, ch. 5][autorag]
- **MLflow is wired into both.** Pipeline runs and workbench SDK calls are
  tracked automatically by the project's MLflow. [RN §2.1][rn],
  [PIPE ch. 4][pipe]

The workbench is where agent code is written and tried, usually against the
OpenAI-compatible APIs of OGX or of MaaS directly. Pipelines are for the
repeatable parts: ingestion, evaluation (RAGAS remote provider runs as
pipelines, [RN §3.6][rn]) and RAG optimisation.

**Consuming our MaaS models from a workbench.**

- Users mint keys in Gen AI studio → AI asset endpoints → Create API key, and
  see their subscriptions and limits there. [MAAS §2.1, §2.2][maas]
- The documented notebook pattern is §2.2.6 "Test models in a Jupyter
  notebook": the gateway base URL plus a key, through the OpenAI-compatible
  `/v1/chat/completions`. [MAAS §2.2.5, §2.2.6][maas]
- **Our constraint** (from
  [running-under-autoshift.md](running-under-autoshift.md#who-can-mint-a-maas-key)):
  `granite-4-tiny-gpu` `accessGroups` is narrowed to `maas-users` and three
  ServiceAccount groups. A workbench user must be in `maas-users`, or in a new
  group added to `accessGroups`, or the key mint fails with
  `invalid_subscription`. kubeadmin can never mint.
- A **deployed** agent (not a notebook) should mint its own key from its
  ServiceAccount, as Hermes does. That means adding
  `system:serviceaccounts:<ns>` to `accessGroups` for a namespace that holds
  only that agent, never a shared data science project. Otherwise every
  workbench pod in the project could mint.
- Gen AI studio's playground and AutoRAG reach models through OGX, which needs
  an `OGXServer` per project with the model as a `remote::vllm` provider and
  `apiToken` from a Secret labelled `ogx.io/watch: "true"`.
  [OGX §3.5 "Secrets management"][ogx] Pointing that provider at the MaaS
  gateway with a MaaS key, instead of at the predictor Service, is plausible
  but **(unverified)**.

### 4. What is on the cluster and in the fork today

Observed on `rhoai` (read-only queries):

| Item | State |
|---|---|
| DSC components Managed | aigateway, **aipipelines**, dashboard, feastoperator, kserve, mcplifecycleoperator, mlflowoperator, modelregistry, ogx, ray, trainingoperator, trustyai, **workbenches** |
| DSC components Removed | kueue, llamastackoperator, trainer |
| DSC conditions | Ready, AIPipelinesReady, WorkbenchesReady, DashboardReady, OGXReady, ModelsAsAServiceReady all True |
| `DataSciencePipelines` component CR | Ready, ArgoWorkflowAvailable, DeploymentsAvailable all True |
| Controllers in `redhat-ods-applications` | `data-science-pipelines-operator-controller-manager`, `notebook-controller-deployment`, `odh-notebook-controller-manager`, `workbenches-operator` |
| DSPAs / Notebooks / OGXServers | **none** in any namespace |
| Dashboard projects (`opendatahub.io/dashboard=true`) | only `llm` (the model namespace) |
| `OdhDashboardConfig` spec | only `mcpCatalog: true`; everything else at defaults |
| `Auth` | allowedGroups `system:authenticated`, adminGroups `rhods-admins` (empty group) |
| Groups | `cluster-admins` (danclark), `maas-users` (maas-user, danclark), `rhods-admins` (empty) |
| Hardware profiles | `default-profile` only |
| Connection types | `oci-v1`, `s3`, `uri-v1` |
| DSCI | `trustedCABundle.managementState: Managed`, `customCABundle: ""` |
| StorageClass | `gp3-csi` default, `gp2-csi` |
| CCO mode | `Mint` (no STS, no service-account issuer), so IRSA is not available |
| Ingress certificate | default (self-signed; no `defaultCertificate`) |
| Workers | 3 × m6i.4xlarge at 41–54 % CPU requests; g6.xlarge GPU node at 69 % |
| GitOps | `openshift-gitops-operator.v1.22.3`; no separate Argo Workflows |

In the fork (`policies/stable/openshift-ai`):

- `manifests/dsc/datasciencecluster.yaml` already has `aipipelines` and
  `workbenches` (`workbenchNamespace: rhods-notebooks`) Managed. Nothing sets
  `argoWorkflowsControllers`, so it takes the default, Managed.
- `manifests/dsc/dscinitialization.yaml` enforces `customCABundle: ""` with
  musthave. **A hand `oc patch` of the RDS CA into the DSCI, as PIPE §1.1.1
  instructs, will be reverted by `policy-openshift-ai-dsc`.**
- `policy-openshift-ai-agents-cat` exists, but `openshift-ai-agents-catalog`
  is not set in `hub.yaml`, so it is off. `openshift-ai-mcp-catalog: 'true'`
  is on.
- `openshift-data-foundation` already supports `odf-multi-cloud-gateway:
  standalone` (NooBaa only); `odf: 'false'` in hub.yaml.
- `htpasswd-users` (`config.htpasswdUsers.groups[]`) already manages groups,
  members and per-namespace roles from git.

## Design

### What goes where

Applying the tests in [what-belongs-in-autoshift.md](what-belongs-in-autoshift.md):

| Piece | Where | Why |
|---|---|---|
| `aipipelines`, `workbenches` in the DSC | **Already in** `openshift-ai` | Platform; done |
| Readiness of pipelines and workbenches | `openshift-ai`, inform | Catches the "Compliant but nothing works" shape |
| `Auth` user/admin groups | `openshift-ai`, config-driven | Cluster singleton, every tenant cares |
| Dashboard flags for AutoRAG / AutoML / saved agents | `openshift-ai`, opt-in labels | Same pattern as the existing catalog flags |
| A curated project with group access and a pipeline server | **New** `openshift-ai-projects`, config-driven | A shaped CR, a few fields per entry |
| S3 bucket and IAM credentials | **Script** (`scripts/pipelines-s3.sh`) plus an inform policy | Billable AWS resource; secret material cannot be in git |
| Workbenches | **Self-service** in the dashboard | A person's workspace; no second tenant wants yours |
| User-created projects and their pipeline servers | **Self-service** | The dashboard already does this |
| `OGXServer` per project | Self-service now; candidate for `openshift-ai-projects` later | TP/DP, and the MaaS-backed provider is unverified |
| MaaS keys for people | Self-service (dashboard) | Runtime-minted, per person |

### Changes to `openshift-ai`

Two new policies in the existing directory. Both depend on
`policy-openshift-ai-dsc`.

**`policy-openshift-ai-pipelines-ready`** (35 characters, inform). Asserts
`default-dsc` conditions `AIPipelinesReady` and `WorkbenchesReady` (both observed True on the
cluster) are True, and
that the `data-science-pipelines-operator-controller-manager` Deployment is
Available. It needs no new label and uses the existing placement.

**`policy-openshift-ai-access`** (26 characters, enforce). Reads
`config.openshiftAi.access` and sets `auth.services.platform.opendatahub.io/auth`.
musthave, so only the listed fields are merged:

```yaml
config:
  openshiftAi:
    access:
      adminGroups: ['rhods-admins']      # default if absent
      allowedGroups: ['system:authenticated']
```

Render it with `toJson`, not `toYaml | nindent` (hub template trap). If
`config.openshiftAi.access` is absent, the block must still render a
non-empty object, or `make test`'s empty-policy check fails, which is
correct. Gate it on a label `openshift-ai-access` so a cluster that manages
groups in the dashboard is not overwritten.

**Optional: `policy-openshift-ai-autorag`** (27 characters). The
`genAiStudio`, `autorag` and `automl` flags, and `managedPipelines` are then
set per DSPA in `openshift-ai-projects`. Opt-in label
`openshift-ai-autorag`, Technology Preview. It is not useful without OGX plus
Milvus or pgvector, so it belongs to phase 3. The `agentConfigManagement`
flag (Developer Preview) can ride on the existing
`openshift-ai-agents-catalog` label, because both are Developer Preview
dashboard-only agent features.

### New directory `openshift-ai-projects`

Enablement label `autoshift.io/openshift-ai-projects`. Data in
`config.openshiftAiProjects`. Placement requires `openshift-ai: 'true'` and
`openshift-ai-projects: 'true'`. **No `cluster-type: spoke` predicate**: it
must match the self-managed hub.

```yaml
config:
  openshiftAiProjects:
    projects:
      - name: agent-lab                 # namespace
        displayName: 'Agent lab'
        description: 'Build agents on MaaS models'
        groups:                         # RoleBindings in the namespace
          admin: ['ai-leads']
          edit: ['ai-developers']
          view: []
        pipelineServer:
          enabled: true
          name: dspa                    # route becomes ds-pipeline-dspa
          pipelineStore: kubernetes     # match the dashboard default, not the CRD's
          managedPipelines: false       # true = AutoML/AutoRAG (TP)
          objectStorage:
            # Secret created out of band by scripts/pipelines-s3.sh, never in git
            secretName: pipelines-s3
            bucket: ''                  # default: from the Secret's BUCKET key? see Open questions
            host: s3.us-east-2.amazonaws.com
            region: us-east-2
            basePath: agent-lab
          database:
            type: builtin               # builtin | external
            # external:
            #   host: ...rds.amazonaws.com
            #   port: '3306'
            #   username: dspa
            #   pipelineDBName: agent_lab
            #   passwordSecret: pipelines-db   # out of band
            #   caConfigMap: rds-ca            # out of band, feeds apiServer.cABundle
```

Policies, all `policy-ai-projects-*` (abbreviate the component, not the
directory), with `placementBindingDefaults.name: binding-policy-ai-projects`:

| Policy | Mode | Depends on | Creates or asserts |
|---|---|---|---|
| `policy-ai-projects-ns` (21) | enforce | `policy-openshift-ai-dsc` | `Namespace` labelled `opendatahub.io/dashboard: 'true'` with display-name and description annotations; RoleBindings to `admin` / `edit` / `view` ClusterRoles per group |
| `policy-ai-projects-s3-secret` (28) | **inform** | `policy-ai-projects-ns` | The named Secret exists in each project with an access key and secret key, never reading values (the `openshift-ai-maas-db` pattern) |
| `policy-ai-projects-dspa` (23) | enforce | `policy-ai-projects-s3-secret`, `policy-openshift-ai-dsc` | `DataSciencePipelinesApplication` per entry with `pipelineServer.enabled` |
| `policy-ai-projects-ready` (24) | inform | `policy-ai-projects-dspa` | Each DSPA reports `Ready=True` (DSPA conditions are listed in [PIPE ch. 8][pipe]) |

The DSPA is fully determined by config, with no cluster lookup: host, region,
bucket and basePath come from values; the credentials are referenced by Secret
name and key names (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`). That avoids
the `%!s(<nil>)` lookup trap entirely. The dependency on the inform Secret
policy matters: a DSPA created before its Secret exists goes
`ObjectStorageAvailable=False`, and connection settings cannot be edited
afterwards ([PIPE §1.1][pipe]); for a CR the policy owns, edits are
reconciled, which is probably fine, but this is **(unverified)**.

Hub template traps that apply:

- Range with `toJson` for the RoleBinding subjects lists.
- Compare `managedPipelines` as a string (`eq (toString .x) "true"`), never
  `toInt` / `toBool` on a hub-resolved value.
- An empty `projects` list renders nothing and reports Compliant. Declare a
  non-empty sample in **both** `autoshift/values/clustersets/_example.yaml`
  and `clusters/_example.yaml`, or CI never exercises it.
- `musthave` on the DSPA. Turning the label off stops management and deletes
  nothing (AutoShift's rule). Deleting a project from the list leaves it in
  place too, so say so in the README.

Labels to declare in both example files: `openshift-ai-projects`,
`openshift-ai-access`, and later `openshift-ai-autorag`.

Groups: extend `config.htpasswdUsers.groups` with `ai-developers` (and
`ai-leads`). Add `ai-developers` to `granite-4-tiny-gpu.accessGroups` so its
members can mint MaaS keys. For real identity providers, the groups come from
LDAP or OIDC sync instead; the policy only references names.

### S3 on AWS, without credentials in git

**Recommended: `scripts/pipelines-s3.sh create | status | secret | destroy`**,
built like `maas-database.sh`:

1. One bucket per cluster, `<cluster>-<account-id>-ai-pipelines` in
   `AWS_REGION`, with Block Public Access, SSE-S3 (or SSE-KMS), and
   `kubernetes.io/cluster/...` tags omitted so cluster destroy leaves it,
   like the VPC. `--dry-run` supported; reuse the bucket if it exists.
2. Per project in `config.openshiftAiProjects` (read with Go `yq`): an IAM
   user `<cluster>-dspa-<project>` with an inline policy limited to
   `s3:ListBucket` on the bucket with the `<project>/*` prefix condition, and
   `s3:GetObject` / `PutObject` / `DeleteObject` on `arn:...:<bucket>/<project>/*`.
3. Keys written to `secrets/pipelines-s3-<project>.env` (`umask 077`) and to
   Secret `pipelines-s3` in the project namespace (keys `AWS_ACCESS_KEY_ID`,
   `AWS_SECRET_ACCESS_KEY`), only once the namespace exists, the same split as
   `maas-database.sh create --no-secret` / `secret`.
4. `destroy` empties and deletes the bucket and users. `90-destroy-cluster.sh
   --with-vpc` should call it, or at least warn, because it is outside every
   stack.

Why this over the alternatives:

| Option | For | Against |
|---|---|---|
| **Script + AWS S3** (recommended) | AWS public CA, so no TLS work; no in-cluster footprint; matches precedent; S3 has FIPS endpoints in US regions (`s3-fips.us-east-2.amazonaws.com`, AWS documentation, not verified against RHOAI) | Imperative; long-lived IAM keys; AWS-only |
| ODF MCG standalone + `ObjectBucketClaim` | Fully declarative: the OBC yields a Secret and ConfigMap in the project, nothing out of band; portable to bare metal and disconnected; the fork already has `odf-multi-cloud-gateway: standalone` | Installs ODF (NooBaa core, db, endpoint) on a busy cluster; the in-cluster S3 endpoint is service-CA signed, which brings back the x509 trust problem; DSPA would need a `lookup` of the OBC ConfigMap (nil trap); ODF under FIPS **(unverified)** |
| CCO `CredentialsRequest` (Mint mode mints an IAM user) | Declarative credentials from a policy | CCO is meant for platform components; using it for tenant workloads is not documented as supported **(unverified)**; it still does not create the bucket |
| IRSA via `serviceAccountAnnotations` / `credentialsMode.fromEnv` | No static keys | Cluster is Mint, not STS; not in the 3.5 docs; UI support is only a draft feature (RHAISTRAT-2851) |

### Phased plan

**Phase 0: manual proof on a cluster (no code).** On the current cluster or
the FIPS rebuild, as a cluster admin:

1. Create bucket, IAM user and Secret by hand (the commands become
   `pipelines-s3.sh`).
2. Create project `agent-lab` in the dashboard and configure the pipeline
   server with S3 and the default database, ticking "Enable AutoML and AutoRAG
   pipelines" to see what it adds.
3. **Then** create a Jupyter Data Science CPU workbench and check that the
   Elyra runtime configuration exists.
4. Run the Elyra hello-world pipeline, with a DNS-compliant name.
5. Enable Kale in the workbench; check it shows "connected".
6. As `maas-user`, mint a key and run [MAAS §2.2.6][maas] against
   `granite-4-tiny-gpu` from the notebook. Note any x509 error from the
   self-signed ingress.
7. Export the DSPA YAML the dashboard produced. **That is the template for
   phase 1**, since the docs give no full DSPA example.
8. Record etcd size and worker CPU requests before and after (the hub rule).

**Phase 1: codify the project.** `scripts/pipelines-s3.sh`;
`openshift-ai-projects` with `-ns`, `-s3-secret`, `-dspa`, `-ready`;
`ai-developers` in `htpasswdUsers` and in `accessGroups`;
`policy-openshift-ai-pipelines-ready`. Add a step to `scripts/checkup.sh`
(DSPA Ready per configured project) and a pipeline run to the smoke test.
Gate: `GOTOOLCHAIN=auto make test` (check the skipped count), plus Vale on the
new README.

**Phase 2: production database and access.** RDS MariaDB 10.11 per cluster
(`scripts/pipelines-database.sh`, one schema per project, TLS on), the RDS CA
delivered as a ConfigMap referenced by `apiServer.cABundle` and
`customExtraParams: '{"tls":"true"}'`, not via the DSCI.
`policy-openshift-ai-access` to move from `system:authenticated` to
`ai-developers` + `maas-users`.

**Phase 3: agent tooling (Preview, opt-in).** `policy-openshift-ai-autorag`
flags, `managedPipelines` per project, an `OGXServer` per project backed by a
remote pgvector, a MaaS connection type so a workbench gets
`OPENAI_BASE_URL` and `OPENAI_API_KEY` from a Connection rather than a pasted
key, and the Docling ingestion pipeline. Each item behind its own label
because each is TP or DP.

**Phase 4 (later):** ODF MCG `ObjectBucketClaim` as the storage backend for
non-AWS and disconnected clusters, selected by
`pipelineServer.objectStorage.type: obc`.

## Open questions and risks

**Preview status.** Pipelines and workbenches are GA. Almost everything that
makes them an *agent* platform is not: playground, RAG sources, AutoRAG and
AutoML are TP; OGX's agent APIs, Agent Catalog, saved agents, Kale and
OpenShell are DP. OGX is GA in one Red Hat source and TP in another, and is
excluded from 3.5 EUS (support ends 2027-03-27). Position phase 3 as a
preview track.

**FIPS (next cluster is FIPS).**

- The only RHOAI statement found is the UBI 9 / RHEL 9 rule for custom
  pipeline images [INST §3.1.2][inst]. A general "RHOAI is designed for FIPS"
  statement for 3.5 was not found **(unverified)**; check the Supported
  Configurations article in full and ask the product team before telling a
  customer.
- Python under FIPS: Hermes already fails on `md5` without
  `usedforsecurity=False` ([rebuild-fips-plan.md](rebuild-fips-plan.md)).
  Pipeline caching, Elyra, Kale and agent frameworks may hash with md5
  **(unverified)**. Add to the FIPS checklist: an Elyra run with caching on,
  a `kfp` SDK submit, a LangGraph sample from the Agent Catalog.
- Wheels that bundle their own OpenSSL (for example `cryptography` from PyPI)
  run but are not FIPS validated, the same gap as Open WebUI.
- Use the S3 FIPS endpoint in the DSPA `host` on a FIPS cluster.

**TLS.** The ingress certificate is self-signed. A notebook calling the MaaS
gateway by its route host must trust the ingress CA. Whether RHOAI's managed
trusted CA bundle (`odh-trusted-ca-bundle`, keys `ca-bundle.crt` and
`odh-ca-bundle.crt`) includes it is **(unverified)**. The Let's Encrypt plan
removes the issue.

**DSCI ownership.** Documented procedures that patch
`DSCInitialization.spec.trustedCABundle.customCABundle` conflict with
`policy-openshift-ai-dsc`. Either make that field config-driven in the policy
or use per-DSPA `cABundle` (recommended).

**Capacity.** Each DSPA adds an API server, persistence agent, scheduled
workflow controller, MLMD gRPC and Envoy, a per-project Argo workflow
controller and, with the built-in DB, MariaDB **(pod list from the CRD and
docs; resource cost unmeasured)**. Workbenches add a pod and a 20 GiB gp3 PVC
each. Worker CPU requests are 41–54 % today. Measure per project in phase 0.

**Self-service versus policy.** A policy-owned DSPA and a user editing it in
the dashboard will fight, and the policy will win. The README must say that
curated projects are managed from values, and users create their own projects
for anything else.

**`accessGroups` scope.** Adding a whole project's ServiceAccount group lets
every workbench pod there mint MaaS keys and spend the quota. Prefer human
groups for notebooks, and dedicated namespaces for deployed agents.

**Bucket lifecycle.** The bucket and IAM users live outside both the cluster
and the VPC stack, like the `maas-database.sh` extras. Without a `destroy`
step they leak, and IAM users with live keys are the worse leak.

**Open questions.**

1. Does the RHDP sandbox account allow creating IAM users and inline policies
   with the credentials in `secrets/aws.env`? The cluster's CCO mints users,
   which suggests yes **(unverified)**.
2. One bucket with per-project prefixes (recommended), or a bucket per
   project?
3. Should `openshift-ai-projects` also create an `OGXServer` per project, and
   can its `remote::vllm` provider point at the MaaS gateway with a MaaS key?
4. Should `workbenchNamespace` stay `rhods-notebooks`, given that basic
   workbenches there do not get an Elyra runtime configuration automatically?
   A curated project per team avoids the question.

[pipe]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/working_with_ai_pipelines/index
[inst]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/installing_and_uninstalling_openshift_ai_self-managed/index
[disc]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/index
[rn]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/release_notes/index
[sc]: https://access.redhat.com/articles/rhoai-supported-configs
[gs]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/getting_started_with_red_hat_openshift_ai_self-managed/index
[mgr]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/managing_resources/index
[mgmt]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/managing_openshift_ai/index
[maas]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/govern_llm_access_with_models-as-a-service/index
[ogx]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/working_with_ogx/index
[rag]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/building_rag_applications_with_ogx/index
[autorag]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/working_with_autorag/index
[play]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/experimenting_with_models_in_the_gen_ai_playground/index
[s3]: https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/working_with_data_in_an_s3-compatible_object_store/index
