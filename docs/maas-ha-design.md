# Models-as-a-Service high availability: design

Status: design, 2026-11-09. Nothing here is applied. Facts were read from sandbox141 (RHOAI
3.5.2, Red Hat Connectivity Link 1.5.0, OpenShift 4.22) and from Red Hat documentation, cited
inline; anything not verified is marked.

## Summary

Every component in the MaaS request path runs a single replica, with no PodDisruptionBudget, so
any node drain interrupts it: a MachineConfig rollout, an upgrade, and now a cluster autoscaler
scale-down. The rate limiter keeps its counters in memory, so a restart resets everyone's quota
window, and it cannot simply be scaled out. Within the single-zone cluster we have, the cheap
improvements are: two `maas-api` replicas, two Authorino replicas, Limitador counters that
survive restarts, and a PodDisruptionBudget on each. Model and database redundancy cost real
money and are separate decisions. Zone-level HA is out of scope: the VPC and every node are in
one availability zone by design.

## What is there today (sandbox141, observed)

| Component | Where | Replicas | PDB | Notes |
|---|---|---|---|---|
| `maas-api` | `redhat-ai-gateway-infra` | 1 | none | Rendered by `maas-controller`, which resets a manual `oc scale` (see below) |
| Authorino (API key and auth checks) | `kuadrant-system` | 1 | none | The fork's `connectivity-link` policy sets `replicas: 1` in `manifests/kuadrant/authorino.yaml` |
| Limitador (token and request limits) | `kuadrant-system` | 1 (`replicas` unset) | none | **In-memory storage**: counters reset on restart; two replicas would each count separately |
| `payload-processing`, `payload-pre-processing` | `openshift-ingress` | 1 each | none | Owned by `maas-controller` (`Config/default`). Whether replicas are configurable is **unverified** |
| `maas-default-gateway` (Envoy) | `openshift-ingress` | 2, with HPA | none | Already redundant |
| `istiod-openshift-gateway` | `openshift-ingress` | 1, with HPA | none | Control plane only; running gateways keep serving if it restarts |
| Model `granite-4-tiny-gpu` | `llm` | 1, on 1 GPU node | none | The autoscaler allows up to 2 GPU nodes (`machineSets.gpu` 1-2) |
| MaaS database | RDS `rhoai-maas` | single-AZ `db.t4g.small`, 7-day backups | n/a | `maas-api` will not start without it |
| Cluster | VPC `rhoai-vpc` | every node in `us-east-2a` | n/a | Single zone by design (`docs/aws-vpc-and-cloudformation.md`) |

Kuadrant already has `spec.observability.enable: true`.

## The supported knobs

| Component | How, and source |
|---|---|
| `maas-api` replicas | Annotate the `MaasTenantConfig` (on this cluster `default-tenant` in `models-as-a-service`) with `maas.opendatahub.io/maas-api-replicas=<n>`. `maas-controller` reads it and renders the Deployment with that count; removing the annotation returns to 1. A direct `oc scale` or an HPA is reverted within 3-5 minutes because the controller applies with server-side apply and force ownership. Available from RHOAI 3.5. ([Red Hat solution 7147427](https://access.redhat.com/solutions/7147427)) |
| Limitador shared counters | `spec.storage.redis.configSecretRef` naming a Secret with key `URL` (`redis://` or `rediss://`). Red Hat's examples name AWS ElastiCache (Redis OSS), Valkey and Dragonfly. ([RHCL 1.5 *Install*, §1.7 "Configure Redis storage for rate limiting"](https://access.redhat.com/documentation/en-us/red_hat_connectivity_link/1.5/html-single/install_connectivity_link/index#configure-redis_install-on-ocp)) |
| Limitador replicas, PDB, other storage | The CRD has `spec.replicas`, `spec.pdb {minAvailable, maxUnavailable}`, and `spec.storage` with `disk`, `redis` and `redis-cached` (observed in the CRD schema). The `Limitador` object is owned by the `Kuadrant` CR, but RHCL's own procedure patches its `storage`, so editing these fields is expected. Whether the Kuadrant operator leaves `replicas` and `pdb` alone is **unverified** |
| Authorino replicas | `spec.replicas` on the `Authorino` CR (observed). Already a field in our policy |
| Model replicas | `spec.replicas` on the `LLMInferenceService` (observed: 1) |
| MaaS database | `scripts/maas-database.sh create --ha` already provisions Multi-AZ (synchronous standby, roughly double the cost) |

## Design

### Tier 1: no new infrastructure (recommended first)

| Change | Policy | Config (hub values) |
|---|---|---|
| `maas-api` to 2 replicas through the tenant annotation | `openshift-ai-maas`: a `musthave` on `MaasTenantConfig/default-tenant` setting only `metadata.annotations["maas.opendatahub.io/maas-api-replicas"]` | `config.openshiftAiMaas.maasApiReplicas: 2` |
| PDB for `maas-api` (`minAvailable: 1`) | `openshift-ai-maas`, a separate `PodDisruptionBudget` object (the controller renders the Deployment, not a PDB) | on when `maasApiReplicas` > 1 |
| Authorino to 2 replicas, plus PDB | `connectivity-link`: replace the literal `replicas: 1` in `authorino.yaml` with config | `config.connectivityLink.authorino.replicas: 2` |
| Limitador counters survive restarts: `spec.storage.disk` (a PVC) | `connectivity-link`, a `musthave` on the `Limitador` `spec.storage` only | `config.connectivityLink.limitador.storage: disk` |

Disk storage keeps one Limitador replica, so a drain still interrupts rate limiting for the few
seconds Limitador takes to restart on another node. Its value is that the restart no longer
resets every user's token window to zero. A PDB on a single replica would block every node drain,
so it is not used here.

A PDB with `minAvailable: 1` only helps with two or more replicas spread across nodes. The
controller renders `maas-api`, so pod anti-affinity cannot be added (**unverified**); the scheduler
spreads replicas of one Deployment across nodes by default, which is usually enough on three
workers.

### Tier 2: shared rate-limit store, Limitador scaled out

- An AWS ElastiCache for Valkey (or Redis OSS) instance in the VPC, created by a script like
  `maas-database.sh`: `scripts/maas-ratelimit-store.sh create | status | secret | destroy`. TLS
  (`rediss://`), an auth token in `secrets/`, the connection URL in Secret
  `kuadrant-system/redis-config` (key `URL`). Like the RDS instance, it lives outside the VPC
  stack and needs a destroy step before `90-destroy-cluster.sh --with-vpc`.
- Limitador `storage.redis.configSecretRef: redis-config` (or `redis-cached`, which batches
  writes for lower latency at the cost of slight over-admission), `replicas: 2`,
  `pdb.minAvailable: 1`.
- An inform policy that the Secret exists, in the same shape as the other out-of-band secrets.
- Config: `config.connectivityLink.limitador.storage: redis`, `.replicas: 2`,
  `.redisSecretName: redis-config`.

An in-cluster Redis would avoid the AWS resource, but there is no Red Hat supported Redis operator
in this stack, and it would put rate-limit state on the same nodes it protects.

### Tier 3: the expensive parts (separate decisions)

| Change | Cost on this layout | Notes |
|---|---|---|
| Model on 2 replicas, on 2 GPU nodes, plus PDB | A second `g6.xlarge`, about $0.80/h on demand | The autoscaler already allows 2 GPU nodes; the model needs `replicas: 2` and the PDB. Doubles the model's capacity as well as making it redundant |
| RDS Multi-AZ | Roughly double the database cost | `maas-database.sh create --ha`. Protects against a database host or zone failure, but the cluster itself is single-zone |
| Zone-level HA | A multi-AZ VPC and a reinstall | Out of scope; would change the CloudFormation template and every single-zone assumption |

## Test plan (when built)

1. Baseline: a loop sending one small chat completion a second through the MaaS gateway with a
   test key, counting non-2xx responses.
2. Delete one `maas-api` pod, then one Authorino pod: expect zero failed requests.
3. Drain one worker (`oc adm drain`) while the loop runs: expect zero failed requests with
   Tier 1, except a few seconds of rate-limit errors while Limitador moves (Tier 1) or none
   (Tier 2).
4. Rate-limit persistence: consume part of a subscription's window, restart Limitador, and check
   the remaining allowance did not reset (disk or Redis).
5. Confirm the replica counts hold across a `maas-controller` reconcile (wait 10 minutes) and a
   bootstrap.
6. `scripts/checkup.sh`: add a line reporting replicas and PDBs for the MaaS path.

## Tier 1 results (sandbox141, 2026-11-10)

Built as `policy-maas-api-ha` (openshift-ai-maas) and `policy-rhcl-ha` (connectivity-link); live and
Compliant. Measured with a loop of one small chat completion a second through the MaaS gateway:

| Test | Failures | Finding |
|---|---|---|
| `maas-api` replica count after 8 minutes | none | The `maas.opendatahub.io/maas-api-replicas` annotation holds across maas-controller reconciles |
| Restart Limitador within one token window | none | Counters survive on disk: 299843 tokens remaining before and after |
| Drain worker A (a `maas-api` and an Authorino replica, Limitador, 5 of 10 gateway pods) | 0 of 116 | Limitador was unavailable 24 s (EBS detach and re-attach) with no errors: the rate-limit check fails open |
| Delete only the two payload-processing pods | 2 of 51 (about 2 s) | It is an Envoy `ext_proc` with `failure_mode_allow: true`; its replica count is not configurable (`Config` has only `limitadorScrapeInterval` and `usageLogging`) |
| Drain worker B (the other `maas-api` and Authorino replicas, 3 gateway pods, both payload-processing services), twice | 34 of 208, then 11 of 117 | All HTTP 500 with an empty body and no `server` header, in the first 13 to 53 s of the drain. The external ELB kept the node `InService` throughout (health check `HTTP:10256/healthz`, 10 s x 6), so it is not the load balancer |

So tier 1 turns a drain from a full outage into a burst of gateway 500s lasting seconds, sometimes
none. The burst lines up with the eviction of in-path pods (Authorino, `maas-api`, payload-processing)
before Envoy's endpoints catch up, with the auth filter failing closed. Closing it needs graceful
termination (preStop delays) or retries on components owned by maas-controller and the Kuadrant
operator, which expose no setting for either: a candidate RFE. Not yet isolated which of the three
evictions contributes most.

## Open questions

- Answered: `payload-processing` is in the path but fails open and is not scalable; see tier 1 results.
- Does the Kuadrant operator reconcile `Limitador.spec.replicas` and `spec.pdb` back to defaults?
  (Tier 1 only sets `spec.storage`, which it keeps.) Test before tier 2 relies on it.
- Answered: `disk` storage works under the restricted SCC; the PVC bound and counters persist.
- How does the cluster autoscaler interact with the PDBs: scale-down skips a node whose pods
  cannot be evicted, which is the intended effect, but it should be watched once both are live.
