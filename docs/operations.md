# Operations

## What it costs

Phase 10 builds 3 control plane and 3 worker nodes. On AWS with defaults that
is roughly 36 vCPUs of EC2, ~720 GiB of EBS, one NAT gateway, one Elastic IP,
and a couple of load balancers.

```bash
scripts/cluster-power.sh status
```

prints the live counts and says plainly what each one costs while parked.

## Parking

Stop the nodes without destroying anything:

```bash
scripts/cluster-power.sh stop --wait
scripts/cluster-power.sh start --wait
```

Nodes are found through the AWS Resource Groups Tagging API using the
cluster's infrastructure ID, so this picks up whatever exists — including a
GPU node you scaled up. The ID comes from `metadata.json`, not from `oc`,
because the cluster API is down exactly when you need this.

Workers stop before the control plane and start after it.

**Parking saves the compute charge and nothing else.** EBS, the NAT gateway,
Elastic IPs, and load balancers keep billing. For a long break, destroy
instead.

After `start`, nodes usually return `NotReady` with pending CSRs — kubelet
certificates were not renewed while the cluster was off. The script prints the
approval command; expect to run it twice.

## Destroying

```bash
scripts/90-destroy-cluster.sh              # keep the VPC
scripts/90-destroy-cluster.sh --with-vpc   # remove the VPC too
scripts/90-destroy-cluster.sh --purge      # delete rather than archive state
```

Works from `metadata.json`, which the installer writes before creating
anything — so it cleans up a run that died partway, not just a finished
cluster. It deletes everything tagged
`kubernetes.io/cluster/<infraID>=owned`.

The VPC is kept by default because it carries no owned tags, which is what
lets it outlive the cluster. Keeping it makes the next build faster; it also
keeps costing you a NAT gateway.

The cluster state directory is archived to
`clusters/<name>-destroyed-<timestamp>/` rather than deleted, because
`metadata.json` is your only record of which resources belonged to the
cluster. Delete it once you are satisfied nothing was left behind.

## Verifying nothing is left

```bash
set -a; . secrets/aws.env; set +a
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=kubernetes.io/cluster/<infraID>,Values=owned" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text

aws ec2 describe-instances \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId' --output text
```

Both empty means the cluster is gone. The VPC stack shows separately:

```bash
aws cloudformation describe-stacks --stack-name rhoai-vpc --query 'Stacks[0].StackStatus'
```

## Rebuilding

With the VPC kept, a rebuild skips network creation:

```bash
scripts/90-destroy-cluster.sh
scripts/10-deploy-cluster.sh
```

The new cluster gets a fresh infrastructure ID and reuses the same subnets.

## Upgrading the guide

The guide is a pinned submodule. To take upstream changes:

```bash
cd rhoai-maas-guide
git fetch upstream && git merge upstream/main && git push origin main
cd .. && git add rhoai-maas-guide && git commit -m "Bump guide"
```

Committing the pointer is what records which guide revision a cluster was
built against.
