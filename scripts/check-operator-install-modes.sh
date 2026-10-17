#!/usr/bin/env bash
#
# check-operator-install-modes.sh - find AutoShift operator policies whose
#                                   OperatorGroup scope the cluster will reject.
#
# Usage: scripts/check-operator-install-modes.sh [--all]
#
# Options:
#   --all   Also list the policies that are correct, not just the broken ones.
#
# The failure this catches. The shared components/operator-install chart
# defaults targetNamespaces to an empty list, which means an AllNamespaces
# (cluster-scoped) OperatorGroup. An operator whose CSV declares
# AllNamespaces=False cannot be installed that way: OLM rejects the
# OperatorGroup and the CSV sits in Failed with
#
#   UnsupportedOperatorGroup: AllNamespaces InstallModeType not supported
#
# The policy meanwhile reports only "the ClusterServiceVersion required by the
# policy was not found", which reads like a catalog or network problem. Nothing
# fails at render time, so `make test` stays green and the defect only appears
# on a cluster, operator by operator. Six instances were found this way by
# hand before this script existed.
#
# The authority is the cluster's own catalog: every CSV declares its supported
# install modes in its PackageManifest, so this needs no installation and does
# not change anything.
#
# Exit status: 0 if nothing is broken, 1 if anything is.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOW_ALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --all)     SHOW_ALL=1; shift ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "check-operator-install-modes.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
: "${AUTOSHIFT_DIR:?AUTOSHIFT_DIR must be set in cluster.env}"

KUBECONFIG="${CLUSTER_DIR}/auth/kubeconfig"
[ -f "$KUBECONFIG" ] || { echo "Error: no kubeconfig at ${KUBECONFIG}." >&2; exit 1; }
export KUBECONFIG
"$OC" get --raw /readyz >/dev/null 2>&1 || { echo "Error: cluster API not reachable." >&2; exit 1; }

PM="$(mktemp)"; trap 'rm -f "$PM"' EXIT
echo "==> Reading the operator catalog"
"$OC" get packagemanifest -n openshift-marketplace -o json > "$PM" 2>/dev/null || {
    echo "Error: could not read packagemanifests." >&2; exit 1; }

AUTOSHIFT_DIR="$AUTOSHIFT_DIR" PM="$PM" SHOW_ALL="$SHOW_ALL" python3 -I - <<'PYEOF'
import os, re, json, pathlib, sys

pm = {i['metadata']['name']: i for i in json.load(open(os.environ['PM']))['items']}
show_all = os.environ['SHOW_ALL'] == '1'
root = pathlib.Path(os.environ['AUTOSHIFT_DIR'])

def modes(pkg):
    it = pm.get(pkg)
    if not it:
        return None, None
    ch = it['status'].get('defaultChannel')
    for c in it['status']['channels']:
        if c['name'] == ch:
            d = c['currentCSVDesc']
            return {m['type']: m['supported'] for m in d.get('installModes', [])}, d.get('version')
    return None, None

broken, unknown, fine = [], [], []
paths = sorted(root.glob("policies/*/*/manifests/operator-install/kustomization.yaml"))
if not paths:
    print(f"Error: no operator policies found under {root}/policies", file=sys.stderr)
    sys.exit(1)

for k in paths:
    s = k.read_text()
    comp = k.parts[len(root.parts) + 1 + 1]
    m = re.search(r'"autoshift\.io/[a-z0-9-]+-subscription-name"\s*\|\s*default\s*"([^"]+)"', s)
    ns = re.search(r'^\s+namespace:\s*(\S+)\s*$', s, re.M)
    if not m:
        unknown.append((comp, "(no subscription-name default to read)")); continue
    pkg, scoped = m.group(1), "targetNamespaces" in s
    im, ver = modes(pkg)
    if im is None:
        unknown.append((comp, f"{pkg} is not in this cluster's catalog")); continue
    if not im.get("AllNamespaces", False) and not scoped:
        broken.append((comp, pkg, ver, im, ns.group(1) if ns else "<unknown>"))
    else:
        fine.append((comp, pkg, ver, scoped))

print()
if broken:
    print(f"BROKEN — AllNamespaces=False but the policy sets no targetNamespaces ({len(broken)}):\n")
    for comp, pkg, ver, im, namespace in broken:
        print(f"  {comp}  ({pkg} v{ver})")
        print("    " + ", ".join(f"{k}={v}" for k, v in im.items()))
        print(f"    fix: add to policies/*/{comp}/manifests/operator-install/kustomization.yaml")
        print( "           targetNamespaces:")
        print(f"             - {namespace}")
        print()
else:
    print(f"No install-mode mismatches. {len(fine)} operator policies checked.\n")

if unknown:
    print(f"Could not verify ({len(unknown)}) — absent from this cluster's catalog:")
    for comp, why in unknown:
        print(f"  {comp}: {why}")
    print("  A disconnected or differently-subscribed cluster may carry these.\n")

if show_all and fine:
    print(f"OK ({len(fine)}):")
    for comp, pkg, ver, scoped in fine:
        print(f"  {comp:<32} {pkg} v{ver}{'  [scoped]' if scoped else ''}")

sys.exit(1 if broken else 0)
PYEOF
