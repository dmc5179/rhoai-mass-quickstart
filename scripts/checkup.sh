#!/usr/bin/env bash
#
# checkup.sh - walk the whole RHOAI MaaS chain in dependency order and report
#              the first place it breaks.
#
# Usage: scripts/checkup.sh [--section <name>] [--quiet]
#
# Options:
#   --section <name>  Run one section only: cluster, autoshift, policies, workloads,
#                     operators, gpu, maas, load
#   --quiet           Only print problems and the summary
#
# Read-only. Changes nothing, installs nothing.
#
# Why this exists. The stack is ACM, GitOps, five operators and three custom
# resources deep, and almost none of its failures announce themselves. What we
# actually hit, in one day:
#
#   - a policy that was never PLACED, so it had no status at all and appeared
#     in no list of NonCompliant policies
#   - a policy reporting Compliant while its template resolved to nothing
#   - a CSV in Failed with UnsupportedOperatorGroup, while the policy said only
#     "the ClusterServiceVersion required by the policy was not found"
#   - a GPU node that was Ready and schedulable and advertised no GPU, because
#     NFD labelled by PCI class instead of vendor
#   - a ClusterPolicy that was never created, because one field in it did not
#     exist in the installed CRD
#
# Every one looked healthy from one level up. So this checks for things that
# are silently ABSENT, not just things that report failure, and it walks the
# chain in order so the output names the first broken link rather than the
# twenty things downstream of it.
#
# It also checks what this stack is pinned to, because a drifted pin looks
# healthy too: RHOAI exactly rhods-operator.3.5.2; Connectivity Link 1.5.x with
# its CONNLINK-1878 memory override and every KuadrantControlPlane component
# up; MaaS switched on in the DSC; the endpoint picker fix from solution
# 7148630; and each model's live vLLM image against the one the RHOAI bundle
# declares.

set -uo pipefail   # deliberately not -e: a failing probe is a finding

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION=""
QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --section) SECTION="$2"; shift 2 ;;
        --quiet)   QUIET=1; shift ;;
        -h|--help) sed -n '2,39p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "checkup.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
[ -f "$KUBECONFIG" ] || { echo "Error: no kubeconfig at ${KUBECONFIG}." >&2; exit 1; }
export KUBECONFIG

# MachineSets, Machines and Applications all have ambiguous short names once
# ACM is installed: it brings in Cluster API and app.k8s.io, whose resources
# share them. oc then resolves to the empty one and reports "No resources
# found" on a cluster that plainly has them. Always fully qualified here.
MS="machinesets.machine.openshift.io"
APP="applications.argoproj.io"

FIRST_BREAK=""
PROBLEMS=0

ok()   { [ "$QUIET" -eq 1 ] || printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { [ "$QUIET" -eq 1 ] || printf '    %s\n' "$1"; }
bad()  {
    printf '  \033[31m✗\033[0m %s\n' "$1"
    [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^[[:space:]]*//; s/^/      /'
    PROBLEMS=$((PROBLEMS + 1))
    [ -z "$FIRST_BREAK" ] && FIRST_BREAK="$1"
    return 0
}
warn() { printf '  \033[33m!\033[0m %s\n' "$1"
         [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^[[:space:]]*//; s/^/      /'
         return 0; }
head_() { [ "$QUIET" -eq 1 ] || printf '\n\033[1m%s\033[0m\n' "$1"; }
run()  { timeout 90 "$OC" "$@" 2>/dev/null; }
want() { [ -z "$SECTION" ] || [ "$SECTION" = "$1" ]; }

# Feed "LEVEL|title|detail" lines from a probe into ok/warn/bad/info. Read from
# a here-string, never a pipe: a pipe runs this in a subshell and the PROBLEMS
# and FIRST_BREAK it sets would be lost.
report() {
    local lvl title detail
    while IFS='|' read -r lvl title detail; do
        case "$lvl" in
            OK)   ok "$title" ;;
            INFO) info "$title" ;;
            WARN) if [ -n "$detail" ]; then warn "$title" "$detail"; else warn "$title"; fi ;;
            BAD)  if [ -n "$detail" ]; then bad "$title" "$detail"; else bad "$title"; fi ;;
        esac
    done
    return 0
}

# Scratch space for probes that compare two documents. Holds cluster JSON only.
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# What this stack is pinned to. The RHOAI pin is openshift-ai-version in the
# AutoShift hub values; the Connectivity Link minor comes from
# connectivity-link-channel: stable-1.5.
RHOAI_CSV_WANT="rhods-operator.3.5.2"
RHCL_MINOR_WANT="1.5"
RHCL_NS="openshift-operators"
# The vLLM CUDA runtime the rhods-operator 3.5.2 bundle declares
# (RELATED_IMAGE_RHAII_VLLM_CUDA_IMAGE). Used only if the CSV cannot be read;
# otherwise the expected image is taken from the installed CSV itself.
VLLM_IMAGE_FALLBACK="registry.redhat.io/rhaii/vllm-cuda-rhel9@sha256:fd9540f3882b9aae5f862eba6c295d0e9c6b43f8c17b27b179481bfa330bfbc1"

SUB="subscriptions.operators.coreos.com"
CSV="clusterserviceversions.operators.coreos.com"
DEPLOY="deployments.apps"
POLICY="policies.policy.open-cluster-management.io"
DSC="datascienceclusters.datasciencecluster.opendatahub.io"
EF="envoyfilters.networking.istio.io"

# "<namespace> <installedCSV> <currentCSV>" of the RHOAI Subscription, or nothing.
rhoai_sub() {
    run get "$SUB" -A -o json | python3 -I -c 'import json,sys
for s in json.load(sys.stdin)["items"]:
    if s.get("spec",{}).get("name")=="rhods-operator":
        st=s.get("status") or {}
        print(s["metadata"]["namespace"], st.get("installedCSV") or "-", st.get("currentCSV") or "-")
        break' 2>/dev/null
}

# "<name> <version> <phase>" of the Connectivity Link CSV, or nothing.
rhcl_csv() {
    run get "$CSV" -n "$RHCL_NS" -o json | python3 -I -c 'import json,sys
for c in json.load(sys.stdin)["items"]:
    if c["metadata"]["name"].startswith("rhcl-operator."):
        print(c["metadata"]["name"], c.get("spec",{}).get("version") or "?", (c.get("status") or {}).get("phase") or "?")
        break' 2>/dev/null
}

run get --raw /readyz >/dev/null || { echo "Error: cluster API not reachable." >&2; exit 1; }

# --- cluster ----------------------------------------------------------------
if want cluster; then
    head_ "Cluster"
    nr="$(run get nodes --no-headers | grep -cv ' Ready ')"
    tot="$(run get nodes --no-headers | wc -l)"
    if [ "${nr:-1}" -eq 0 ]; then ok "all ${tot} nodes Ready"
    else bad "${nr} of ${tot} nodes not Ready" "$(run get nodes --no-headers | grep -v ' Ready ' | awk '{print $1" "$2}' | head -3)"; fi

    mcp_bad="$(run get mcp --no-headers | awk '$3!="True"||$5=="True"{print "  "$1" updated="$3" degraded="$5}')"
    if [ -z "$mcp_bad" ]; then ok "MachineConfigPools settled"
    else bad "MachineConfigPool not settled" "$mcp_bad"
         info "A rolling MachineConfig blocks CPMS changes — see solution 7132901"; fi

    co_bad="$(run get co --no-headers | awk '$3!="True"||$4!="False"||$5!="False"{print $1}' | tr '\n' ' ')"
    if [ -z "$co_bad" ]; then ok "all cluster operators healthy"
    else bad "cluster operators unhealthy: ${co_bad}"
         info "If several are degraded at once, check 'load' before debugging any of them"; fi

    # FIPS, from what the cluster records rather than from a node: the
    # install-config's `fips`, and each pool's rendered MachineConfig, whose
    # spec.fips is what makes its nodes boot with fips=1. Reading a node's
    # /proc/sys/crypto/fips_enabled would need `oc debug`, which creates a pod,
    # and this script changes nothing. FIPS cannot be switched after install,
    # so a mismatch with cluster.env means the cluster predates the setting or
    # was built with --no-fips, not that anything is broken.
    ic_fips="$(run get configmap cluster-config-v1 -n kube-system -o jsonpath='{.data.install-config}' \
               | awk -F': *' '$1=="fips"{print $2}')"
    ic_fips="${ic_fips:-false}"
    pool_fips="$(run get mcp -o json | OC="$OC" python3 -I -c '
import json, subprocess, sys, os
oc = os.environ.get("OC", "oc")
for p in json.load(sys.stdin)["items"]:
    rendered = (p.get("spec", {}).get("configuration") or {}).get("name", "")
    out = subprocess.run([oc, "get", "machineconfig", rendered, "-o", "jsonpath={.spec.fips}"],
                         capture_output=True, text=True, timeout=60).stdout.strip() if rendered else ""
    print(p["metadata"]["name"] + "=" + (out or "false"))' 2>/dev/null | tr '\n' ' ')"
    if [ "$ic_fips" = "true" ]; then
        if grep -q '=false' <<<"$pool_fips"; then
            bad "FIPS requested at install, but not every pool renders it: ${pool_fips}"
        else
            ok "FIPS mode: on (install-config; rendered MachineConfigs: ${pool_fips% })"
        fi
    else
        ok "FIPS mode: off"
    fi
    if [ "${FIPS:-}" = "true" ] && [ "$ic_fips" != "true" ]; then
        info "cluster.env now defaults to FIPS=true; this cluster was built without it (install-time only)."
    fi
fi

# --- autoshift plumbing -----------------------------------------------------
if want autoshift; then
    head_ "AutoShift"
    mc="$(run get managedcluster --no-headers | awk '{print $1}' | head -1)"
    if [ -z "$mc" ]; then bad "no ManagedCluster — ACM not installed, or bootstrap incomplete"
    else
        cs="$(run get managedcluster "$mc" -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}')"
        if [ -z "$cs" ] || [ "$cs" = "default" ]; then
            bad "${mc} is in clusterset '${cs:-<none>}'" "Run: scripts/50-autoshift.sh adopt"
        else ok "${mc} in clusterset '${cs}'"; fi

        n="$(run get managedcluster "$mc" -o json | python3 -I -c 'import json,sys;print(sum(1 for k in json.load(sys.stdin)["metadata"]["labels"] if k.startswith("autoshift.io/")))' 2>/dev/null)"
        [ "${n:-0}" -gt 0 ] && ok "${n} autoshift.io labels stamped" \
                            || bad "no autoshift.io labels on ${mc}" "cluster-labels policy has not run"
    fi

    appbad="$(run get "$APP" -n openshift-gitops --no-headers | awk '$2!="Synced"||$3!="Healthy"{print "  "$1" "$2"/"$3}')"
    if [ -z "$appbad" ]; then ok "all ArgoCD Applications Synced and Healthy"
    else warn "ArgoCD Applications not Synced/Healthy" "$appbad"
         info "Policies come from Git. An unsynced app means your last push is not live."; fi
fi

# --- policy placement -------------------------------------------------------
# The quietest failure in the stack. An enabled policy whose Placement does not
# match has NO compliance status at all, so it appears in no list of
# NonCompliant policies and reads as healthy from every angle.
if want policies; then
    head_ "Policy placement"
    mc="$(run get managedcluster --no-headers | awk '{print $1}' | head -1)"
    if [ -n "$mc" ]; then
        placed="$(run get policy -n "$mc" --no-headers | wc -l)"
        root="$(run get policy -n policies-autoshift --no-headers | wc -l)"
        ok "${placed} policies placed on ${mc} (of ${root} defined)"
        # Listing every unplaced policy is noise: most are simply switched off.
        # The interesting case is a Placement where every predicate matches
        # this cluster EXCEPT one, which means the policy is enabled but can
        # never be placed. That is precisely what a cluster-type: spoke
        # predicate does on a self-managed hub.
        unplaced="$(OC="$OC" MC="$mc" python3 -I "${ROOT}/scripts/lib-placement-check.py")"
        if [ -n "$unplaced" ]; then
            bad "Placements that can never match this cluster" "$unplaced"
            info "Every other predicate on these matches, so the policy is enabled but"
            info "will never be placed. An unplaced policy has NO compliance status at"
            info "all, so it appears in no list of NonCompliant policies and reads as"
            info "healthy from every angle."
        else
            ok "no enabled policy is blocked by an unsatisfiable predicate"
        fi

        nc="$(run get policy -n "$mc" --no-headers | awk '$3=="NonCompliant"{print "  "$1}')"
        pend="$(run get policy -n "$mc" --no-headers | awk '$3=="Pending"{print "  "$1}')"
        [ -z "$nc" ] && ok "no NonCompliant policies" || bad "NonCompliant policies" "$nc"
        if [ -n "$pend" ]; then
            info "Pending (waiting on a dependency, not itself a failure):"
            printf '%s\n' "$pend" | sed 's/^[[:space:]]*//; s/^/      /'
        fi
    fi
fi

# --- operators --------------------------------------------------------------
if want operators; then
    head_ "Operators"
    csvbad="$(run get csv -A --no-headers | awk '$NF!="Succeeded" && $NF!="PHASE"{print "  "$1" "$2" "$NF}' | sort -u)"
    if [ -z "$csvbad" ]; then ok "all ClusterServiceVersions Succeeded"
    else
        bad "ClusterServiceVersions not Succeeded" "$csvbad"
        # By far the most common cause in this repo: six instances in one day.
        for ns_csv in $(run get csv -A --no-headers | awk '$NF=="Failed"{print $1"/"$2}'); do
            ns="${ns_csv%%/*}"; csv="${ns_csv##*/}"
            reason="$(run get csv "$csv" -n "$ns" -o jsonpath='{.status.reason}')"
            if [ "$reason" = "UnsupportedOperatorGroup" ]; then
                info "${csv}: UnsupportedOperatorGroup — the policy needs targetNamespaces."
                info "  Run scripts/check-operator-install-modes.sh for the full sweep."
            elif [ -n "$reason" ]; then
                info "${csv}: ${reason}"
            fi
        done
    fi

    # RHOAI pinned at exactly 3.5.2. The OperatorPolicy approves only the CSVs
    # in its versions list, so a newer z-stream shows up as a currentCSV or an
    # unapproved InstallPlan that never installs. That is the pin working, but
    # it is worth seeing before someone approves it by hand.
    read -r rns rinst rcur <<< "$(rhoai_sub)"
    if [ -z "${rns:-}" ]; then
        info "no rhods-operator Subscription (openshift-ai label off) — skipping RHOAI version"
    else
        rphase="$(run get "$CSV" "$rinst" -n "$rns" -o jsonpath='{.status.phase}')"
        if [ "$rinst" != "$RHOAI_CSV_WANT" ]; then
            bad "RHOAI installed CSV is '${rinst}', expected ${RHOAI_CSV_WANT}" \
                "The hub values pin openshift-ai-version: '${RHOAI_CSV_WANT}' on stable-3.x. Check policy-openshift-ai-operator-install."
        elif [ "$rphase" != "Succeeded" ]; then
            bad "${RHOAI_CSV_WANT} is ${rphase:-not found} in ${rns}, not Succeeded"
        else
            ok "RHOAI ${RHOAI_CSV_WANT} Succeeded"
        fi
        pending="$( { [ "$rcur" != "-" ] && [ "$rcur" != "$rinst" ] && echo "$rcur"
                      run get installplans.operators.coreos.com -n "$rns" -o json | python3 -I -c 'import json,sys
for p in json.load(sys.stdin)["items"]:
    if not p.get("spec",{}).get("approved", True):
        for c in p["spec"].get("clusterServiceVersionNames") or []: print(c)' 2>/dev/null
                    } | grep -vx -- "$RHOAI_CSV_WANT" | sort -u | paste -sd " ")"
        [ -n "$pending" ] && warn "newer RHOAI CSV offered but not installed: ${pending}" \
            "Expected while openshift-ai-version pins ${RHOAI_CSV_WANT}. Do not approve the InstallPlan by hand; move the pin in hub.yaml."
    fi

    # Connectivity Link 1.5: one CSV, and the CONNLINK-1878 memory override.
    read -r lname lver lphase <<< "$(rhcl_csv)"
    if [ -z "${lname:-}" ]; then
        info "no rhcl-operator CSV in ${RHCL_NS} (connectivity-link label off) — skipping"
    else
        case "$lver" in
            "${RHCL_MINOR_WANT}".*) ok "Connectivity Link ${lver} (${lname}, ${lphase})" ;;
            *) warn "Connectivity Link is ${lver}, expected ${RHCL_MINOR_WANT}.x" \
                    "The hub values select connectivity-link-channel: stable-${RHCL_MINOR_WANT}. On 1.4, Authorino, Limitador and DNS are separate CSVs and KuadrantControlPlane does not exist." ;;
        esac
        # OLM regenerates the Deployment from the CSV plus Subscription
        # spec.config, so the Deployment is where the override has to show.
        lim="$(run get "$DEPLOY" kuadrant-operator-controller-manager -n "$RHCL_NS" \
               -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')"
        subl="$(run get "$SUB" -n "$RHCL_NS" -o json | python3 -I -c 'import json,sys
for s in json.load(sys.stdin)["items"]:
    if s.get("spec",{}).get("name")=="rhcl-operator":
        print(((s["spec"].get("config") or {}).get("resources") or {}).get("limits",{}).get("memory",""))' 2>/dev/null)"
        if [ "$lim" = "2Gi" ]; then
            ok "kuadrant-operator-controller-manager memory limit 2Gi (CONNLINK-1878 override in place)"
        elif [ "$subl" = "2Gi" ]; then
            bad "kuadrant-operator-controller-manager memory limit is '${lim:-unset}' though the Subscription asks for 2Gi" \
                "OLM has not rolled the Deployment yet. Check: oc get ${CSV} ${lname} -n ${RHCL_NS} -o jsonpath='{.status.phase}'"
        else
            bad "kuadrant-operator-controller-manager memory limit is '${lim:-unset}', expected 2Gi" \
                "Without it the controller is OOMKilled on 1.5 (CONNLINK-1878). The connectivity-link policy sets it in the Subscription's spec.config.resources; check policy-rhcl-operator-install is Compliant. A hand patch to the Deployment is reset by OLM."
        fi
    fi
fi

# --- gpu chain --------------------------------------------------------------
if want gpu; then
    head_ "GPU chain"
    gms="$(run get "$MS" -n openshift-machine-api --no-headers | grep -c -- '-gpu-')"
    [ "${gms:-0}" -gt 0 ] && ok "${gms} GPU MachineSet(s)" \
        || warn "no GPU MachineSet" "Expected if autoshift.io/gpu-nodes is unset. Run scripts/45-autoshift-values.sh."

    gnodes="$(run get nodes -l node-role.kubernetes.io/gpu --no-headers | wc -l)"
    if [ "${gnodes:-0}" -eq 0 ]; then
        [ "${gms:-0}" -gt 0 ] && bad "GPU MachineSet exists but no GPU node" \
            "$(run get machines.machine.openshift.io -n openshift-machine-api --no-headers | grep -- '-gpu-' | awk '{print "  "$1" "$2}' | head -3)"
    else
        ok "${gnodes} GPU node(s)"
        # The label the GPU operator gates on. Labelling by PCI class instead of
        # vendor yields pci-0300/pci-0302 and the operator deploys nothing.
        vend="$(run get nodes -l feature.node.kubernetes.io/pci-10de.present=true --no-headers | wc -l)"
        if [ "${vend:-0}" -eq 0 ]; then
            bad "no node has feature.node.kubernetes.io/pci-10de.present" \
                "NFD is labelling by PCI class, not vendor. Set deviceLabelFields: [\"vendor\"]"
            info "The GPU operator gates every operand on this label and will deploy nothing."
        else ok "${vend} node(s) carry the NVIDIA vendor label"; fi

        cp="$(run get clusterpolicy --no-headers | wc -l)"
        if [ "${cp:-0}" -eq 0 ]; then
            bad "no ClusterPolicy" "The nvidia-gpu-operator policy could not create it."
            info "Common cause: a field in the manifest that the installed CRD does not define."
            info "Check: oc get policy -A | grep nvidia-gpu-cluster-policy"
        else ok "ClusterPolicy present"; fi

        cap="$(run get nodes -l node-role.kubernetes.io/gpu -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}')"
        if [ -z "$cap" ]; then
            bad "no node advertises nvidia.com/gpu" "Driver stack has not finished, or never started."
            info "A GPU node with no driver is Ready and schedulable and reports no GPU."
            info "Check: oc get pods -n nvidia-gpu-operator"
        else ok "nvidia.com/gpu capacity: ${cap}"; fi
    fi
fi

# --- maas chain -------------------------------------------------------------
if want maas; then
    head_ "RHOAI Models-as-a-Service"
    if ! run get crd datascienceclusters.datasciencecluster.opendatahub.io >/dev/null; then
        info "RHOAI not installed (openshift-ai label off) — skipping"
    else
        dsc="$(run get datasciencecluster --no-headers | awk '{print $1}' | head -1)"
        [ -n "$dsc" ] && ok "DataScienceCluster ${dsc}" || bad "no DataScienceCluster"

        # MaaS is switched on in the DSC by its own policy, which merges one
        # field into default-dsc after policy-openshift-ai-dsc is Compliant.
        if run get "$POLICY" policy-openshift-ai-maas-dsc -n policies-autoshift >/dev/null; then
            pc="$(run get "$POLICY" policy-openshift-ai-maas-dsc -n policies-autoshift -o jsonpath='{.status.compliant}')"
            case "$pc" in
                Compliant) ok "policy-openshift-ai-maas-dsc Compliant" ;;
                Pending)   warn "policy-openshift-ai-maas-dsc Pending" "Waits on policy-openshift-ai-dsc being Compliant." ;;
                "")        bad "policy-openshift-ai-maas-dsc has no status" "Not placed: check the openshift-ai-maas label (see Policy placement above)." ;;
                *)         bad "policy-openshift-ai-maas-dsc is ${pc}" ;;
            esac
        else
            bad "policy-openshift-ai-maas-dsc not defined" \
                "The AutoShift branch the hub reads predates it. Run: scripts/50-autoshift.sh refresh"
        fi
        ms="$(run get "$DSC" default-dsc -o jsonpath='{.spec.components.aigateway.modelsAsAService.managementState}')"
        if [ "$ms" = "Managed" ]; then ok "default-dsc aigateway.modelsAsAService Managed"
        else bad "default-dsc aigateway.modelsAsAService is '${ms:-unset}', expected Managed"; fi

        # Connectivity Link 1.5 deploys Authorino, Limitador, DNS and the MCP
        # Gateway itself, through a KuadrantControlPlane named 'default' that the
        # operator owns. Status only; never edit or delete it, which cascades.
        # The CRD's API group is looked up rather than assumed, so the resource
        # is always addressed by its full name.
        kcp="$(run get crd -o name | sed -n 's|^customresourcedefinition.apiextensions.k8s.io/\(kuadrantcontrolplanes\..*\)$|\1|p' | head -1)"
        read -r _ lver _ <<< "$(rhcl_csv)"
        if [ -z "$kcp" ]; then
            case "${lver:-}" in
                "${RHCL_MINOR_WANT}".*) bad "Connectivity Link ${lver} but no KuadrantControlPlane CRD" ;;
                *) info "no KuadrantControlPlane CRD (Connectivity Link ${lver:-absent}) — skipping" ;;
            esac
        else
            run get "$kcp" -A -o json > "$TMPD/kcp.json"
            run get "$DEPLOY" -A -o json > "$TMPD/deploy.json"
            report <<< "$(python3 -I - "$TMPD/kcp.json" "$TMPD/deploy.json" <<'PY' 2>/dev/null || echo "WARN|could not read KuadrantControlPlane status"
import json, sys
def load(p):
    try: return json.load(open(p))
    except Exception: return {"items": []}
kcp, deps = load(sys.argv[1]), load(sys.argv[2])
true = lambda v: str(v).lower() == "true"
cp = [i for i in kcp.get("items", []) if i["metadata"]["name"] == "default"]
if not cp:
    print("BAD|no KuadrantControlPlane named default|The Kuadrant operator creates it on 1.5; check kuadrant-operator-controller-manager logs. Never create it by hand.")
    sys.exit()
comps = (cp[0].get("status") or {}).get("components") or []
if not comps:
    print("BAD|KuadrantControlPlane default has no status.components|The operator has not reconciled it yet.")
    sys.exit()
nr = [c.get("name", "?") for c in comps if not true(c.get("ready"))]
print("BAD|KuadrantControlPlane components not ready: " + " ".join(nr) if nr else
      "OK|KuadrantControlPlane default: %d components ready" % len(comps))
crd = ["%s/%s" % (c.get("name", "?"), d.get("name", "?")) for c in comps
       for d in (c.get("crds") or []) if not true(d.get("established"))]
print("BAD|component CRDs not established: " + " ".join(crd) if crd else "OK|all component CRDs established")

def images(x):
    # images[] entries may be plain strings or objects; take anything image-shaped.
    if isinstance(x, str): return {x} if "/" in x else set()
    if isinstance(x, dict): return set().union(*[images(v) for v in x.values()]) if x else set()
    if isinstance(x, list): return set().union(*[images(v) for v in x]) if x else set()
    return set()
def same(a, b):
    return a == b or ("@" in a and "@" in b and a.split("@")[1] == b.split("@")[1])
def dep_images(d):
    s = d.get("spec", {}).get("template", {}).get("spec", {})
    return [c.get("image", "") for c in (s.get("containers") or []) + (s.get("initContainers") or [])]
def available(d):
    cond = {c["type"]: c["status"] for c in (d.get("status") or {}).get("conditions") or []}
    return cond.get("Available") == "True"

for want in ("authorino", "limitador", "dns", "mcp"):
    cs = [c for c in comps if want in c.get("name", "").lower()]
    if not cs:
        print("BAD|KuadrantControlPlane has no %s component|On Connectivity Link 1.5 it should deploy authorino, limitador, dns-operator and mcp-gateway." % want)
        continue
    for c in cs:
        name, imgs = c.get("name", "?"), images(c.get("images"))
        # Matched by the images the component reports, which needs no knowledge
        # of the Deployment's name; the component name is only a fallback.
        hit = [d for d in deps.get("items", []) if any(same(i, j) for i in imgs for j in dep_images(d))]
        if not hit:
            hit = [d for d in deps.get("items", []) if name.lower() in d["metadata"]["name"].lower()]
        if not hit:
            print("WARN|component %s: no Deployment found|Matched by its status images, then by name; look with: oc get deployments.apps -A | grep -i %s" % (name, want))
            continue
        ids = " ".join("%s/%s" % (d["metadata"]["namespace"], d["metadata"]["name"]) for d in hit)
        down = [d["metadata"]["name"] for d in hit if not available(d)]
        print("BAD|component %s: Deployment not Available: %s" % (name, " ".join(down)) if down else
              "OK|component %s: %s" % (name, ids))
PY
)"
        fi

        if run get crd kuadrants.kuadrant.io >/dev/null; then
            kr="$(run get kuadrant -A -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')"
            if [ "$kr" = "True" ]; then ok "Kuadrant Ready"
            else bad "Kuadrant not Ready" \
                 "$(run get kuadrant -A -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].reason}: {.items[0].status.conditions[?(@.type=="Ready")].message}')"; fi
        fi

        gw="$(run get gateway -A --no-headers | wc -l)"
        [ "${gw:-0}" -gt 0 ] && ok "${gw} Gateway(s)" || warn "no Gateway — MaaS has no entry point"

        # Red Hat solution 7148630. With Connectivity Link 1.4 or later the
        # endpoint picker runs before the model header exists, so requests
        # succeed but skip prefix-cache and load-aware scheduling. The MaaS fix
        # is backported to the 3.5 branch; whether 3.5.2 carries it is read off
        # the cluster: the fixed payload-processing EnvoyFilter has a REMOVE patch.
        if run get crd "$EF" >/dev/null; then
            if ! run get "$EF" payload-processing -n openshift-ingress >/dev/null; then
                warn "no payload-processing EnvoyFilter in openshift-ingress" "maas-controller creates it; cannot tell whether the solution 7148630 fix is present."
            # Read into a variable first: with pipefail, `oc ... | grep -q` reports
            # failure when grep exits on the first match and oc, still writing
            # this long object, gets SIGPIPE. It gave a false "fix absent".
            elif ef_yaml="$(run get "$EF" payload-processing -n openshift-ingress -o yaml)" \
                 && grep -q 'operation: REMOVE' <<<"$ef_yaml"; then
                ok "payload-processing EnvoyFilter carries the endpoint picker fix (solution 7148630)"
                run get "$EF" maas-epp-after-ipp-workaround -n openshift-ingress >/dev/null && \
                    info "maas-epp-after-ipp-workaround is no longer needed; delete it: oc delete ${EF} maas-epp-after-ipp-workaround -n openshift-ingress"
            elif run get "$EF" maas-epp-after-ipp-workaround -n openshift-ingress >/dev/null; then
                ok "endpoint picker fix absent, solution 7148630 workaround EnvoyFilter applied"
            else
                warn "MaaS requests bypass the endpoint picker (solution 7148630)" \
                    "This MaaS build lacks the fix: payload-processing has no 'operation: REMOVE' patch.
                     Fix: apply the EnvoyFilter maas-epp-after-ipp-workaround (openshift-ingress, priority 20,
                     after payload-processing's 10) from https://access.redhat.com/solutions/7148630.
                     Run its Diagnostic Steps first; delete it after upgrading to a fixed build."
            fi
        fi

        # Open question, not a check (solution 7143483): from 4.21.22 the ingress
        # operator is said to stop managing the servicemeshoperator3 Subscription.
        # Recorded here so each new cluster answers it.
        smsub="$(run get "$SUB" -A -o json | python3 -I -c 'import json,sys
for s in json.load(sys.stdin)["items"]:
    if s.get("spec",{}).get("name")=="servicemeshoperator3":
        print("%s/%s installed=%s" % (s["metadata"]["namespace"], s["metadata"]["name"], (s.get("status") or {}).get("installedCSV","-")))' 2>/dev/null | head -1)"
        gwver="$(run get "$DEPLOY" ingress-operator -n openshift-ingress-operator \
                 -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="GATEWAY_API_OPERATOR_VERSION")].value}')"
        info "Service Mesh Subscription: ${smsub:-none}; ingress operator GATEWAY_API_OPERATOR_VERSION=${gwver:-unset}"
        info "  (solution 7143483 question; see docs/rhoai-disconnected-additional-images.md)"

        if run get crd llminferenceservices.serving.kserve.io >/dev/null; then
            n="$(run get llminferenceservice -A --no-headers | wc -l)"
            if [ "${n:-0}" -eq 0 ]; then
                bad "no LLMInferenceService" "Nothing is being served."
                info "If policy-openshift-ai-models looks fine, check it is PLACED and that"
                info "config.openshiftAiModels is in the cluster's rendered-config ConfigMap."
            else
                ok "${n} LLMInferenceService(s)"
                nr="$(run get llminferenceservice -A -o json | python3 -I -c 'import json,sys
bad=[]
for i in json.load(sys.stdin)["items"]:
    c={x["type"]:x["status"] for x in (i.get("status",{}).get("conditions") or [])}
    if c.get("Ready")!="True": bad.append(i["metadata"]["name"])
print(" ".join(bad))' 2>/dev/null)"
                [ -z "$nr" ] && ok "all models Ready" || bad "models not Ready: ${nr}"

                # The runtime actually running, against the one the installed
                # bundle declares. config.openshiftAiModels[].image is pinned by
                # hand and drifted once already (a 3.4.1 build under 3.5).
                read -r rns rinst _ <<< "$(rhoai_sub)"
                vwant=""
                [ -n "${rns:-}" ] && vwant="$(run get "$CSV" "$rinst" -n "$rns" -o json | python3 -I -c 'import json,sys
def walk(x):
    if isinstance(x, dict):
        if x.get("name") == "RELATED_IMAGE_RHAII_VLLM_CUDA_IMAGE" and x.get("value"): print(x["value"]); sys.exit()
        for v in x.values(): walk(v)
    elif isinstance(x, list):
        for v in x: walk(v)
walk(json.load(sys.stdin))' 2>/dev/null)"
                vsrc="${rinst:-CSV}"
                [ -n "$vwant" ] || { vwant="$VLLM_IMAGE_FALLBACK"; vsrc="the ${RHOAI_CSV_WANT} default in checkup.sh"; }
                run get llminferenceservice -A -o json > "$TMPD/llmisvc.json"
                for ns in $(python3 -I -c 'import json,sys
print(" ".join(sorted({i["metadata"]["namespace"] for i in json.load(open(sys.argv[1]))["items"]})))' "$TMPD/llmisvc.json" 2>/dev/null); do
                    run get pods -n "$ns" -o json > "$TMPD/pods-${ns}.json"
                done
                report <<< "$(VWANT="$vwant" VSRC="$vsrc" python3 -I - "$TMPD" <<'PY' 2>/dev/null || echo "WARN|could not compare model runtime images"
import glob, json, os, sys
want, src, d = os.environ["VWANT"], os.environ["VSRC"], sys.argv[1]
digest = want.split("@", 1)[1] if "@" in want else None
pods = [p for f in glob.glob(os.path.join(d, "pods-*.json")) for p in json.load(open(f)).get("items", [])]
for m in json.load(open(os.path.join(d, "llmisvc.json")))["items"]:
    name, ns = m["metadata"]["name"], m["metadata"]["namespace"]
    mine = [p for p in pods if p["metadata"]["namespace"] == ns
            and name in (p["metadata"].get("labels") or {}).values()]
    seen = []
    for p in mine:
        ids = {s.get("name"): s.get("imageID", "") for s in (p.get("status") or {}).get("containerStatuses") or []}
        for c in p.get("spec", {}).get("containers") or []:
            if "vllm" in c.get("image", ""):
                seen.append((c["image"], ids.get(c["name"], "")))
    if not seen:
        print("WARN|%s: no running vLLM container found|Looked for pods in %s labelled with the model name." % (name, ns))
        continue
    good = [i for i, iid in seen if (digest and (digest in i or digest in iid)) or i == want]
    bad = sorted({i for i, iid in seen} - set(good))
    if bad:
        print("WARN|%s runs a vLLM image that is not the bundle's|running: %s  expected (%s): %s  Fix config.openshiftAiModels[].image in the hub values." % (name, " ".join(bad), src, want))
    else:
        print("OK|%s vLLM runtime is the bundle's (%s)" % (name, (digest or want)[:19]))
PY
)"
            fi
        fi
    fi
fi

# --- maas resilience and usage ----------------------------------------------
# What the openshift-ai-maas HA/telemetry policies and connectivity-link's
# rhcl-ha set up, checked from the objects they produce. A policy cannot run
# PromQL, so the telemetry flow check (the counters carry a subscription label)
# lives here.
if want maas && run get maastenantconfigs.maas.opendatahub.io default-tenant -n models-as-a-service >/dev/null; then
    head_ "MaaS resilience and usage"
    want_api="$(run get maastenantconfigs.maas.opendatahub.io default-tenant -n models-as-a-service \
                -o jsonpath='{.metadata.annotations.maas\.opendatahub\.io/maas-api-replicas}')"
    have_api="$(run get deploy maas-api -n redhat-ai-gateway-infra -o jsonpath='{.status.availableReplicas}')"
    if [ -n "$want_api" ]; then
        [ "${have_api:-0}" = "$want_api" ] && ok "maas-api ${have_api}/${want_api} replicas (annotation on default-tenant)" \
            || bad "maas-api has ${have_api:-0} available, the annotation asks for ${want_api}" \
                   "maas-controller renders the count from maas.opendatahub.io/maas-api-replicas; check its log."
    else
        info "maas-api runs ${have_api:-?} replica(s); no HA annotation (policy-maas-api-ha off)"
    fi
    have_auth="$(run get deploy authorino -n kuadrant-system -o jsonpath='{.status.availableReplicas}')"
    info "Authorino ${have_auth:-?} available replica(s)"
    for pdb in redhat-ai-gateway-infra/maas-api kuadrant-system/authorino; do
        ns="${pdb%/*}"; nm="${pdb#*/}"
        line="$(run get pdb "$nm" -n "$ns" -o jsonpath='{.status.disruptionsAllowed} {.status.currentHealthy} {.status.expectedPods}')"
        [ -z "$line" ] && continue
        read -r allowed healthy expected <<<"$line"
        if [ "${allowed:-0}" -ge 1 ]; then ok "PDB ${pdb}: ${healthy}/${expected} healthy, ${allowed} disruption allowed"
        else warn "PDB ${pdb} allows no disruption (${healthy}/${expected} healthy)" \
                  "A node drain will wait on this until another replica is Ready."; fi
    done
    lstore="$(run get limitadors.limitador.kuadrant.io limitador -n kuadrant-system -o jsonpath='{.spec.storage}')"
    case "$lstore" in
        *disk*)  ok "Limitador counters on disk (survive a restart)" ;;
        *redis*) ok "Limitador counters in Redis (shared across replicas)" ;;
        *)       info "Limitador counters in memory: a restart resets every token window (policy-rhcl-ha off)" ;;
    esac
    tel="$(run get maastenantconfigs.maas.opendatahub.io default-tenant -n models-as-a-service -o jsonpath='{.spec.telemetry.enabled}')"
    if [ "$tel" = "true" ]; then
        # The flow check: the platform Prometheus scrapes Limitador
        # (kuadrant-system carries the cluster-monitoring label).
        res="$(timeout 60 "$OC" exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
                curl -s --get http://localhost:9090/api/v1/query \
                --data-urlencode 'query=count by (subscription) (authorized_hits)' 2>/dev/null \
               | python3 -I -c 'import json,sys
r=json.load(sys.stdin)["data"]["result"]
lab=[x["metric"].get("subscription","") for x in r]
print("labelled" if any(lab) else ("unlabelled" if r else "none"))' 2>/dev/null)"
        case "$res" in
            labelled)   ok "MaaS telemetry on, and authorized_hits carries a subscription label" ;;
            unlabelled) bad "MaaS telemetry on, but authorized_hits has no subscription label" \
                            "Check TelemetryPolicy maas-telemetry in openshift-ingress (policy-maas-telemetry-ready)." ;;
            none)       info "MaaS telemetry on; no authorized_hits series yet (run scripts/35-smoke-test.sh)" ;;
            *)          warn "MaaS telemetry on, but the Prometheus query failed" ;;
        esac
    else
        info "MaaS telemetry off (policy-maas-telemetry not enabled)"
    fi
fi

# --- workloads: Hermes agent, Open WebUI and OpenShell ----------------------
# Only when their policies are placed. Hermes and the OpenShell provider each
# keep a MaaS key that they renew themselves, and record its expiry where this
# can read it: Hermes on Secret hermes-maas-key (annotation
# hermes.autoshift.io/expires-at), OpenShell on ConfigMap
# openshell-maas-provider-state (expiresAt). Both are epoch seconds. A key that
# is close to expiry means the renewal has not happened; the -key and
# -provider-ready policies say the same thing on the hub. Hermes logs no tool
# calls at default verbosity: the tool loop is recorded in its state.db.
key_left() {   # $1 label, $2 expiry epoch, $3 hint, $4 renewal window in hours (default 168)
    # Each key is renewed at the start of its renewal window (renewBefore,
    # 168h by default). One still in the window two hours later means renewal
    # is failing, days before the key actually stops working.
    local left_h=$(( ($2 - $(date +%s)) / 3600 )) win="${4:-168}"
    if [ "$left_h" -le 0 ]; then
        bad "$1 MaaS key expired $(date -u -d "@$2" +%Y-%m-%dT%H:%MZ)" "$3"
    elif [ "$left_h" -lt $(( win - 2 )) ]; then
        warn "$1 MaaS key is ${left_h}h from expiry, inside its ${win}h renewal window and not renewed" "$3"
    else
        ok "$1 MaaS key valid until $(date -u -d "@$2" +%Y-%m-%d) (about $(( left_h / 24 )) days)"
    fi
}
if want workloads; then
    PL="$(run get policy -n "$(run get managedcluster --no-headers | awk '{print $1}' | head -1)" --no-headers)"
    pol_status() {   # report each named policy that is placed; skip the rest
        local p st
        for p in "$@"; do
            st="$(awk -v p="$p" '$1 ~ "\\."p"$" {print $3}' <<<"$PL")"
            [ -z "$st" ] && continue
            [ "$st" = "Compliant" ] && ok "${p} Compliant" || bad "${p} ${st}"
        done
    }
    if grep -qE "policy-(hermes-agent|open-webui)" <<<"$PL"; then
        head_ "Workloads: Hermes agent and Open WebUI"
        pol_status policy-hermes-agent-access policy-hermes-agent policy-hermes-agent-ready \
                   policy-hermes-agent-key policy-open-webui policy-open-webui-ready
        hns="$(run get deploy -A -l app.kubernetes.io/name=hermes-agent -o jsonpath='{.items[0].metadata.namespace}')"
        if [ -n "$hns" ]; then
            hp="$(run get pods -n "$hns" -l app.kubernetes.io/name=hermes-agent -o name | head -1)"
            if [ -z "$hp" ]; then
                bad "no hermes-agent pod in ${hns}"
            else
                ready="$(run get "$hp" -n "$hns" -o jsonpath='{.status.containerStatuses[0].ready}')"
                [ "$ready" = "true" ] && ok "hermes-agent pod Ready (${hp#pod/})" || bad "hermes-agent pod not Ready (${hp#pod/})"
            fi
            exp="$(run get secret hermes-maas-key -n "$hns" -o jsonpath='{.metadata.annotations.hermes\.autoshift\.io/expires-at}')"
            if [[ "$exp" =~ ^[0-9]+$ ]]; then
                key_left "Hermes" "$exp" "Its [bootstrap] log says why: oc logs deploy/hermes-agent -n ${hns} | grep bootstrap"
                hlog="$(run logs deploy/hermes-agent -n "$hns" --tail=-1)"
                renew="$(grep -o 'restart for key renewal at [^ ]*' <<<"$hlog" | tail -1 || true)"
                [ -n "$renew" ] && info "Hermes will ${renew}"
            elif [ -n "$hp" ] && run logs "$hp" -n "$hns" --tail=-1 | grep -q '403'; then
                bad "Hermes could not mint a MaaS key (403)" \
                    "Its ServiceAccount group must be in the model's accessGroups and the subscription's owner groups."
            else
                warn "no stored Hermes MaaS key (Secret ${hns}/hermes-maas-key)" \
                    "The pod mints it at startup; read: oc logs deploy/hermes-agent -n ${hns} | grep bootstrap"
            fi
            info "Tool calls are not logged at default verbosity; Hermes records them in its state.db."
        fi
        owns="$(run get deploy -A -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].metadata.namespace}')"
        if [ -n "$owns" ]; then
            route="$(run get route -n "$owns" -o jsonpath='{.items[0].spec.host}')"
            avail="$(run get deploy -n "$owns" -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].status.availableReplicas}')"
            proxy="$(run get deploy -n "$owns" -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].spec.template.spec.containers[*].name}')"
            [[ " $proxy " == *" oauth-proxy "* ]] && login="OpenShift login" || login="local accounts"
            [ "${avail:-0}" -ge 1 ] && ok "Open WebUI available at https://${route} (${login})" \
                || bad "Open WebUI not available" \
                       "In local mode, CreateContainerConfigError means the open-webui-admin Secret is missing."
        fi
    fi
    if grep -q "policy-openshell-gateway" <<<"$PL"; then
        head_ "Workloads: OpenShell"
        pol_status policy-agent-sandbox-operator-install policy-openshell-prereqs policy-openshell-namespace \
                   policy-openshell-gateway policy-openshell-gateway-ready \
                   policy-openshell-maas-provider policy-openshell-maas-provider-ready
        ready="$(run get pod openshell-0 -n openshell -o jsonpath='{.status.containerStatuses[0].ready}')"
        if [ "$ready" = "true" ]; then
            ok "OpenShell gateway pod openshell-0 Ready"
        else
            bad "OpenShell gateway pod openshell-0 not Ready" \
                "No pod at all usually means admission: oc -n openshell describe statefulset openshell | sed -n '/Events:/,\$p'"
        fi
        run get configmap openshell-additional-ca -n openshell >/dev/null \
            && ok "ConfigMap openshell/openshell-additional-ca present (sandbox trust for MaaS TLS)" \
            || bad "ConfigMap openshell/openshell-additional-ca missing" \
                   "Sandboxes will not trust the cluster ingress certificate; check policy-openshell-namespace."
        sbx="$(run get sandboxes.agents.x-k8s.io -n openshell --no-headers | wc -l)"
        info "Sandboxes in openshell: ${sbx}"
        if grep -q "policy-openshell-maas-provider" <<<"$PL"; then
            exp="$(run get configmap openshell-maas-provider-state -n openshell -o jsonpath='{.data.expiresAt}')"
            if [[ "$exp" =~ ^[0-9]+$ ]]; then
                key_left "OpenShell provider" "$exp" \
                    "The provider CronJob renews it; read its last run: oc -n openshell logs job/\$(oc -n openshell get jobs -o name --sort-by=.metadata.creationTimestamp | tail -1 | cut -d/ -f2)"
            else
                warn "OpenShell provider has no recorded MaaS key yet (ConfigMap openshell/openshell-maas-provider-state)" \
                    "It appears after the provider CronJob's first successful run, every 15 minutes by default."
            fi
            # Runs every 15 minutes by default; two missed intervals is worth a look.
            last="$(run get cronjob openshell-maas-provider -n openshell -o jsonpath='{.status.lastSuccessfulTime}')"
            failed="$(run get jobs -n openshell -o jsonpath='{range .items[*]}{.metadata.name} {.status.failed}{"\n"}{end}' \
                      | awk '$1 ~ /^openshell-maas-provider/ && $2 > 0' | wc -l)"
            if [ -z "$last" ]; then
                warn "OpenShell provider CronJob has never succeeded"
            elif [ $(( $(date +%s) - $(date -d "$last" +%s) )) -gt 1800 ]; then
                warn "OpenShell provider CronJob last succeeded at ${last}, over 30 minutes ago (${failed} failed job(s) kept)" \
                    "Read the newest failed job: oc -n openshell get jobs | grep openshell-maas-provider"
            else
                ok "OpenShell provider CronJob last succeeded at ${last}"
            fi
        fi
        info "End to end (creates a throwaway sandbox, spends one chat completion): scripts/openshell-smoke-test.sh"
    fi
fi

# --- load -------------------------------------------------------------------
# Not a failure in itself, but it is the cause that presents as five unrelated
# failures elsewhere, so it is worth seeing before debugging any of them.
if want load; then
    head_ "Load"
    P="$(run get pods -n openshift-etcd -l app=etcd -o name | head -1)"
    if [ -n "$P" ]; then
        db="$(timeout 90 "$OC" exec -n openshift-etcd "${P#pod/}" -c etcdctl -- \
              etcdctl endpoint status -w json 2>/dev/null \
              | python3 -I -c 'import json,sys;print(max(e["Status"]["dbSize"] for e in json.load(sys.stdin))//1048576)' 2>/dev/null)"
        if [ -n "$db" ]; then
            # Compare against what the control plane actually is, not against a
            # fixed string. Reporting the recommendation as though it described
            # this cluster is how you reassure someone about a machine they do
            # not have. Red Hat articles/7132959 keys the recommendation off the
            # pre-defrag high-water mark, which is what etcdctl reports here.
            if   [ "$db" -lt 250 ]; then want_cpu=4
            elif [ "$db" -lt 500 ]; then want_cpu=8
            else                          want_cpu=10; fi
            cpu="$(run get nodes -l node-role.kubernetes.io/control-plane \
                   -o jsonpath='{.items[*].status.capacity.cpu}' | tr ' ' '\n' | sort -n | head -1)"
            have="${cpu:-?} vCPU"
            if [ -n "$cpu" ] && [ "$cpu" -ge "$want_cpu" ]; then
                ok "etcd ${db} MB, control plane ${have} (needs ${want_cpu})"
            elif [ -n "$cpu" ]; then
                bad "etcd ${db} MB on a ${have} control plane" \
                    "articles/7132959 suggests ${want_cpu} vCPU at this etcd size. Expect API timeouts, crash-looping ovnkube-controller and NotReady nodes before anything says 'too small'."
            else
                warn "etcd ${db} MB" "could not read control plane CPU capacity"
            fi
        fi
    fi
    maxcpu="$(run describe node -l node-role.kubernetes.io/worker \
              | awk '/Allocated resources/{f=1} f&&/^  cpu/{gsub(/[()%]/,"",$3); print $3; f=0}' | sort -rn | head -1)"
    if [ -n "$maxcpu" ]; then
        if   [ "$maxcpu" -lt 70 ]; then ok "worker CPU requests peak at ${maxcpu}%"
        elif [ "$maxcpu" -lt 90 ]; then warn "worker CPU requests peak at ${maxcpu}%"
        else bad "worker CPU requests peak at ${maxcpu}%" "Pods will not schedule; webhooks without endpoints fail closed."; fi
    fi
fi

# --- summary ----------------------------------------------------------------
printf '\n\033[1mSummary\033[0m\n'
if [ "$PROBLEMS" -eq 0 ]; then
    printf '  No problems found.\n'
    exit 0
fi
printf '  %d problem(s). Fix this one first, the rest may follow from it:\n\n    %s\n\n' "$PROBLEMS" "$FIRST_BREAK"
printf '  Sections run in dependency order, so earlier findings cause later ones.\n'
exit 1
