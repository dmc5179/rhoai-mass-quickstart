# Running under AutoShift

Phase 50 puts the cluster under RHACM and OpenShift GitOps, after which
capability arrives as policy rather than as a script. That is the point of it.
It also changes the failure modes, in ways that are not obvious from the
policy layer, and this page is the record of what we learned destroying a
cluster to find out.

## Size for the hub, not for the cluster

An ACM hub is not a lightly loaded OpenShift cluster, and the control plane
has to be sized for what it will run rather than for what it is at install
time.

Red Hat's [control plane sizing
guidance](https://access.redhat.com/articles/7132959) puts the minimum at
4 vCPU / 16 GiB and qualifies it precisely:

> This is generally sufficient for clusters with an etcd database size up to
> approximately 250 MiB **and low load**.

| etcd DB size (high-water) | Recommended control plane |
|---|---|
| up to ~250 MiB | 4 vCPU, 16 GiB |
| ~250 – ~500 MiB | 8 vCPU, 32 GiB |
| ~500 – ~750 MiB | 10 vCPU, 48 GiB |

Measure the pre-defrag high-water mark, which is what the table is calibrated
against:

```bash
OC=./bin/oc
P=$($OC get pods -n openshift-etcd -l app=etcd -o name | head -1)
$OC exec -n openshift-etcd ${P#pod/} -c etcdctl -- etcdctl endpoint status -w table
```

`cluster.env` defaults to `m6i.2xlarge` control plane and `m6i.4xlarge`
workers for this reason. They are not the cheapest values that will install.

## The failure does not say "too small"

This is the part worth internalising. An overloaded control plane does not
report that it is overloaded. What we actually observed, in order:

1. etcd at a 545 MB high-water mark on 4 vCPU / 16 GiB control plane nodes
2. API server requests beginning to time out
3. `ovnkube-controller` crash-looping, because it could not write a node
   annotation within the timeout:
   ```
   failed to update masquerade subnet annotation on node: ...
   Timeout: request did not complete within requested timeout
   ```
4. That node therefore never getting a CNI configuration, so kubelet reported
   `NetworkPluginNotReady` and the node went `NotReady`
5. The MachineConfig roll stalling, because an unavailable node counts against
   `maxUnavailable` (default 1)
6. `MachineConfigPool` flapping through `RenderDegraded` as the MCO's own API
   calls timed out

Six cluster operators were degraded. None of them said anything about
capacity. If you find yourself debugging CNI on a cluster that was working an
hour ago, check etcd size and worker CPU requests before you debug CNI.

```bash
oc describe node -l node-role.kubernetes.io/worker | grep -A5 'Allocated resources'
```

CPU requests at 99% of allocatable means nothing more can schedule — including
the webhook pods that other things block on.

## Turning a policy off does not uninstall anything

AutoShift's policies use `pruneObjectBehavior: None`. Setting a label to
`false` stops the policy reconciling; it does **not** remove the operator,
its namespace, its CRDs, or its webhooks.

The practical consequence: **you cannot undo an over-enabled cluster by
editing values.** Reclaiming capacity means uninstalling each operator by
hand — subscription, CSV, CRDs, namespace — on a cluster that is by then too
full to schedule anything, with namespaces that hang in `Terminating` on
finalizers.

It can also leave actively harmful debris. One orphaned validating webhook,
whose backing pods could no longer be scheduled, failed closed and blocked
`oc exec` across the entire cluster:

```
Internal error occurred: failed calling webhook "validate-exec.devworkspace-controller.svc":
no endpoints available for service "devworkspace-webhookserver"
```

Check for these before concluding a cluster is salvageable:

```bash
oc get validatingwebhookconfiguration -o json \
  | jq -r '.items[].webhooks[]?.clientConfig.service | select(.) | "\(.namespace)/\(.name)"' \
  | sort -u | while read -r s; do
      ns=${s%%/*}; n=${s##*/}
      [ -z "$(oc get endpoints "$n" -n "$ns" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ] \
        && echo "NO ENDPOINTS: $s"
    done
```

Given all that, **rebuilding is often faster than repairing**, and it is not an
admission of defeat. A rebuild here is about 90 minutes and fully scripted;
unpicking twenty operators by hand is longer, riskier, and ends somewhere you
cannot describe. The VPC lives in its own CloudFormation stack precisely so
that destroying the cluster is cheap.

## `adopt` turns everything on at once

```bash
scripts/50-autoshift.sh adopt
```

This is the switch, not `bootstrap`. Up to this point the hub is in the
`default` clusterset and no policy is acting on it. Adopting it into the
target clusterset activates **every** policy enabled in that clusterset's
values file simultaneously.

The shipped `hub.yaml` had 59 labels set to `true`. Adopting with that file
installed ACS, AAP, Quay, GitLab, compliance, the full logging and tracing
stack, service mesh, dev-hub, dev-spaces and more, in parallel, on a
three-worker cluster. That is what produced everything above.

The trimmed profile in this project's AutoShift branch is nine labels. Before
you adopt:

```bash
python3 -c "
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
for n,b in d['hubClusterSets'].items():
    on=[k for k,v in (b.get('labels') or {}).items() if str(v).lower()=='true']
    print(f'{n}: {len(on)} enabled'); [print('  ',k) for k in sorted(on)]
" $AUTOSHIFT_DIR/autoshift/values/clustersets/hub.yaml
```

Add capability one at a time, and re-measure etcd size and worker CPU requests
after each. That is slower than enabling everything to see what happens, and
it is the only approach that leaves you able to attribute a regression.

## Enable the MaaS chain as a unit

Four labels are one feature, and any subset is broken:

```yaml
openshift-ai: 'true'          # the DataScienceCluster
connectivity-link: 'true'     # Kuadrant/Authorino
openshift-ai-maas: 'true'     # the gateway
openshift-ai-models: 'true'   # plus config.openshiftAiModels
```

The upstream `hub.yaml` shipped with `openshift-ai-maas: 'true'` and
`openshift-ai: 'false'`, which cannot work — the gateway needs the
DataScienceCluster. Nothing reports that as an error; the MaaS policies simply
sit Pending on an unmet dependency.

RHOAI is roughly 75 GB of images. Do not enable it until the control plane has
headroom.

## ACM shadows `machine` and `machineset`

Once ACM is installed, the Cluster API CRDs register a second pair of
resources with the same short names under `cluster.x-k8s.io`. `oc` resolves
the ambiguous name to the CAPI one, which is empty:

```console
$ oc get machineset -n openshift-machine-api
No resources found in openshift-machine-api namespace.

$ oc get machinesets.machine.openshift.io -n openshift-machine-api
NAME                            DESIRED   CURRENT   READY   AVAILABLE
rhoai-xxxxx-worker-us-east-2a   3         3         3       3
```

A silent wrong answer, not an error. Always use the fully qualified names
after phase 50. AutoShift's own policies are immune because their hub
templates spell out `lookup "machine.openshift.io/v1beta1" "MachineSet"` —
that explicitness is load-bearing, not stylistic.

## Policies that report Compliant while doing nothing

Two cases to know about, because both look healthy:

- A `ConfigurationPolicy` naming a CRD that does not exist yet reports
  Compliant. This is why the policy graph uses dependencies rather than waits:
  `policy-nvidia-gpu-cluster-policy` depends on
  `policy-nvidia-gpu-operator-install` so the ClusterPolicy is never applied
  against a missing CRD.
- An `object-templates-raw` block that resolves to an empty string applies no
  objects and reports Compliant. AutoShift's validation suite fails the build
  on this, which is the only reason it gets caught.

When a policy says Compliant and the thing it manages plainly is not working,
check whether it rendered anything at all.
