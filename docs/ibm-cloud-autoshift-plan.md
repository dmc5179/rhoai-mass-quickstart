# Adding IBM Cloud support to AutoShift

> **Parked, 2026-10-18. Not a backlog item.** This project is not adding IBM
> Cloud to AutoShift; IBM Cloud OpenShift deployment is being handled as a
> separate effort elsewhere. The page is kept because the research was done
> and may be worth something to that effort — not because anyone intends to
> build this. It is unlinked from the README for that reason.
>
> One thing here *was* built and should not be reverted: the
> provider-tolerant zone fix below, applied as `e494f5a2` in the AutoShift
> fork. It corrects a real nil dereference on vSphere and every other
> non-AWS provider spec, and it is live and verified on the AWS cluster. IBM
> Cloud is how it was noticed, not why it matters.

Research, not implemented. Everything here is verified against
`auto-shift/autoshiftv2` at `6a0ee770` (`main`, and identical on `rhoai-maas`
for every path involved), the live OpenShift 4.22 cluster, and Red Hat product
documentation. Items marked *inferred* are not verified.

The companion checklist is
[`docs/adding-a-platform.md`](https://github.com/dmc5179/autoshiftv2/blob/rhoai-maas/docs/adding-a-platform.md)
in the AutoShift fork, derived from the vSphere commits. This page is that
checklist turned into IBM Cloud specifics, plus the corrections it needs.

## Read this first: the scoping decision

**ACM/MCE does not list IBM Cloud as a cluster-creation target.** The MCE 2.9
support matrix covers Hive-based creation for AWS, AWS GovCloud, GCP, Azure,
Azure Government, Nutanix (API only), vSphere and OpenStack. IBM Cloud VPC
appears in none of them, and the ACM 2.14 *Clusters* guide has no IBM Cloud
creation section and no IBM Cloud credential type. IBM Cloud appears only on the
import side — ROKS, IKS, IBM Z, IBM Power.

That splits the work:

| | Supported? |
|---|---|
| The three **node policies** (`infra-nodes`, `worker-nodes`, `storage-nodes`) | Yes. They act on an existing managed cluster through the Machine API, and `IBMCloudMachineProviderSpec` has its own Red Hat docs module. |
| **`cluster-install`** (Hive provisioning) | Outside the documented matrix. The Hive code path exists and would very likely provision *(inferred)*, but the console will not offer it. |

Dropping `cluster-install` is not actually cheaper. Without
`_example-cluster-install-ibmcloud.yaml` the test harness never builds a
`managed-ibmcloud` profile, so the three node policies render empty in every
profile and the empty-policy gate fails the build. Shipping both with the
install path documented as caveated is the lower-friction option; the caveat is
a sentence, not a code change.

## Three corrections to the generic checklist

**1. The provider spec has its own API group.** `providerSpec.value.apiVersion`
is `ibmcloudproviderconfig.openshift.io/v1beta1`, **not**
`machine.openshift.io/v1beta1`. Only the outer `MachineSet` uses the
`machine.openshift.io` group. AWS and vSphere both use `machine.openshift.io`
inside `providerSpec.value`, so this is the single place where copying
`create-*-nodes-aws.yaml` verbatim would be wrong.

**2. IBM Cloud needs a second secret that no other platform does.**
`credentialsMode: Manual` is mandatory, so the Cloud Credential Operator mints
nothing and Hive cannot derive component credentials from the account API key.
The `ccoctl ibmcloud create-service-id` output has to be staged into a Secret
and referenced from `ClusterDeployment.spec.provisioning.manifestsSecretRef`.
Omit it and the install reaches bootstrap and stalls on unresolved
`CredentialsRequests`. The checklist has no concept of a second credential
artefact.

**3. The known gap is four files, not two — and worse than described.**

## The shared-manifest bug, and why CI hides it

Four manifests read `providerSpec.value.placement.availabilityZone`, an AWS-only
field, from placements with no `-provider` predicate:

| Manifest | Placement | Provider predicate |
|---|---|---|
| `infra-nodes/manifests/remove-infra-nodes.yaml` | `placement-remove.yaml` | none |
| `infra-nodes/test/check-cluster-infra-nodes.yaml` | `placement-infra-nodes.yaml` | none |
| `worker-nodes/test/check-cluster-worker-nodes.yaml` | `placement-test.yaml` | none |
| `storage-nodes/test/check-cluster-storage-machineset.yaml` | `placement-test.yaml` | guards `ne "baremetal"` only |

On a provider whose spec has no `placement` key, `.placement.availabilityZone`
is a nil dereference. The `ConfigurationPolicy` fails with *nil pointer
evaluating interface {}.availabilityZone* rather than rendering nothing.

**CI cannot see this.** `tools/testdata/cluster-openshift-resources.yaml` is a
deliberate hybrid where AWS *and* vSphere fields are always present on the same
object — the one fixture that masks the bug. IBM Cloud inherits it unchanged.

**Recommendation: make the shared manifests provider-tolerant; do not add
provider predicates.** Three reasons:

1. `placement-remove.yaml` and `placement-infra-nodes.yaml` back five policies
   each. Splitting either per provider multiplies `PlacementBinding`s.
2. A provider allowlist **fails closed on cleanup**. `policy-remove-infra-nodes`
   has `pruneObjectBehavior: DeleteAll`; a cluster on a provider nobody added to
   the list keeps its infra MachineSets forever, silently and Compliant.
3. The `check-*` policies are `inform`. Being readable on every provider is the
   point; gating by provider means new platforms get no readiness signal.

The fix is one shared preamble replacing the single `ternary` line in each file:

```gotemplate
{{- $worker_zone := "" }}
{{- $pv := (dig "spec" "template" "spec" "providerSpec" "value" dict $worker_ms) }}
{{- if (dig "zone" "" $pv) }}
  {{- $worker_zone = (dig "zone" "" $pv) }}
{{- else if (dig "placement" "availabilityZone" "" $pv) }}
  {{- $worker_zone = (dig "placement" "availabilityZone" "" $pv) }}
{{- else if (dig "metadata" "name" "" $worker_ms) }}
  {{- $worker_zone = trimPrefix (printf "%s-worker-" $infrastructure_id) (dig "metadata" "name" "" $worker_ms) }}
{{- end }}
```

`dig` throughout, because that is what turns a nil dereference into an empty
string.

**Land this as a separate prerequisite PR before the IBM work.** Applied to the
fork as `e494f5a2`.

**Correction, found by trying it: the fix cannot be proved in CI, and the
obvious way to try breaks the build.** This page previously recommended adding
a third worker `MachineSet` stub carrying vSphere fields only and no
`placement`. That does not work. Every manifest ranges over the same shared
fixture with `$worker_ms` set to the *last* match, so a single-provider stub
also reaches the AWS **create** manifests:

```
template: tmpl:36:52: executing "tmpl" at
<.spec.template.spec.providerSpec.value.placement.availabilityZone>:
invalid value; expected string
```

It broke `policy-gpu-nodes-aws` among others — manifests that are correct on a
real cluster, because each is gated by its own `placement-aws.yaml` provider
predicate. The hybrid fixture is not merely masking the bug; the whole harness
assumes one worker MachineSet shared by every provider profile.

Proving this needs per-provider MachineSet fixtures keyed to the profile under
test — a harness change, and a prerequisite to the prerequisite. Until then the
fix is reviewable but not CI-verifiable, which is worth saying in the PR rather
than letting a green build imply coverage that does not exist.

## The 22 touchpoints

| # | File | Action |
|---|---|---|
| 1 | `.github/config-key-conventions.yaml` | add `ibmcloud` to `shared:` |
| 2 | `autoshift/templates/_validate-cluster-install.tpl` | `$validPlatforms` (L205), four key lists (~L188), an `if eq $platform "ibmcloud"` block after L548 |
| 3–5 | `policies/stable/infra-nodes/` | `manifests/create-infra-nodes-ibmcloud.yaml`, `placement-ibmcloud.yaml`, a `policies[]` entry |
| 6–8 | `policies/stable/worker-nodes/` | same three |
| 9–11 | `policies/stable/storage-nodes/` | same three |
| 12–13 | `policies/stable/cluster-install/` | `manifests/ibmcloud.yaml`, a `policies[]` entry |
| 14 | `autoshift/values/clusters/_example-cluster-install-ibmcloud.yaml` | **load-bearing for CI, not documentation** |
| 15–18 | `tools/testdata/` | `cluster-openshift-resources.yaml` (both worker stubs), `cluster-secrets.yaml` (two Secrets), `acs-managedclusters.yaml`, `acs-secrets.yaml` |
| 19 | `tools/internal/resolver/e2e_test.go` | one `assertContains` for `-ibmcloud-creds` |
| 20 | `autoshift/values/clustersets/_example.yaml` | provider comments on L1491/1512/1530 |
| 21 | `autoshift/values/clusters/_example.yaml` | nothing — every label is already declared |
| 22 | docs | `cluster-install.md`, `values-reference.md` L520/L549, `README.md` |

**No new `autoshift.io/` labels**, so the label-contract work is zero. Every
label the IBM manifests read is already declared.

**No `kustomization.yaml` changes.** `versions.yaml`, `scripts/`, the `Makefile`,
`mkdocs.yaml` and `.gitleaks.toml` need none either.

Policy name lengths, against the 40-char cap: `policy-infra-nodes-ibmcloud` 27,
`policy-worker-nodes-ibmcloud` 28, `policy-storage-nodes-ibmcloud` 29,
`policy-cluster-install-ibmcloud` 31. The cap applies to Policy names only, not
Placements.

## IBM Cloud specifics worth knowing

**Shape.** IBM Cloud is AWS-shaped, not vSphere-shaped: `zone` and `region` sit
directly on `providerSpec.value` rather than nested under `placement`. Base the
node manifests on the AWS ones and flatten that one level.

**Sizing is profile-driven.** `*-nodes-instance-type` carries an IBM Cloud
instance profile (`bx2-4x16`). `-numcpu`, `-memory-mib` and
`-numcores-per-socket` have no equivalent and must be ignored.

**`bootVolume` has no size field** on `release-4.16` or `release-4.19` — only
`encryptionKey`. `profile`/`sizeGiB`/`iops` exist on `main` (post-4.19), so a
volume-size label has nowhere to go until 4.20+. Re-check on the next rebase.

**ODF needs no block devices in the MachineSet** *(inferred)*.
`IBMCloudMachineProviderSpec` has no secondary-volume field at all, so storage
nodes can only set the boot volume and ODF must consume dynamically provisioned
PVs from the VPC Block CSI driver. No Red Hat doc confirms a supported
ODF-on-IBM-Cloud-VPC topology — treat as structurally forced, not blessed.

**The base domain is a provisioned service, not a DNS record.** Public clusters
need an IBM Cloud Internet Services instance on at least the **Standard Next**
plan, holding an authoritative zone **in the same account**. Private clusters
(`publish: Internal`) need IBM Cloud DNS Services on the **Standard DNS** plan.
Wrong account or wrong plan tier and the install fails.

**Existing-VPC installs are all-or-nothing.** Setting `vpcName` makes
`networkResourceGroupName`, `controlPlaneSubnets` and `computeSubnets` all
required, one subnet per availability zone for each pool. Half-specifying fails
well into provisioning, so validate the group together.

**No zone-spread cost signal.** The AWS example warns that each zone costs a NAT
gateway and an Elastic IP. IBM Cloud VPC provisions its own load balancers and
has no equivalent per-zone charge, so that advice must *not* be copied.

**`IC_API_KEY`, not `IBMCLOUD_API_KEY`.** The latter is the Power VS variant.
Irrelevant to the policy path — Hive reads the Secret — but it will catch anyone
reproducing the install by hand.

**The credential key `ibmcloud_api_key` is already legacy.** `ccoctl` emits both
it and `ibm-credentials.env`, with a source TODO to drop the former once
in-cluster components migrate. Correct today; worth a comment so the flip is a
one-line change.

**`/dev/vda`, not `/dev/sda` or NVMe** *(inferred)*, for day-1 disk
partitioning. IBM Cloud VPC boot volumes attach over virtio.

**Infra-node profile sizing has no IBM-specific Red Hat guidance.** The
installer default everywhere is `bx2-4x16`. Anything larger is a mapping of the
generic sizing table onto the balanced family, not a Red Hat recommendation.

## Expected failure order while iterating

Each has a message that does not name the real cause:

1. `TestConfigKeyConventions` — `config key "ibmcloud" … matches no policy directory` → touchpoint 1
2. A helm error naming `$validPlatforms` → touchpoint 2
3. `<no value>` in resolved output → missing IBM fields on the worker stubs
4. `reportEmptyConfigurationPolicies` → usually a zone-label mismatch against the stub
5. The new `assertContains` → the `ibmcloud-creds` Secret is missing, or the policy body's `if` guard never opened

One subtlety: pin the IBM stub zones to the **same** `us-east-2a`/`us-east-2b`
strings the AWS fields use. `BuildSyntheticLabels` seeds the zone labels from the
example values, so real IBM strings (`us-south-1`) would miss the zone-match path
and leave it unexercised.

## Validation

```bash
make install-policy-generator
cd tools && GOTOOLCHAIN=auto go test -tags integration ./... -count=1
```
