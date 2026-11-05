# RHOAI 3.5.2 disconnected: what the "additional images" are for

Red Hat's disconnected install helper for RHOAI 3.5.2 tells you to mirror 48
`additionalImages` on top of the `rhods-operator` bundle. Together they add
about **212 GB** of layers that the operator's own mirror doesn't already
contain. This page explains what each of those images is for, and which ones a
given site needs.

**The short answer:** a fresh RHOAI 3.5.2 install serving models through MaaS
needs **none** of the 48. All 48 are accounted for:

- **42 are only needed after an upgrade.** RHOAI creates older version tags on
  its ImageStreams, and these are the images behind those tags.
- **6 are images for workloads you might run** (Ray and fine-tuning).

None of them is needed by a fresh install and missing from the operator bundle.

Annotated copy of Red Hat's file:
[`disconnected/reference/rhoai-3.5.2-imagesetconfig-helper-annotated.yaml`](../disconnected/reference/rhoai-3.5.2-imagesetconfig-helper-annotated.yaml).
All 48 entries there are commented out, which suits a fresh install. They are
grouped A to E, each group with an "UNCOMMENT IF" line, and every entry names
the ImageStream tag that references it.

Investigated 2026-11-04 against the `redhat-operator-index:v4.22` catalog,
`rhods-operator.3.5.2`. The findings come from reading the bundle and the images
it deploys. **Nothing here has been tested on a disconnected cluster yet**; see
[confirming it](#confirming-it-on-a-disconnected-build).

## The three categories

Sizes are compressed layer sizes for linux/amd64, deduplicated by layer digest,
which is how `oc-mirror` v2 counts them.

### 1. Only needed after an upgrade: 42 images, ~170 GB

Each RHOAI workbench ImageStream carries the current version plus older ones.
For example, the Jupyter minimal ImageStream `s2i-minimal-notebook` that 3.5.2
creates:

| Tag | Annotation | Image comes from |
|---|---|---|
| `3.5` | `workbench-image-recommended: 'true'` | the bundle (`RELATED_IMAGE_*`): **mirrored with the operator** |
| `3.4` | `recommended: 'false'` | `additionalImages` |
| `2025.2` | `recommended: 'false'` | `additionalImages` |
| `2025.1` | `image-tag-outdated: "true"` | `additionalImages` |

The older tags exist so that a workbench created on an earlier release, and
pinned to that tag, still starts after the upgrade. On a new cluster nothing is
pinned to them.

| Generation | Images | Size | Contents |
|---|---|---|---|
| `3.4` (previous release) | 14 | ~49.7 GB | the `3.4` tag on all 11 workbench ImageStreams, plus `training-hub-universal-{cuda,rocm,cpu}:3.4` |
| `2025.2` | 18 | ~72.5 GB | the `2025.2` tag on all 11 workbench ImageStreams, plus the 7 `runtime-*-2025-2` pipeline-runtime ImageStreams. Kept in 3.5 for RHAIRFE-895; slated to drop in 3.6 |
| `2025.1` | 10 | ~46.9 GB | py311 workbenches. The tag is marked outdated, and the source list labels them deprecated |

- **Fresh install:** skip all 42.
- **Upgrading from 3.4 with active workbenches:** the 14 `3.4` images are the
  ones most likely to matter.
- **`2025.x` images:** keep only if someone still has workbenches or pipelines
  on those versions.

### 2. Needed by a fresh install but not in the bundle: none

The images behind the current tags are all declared in the bundle's
`relatedImages` and mirror with `rhods-operator`:

- current workbench images
- current pipeline runtimes
- `3.5` training-hub images
- every MaaS image: `maas-api`, `maas-controller`, payload processing, the
  key-cleanup image, and the usage-logs proxy (`ubi9/python-312`)

The 42 images in category 1 *are* missing from the bundle (see
[the bug](#is-this-a-bug-yes-for-the-42)), but none of them is needed for a
fresh install.

### 3. Images for workloads you choose to run: 6 images, ~42.6 GB

| Image | Tag | Needed only if |
|---|---|---|
| `quay.io/modh/ray` ×5 | `2.52.1-py311-cu121`, `2.55.1-py312-cu128`, `2.55.1-py312-cu129-th081`, `2.52.1-py311-rocm61`, `2.55.1-py312-rocm64` | users create Ray clusters (CodeFlare SDK) |
| `quay.io/modh/fms-hf-tuning` | `v3.1.0` | users run fine-tuning on this image with Kubeflow Training Operator v1, which RHOAI 3.5 lists as **Deprecated** (RHOAIENG-37682) |

Nothing RHOAI deploys references these. The KubeRay controller that runs Ray
clusters is in the bundle; these are the images the Ray clusters themselves run.
Both repositories are on `quay.io`, not `registry.redhat.io`, so the mirror host
needs access to quay.io.

## For a MaaS site

None of the 48 is involved in serving models through MaaS. Leaving out all 48
saves about 212 GB. Adding back only the 14 `3.4` images for an upgrading site
keeps the saving at about 162 GB.

Our own imagesets (`disconnected/imageset-config-rhoai-3.5.2-ocp4.2{1,2}.yaml`)
added three things the helper list doesn't. None of them is a RHOAI bundle bug:

| Our extra | Bug? | Why |
|---|---|---|
| vLLM runtime `rhaii/vllm-cuda-rhel9@sha256:5800e12b…` | **No. It was our stale pin, fixed 2026-11-05** | The bundle already declares a vLLM CUDA runtime: `RELATED_IMAGE_RHAII_VLLM_CUDA_IMAGE` = `…@sha256:fd9540f3…`, labelled `version=3.5.2`, plus ROCm, CPU, Gaudi and Spyre variants. Ours was labelled `version=3.4.1`. It had been pinned on 2026-10-17 to replace a nonexistent `:3.0` tag (autoshiftv2 `5bc08b88`), not chosen for its version. `config.openshiftAiModels[].image` now points at `fd9540f3…`, and both imagesets have dropped the entry, since the image mirrors with `rhods-operator`. The `rhoai-maas-guide` submodule still pins `5800e12b…`, because it is upstream content we don't edit |
| the model ModelCar | No | Model choice is the customer's. No bundle can know it |
| Service Mesh 3.3.1 (`servicemeshoperator3`) | **Not a RHOAI bug** | See below |

### Service Mesh is OpenShift's dependency, not RHOAI's

RHOAI doesn't install Service Mesh. RHOAI needs the Gateway API, and on
OpenShift 4.21 and 4.22 the **cluster ingress operator** provides it. That
operator, part of OpenShift itself, installs `servicemeshoperator3` to get
Istio. The pinned version is named in its own environment
(`GATEWAY_API_OPERATOR_VERSION=servicemeshoperator3.v3.3.1`), and the Istio
images are not in the release payload. That makes it an OpenShift-to-OLM
relationship that RHOAI can't declare. Dependency metadata wouldn't fix it
either:

- **OLM v1 doesn't support dependencies at all.** From *Extensions*, OpenShift
  4.22, §5.1.1: "OLM v1 does not support Operators that declare dependencies by
  using file-based catalog properties", meaning `olm.gvk.required`,
  `olm.package.required` and `olm.constraint`. An operator that declares them
  can't be installed as a ClusterExtension.
- **OLM v0 (Classic) does resolve dependencies on the cluster, but `oc-mirror`
  doesn't follow them.** Connectivity Link shows this: its bundle pins
  `authorino-operator`, `dns-operator` and `limitador-operator` with
  `olm.package.required`, and we still have to list all three in the imageset
  by hand.

If there is a gap, it belongs to OpenShift: whether the OpenShift disconnected
documentation tells customers that the Gateway API needs `servicemeshoperator3`
mirrored at a specific version. That hasn't been checked.

**This may be changing, and needs checking.** Red Hat solution 7143483 (updated
2026-08-21) says that under OCPBUGS-82146 and OCPBUGS-82147 the ingress operator
"no longer automatically installs or manages the Service Mesh Operator
subscription when Gateway API is enabled". It names 4.21.22 and 4.20.31 as
fixed. That conflicts with what we recorded on 4.21.37 and 4.22.18, where the
ingress operator still carries `GATEWAY_API_OPERATOR_VERSION`. Either it now
deploys Istio without OLM, in which case the `servicemeshoperator3` entry may be
unnecessary but the Istio images still have to come from somewhere, or the
solution describes a narrower change. Check on the next cluster with:

```bash
oc get subscriptions.operators.coreos.com -A | grep servicemesh
oc get deploy ingress-operator -n openshift-ingress-operator \
  -o jsonpath='{.spec.template.spec.containers[*].env}' | tr ',' '\n' | grep -i -e GATEWAY -e ISTIO
oc get pods -n openshift-ingress -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u
```

## What happens if you leave them out

- **Older ImageStream tags fail to import.** The dashboard may still offer
  `3.4` or `2025.2` as a version you can pick, and a workbench started on it
  won't pull its image. The `2025.1` tags are marked outdated, so they are
  probably hidden.
- **Ray and fine-tuning jobs fail to pull**, unless the user points them at an
  image that is mirrored.
- **Nothing else is expected to break.** One thing is unverified: whether failed
  tag imports surface anywhere as Degraded, rather than as noise.

## Is this a bug? Yes, for the 42

`oc-mirror` decides which images to copy for an operator from the bundle's
`relatedImages`. In both places checked, the image for each **current** tag is
wired through a `RELATED_IMAGE_*` variable and is declared. Each **older** tag is
a hardcoded digest in a `params.env` file and is not:

| Where | Undeclared digests |
|---|---|
| workbenches module image `odh-workbenches-operator-rhel9`, `/opt/manifests/workbenches/notebooks/rhoai/base/params.env` | 39 (all workbench and pipeline-runtime older tags) |
| rhods-operator image `odh-rhel9-operator`, `/opt/manifests-template/trainer/rhoai/params.env` | 3 (training hub `3.4`) |

RHOAI creates these references on every cluster but doesn't declare them. The
gap is closed by hand, through a separately maintained list in another
repository (`red-hat-data-services/rhoai-additional-images`, `rhoai-3.5`,
`rhoai-disconnected-images.yaml`). The disconnected helper copies that list
verbatim. Draft:
`bug-rhods-operator-relatedimages-missing-older-imagestream-tags.md` (moved to `~/workspace/redhat-research/rhoai-mass-disconnected/handoff/`)
(RHOAIENG).

Fixing that bug shortens the list to 6 entries but doesn't shrink the mirror:
the 42 images would move into the operator's own mirror set. Making the older
generations optional is a product decision. The RFE draft asks for it:
`rfe-rhoai-disconnected-additional-images.md` (moved to `~/workspace/redhat-research/rhoai-mass-disconnected/handoff/`).

## Is the Ray omission a bug? Arguably, yes

The argument that it isn't a bug: `relatedImages` lists what an operator
*deploys*. Ray images are chosen in user code, the same as any base image a user
picks, and the operator never starts one on its own. The RHOAI 3.5 docs also put
this on the customer. The prerequisites for *Running distributed data science
workloads in a disconnected environment* (§4.3) include "You can access the
following software from the disconnected cluster: A Ray cluster image".

The RHOAI 3.5 documentation (*Accelerate data processing and training with
distributed workloads*) undercuts that position in three places:

1. **§2.3.1, "About base training images":** "The following table lists the
   training images that are **installed with Red Hat OpenShift AI by default**",
   followed by Ray CUDA and Ray ROCm. An image documented as installed by
   default, but absent from the bundle, is a packaging defect or a
   documentation defect. Either way it's a defect.
2. **§4.1.2:** if the user sets no image, the CodeFlare SDK falls back to a
   default `quay.io/modh/ray` image. That SDK ships inside Red Hat's own
   workbench images. So in a disconnected cluster, a Red Hat-supplied default
   points at an image that only mirrors if the customer finds a separate list.
   The tags that section names (`2.35.0-py39-cu121`, `2.47.1-py311-cu121`)
   don't match any of the five on the 3.5.2 list (`2.52.1`/`2.55.1`). Either the
   docs are stale, or the SDK default and the mirror list disagree. That needs
   checking against the SDK in the 3.5 workbench images.
3. **The images are served from `quay.io/modh`.** A supported product default
   outside `registry.redhat.io` is unusual. It also means a mirror needs a second
   registry's credentials and egress.

**Recommendation:** file the Ray images as a bug. Either they belong in
`relatedImages`, which bundles may list even for images the operator doesn't
start, or the documentation must stop saying "installed by default" and name
the images a disconnected site has to mirror for Ray. If engineering's answer is
"workload images are out of scope by design", the bug becomes a documentation
bug rather than going away. Draft, for RHOAIENG so that engineering makes the
call before it goes to documentation:
`bug-rhoai-ray-images-not-in-bundle.md` (moved to `~/workspace/redhat-research/rhoai-mass-disconnected/handoff/`).

`fms-hf-tuning` is a weaker case. It serves the Kubeflow Training Operator v1,
which RHOAI 3.5 lists as Deprecated, so it belongs in the RFE's optional and
deprecated tier rather than in a bug.

## How the list is produced

- The documentation (*Deploy or decommission OpenShift AI in disconnected
  environments*, §3.2) sends customers to
  `red-hat-data-services/rhoai-disconnected-install-helper`.
- That repository's script (`rhoai-z-dih.sh`, `find_images`) reads
  `.additional-images[]` from `red-hat-data-services/rhoai-additional-images`,
  branch `rhoai-<x.y>`, file `rhoai-disconnected-images.yaml`.
- For 3.3 and later it filters out only old `quay.io/modh` notebook
  repositories. For 3.5.2 the published list equals the source file exactly.
- The source file groups the images under comments (deprecated, RHAIRFE-895,
  RHOAIENG-75433, RHOAIENG-37682). Those comments don't reach the published
  file.

## oc-mirror does deduplicate these layers

A belief worth correcting: `oc-mirror` v2 does **not** transfer
`additionalImages` without deduplication. `CollectAll` merges release,
operator, additional and Helm images into one list. The archive builder
(`internal/pkg/archive/archive.go`, `addBlobsDiff`) skips any layer already in
history or already added. The 212 GB is genuinely new content: older and
current workbench generations share essentially no layers.

A practical consequence: a site that mirrored 3.5.1 with the same oc-mirror
workspace should transfer little extra for 3.5.2 if the older-tag digests are
unchanged. That hasn't been checked against the 3.5.1 list.

## Method

1. Rendered the `rhods-operator` 3.5.2 bundle from
   `redhat-operator-index:v4.22`. `oc-mirror --v2 --dry-run` for that package
   alone produces 138 images. The CSV declares 136 unique digests.
2. Extracted `/opt` from the operator image
   `registry.redhat.io/rhoai/odh-rhel9-operator@sha256:ae88dfb2…` and the full
   filesystem of the workbenches module image
   `registry.redhat.io/rhoai/odh-workbenches-operator-rhel9@sha256:231bb584…`.
3. Compared every `registry.redhat.io/…@sha256:` reference in them with the
   CSV's `relatedImages`.
4. Mapped each `params.env` key to the ImageStream tag that consumes it through
   its `…_PLACEHOLDER` name.
5. Sized layers with `skopeo inspect --raw`, linux/amd64 manifest, deduplicated
   by digest.

Not yet checked: the other component module images (dashboard, pipelines and so
on). They may hold further undeclared references. That wouldn't change anything
above about the 48, but it limits how complete the bundle can be called.

## Confirming it on a disconnected build

Mirror with none of the 48, install, then:

```bash
oc get pods -A | grep -E 'ImagePull|ErrImage'
oc get imagestreams -n redhat-ods-applications -o json \
  | jq -r '.items[] | .metadata.name as $n | .status.tags[]? | select(.conditions[]?.status=="False") | "\($n):\(.tag)"'
```

Expected:

- no pods failing to pull
- import failures only on the `3.4`, `2025.2`, `2025.1` and `*-2025-2` tags
- no Degraded conditions on RHOAI components caused by them

A result like that is the missing evidence for both Jira drafts.

## Ownership

Since 2026-11-05 this topic, including the Jira drafts and the planned tests, is
owned by the `rhoai-mass-disconnected` work in
`~/workspace/redhat-research/rhoai-mass-disconnected/`. This page is a snapshot
of the findings as of the handoff.
