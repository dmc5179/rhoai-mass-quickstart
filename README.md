# RHOAI MaaS Quickstart

Deploy OpenShift 4.22, then Red Hat OpenShift AI with Models-as-a-Service, and
serve a real LLM behind an authenticated, rate-limited API.

Everything is plain shell scripts. There is no operator to install, no
controller to run, and no AI assistant required.

```bash
scripts/00-init.sh             # fetch oc and openshift-install
scripts/10-deploy-cluster.sh   # network + OpenShift        ~40 min
scripts/20-deploy-maas.sh      # RHOAI + MaaS + a model     ~30 min
scripts/35-smoke-test.sh       # ask the model a question   ~1 min
scripts/40-lightspeed.sh install  # optional: console assistant  ~10 min
```

GPU nodes are no longer a script. They come from the `gpu-nodes` AutoShift
policy in phase 50, driven by the labels `scripts/45-autoshift-values.sh`
renders:

```bash
scripts/45-autoshift-values.sh --replicas 1 --force   # ask for one GPU node
scripts/50-autoshift.sh bootstrap                     # ACM + GitOps + AutoShift
scripts/50-autoshift.sh adopt                         # hub manages itself
```

Order matters. Helm reads values at install time, so phase 45 has to run
before the bootstrap that applies it — running it afterwards means another
bootstrap. Phase 45 needs only a reachable cluster, not ACM.

`adopt` is the step that cannot be undone by editing values: it activates
every enabled policy at once, and turning a label back off stops reconciling
without uninstalling anything. See
[docs/running-under-autoshift.md](docs/running-under-autoshift.md).

---

## Start here

**1. Pick your platform.** Set `PLATFORM` in `cluster.env`.

| Platform | Status | Read this |
|---|---|---|
| `aws` | Working end to end | [docs/aws.md](docs/aws.md) |
| `ibmcloud` | Config generation ready, not yet run | [docs/ibm-cloud.md](docs/ibm-cloud.md) |
| `baremetal` | Config generation ready, not yet run | [docs/bare-metal.md](docs/bare-metal.md) |

**2. Check you have what you need.** [docs/prerequisites.md](docs/prerequisites.md)
— accounts, a pull secret, DNS, local tooling, and one workstation kernel
setting that will otherwise fail the install 40 seconds in.

**3. Follow your platform's walkthrough.** Each one is a linear
start-to-finish page.

**4. Then:**

- [docs/gpu-and-models.md](docs/gpu-and-models.md) — choosing a model, GPU
  nodes, and OCI modelcars
- [docs/verifying.md](docs/verifying.md) — proving it works
- [docs/operations.md](docs/operations.md) — parking, costs, teardown
- [docs/running-under-autoshift.md](docs/running-under-autoshift.md) — sizing
  for an ACM hub, why `adopt` is the irreversible step, and the failures that
  do not say what they are
- [docs/ibm-cloud-autoshift-plan.md](docs/ibm-cloud-autoshift-plan.md) —
  researched, not built: what adding IBM Cloud to AutoShift would take
- [docs/troubleshooting.md](docs/troubleshooting.md) — things that have
  actually gone wrong here
- [docs/reference.md](docs/reference.md) — every script and every setting

---

## What you end up with

An OpenShift cluster running RHOAI, with a model served through a Kuadrant
gateway that enforces API keys, per-subscription rate limits, and usage
tracking. Clients talk to it with the OpenAI API:

```bash
curl https://maas.apps.<your-cluster>/v1/chat/completions \
  -H "Authorization: Bearer <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"<model-id>","messages":[{"role":"user","content":"Hello"}]}'
```

## How it is put together

```
cluster.env            Every setting you are likely to change. Start here.
secrets/               Credentials. Gitignored.
cloudformation/        Standalone AWS VPC
templates/             One install-config template per platform
scripts/               Numbered phases, run in order
bin/                   oc, kubectl, openshift-install-fips (fetched)
clusters/<name>/       Installer state: kubeconfig, metadata. Keep it.
logs/                  Timestamped run logs
rhoai-maas-guide/      Upstream guide, pinned as a submodule
docs/                  You are here
```

Two design choices worth knowing up front, because they shape everything else:

**The network outlives the cluster.** On AWS the VPC is a separate
CloudFormation stack carrying no `kubernetes.io/cluster/*: owned` tags, so
`destroy cluster` leaves it standing and the next build reuses it. Rebuilding
costs ~40 minutes instead of ~45, and the VPC's identity stays stable.

**The model installation is not ours.** `rhoai-maas-guide` is a pinned
submodule of [the upstream
guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide), which Red Hat's
own [MaaS
documentation](https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.5/html-single/govern_llm_access_with_models-as-a-service/index)
references as its companion. Phases 20 and 30 are thin wrappers around it. We
pin a commit so a given cluster build is reproducible.

## Getting the repo

```bash
git clone --recurse-submodules git@github.com:dmc5179/rhoai-mass-quickstart.git
# or, if you already cloned it flat:
git submodule update --init
```

## This is not a supported product

It is an opinionated wrapper around Red Hat's documented install paths,
assembled for demo and lab use. For anything that matters, follow the official
documentation linked throughout these pages.
