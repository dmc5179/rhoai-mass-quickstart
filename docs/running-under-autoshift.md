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

Five labels are one feature, and any subset is broken:

```yaml
openshift-ai: 'true'          # the DataScienceCluster
connectivity-link: 'true'     # Kuadrant/Authorino
openshift-ai-maas: 'true'     # the gateway
openshift-ai-models: 'true'   # plus config.openshiftAiModels
leader-worker-set: 'true'     # multi-node serving
```

Rather than hand-editing those, use the helper, which refuses to enable a
group whose prerequisite feature is off or whose required config is absent:

```bash
scripts/autoshift-feature.sh list
scripts/autoshift-feature.sh enable maas   # requires: gpu
```

The upstream `hub.yaml` shipped with `openshift-ai-maas: 'true'` and
`openshift-ai: 'false'`, which cannot work — the gateway needs the
DataScienceCluster. Nothing reports that as an error; the MaaS policies simply
sit Pending on an unmet dependency.

RHOAI is roughly 75 GB of images. Do not enable it until the control plane has
headroom.

## MaaS needs a database, and no label will give you one

This is the fifth requirement of that chain and the one that catches people,
because it is not a label and nothing in the policy layer supplies it.

`maas-api` reads a PostgreSQL connection URL from a Secret, once, at startup.
Without it the pod does not degrade — it exits:

```
error: failed to load database URL: failed to read secret
redhat-ai-gateway-infra/maas-db-config: secrets "maas-db-config" not found
```

and `CrashLoopBackOff`s indefinitely. Every MaaS policy reports Compliant
throughout, because every MaaS policy is doing exactly what it was asked.
What you see three layers away is an *authenticated* request to the gateway
answered with `no healthy upstream`, which points at the gateway.

**The script path and the policy path differ here, and that is the whole
trap.** Phase 20 wraps the guide's `setup-maas.sh`, which deploys a
single-replica `postgres` Deployment with a PVC and creates `maas-db-config`
itself. Arriving at MaaS through AutoShift policies instead, you skip that
script — and nothing else creates a database.

On AWS, provision one:

```bash
scripts/maas-database.sh create          # RDS PostgreSQL, ~10 min
scripts/maas-database.sh status
```

It writes the Secret into `redhat-ai-gateway-infra`, so it has to run after
RHOAI has created that namespace. To overlap the ~10 minutes of RDS
provisioning with the RHOAI rollout, split it:

```bash
scripts/maas-database.sh create --no-secret   # any time after the VPC exists
scripts/maas-database.sh secret               # once the namespace is there
```

`maas-api` only reads the Secret at startup, so if it is already crash-looping
when the Secret lands, restart it:

```bash
oc rollout restart deployment/maas-api -n redhat-ai-gateway-infra
```

Off AWS, use that provider's managed PostgreSQL or run
`crunchy-postgres-operator` in-cluster — it is in the mirror list for exactly
this reason. There is deliberately no `cloudnative-pg` policy: a database the
cluster depends on, running inside that cluster, makes its own backups and
failover the cluster's problem.

`policy-openshift-ai-maas-db` is an inform-only policy asserting that the
Secret exists and that the `maas-api` Deployment is Available, so the cause
is visible at the layer that owns it rather than as a gateway symptom. It
never looks at the Secret's contents — the URL carries a password and is
created out of band, the same way the Lightspeed API key is.

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
