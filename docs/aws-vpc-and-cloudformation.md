# The AWS network: how the VPC stack and the scripts fit together

A reference for anyone - person or agent - writing a new network template or a
new VPC deploy script for this repository. It describes the contract between
`cloudformation/01_vpc.yaml` and the scripts that consume it, so a new template
can be dropped in without breaking everything downstream.

Every statement here is checked against the code as of 2026-11-03.

## The shape of it

```
cluster.env ──► scripts/10-deploy-cluster.sh
                 │ 1. aws cloudformation create-stack  (cloudformation/01_vpc.yaml)
                 │    or reuse the stack if it already exists
                 │ 2. scripts/generate-install-config.sh
                 │      reads stack OUTPUTS ──► install-config.yaml
                 │ 3. openshift-install create cluster  (installs INTO the VPC)
                 ▼
            clusters/<CLUSTER_NAME>/   installer state, kubeconfig
```

**The VPC is deliberately not part of the cluster.** It lives in its own
CloudFormation stack with no `kubernetes.io/cluster/*: owned` tags, so
`openshift-install destroy cluster` leaves it standing and the next build
reuses it. The installer adds its own `: shared` tags to the subnets at install
time and removes them at destroy. Destroying the VPC is a separate, explicit act:
`scripts/90-destroy-cluster.sh --with-vpc`.

This is a bring-your-own-VPC (installer-provisioned infrastructure into an
existing VPC) install, not user-provisioned infrastructure. The installer still
creates the instances, load balancers and DNS records; it just puts them in
subnets we hand it.

## The contract: parameters in, outputs out

### Parameters `10-deploy-cluster.sh` passes

| Template parameter | From `cluster.env` | Notes |
|---|---|---|
| `InfrastructureName` | `VPC_INFRA_NAME` | naming prefix only; not tied to the cluster name or infra ID |
| `VpcCidr` | `VPC_CIDR` | must not overlap `100.64.0.0/16` (OVN-Kubernetes uses it) |
| `AvailabilityZone` | `VPC_AZ` | blank = first AZ in the region |

`01_vpc.yaml` also has `SubnetBits` (default 12), which the script does not pass.

### Outputs the scripts read - THE INTERFACE

**A new template that exposes these output names with these value shapes works
with every downstream script unchanged.** That is the single most useful thing
to preserve.

| Output | Shape | Read by |
|---|---|---|
| `InstallConfigSubnets` | a YAML document: `platform.aws.vpc.subnets` with roles (below) | `generate-install-config.sh` |
| `AvailabilityZone` | a zone name, `us-east-2a` | `generate-install-config.sh`, `maas-database.sh` |
| `VpcId` | `vpc-…` | `maas-database.sh`, `cluster-power.sh` |
| `PrivateSubnetId` | `subnet-…` | `maas-database.sh` |
| `PublicSubnetId`, `PublicSubnetIds`, `PrivateSubnetIds` | IDs | exported, not currently read |

`InstallConfigSubnets` is a paste-ready block, which keeps every subnet role
assignment in the template rather than spread across scripts:

```yaml
platform:
  aws:
    region: us-east-2
    vpc:
      subnets:
      - id: subnet-PUBLIC
        roles:
        - type: IngressControllerLB
        - type: ControlPlaneExternalLB
        - type: BootstrapNode
      - id: subnet-PRIVATE
        roles:
        - type: ClusterNode
        - type: ControlPlaneInternalLB
```

All five roles are assigned explicitly so the installer does not fall back to
auto-discovering subnets, which keeps the VPC usable for non-cluster resources.
A fully private / disconnected design changes which subnets carry which roles -
an internal-only cluster has no `IngressControllerLB` or
`ControlPlaneExternalLB` on a public subnet - so a new template must emit the
roles that match its own topology.

## What `generate-install-config.sh` patches, and what it does not

It starts from `templates/install-config.yaml.aws` and overwrites only:

- `platform.aws.region` (from `AWS_DEFAULT_REGION`)
- `platform.aws.vpc.subnets` (from `InstallConfigSubnets`)
- control plane and compute `zones` (from `AvailabilityZone`), `type`, `replicas`
- `baseDomain` (from `BASE_DOMAIN`, or auto-detected), `metadata.name`,
  `pullSecret`, `sshKey`

Everything else comes **verbatim from the template**, which bites when the
network changes:

- **`networking.machineNetwork` is hardcoded to `10.0.0.0/16`** and is not
  patched. It must contain the VPC CIDR. A VPC on any other CIDR needs the
  template - or the script - changed too, or the install fails.
- `publish: External` and `credentialsMode: Mint` are fixed. A disconnected
  design may need `publish: Internal`, and needs a credentials mode the
  installer can actually exercise without internet access - check the 4.22
  docs for the variant you build.
- There is no `imageDigestSources` or `additionalTrustBundle`. A disconnected
  install needs both, pointing at the mirror registry.

**Base domain auto-detection:** with `BASE_DOMAIN=""`, the script lists **public**
Route 53 hosted zones and uses the only one. Zero or more than one is an error,
deliberately. A disconnected design that uses a **private** hosted zone must set
`BASE_DOMAIN` explicitly, since auto-detection only considers public zones.

**yq:** the script uses **Go yq v4 (mikefarah)**, which Fedora ships as `yq`.
It does not have `--arg`; values go in through the environment:
`V="$x" yq -i '.a = strenv(V)'` for strings, `env(V)` for parsed values such as
lists and integers. Go yq preserves comments, so checks that grep the output must
ignore comment lines (the `CHANGEME` check uses `^[^#]*CHANGEME`).

## What `01_vpc.yaml` builds today

Single availability zone, by design:

| Resource | Purpose |
|---|---|
| VPC | |
| 1 public subnet + internet gateway + route table | load balancers, bootstrap |
| 1 private subnet + route table | cluster nodes |
| 1 NAT gateway + Elastic IP | private subnet egress to the internet |
| S3 gateway endpoint | S3 traffic stays inside AWS |

It is a **connected** design: the NAT gateway gives the private subnet a route
to the internet. A simulated-disconnected template removes that route.

## Building a disconnected variant: what Red Hat documents

From *Installing on AWS*, OpenShift 4.22, section 3.4 ("Installing a cluster on
AWS in a disconnected environment",
<https://access.redhat.com/documentation/en-us/openshift_container_platform/4.22/html-single/installing_on_aws/index>):

> If you are working in a disconnected environment, you are unable to reach the
> public IP addresses for EC2, ELB, and S3 endpoints.

Three documented options: **VPC endpoints** for
`ec2.<region>.amazonaws.com`, `elasticloadbalancing.<region>.amazonaws.com` and
`s3.<region>.amazonaws.com`; a **proxy**; or a proxy with VPC endpoints, in
which case the endpoints go in the proxy's `noProxy`. `01_vpc.yaml` already has
the S3 gateway endpoint; EC2 and ELB would be new interface endpoints.

Also from that section: a private hosted zone shared from **another** account
requires the `Passthrough` or `Manual` credentials mode.

Content this repository already has for the mirror side:

- `disconnected/imageset-config-rhoai-3.5.2-ocp4.21.yaml` and `-ocp4.22.yaml` -
  oc-mirror v2 ImageSetConfigurations for RHOAI 3.5.2 + MaaS, dry-run validated.
  Their header comments record the non-obvious parts: Service Mesh 3 must be
  mirrored and pinned to 3.3.1 although no CSV ever appears (the ingress operator
  installs it for the Gateway API); Connectivity Link 1.4.3 pins its three
  dependencies to exact versions; tag-mirrored images land in an
  ImageTagMirrorSet rather than the ImageDigestMirrorSet.
- oc-mirror gotchas, learned here: never set `REGISTRY_AUTH_FILE` (oc-mirror v2's
  embedded registry parses every `REGISTRY_*` variable as its own config and
  crashes) - use `--authfile`; a `--dry-run` in mirror-to-mirror mode still
  pings the destination registry, so dry-run mirror-to-disk (`file://`) instead.

## Script conventions to follow

A new deploy script should look like its neighbours:

- **Source order:** `cluster.env` (needs `ROOT` set first), then
  `bin/ocp-env.sh`, then `scripts/lib-logging.sh`. Never modify `PATH`; binaries
  are addressed as `$OC`, `$OPENSHIFT_INSTALL`, `$HELM` from `ocp-env.sh`.
  `OPENSHIFT_INSTALL` is `openshift-install-fips`.
- **Logging:** call `start_logging "<prefix>" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}`
  before any real work. Output then also goes to `logs/<prefix>-<timestamp>.log`
  with an exit-status footer. (`10-deploy-cluster.sh` predates the library and
  inlines the same re-exec-under-tee technique.)
- **Credentials:** AWS keys and region come from `secrets/aws.env`
  (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`).
  `secrets/` is gitignored except named `.example` files. Generated credentials
  are written there with `umask 077`.
- **`--dry-run`:** check wiring and print what would be created, create nothing.
  Note a dry run cannot exercise anything that needs the stack's outputs.
- **Idempotence:** reuse an existing stack rather than failing or duplicating it.
- **Pre-flight before a long run:** credentials (`aws sts get-caller-identity`),
  and the local inotify limit - the installer's local Cluster API control plane
  dies ~40 seconds in with "too many open files" if fewer than ~256 inotify
  instances are free (`10-deploy-cluster.sh` checks and prints the fix).
- `10-deploy-cluster.sh` refuses to run while `clusters/<CLUSTER_NAME>/` is
  non-empty. After a cluster is lost, move that directory aside first.

## Known gaps around the VPC lifecycle

- **`--with-vpc` cannot delete a VPC that `maas-database.sh` has used.**
  `maas-database.sh create` adds a second subnet in another AZ (RDS insists on
  two), a security group and a DB subnet group, **outside** the stack. Its
  `destroy` removes the instance, the subnet group and the security group, but
  **not that extra subnet**, and `90-destroy-cluster.sh` knows about none of
  them. Deleting the stack then fails on a dependency violation until they are
  removed by hand.
- `maas-database.sh` derives the extra subnet from the subnets that actually
  exist - same prefix length, first free block - rather than replaying the
  template's `!Cidr` arithmetic, because that depends on `SubnetBits` and a
  wrong guess yields a plausible CIDR that overlaps a real subnet.

## Account-level facts for Red Hat Demo Platform

- An **AWS Blank Open Environment** arrives with admin keys and exactly one
  public Route 53 zone (`sandbox<N>.opentlc.com`), which is what base-domain
  auto-detection needs. It also carries RHDP's own stack,
  `sandbox-<id>-open-environment` - leave it alone.
- Each environment is a **new AWS account**, so quotas reset. Check
  *Running On-Demand G and VT instances* (`L-DB2E81BA`) before a GPU build;
  recent environments have arrived with 64 vCPU already.
- When an environment expires, the account and everything in it go with it.
  Nothing needs destroying in AWS; the local `clusters/` and
  `secrets/maas-db.env` are what go stale.
