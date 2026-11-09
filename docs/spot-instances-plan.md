# Plan: spot instances to keep the us-east-2 build cheap

Status: **plan only, not started** (2026-11-08). Nothing here is implemented
except what the "Already done" section says.

## Where the money goes today

`cluster.env` defaults, all on-demand, in one availability zone:

| Piece | Default | Spot possible? |
|---|---|---|
| Control plane | 3 × `m6i.2xlarge` | **No.** Control plane machines are not supported on spot, and losing etcd members on an RHACM hub is not survivable |
| Workers | 3 × `m6i.4xlarge` | **Yes**, through the Machine API |
| GPU | 1 × `g6.xlarge` (from the `gpu-nodes` policy) | **Yes. Already supported**, see below |
| NAT gateway, EBS, RDS (`maas-database.sh`), load balancers | per hour | No (not EC2 compute) |

Workers and GPU are the only spot candidates. That is roughly half the
compute bill; the control plane stays on-demand regardless.

Get real numbers before deciding (step 0). Spot prices and interruption rates
vary by instance type and zone, and us-east-2 GPU spot capacity in particular
is not guaranteed.

## How OpenShift does spot on AWS

From *Machine management*, OpenShift 4.22, §2.1.9 ("Machine sets that deploy
machines as Spot Instances"):

- Add `spotMarketOptions: {}` under a compute MachineSet's
  `providerSpec.value`. An empty value bids up to the on-demand price;
  `maxPrice` caps it.
- AWS gives a two-minute warning. A termination handler on the node deletes
  the Machine, and the MachineSet requests a new spot instance to keep its
  replica count. Workloads are drained during the warning.
- Spot is set **per MachineSet**, so a MachineSet is all spot or all
  on-demand, and one instance type each. Mixing means several MachineSets.
- Changing a MachineSet only affects machines created afterwards. Existing
  machines keep running on-demand until they are replaced.
- **No fallback.** If spot capacity is unavailable, the Machine fails and
  stays failed. It is not retried as on-demand (Red Hat solution 6979673
  describes the churn when interruptions are frequent).
- The installer's `install-config.yaml` has no spot setting for compute, so
  installer-created workers always start on-demand. Spot workers are added
  after install.

## Already done

- **GPU spot, end to end.** `scripts/45-autoshift-values.sh --spot` sets the
  `autoshift.io/gpu-nodes-spot` label, and the fork's `gpu-nodes` policy adds
  `spotMarketOptions: {}` to the GPU MachineSet it clones from the cluster's
  worker MachineSet. No fallback, as above.

## The plan

### Step 0: measure first (this repo, no cluster needed)

`scripts/spot-check.sh`: read-only and `--dry-run`-safe. For the configured
region:

- current spot price vs on-demand for the worker and GPU types, with
  alternatives (`m6i.4xlarge`, `m6a.4xlarge`, `m7i.4xlarge`; `g6.xlarge`,
  `g5.xlarge`), using `aws ec2 describe-spot-price-history`;
- spot placement scores per zone (`aws ec2 get-spot-placement-scores`), which
  rate how likely a request is to be filled;
- a rough hourly cost comparison for the default layout: all on-demand, versus
  spot workers, versus spot workers and GPU.

It decides which zone (`VPC_AZ`) and which instance types to use before
phase 10. The VPC is single-AZ by design, so the zone choice matters.

**Done (2026-11-09).** The script also reports the account's spot vCPU
quotas, because AWS scores placement against quota as well as capacity, and
reads the zone from the VPC stack when `VPC_AZ` is empty. First reading, on
the RHDP account in us-east-2 (zone us-east-2a from stack `rhoai-vpc`):

| | On-demand | Spot, us-east-2a | Placement score (a / b / c) |
|---|---|---|---|
| m6i.4xlarge | $0.768/h | $0.262 (-66%) | 1 / 1 / 1 |
| m6a.4xlarge | $0.691/h | $0.220 (-68%) | 1 / 1 / 1 |
| m7i.4xlarge | $0.806/h | $0.238 (-70%) | 2 / 3 / 2 |
| g6.xlarge | $0.805/h | $0.424 (-47%) | 1 / 1 / 1 |
| g5.xlarge | $1.006/h | $0.549 (-45%) | 1 / 1 / 1 |

Quotas: 1152 standard spot vCPUs and 64 G/VT, both far above what the plan
requests, so the low scores are spot capacity, not account limits. With
three workers the plan's rule (two stay on-demand) leaves one spot worker:
$369/month saved on EC2, or $647/month with the GPU node on spot too, out of
$3110/month all on-demand. Parking saves more than either for idle hours.

What it means for step 1: the discount is real, but a score of 1 means a
spot request in us-east-2 is unlikely to be filled right now, and a spot
MachineSet has no fallback. m7i.4xlarge in us-east-2b scores best (3). Re-run
before deciding; scores move.

### Step 1: spot workers in AutoShift (the RHACM way)

Add spot workers through a policy rather than a script, so RHACM owns them:

- Extend the fork's cloning approach (the one `gpu-nodes` uses) to general
  workers: a policy that clones the cluster's own worker MachineSet, adds
  `spotMarketOptions: {}`, and creates N spot workers per zone. Cloning keeps
  the subnet, security groups and AMI correct on a bring-your-own-VPC cluster,
  which is exactly where upstream's `worker-nodes` policy fails (our upstream
  issue #282).
- Labels: `spot-workers: '<replicas>'`, `spot-workers-instance-type`,
  optional `spot-workers-max-price`. Labels only stop management: turning
  them off leaves the MachineSet, as with every AutoShift policy.
- A readiness (inform) policy: the spot MachineSet's replicas are Ready, and
  no Machine has been Failed for more than a few minutes. That is the visible
  signal that spot capacity isn't available.
- Then reduce the installer's on-demand workers to a floor (see decisions).
  RHACM, GitOps and the RHOAI operators must survive a spot interruption, so
  some on-demand capacity stays.

Where it lives, and the upstream path: probably best as a `-spot` option on a
fixed `worker-nodes` policy upstream, since #282 already proposes moving
`worker-nodes` to the cloning approach. In the fork, start as a small new
policy and fold it into #282's fix if upstream takes that direction.

### Step 2: make this repo spot-aware

- **`cluster-power.sh`**: spot instances can't be stopped. The Machine API
  creates one-time spot requests, which AWS does not allow to stop. `stop`
  must scale spot MachineSets (workers and GPU) to 0 and remember their
  counts; `start` scales them back up and lets the Machine API request fresh
  instances. On-demand instances keep today's stop/start behaviour.
- **`checkup.sh`**: report which nodes are spot. Warn on spot Machines in
  `Failed` (no capacity) and on frequent Machine churn (interruptions).
- **`45-autoshift-values.sh`**: add `--spot-workers N` alongside the existing
  `--spot` for GPU, rendering the new labels.
- **`cluster.env`**: `AWS_SPOT_WORKERS`, `AWS_SPOT_WORKER_TYPE`, and the
  on-demand floor, with the reasoning in comments the way the current sizing
  is explained.

### Step 3: docs

- `docs/deploy-rhoai-3.5.2.md`: an optional "spot" path, with step 0 before
  phase 10.
- `docs/operations.md`: parking with spot, and what an interruption looks
  like.
- A short cost section in the README: control plane on-demand, workers and GPU
  optionally spot, and parking.

## Decisions needed before starting

Decided 2026-11-08: the control plane never uses spot, and at least 2 workers
never use spot. Decision 1 below is therefore settled.

1. **On-demand floor for workers.** RHACM, GitOps, RHOAI, Connectivity Link
   and the MaaS API all run on workers. Suggestion: 2 on-demand `m6i.4xlarge`
   plus 1–2 spot, rather than all spot.
2. **GPU on spot?** It's the most expensive instance and the hardest spot
   capacity to get in us-east-2. With no fallback, a reclaimed GPU means the
   model is down until capacity returns. Suggestion: spot for demos where an
   outage is tolerable; on-demand when showing it to someone.
3. **Price cap.** Empty `spotMarketOptions` (bid up to on-demand, the documented
   recommendation) or a `maxPrice`?
4. **Diversify instance types?** One MachineSet per type spreads the risk
   (`m6i`/`m6a`/`m7i`; `g6`/`g5`), at the cost of more objects.
5. **Upstream.** Fold spot into the #282 `worker-nodes` fix, or a separate
   policy?

## Other cost levers (not spot, for comparison)

- **Parking** with `cluster-power.sh` already stops the compute charge when the
  cluster isn't in use. With spot workers, parking becomes scale-to-zero.
- **Destroy the RDS database** when parked for long stretches
  (`maas-database.sh destroy`), since it bills hourly.
- **The NAT gateway** bills hourly even when parked. `cluster-power.sh` already
  explains this.
- **Smaller workers** are not recommended: the sizing comments in `cluster.env`
  record that three `m6i.2xlarge` workers ran out of CPU with the full policy
  set.
