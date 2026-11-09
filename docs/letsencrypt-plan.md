# Let's Encrypt certificates for the API and `*.apps` (plan)

Status: **plan only, nothing applied.** Researched 2026-11-09 against the live
`rhoai` cluster (OpenShift 4.22.18, us-east-2, RHACM 2.17, cert-manager Operator
1.20.1) and `autoshiftv2-mine` branch `rhoai-maas`.

Targets: `api.rhoai.sandbox141.opentlc.com` (port 6443) and
`*.apps.rhoai.sandbox141.opentlc.com` plus the bare `apps.` name. Validation is
DNS-01 against the public Route 53 zone `sandbox141.opentlc.com`
(`Z3V20CMO30MWHD`).

## Recommendation

**Use AutoShift's existing cert-manager policies, and cherry-pick upstream PR
#236 into `rhoai-maas` for the ACME `ClusterIssuer`. Give it Route 53 access
through a dedicated, scoped IAM user. Create that user's key Secret on the
cluster out of band.** Do not use acme.sh.

Why:

| | AutoShift + #236 (recommended) | acme.sh |
|---|---|---|
| Supported | cert-manager Operator for Red Hat OpenShift: Red Hat-supported, documented for exactly this (Route 53 DNS-01, API and ingress certs) | Community script. Not supported. |
| Declarative / RHACM | Yes. Labels and config in `hub.yaml`, policies from Git | No. A cron job, `oc create secret`, `oc patch`, and a host that must stay up |
| Renewal | cert-manager renews in place under the same Secret name. The router and kube-apiserver hot-reload. | Must re-push the Secret yourself on every renewal |
| Safety | Policies patch `APIServer`/`IngressController` **only once the Certificate is Ready** | No gate |
| Work needed | One cherry-pick, plus one label declaration (below) | A new script plus the glue |

acme.sh's `dns_aws` (in `dnsapi/dns_aws.sh`) does the same thing as cert-manager's Route 53 solver.
It finds the public zone with `ListHostedZones` (it skips private zones), UPSERTs the
`_acme-challenge` TXT record with `ChangeResourceRecordSets`, and can fall back to an
instance or container role. It does not poll `GetChange`. It is a reasonable
fallback only for a cluster without the operator.

### What AutoShift already supports (`policies/stable/cert-manager`)

| Policy | Label | What it does | State on `local-cluster` |
|---|---|---|---|
| `policy-cert-manager-operator-install` | `cert-manager` | Operator, `stable-v1` | `true`, Compliant, CSV 1.20.1 |
| `policy-cert-manager-ca` | `cert-manager-ca` (default on, `NotIn false`) | Self-signed `autoshift-selfsigned` and `autoshift-ca` ClusterIssuers | Compliant |
| `policy-cert-manager-api-cert` (+ `-ready`, inform) | `cert-manager-api-cert` | `Certificate cert-manager-api-cert` in `openshift-config` for `api.<baseDomain>` + `extraSANs`. When Ready, it merges `APIServer/cluster spec.servingCerts.namedCertificates`. It never touches `api-int`. | label unset: **unplaced** |
| `policy-cert-manager-ingress-cert` (+ `-ready`) | `cert-manager-ingress-cert` | `Certificate cert-manager-ingress-cert` in `openshift-ingress` for `*.apps.<domain>` and `apps.<domain>`. When Ready, it sets `IngressController/default spec.defaultCertificate`. | label unset: **unplaced** |

Issuer refs are data, in `config.certManager.{apiCert,ingressCert}.issuer` (default
`autoshift-ca`). The README already anticipates an ACME issuer (`zerossl-production-aws`).

**What's missing:** nothing in the fork creates an **ACME ClusterIssuer**, its
**solver credentials**, or the **CertManager `overrideArgs`** that DNS-01 needs here.
The fork has no ACME, DNS-01, or Route 53 support today.

### What PR #236 adds (open, `REVIEW_REQUIRED`, last updated 2026-09-09)

`policy-cert-manager-acme-issuer`, gated by the `cert-manager-acme-issuer` label, takes its input from `config.certManager.acmeIssuer`:

- `issuer.name` + `issuer.spec`: a **full pass-through** ClusterIssuer spec (`toYaml | autoindent`). Any ACME server and any solver work, including `dns01.route53`.
- `certManagerCR.overrideArgs`: patches `CertManager/cluster spec.controllerConfig.overrideArgs`, which is where the DNS-01 recursive nameserver flags go.
- It does **not** create Secrets. Despite its description mentioning `secrets[]`, the diff has none. That fits our rule that credentials never go in Git.

So #236 gives us ACME with Route 53 as-is. Gaps to fix when cherry-picking:

1. It declares `cert-manager-acme-issuer` only in `clustersets/_example.yaml`. Our convention also requires `clusters/_example.yaml`.
2. It supports **one** issuer at a time. To move from staging to production, you change `issuer.name` and `server`. The old ClusterIssuer is left behind (`pruneObjectBehavior: None`), so delete it by hand.
3. `toYaml | autoindent` sits inside a `{{hub` block, so `make test` skips it. Render it on the cluster and look at the result. The author validated it with a nested `http01` spec.
4. Run Vale on its comments. `policies/` is linted.

## Why the explicit IAM user and not ambient credentials

The 4.22 docs offer both (§11.6.1 *Authenticate on AWS*, §11.7.3 *explicit*, §11.7.4
*ambient*). This cluster is `credentialsMode: Mint` and the root `kube-system/aws-creds`
is present. A `CredentialsRequest` would therefore have CCO mint the IAM user with no
human ever holding a key, which is attractive. But it also requires putting
`CLOUD_CREDENTIALS_SECRET_NAME=aws-creds` in the operator **Subscription** `spec.config.env`.
That Subscription belongs to `policy-cert-manager-operator-install`, so the change
touches every cluster with cert-manager. It also needs a new manifest, and it does
not carry over to non-Mint or disconnected clusters. The `operator-install` chart does support
`subscription.config`, so this is a good second phase (open question 3). The explicit
key works with #236 unchanged.

## Step by step

AutoShift reminders: policy changes need **commit and push** in the fork. `hub.yaml`
changes need `scripts/50-autoshift.sh bootstrap` (helm reads values locally), then
`refresh`. Fully qualify the resource names below. ACM and other operators shadow short names.

### 0. Before anything: keep `oc` working after the API cert changes

The installer kubeconfig pins `certificate-authority-data` (five internal CAs). Go
then trusts **only** that bundle, so a Let's Encrypt cert on `api.` breaks `oc` and every
script here with `x509: certificate signed by unknown authority` (KB 5444001, 7010382).
Append the ISRG roots before you enable the API cert:

```bash
cd ~/workspace/rhoai-mass-aws
KC=clusters/rhoai/auth/kubeconfig
umask 077; cp -p "$KC" "$KC.pre-letsencrypt"
curl -sf https://letsencrypt.org/certs/isrgrootx1.pem  -o /tmp/isrgrootx1.pem
curl -sf https://letsencrypt.org/certs/isrg-root-x2.pem -o /tmp/isrg-root-x2.pem
NEW="$( { yq '.clusters[0].cluster."certificate-authority-data"' "$KC" | base64 -d
          cat /tmp/isrgrootx1.pem /tmp/isrg-root-x2.pem; } | base64 -w0 )" \
  yq -i '.clusters[0].cluster."certificate-authority-data" = strenv(NEW)' "$KC"
bin/oc --kubeconfig "$KC" get --raw /readyz      # still "ok" today
```

**Recovery path (tested today):** the named cert applies only when the client sends SNI `api.`. With
`--tls-server-name=api-int.…` the same endpoint presents the internal certificate, which the
original CA still validates:

```bash
bin/oc --kubeconfig "$KC.pre-letsencrypt" \
  --tls-server-name=api-int.rhoai.sandbox141.opentlc.com get --raw /readyz   # -> ok
```

### 1. IAM user and policy (manual, AWS account `130382331273`)

The policy allows **only TXT** changes on **only** the two challenge names, in **only** the public zone:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "PollChange", "Effect": "Allow",
      "Action": "route53:GetChange",
      "Resource": "arn:aws:route53:::change/*" },
    { "Sid": "ReadZone", "Effect": "Allow",
      "Action": "route53:ListResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/Z3V20CMO30MWHD" },
    { "Sid": "Dns01ChallengeOnly", "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/Z3V20CMO30MWHD",
      "Condition": { "ForAllValues:StringEquals": {
        "route53:ChangeResourceRecordSetsRecordTypes": ["TXT"],
        "route53:ChangeResourceRecordSetsActions": ["UPSERT", "DELETE"],
        "route53:ChangeResourceRecordSetsNormalizedRecordNames": [
          "_acme-challenge.api.rhoai.sandbox141.opentlc.com",
          "_acme-challenge.apps.rhoai.sandbox141.opentlc.com" ] } } },
    { "Sid": "FindZone", "Effect": "Allow",
      "Action": "route53:ListHostedZonesByName",
      "Resource": "*" }
  ]
}
```

The `*.apps` and bare `apps.` challenges share one record name, `_acme-challenge.apps.…`.
The upstream cert-manager example grants the same actions on `hostedzone/*` without conditions. Ours is the
tightened form. If issuance fails with `AccessDenied`, first drop the `Actions`
condition, then widen the names to `_acme-challenge.*`.

```bash
set -a; . secrets/aws.env; set +a; umask 077
aws iam create-user --user-name rhoai-cert-manager-route53
aws iam put-user-policy --user-name rhoai-cert-manager-route53 \
  --policy-name route53-dns01 --policy-document file://route53-dns01.json
aws iam create-access-key --user-name rhoai-cert-manager-route53 > secrets/route53-dns01.json
```

### 2. The out-of-band Secret

The ClusterIssuer Secret lives in the cluster resource namespace. That is `cert-manager` here (controller arg
`--cluster-resource-namespace=$(POD_NAMESPACE)`).

```bash
bin/oc create secret generic route53-dns01 -n cert-manager \
  --from-literal=access-key-id="$(jq -r .AccessKey.AccessKeyId secrets/route53-dns01.json)" \
  --from-literal=secret-access-key="$(jq -r .AccessKey.SecretAccessKey secrets/route53-dns01.json)"
```

A rebuilt cluster needs this command again. Nothing in Git recreates it.

### 3. Fork: cherry-pick #236 (commit and push to `rhoai-maas`)

Apply #236 and add `cert-manager-acme-issuer: 'false'` to `clusters/_example.yaml`. Then run
`GOTOOLCHAIN=auto make test` and the Vale command from CLAUDE.md.

### 4. `hub.yaml`, staging first

Under `hubClusterSets.hub`:

```yaml
    config:
      certManager:
        acmeIssuer:
          certManagerCR:
            overrideArgs:                       # REQUIRED here, see below
              - '--dns01-recursive-nameservers-only'
              - '--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53'
          issuer:
            name: 'letsencrypt-staging'
            spec:
              acme:
                server: 'https://acme-staging-v02.api.letsencrypt.org/directory'
                email: 'danclark@redhat.com'
                privateKeySecretRef:
                  name: 'letsencrypt-staging-account'
                solvers:
                  - selector:
                      dnsZones: ['rhoai.sandbox141.opentlc.com']
                    dns01:
                      route53:
                        region: 'us-east-1'     # Route 53 is global; the SDK still needs a region
                        hostedZoneID: 'Z3V20CMO30MWHD'
                        accessKeyIDSecretRef:
                          name: 'route53-dns01'
                          key: 'access-key-id'
                        secretAccessKeySecretRef:
                          name: 'route53-dns01'
                          key: 'secret-access-key'
    labels:
      cert-manager-acme-issuer: 'true'
```

**Why `overrideArgs` is not optional here:** the installer created a **private** zone
`rhoai.sandbox141.opentlc.com` (`Z0551871CBWR1KTUYOBX`) that overlaps the names being
validated. From inside the VPC, the self-check would resolve `_acme-challenge.apps.…`
against the private zone, never see the TXT record, and wait forever. This is exactly the
case the docs make the override for (§11.7.3 step 1). `hostedZoneID` pins the public zone
for the same reason.

The policy creates the `ClusterIssuer letsencrypt-staging` and patches `CertManager/cluster`, which
restarts the cert-manager controller. **Test staging with a throwaway Certificate, never through
the api-cert or ingress-cert policies.** The readiness gate would accept a staging cert,
and an untrusted cert on ingress degrades `authentication` and breaks console login (KB 4878721).

```bash
bin/oc create namespace le-test
bin/oc apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: le-staging-test, namespace: le-test}
spec:
  secretName: le-staging-test
  dnsNames: ['*.apps.rhoai.sandbox141.opentlc.com', 'apps.rhoai.sandbox141.opentlc.com', 'api.rhoai.sandbox141.opentlc.com']
  issuerRef: {name: letsencrypt-staging, kind: ClusterIssuer}
EOF
bin/oc get certificates.cert-manager.io,challenges.acme.cert-manager.io -n le-test -w
bin/oc delete namespace le-test       # after Ready=True
```

### 5. Production issuer, then the API cert, then ingress

Change `issuer.name` to `letsencrypt-production`, `server` to
`https://acme-v02.api.letsencrypt.org/directory`, and `privateKeySecretRef.name` to
`letsencrypt-production-account`. Then add:

```yaml
      certManager:
        apiCert:
          issuer: {name: 'letsencrypt-production', kind: 'ClusterIssuer', group: 'cert-manager.io'}
        ingressCert:
          issuer: {name: 'letsencrypt-production', kind: 'ClusterIssuer', group: 'cert-manager.io'}
    labels:
      cert-manager-api-cert: 'true'        # first; wait for kube-apiserver to settle
      # cert-manager-ingress-cert: 'true'  # second, in a later bootstrap
```

`bootstrap`, then `refresh`. Delete the orphaned `clusterissuer.cert-manager.io/letsencrypt-staging`.

| Policy | Creates | Effect |
|---|---|---|
| `acme-issuer` | `ClusterIssuer letsencrypt-production`, CertManager overrideArgs | none on traffic |
| `api-cert` | `Certificate openshift-config/cert-manager-api-cert` (ECDSA P-384) → when Ready, `APIServer namedCertificates: [{names: [api.…], servingCertificate: cert-manager-api-cert}]` | **one kube-apiserver revision rollout** (no reboot). Watch `oc get co kube-apiserver` until PROGRESSING=False. |
| `ingress-cert` | `Certificate openshift-ingress/cert-manager-ingress-cert` → when Ready, `IngressController default spec.defaultCertificate.name: cert-manager-ingress-cert` | **one router rolling update**. Later renewals hot-reload. |

The policies request `duration: 8760h`. Let's Encrypt ignores that and issues its own
lifetime (90 days today). cert-manager schedules renewal from the actual expiry, 30 days
before (`renewBefore: 720h`). No change is needed.

### MaaS gateway

`maas.apps.…` is one label under `apps`, so the wildcard covers it. The
`openshift-ai-maas` policy already templates the HTTPS listener's `certificateRefs` from
`IngressController.spec.defaultCertificate` (falling back to `router-certs-default`). It
**follows the ingress cert automatically**, and both live in `openshift-ingress`. One caveat:
the Gateway is `musthave`, and `musthave` merges lists, so the listener may end up with
**both** refs. Check, and if so, remove the stale `router-certs-default` entry or make
that object `mustonlyhave`. `data-science-gateway` (`rh-ai.apps…`) is a reencrypt Route,
so it inherits the wildcard. Hermes appends `default-ingress-cert` to the system bundle,
so Let's Encrypt is trusted there too.

## Verification

`openssl` is **not installed** on this workstation (`sudo dnf install openssl`). `curl -v` works without it.

```bash
H=rhoai.sandbox141.opentlc.com
for ep in api.$H:6443 console-openshift-console.apps.$H:443 oauth-openshift.apps.$H:443 maas.apps.$H:443; do
  echo "== $ep"; openssl s_client -connect $ep -servername ${ep%:*} </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -issuer -enddate -ext subjectAltName
done
curl -sv -o /dev/null https://api.$H:6443/readyz 2>&1 | grep -E 'issuer:|expire|verify'   # no -k
bin/oc whoami && bin/oc get co kube-apiserver authentication console ingress
bin/oc login -u kubeadmin https://api.$H:6443          # throwaway KUBECONFIG, no --insecure flag
bin/oc get certificates.cert-manager.io -A \
  -o custom-columns=NS:.metadata.namespace,N:.metadata.name,READY:.status.conditions[0].status,RENEW:.status.renewalTime
bin/oc get gateway.gateway.networking.k8s.io maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[?(@.name=="https")].tls.certificateRefs}'
scripts/checkup.sh && scripts/35-smoke-test.sh
```

Expect `issuer: C=US, O=Let's Encrypt, CN=E…` with no `(STAGING)`. All four ClusterOperators should be Available, not Degraded.

## Rollback

Turn the label off **first**. Otherwise the policy re-adds what you remove. Turning it off does not uninstall anything (`pruneObjectBehavior: None`).

- **Ingress:** set `cert-manager-ingress-cert: 'false'`, `bootstrap`, then
  `oc patch ingresscontroller.operator.openshift.io default -n openshift-ingress-operator --type=json -p '[{"op":"remove","path":"/spec/defaultCertificate"}]'`.
  The router rolls back to `router-certs-default`. The MaaS gateway policy follows on its next evaluation.
- **API:** set `cert-manager-api-cert: 'false'`, `bootstrap`, then
  `oc patch apiserver.config.openshift.io cluster --type=json -p '[{"op":"remove","path":"/spec/servingCerts/namedCertificates"}]'`.
  This triggers one more kube-apiserver revision. If `oc` is already broken, use the `--tls-server-name=api-int…` command from step 0.
- **Issuer:** `cert-manager-acme-issuer: 'false'`, then delete the ClusterIssuer and remove `overrideArgs` from `CertManager/cluster`.
- **AWS:** `aws iam delete-access-key …`, `delete-user-policy`, `delete-user`. Then delete `secrets/route53-dns01.json`.

## Risks

- **`oc` and scripts break on the API change** unless step 0 is done. A rebuilt cluster gets a fresh installer kubeconfig and needs step 0 again.
- **Rate limits** (letsencrypt.org/docs/rate-limits). The registered domain is **`opentlc.com`** (not on the Public Suffix List), so the **50 new certs per 7 days** limit is shared with every RHDP sandbox. crt.sh shows heavy Let's Encrypt *and* ZeroSSL issuance under `sandbox141` alone. Renewals are exempt. Separately, **5 certs per 7 days for an identical name set** limits how often a cluster rebuilt under the same name can re-issue. Use staging while iterating. ZeroSSL with EAB, the example in #236, is the fallback CA.
- **Staging on live endpoints** degrades `authentication` and the console. Use staging only on the throwaway cert.
- **Rollouts:** one kube-apiserver revision (about 10–20 min across three masters) and one router rolling update. Do them one at a time. Do not stack other config changes during the rollout.
- **Silent failures in the AutoShift shape:** an issuer that never goes Ready leaves the cluster on its old certs and reports nothing loud. The `-ready` inform policies are the only signal. Let's Encrypt stopped sending expiry emails in 2025.
- **Wildcard requires DNS-01.** HTTP-01 cannot issue `*.apps`.
- **Future spokes** register against `api.` on the hub. With a public cert on the hub API, check ACM 2.17's hub kube-apiserver verification strategy in `KlusterletConfig` (*Clusters* book). `local-cluster` uses `kubernetes.default.svc`, and Argo CD uses in-cluster, so neither is affected today.

## Citations

- *Security and compliance*, OpenShift 4.22, chapter 11 cert-manager Operator: §11.6.1 Authenticate on AWS; §11.7.3 ACME issuer with explicit credentials for AWS Route53; §11.7.4 ambient credentials on AWS; §11.8 Create certificates for the API server and for the Ingress Controller. https://access.redhat.com/documentation/en-us/openshift_container_platform/4.22/html-single/security_and_compliance/index
- Same book: §3.1.2 *Replace the default ingress certificate* (`#replacing-default-ingress_replacing-default-ingress`, which covers the hot reload on renewal). §3.2 *Add an API server named certificate* (the first add rolls a revision; never `api-int`) and §3.2.2 renew (`#customize-certificates-api-renew-named_api-server-certificates`).
- KB 5444001 (append CA to kubeconfig after a custom API cert), KB 7010382 (modify system:admin kubeconfig), KB 4878721 (login x509 is the *ingress* cert's trust).
- Let's Encrypt: rate limits https://letsencrypt.org/docs/rate-limits/, staging https://letsencrypt.org/docs/staging-environment/.
- cert-manager Route 53 solver (upstream IAM policy): https://cert-manager.io/docs/configuration/acme/dns01/route53/
- Upstream PR https://github.com/auto-shift/autoshiftv2/pull/236

## Open questions

1. ACME account email: `danclark@redhat.com`?
2. Let's Encrypt or ZeroSSL? Given the shared `opentlc.com` limit, should the production issuer be ZeroSSL (EAB) from the start? RHDP seems to use it.
3. Phase 2: switch to CCO-minted ambient credentials (`CredentialsRequest` + Subscription env, with `policyCondition` scoping)? That removes the human-held key. It is also a candidate upstream PR.
4. Push the #236 review upstream (with the `clusters/_example.yaml` fix) rather than carry it in the fork?
5. Should step 0 (ISRG roots into the kubeconfig) become part of `10-deploy-cluster.sh` or a cert script, so rebuilds get it?
6. Can the sandbox account create IAM users? It was not checked; the plan stays read-only.
7. Is P-384 acceptable for every client of `maas.apps` (it is the fork's FIPS choice), or make the key algorithm configurable?
