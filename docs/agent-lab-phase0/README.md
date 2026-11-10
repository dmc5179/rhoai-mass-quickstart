# agent-lab: phase 0 of the AI pipelines and workbenches design

The manual proof from [../ai-pipelines-workbenches-design.md](../ai-pipelines-workbenches-design.md)
("Phased plan", phase 0), built on sandbox141 (RHOAI 3.5.2, OpenShift 4.22) on 2026-11-09 from the
CLI rather than the dashboard, so that every step is repeatable and becomes the template for the
`openshift-ai-projects` policy.

| Step | Result |
|---|---|
| S3: bucket + prefix-limited IAM user | **Changed to one bucket per project.** The pipeline server's object-store check calls HeadBucket, which AWS authorizes as `s3:ListBucket` on the whole bucket, so a shared bucket with a folder per project fails with `Access Denied` (`ObjectStoreAvailable=False`). Bucket `rhoai-<account>-agent-lab`, public access blocked, SSE-S3; IAM user `rhoai-dspa-agent-lab` limited to that bucket; keys in `secrets/pipelines-s3-agent-lab.env` (0600) and Secret `agent-lab/pipelines-s3` |
| Project | Namespace `agent-lab`, label `opendatahub.io/dashboard: "true"` |
| Pipeline server | [dspa.yaml](dspa.yaml): Kubernetes pipeline store (the dashboard default), built-in MariaDB, external S3. Ready in about 3 minutes; `ManagedPipelineValid` is `NotApplicable` without AutoML/AutoRAG |
| Workbench | [notebook-as-mutated.yaml](notebook-as-mutated.yaml): Jupyter Data Science CPU 3.5, created as a `Notebook` with `notebooks.opendatahub.io/inject-auth: "true"`; the controller injected `kube-rbac-proxy`. Because the pipeline server existed first, the controller created Secret `ds-pipeline-config` and mounted `/opt/app-root/runtimes/odh_dsp.json` with the right API endpoint, S3 endpoint, bucket and engine (Argo) |
| MaaS from the notebook | **Works with default TLS verification.** The workbench sets `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` to `/etc/pki/tls/custom-certs/ca-bundle.crt`, which trusts the cluster's self-signed ingress, so `requests` reached `granite-4-tiny-gpu` (HTTP 200) with a 1h key minted as `maas-user` from a `user:info user:check-access` token. Key revoked afterwards |
| Pipeline run | `agent_lab_hello.py` (in the workbench home): two lightweight components on `registry.access.redhat.com/ubi9/python-312`, submitted with `kfp` 2.17.0 from the workbench to `https://ds-pipeline-dspa.agent-lab.svc.cluster.local:8443` with the workbench ServiceAccount token. **SUCCEEDED in 80 s**; executor logs written to the project bucket |
| Footprint | etcd 221 to 222 MiB. 13 pods in the project. One worker went from 41% to 57% of CPU requested (the workbench requests 1 CPU, the pipeline server the rest) |

Notes for the policy:

- `kfp` lightweight components read their function source, so a pipeline must come from a file or
  notebook, not from stdin.
- The workbench in RHOAI 3.x is served through the data-science gateway, not an OpenShift Route;
  the dashboard shows its link. The pipeline server gets two Routes (`ds-pipeline-dspa`,
  `ds-pipeline-md-dspa`).
- The exported Notebook is the controller-mutated form: drop the injected sidecar and generated
  fields when turning it into a template.

Still to do by hand in the dashboard (UI only): open the workbench, run Elyra's hello-world
pipeline with a DNS-compliant name, and check Kale shows "connected".

## Teardown

```bash
oc delete project agent-lab
. secrets/aws.env
aws s3 rm s3://rhoai-130382331273-agent-lab --recursive
aws s3api delete-bucket --bucket rhoai-130382331273-agent-lab
for k in $(aws iam list-access-keys --user-name rhoai-dspa-agent-lab --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name rhoai-dspa-agent-lab --access-key-id "$k"; done
aws iam delete-user-policy --user-name rhoai-dspa-agent-lab --policy-name s3-agent-lab-bucket
aws iam delete-user --user-name rhoai-dspa-agent-lab
rm -f secrets/pipelines-s3-agent-lab.env
```

The bucket and IAM user are outside the cluster and the VPC stack, so `90-destroy-cluster.sh` does
not remove them. Run this before tearing the cluster down for the FIPS rebuild.
