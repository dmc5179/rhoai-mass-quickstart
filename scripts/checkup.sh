#!/usr/bin/env bash
#
# checkup.sh - walk the whole RHOAI MaaS chain in dependency order and report
#              the first place it breaks.
#
# Usage: scripts/checkup.sh [--section <name>] [--quiet]
#
# Options:
#   --section <name>  Run one section only: cluster, autoshift, policies,
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

set -uo pipefail   # deliberately not -e: a failing probe is a finding

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION=""
QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --section) SECTION="$2"; shift 2 ;;
        --quiet)   QUIET=1; shift ;;
        -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

        if run get crd kuadrants.kuadrant.io >/dev/null; then
            kr="$(run get kuadrant -A -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')"
            if [ "$kr" = "True" ]; then ok "Kuadrant Ready"
            else bad "Kuadrant not Ready" \
                 "$(run get kuadrant -A -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].reason}: {.items[0].status.conditions[?(@.type=="Ready")].message}')"; fi
        fi

        gw="$(run get gateway -A --no-headers | wc -l)"
        [ "${gw:-0}" -gt 0 ] && ok "${gw} Gateway(s)" || warn "no Gateway — MaaS has no entry point"

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
            fi
        fi
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
