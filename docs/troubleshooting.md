# Troubleshooting

Failures that have actually happened here, with what they looked like and what
fixed them.

## Install dies ~40 seconds in: "too many open files"

```
"Problem running manager" err="too many open files" logger="setup"
failed to start controller "Cluster API": timeout waiting for process cluster-api to start
```

**Not an AWS problem, and not file descriptors** despite the message.

Since OpenShift replaced Terraform with Cluster API, the installer runs a
local Kubernetes control plane on your workstation before touching the cloud.
Those controllers consume inotify *instances*, and the default limit of 128 is
shared with your whole desktop session.

```bash
cat /proc/sys/fs/inotify/max_user_instances          # the limit
find /proc/[0-9]*/fd -lname 'anon_inode:inotify' 2>/dev/null | wc -l   # in use
```

Fix:

```bash
sudo sysctl -w fs.inotify.max_user_instances=8192
echo 'fs.inotify.max_user_instances=8192' | sudo tee /etc/sysctl.d/99-openshift-installer.conf
```

Phase 10 now refuses to start if fewer than 256 are free.

**Worth checking what is consuming them.** In one case 50 of the 128 were held
by leaked `git fsmonitor--daemon` processes accumulated over days of uptime:

```bash
for p in /proc/[0-9]*; do
  n=$(find "$p/fd" -lname 'anon_inode:inotify' 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] && echo "$n $(cat $p/comm)"
done | sort -rn | head

pkill -f 'git fsmonitor--daemon'    # safe; git restarts them on demand
```

## "no public Route 53 hosted zone found"

The installer creates cluster DNS inside an existing zone. Create one, or set
`BASE_DOMAIN` in `cluster.env` explicitly if the account has several. The
script refuses rather than guessing between zones.

## generate-install-config.sh: "Stack rhoai-vpc does not exist"

Expected if you run it standalone before the VPC exists — it reads subnet IDs
from the stack's outputs. Either run `scripts/10-deploy-cluster.sh`, which
creates the stack first, or create just the stack using the command the error
prints.

## MaaS installed, but responses are stub text

You got the CPU simulator. The guide detects GPUs by reading the
`nvidia.com/gpu.memory` node label and silently falls back when it finds none
— the install still reports success.

```bash
"$OC" get nodes -l nvidia.com/gpu.present=true
```

Empty means no GPU was visible when phase 20 ran. Fix:

```bash
scripts/55-autoshift-values.sh --replicas 1 --force   # ask for a GPU node
scripts/50-autoshift.sh bootstrap                     # apply it
$EDITOR cluster.env          # MAAS_MODEL="granite-tiny-gpu"
scripts/20-deploy-maas.sh --from-phase 5
```

`scripts/35-smoke-test.sh` flags this explicitly.

## GPU machine set scaled up but no node appears

```bash
"$OC" get machines.machine.openshift.io -n openshift-machine-api
"$OC" get machinesets.machine.openshift.io -n openshift-machine-api
```

A Machine stuck in `Provisioning` usually means AWS will not give you the
instance:

- **Quota.** *Running On-Demand G and VT instances* defaults to **0** on new
  accounts. Spot has a separate quota.
- **Spot capacity.** Unfulfillable requests sit silently. Spot is requested
  with `autoshift.io/gpu-nodes-spot: 'true'`, and there is deliberately no
  automatic fallback to on-demand — the machines simply never appear and
  `policy-gpu-nodes-test` goes NonCompliant. A silent switch to on-demand
  would be a surprise on the bill. Set the label back to `'false'` to use
  on-demand.
- **Instance type not in your AZ.** The VPC pins one zone:
  ```bash
  aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters Name=instance-type,Values=g6.xlarge Name=location,Values=us-east-2a
  ```

## Spot GPU request denied by a service control policy

```
Spot request failed: error launching instance: You are not authorized to
perform: ec2:RunInstances ... with an explicit deny in a service control
policy
```

An organisation-level SCP, not a capacity shortage, and not something you can
retry around. Seen on Red Hat Demo Platform sandboxes, which permit on-demand
GPU instances but deny spot.

Nothing detects this for you. Set `autoshift.io/gpu-nodes-spot: 'false'`
(the default) and re-apply. Once you know spot is blocked in an account,
leave it off — the failure mode is machines that never appear, with the
denial visible only on the Machine object.

Confirm on-demand is permitted by checking the machine has no error:

```bash
"$OC" get machines.machine.openshift.io -n openshift-machine-api -o json | jq -r '
  .items[] | select(.metadata.name|test("-gpu-")) |
  "\(.metadata.name) \(.status.phase) \(.status.errorMessage // "no error")"'
```

## "no matches for kind NodeFeatureDiscovery ... ensure CRDs are installed first"

A CSV reporting `Succeeded` does not mean its CRDs are registered yet. The
`nvidia-gpu-operator` policy expresses this as a dependency:
`policy-nvidia-gpu-cluster-policy` depends on
`policy-nvidia-gpu-operator-install`, so the ClusterPolicy is not applied
until the operator install reports Compliant. A ConfigurationPolicy naming a
CRD that does not exist yet reports Compliant while doing nothing, which is
why the dependency rather than a wait is what makes the assertion mean
anything.

If the operator install itself never reaches Compliant, check the CSV rather
than the policy — the policy reports only "the ClusterServiceVersion required
by the policy was not found", which reads like a catalog problem even when
the real cause is an OperatorGroup the API server rejected.

## "could not find any suitable subnets for creating the ELB"

A `LoadBalancer` Service — usually the MaaS gateway — cannot find a subnet.
The AWS cloud controller discovers them by tag:

```bash
aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc> \
  --query 'Subnets[].{id:SubnetId,tags:Tags}'
```

Public subnets need `kubernetes.io/role/elb`, private need
`kubernetes.io/role/internal-elb`. `cloudformation/01_vpc.yaml` sets both. A
hand-built VPC often misses them.

## Nodes NotReady after cluster-power.sh start

Expected. Kubelet serving certificates are not renewed while the cluster is
off, so CSRs pile up pending.

```bash
"$OC" get csr -o name | xargs -r "$OC" adm certificate approve
"$OC" get nodes
```

Run it twice — a second round appears as kubelets reconnect. If nodes stay
`NotReady` after both, see
[KCS 7136634](https://access.redhat.com/solutions/7136634).

## Phase 10 refuses: "clusters/<name> is not empty"

A previous cluster or a failed attempt. Clean up first:

```bash
scripts/90-destroy-cluster.sh
```

It works from `metadata.json`, so it handles partial installs. The VPC is kept
unless you pass `--with-vpc`.

## A script fails with confusing yq errors

You have Go yq instead of python-yq. The scripts check and refuse, but if you
bypass them:

```bash
yq --help | grep -q -- '-y' && echo "python-yq (correct)" || echo "Go yq (wrong)"
pip install yq
```

## Where to look

| Log | Contents |
|---|---|
| `logs/deploy-<platform>-<ts>.log` | whole phase 10 run, debug level |
| `logs/destroy-<platform>-<ts>.log` | teardown |
| `clusters/<name>/.openshift_install.log` | installer's own; survives failure |

Both deploy logs are written live, so they are readable from another shell
while a run is in progress.
