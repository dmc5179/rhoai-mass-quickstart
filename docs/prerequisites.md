# Prerequisites

Work through this once. Most of it applies to every platform; the last section
splits by target.

## On your workstation

| Tool | Why | Check |
|---|---|---|
| `bash` 4+ | all scripts | `bash --version` |
| `git` | the guide is a submodule | `git --version` |
| `curl`, `tar` | fetching the installer | — |
| `jq` | JSON wrangling throughout | `jq --version` |
| **python-yq** | rendering install-config | `yq --help \| grep -q -- -y` |
| `aws` CLI v2 | AWS only | `aws --version` |
| `ibmcloud` CLI | IBM Cloud only | `ibmcloud version` |

**`yq` has two incompatible implementations.** These scripts need
[python-yq](https://github.com/kislyuk/yq) (`pip install yq`), which wraps
`jq` and needs `-y` to emit YAML. Go yq (mikefarah) uses different syntax and
will not work. The scripts check this and refuse rather than producing
nonsense.

`oc`, `kubectl`, and `openshift-install-fips` are **not** prerequisites —
`scripts/00-init.sh` fetches them into `bin/`.

## Raise the inotify limit

This will cost you a failed install if you skip it.

```bash
sudo sysctl -w fs.inotify.max_user_instances=8192
echo 'fs.inotify.max_user_instances=8192' | sudo tee /etc/sysctl.d/99-openshift-installer.conf
```

Since OpenShift replaced Terraform with Cluster API, `openshift-install` runs
a temporary local Kubernetes control plane — a `kube-apiserver`, `etcd`, and
several controllers — on your workstation before it creates anything in the
cloud. Those controllers need inotify instances, and the default limit of 128
is shared with your entire desktop session. A browser and an IDE can consume
most of it on their own.

When it runs out, the install dies about 40 seconds in with
`"Problem running manager" err="too many open files"`, which does not look
like a local resource limit. Phase 10 checks for free instances before
starting and refuses with this fix if there are fewer than 256.

Nothing OpenShift stays on your workstation afterwards. Those processes are
torn down when the install finishes; all cluster nodes run in the cloud.

## Red Hat pull secret

Download from
<https://console.redhat.com/openshift/install/pull-secret> and save it:

```bash
$EDITOR secrets/pull-secret.json
jq -e . secrets/pull-secret.json >/dev/null && echo valid
```

It must include a `registry.redhat.io` entry, which the standard one does.
Without it the GPU models cannot pull — they are OCI modelcars hosted there.

```bash
jq -r '.auths | keys[]' secrets/pull-secret.json   # expect registry.redhat.io
```

## SSH key

Used for node access and baked into the install config. Defaults to
`~/.ssh/id_rsa.pub`; override with `SSH_KEY_FILE` in `cluster.env`.

```bash
ls ~/.ssh/id_rsa.pub || ssh-keygen -t ed25519 -f ~/.ssh/id_rsa
```

## Capacity

A default build is 3 control plane nodes and 3 workers. On AWS that is
3 × `m6i.xlarge` plus 3 × `m6i.2xlarge` — **36 vCPUs**, briefly ~40 during
bootstrap. Sandbox accounts often cap below that. Adjust in
`templates/install-config.yaml.<platform>` if needed.

RHOAI with MaaS enables a lot at once — KServe, Kuadrant, model registry,
MLflow, Feast, TrustyAI, Ray, workbenches. 3 × `m6i.2xlarge` is workable but
not generous; if pods sit `Pending` after phase 20, that is the first thing to
look at.

A GPU node is extra and separate. See [gpu-and-models.md](gpu-and-models.md).

---

## Per platform

### AWS

- An account with admin credentials, in `secrets/aws.env`:
  ```bash
  cp secrets/aws.env.example secrets/aws.env && $EDITOR secrets/aws.env
  ```
  The quickest way to get one is an **AWS Blank Open Environment** from
  [Red Hat Demo Platform](https://demo.redhat.com). It arrives with admin
  keys and a Route 53 hosted zone already set up, which covers both this
  requirement and the next one. Order it before you need it: these
  environments have a fixed lifetime, and extending one is easier than
  rebuilding into a fresh account.
- **A public Route 53 hosted zone in that account.** The installer creates
  cluster DNS inside it. With none, phase 10 stops immediately with an
  explicit error rather than part-building anything. An RHDP open environment
  comes with one; otherwise register a domain and create the zone. Leave
  `BASE_DOMAIN` empty to auto-detect it — set it explicitly only if the
  account has more than one.
- For GPU: quota for *Running On-Demand G and VT instances*, which defaults to
  **0** on new accounts. Request an increase early; approval can take days.
  Note this does not carry over — a replacement open environment is a
  different AWS account, so the quota is back to 0 and the request starts
  again. Worth factoring into when you let one expire.

### IBM Cloud

- An API key in `secrets/ibm.env`:
  ```bash
  cp secrets/ibm.env.example secrets/ibm.env && $EDITOR secrets/ibm.env
  ```
  The installer reads `IC_API_KEY`; the `ibmcloud` CLI reads
  `IBMCLOUD_API_KEY`. Set both to the same value.
- **A domain zone in IBM Cloud Internet Services (CIS)** in the same account,
  set as `BASE_DOMAIN`. This is not auto-detected. A private cluster uses IBM
  Cloud DNS Services instead.
- The key needs policies for IAM Identity, Resource Group, Cloud Object
  Storage, Internet Services, DNS Services, and VPC Infrastructure Services.

### Bare metal

- Machines that can boot from a generated ISO. No BMC access needed — this
  uses the agent-based installer.
- Two free IPs on the node subnet for the API and ingress VIPs, outside any
  DHCP pool, with DNS resolving `api.<cluster>.<base domain>` and
  `*.apps.<cluster>.<base domain>` to them.
- One control plane node with a stable address to act as the rendezvous host.

---

Next: [aws.md](aws.md) · [ibm-cloud.md](ibm-cloud.md) · [bare-metal.md](bare-metal.md)
