#!/usr/bin/env bash
#
# autoshift-feature.sh - turn AutoShift capability on and off as whole
#                        features, instead of one label at a time.
#
# Usage: scripts/autoshift-feature.sh status
#        scripts/autoshift-feature.sh enable  <feature>...
#        scripts/autoshift-feature.sh disable <feature>...
#        scripts/autoshift-feature.sh list
#
# Options:
#   --file <path>   Clusterset values file. Default: the one phase 50 reads,
#                   $AUTOSHIFT_DIR/autoshift/values/clustersets/$AUTOSHIFT_CLUSTERSET.yaml
#   --dry-run       Show what would change and exit non-zero if anything would.
#
# Why this exists. Several AutoShift capabilities are more than one label, and
# a partial set fails silently rather than loudly. Enabling openshift-ai-maas
# without openshift-ai gives a gateway with no DataScienceCluster behind it;
# enabling openshift-ai-models without config.openshiftAiModels gives a policy
# that applies nothing and reports Compliant. Both states look fine from the
# policy list. Grouping the labels makes the dependency mechanical rather than
# a comment someone has to read.
#
# This edits YAML line by line rather than parsing and re-emitting it, because
# the values files carry substantial comments that a round-trip would discard.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# feature -> labels that must move together.
# Keep in sync with docs/running-under-autoshift.md.
feature_labels() {
    case "$1" in
        gpu)        echo "node-feature-discovery nvidia-gpu-operator" ;;
        rhoai)      echo "openshift-ai" ;;
        maas)       echo "openshift-ai connectivity-link openshift-ai-maas openshift-ai-models leader-worker-set" ;;
        lightspeed) echo "openshift-lightspeed" ;;
        mcp)        echo "mcp-gateway" ;;
        *)          return 1 ;;
    esac
}

# feature -> config key under hubClusterSets.<set>.config that must exist and
# be non-empty. A label without its config is the silent-no-op case.
feature_config() {
    case "$1" in
        maas) echo "openshiftAiModels" ;;
        *)    echo "" ;;
    esac
}

# feature -> features that must also be on. Checked, never auto-enabled:
# turning on RHOAI because someone asked for Lightspeed is not a decision a
# script should make quietly.
feature_requires() {
    case "$1" in
        maas)       echo "gpu" ;;
        lightspeed) echo "maas" ;;
        *)          echo "" ;;
    esac
}

ALL_FEATURES="gpu rhoai maas lightspeed mcp"

ACTION="${1:-}"; shift || true
VALUES_FILE=""
DRY_RUN=0
FEATURES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --file)    VALUES_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)        echo "autoshift-feature.sh: unknown option '$1'" >&2; exit 2 ;;
        *)         FEATURES+=("$1"); shift ;;
    esac
done

case "$ACTION" in
    list)
        for f in $ALL_FEATURES; do
            printf '  %-11s %s\n' "$f" "$(feature_labels "$f")"
            req="$(feature_requires "$f")"; cfg="$(feature_config "$f")"
            [ -n "$req" ] && printf '  %-11s   requires: %s\n' "" "$req"
            [ -n "$cfg" ] && printf '  %-11s   config:   %s\n' "" "$cfg"
        done
        exit 0 ;;
    status|enable|disable) ;;
    *) echo "Usage: scripts/autoshift-feature.sh {status|enable|disable|list} [feature...]" >&2; exit 2 ;;
esac

. "${ROOT}/cluster.env"
: "${AUTOSHIFT_DIR:?AUTOSHIFT_DIR must be set in cluster.env}"
CLUSTERSET="${AUTOSHIFT_CLUSTERSET:-hub}"
VALUES_FILE="${VALUES_FILE:-${AUTOSHIFT_DIR}/autoshift/values/clustersets/${CLUSTERSET}.yaml}"
[ -f "$VALUES_FILE" ] || { echo "Error: no values file at ${VALUES_FILE}" >&2; exit 1; }

if [ "$ACTION" != "status" ] && [ "${#FEATURES[@]}" -eq 0 ]; then
    echo "Error: name at least one feature. 'list' shows them." >&2; exit 2
fi
for f in ${FEATURES[@]+"${FEATURES[@]}"}; do
    feature_labels "$f" >/dev/null || { echo "Error: unknown feature '${f}'. Try 'list'." >&2; exit 2; }
done

export VALUES_FILE DRY_RUN ACTION
export FEATURE_LIST="${FEATURES[*]:-}"
export ALL_FEATURES

python3 -I - <<'PYEOF'
import os, re, sys

path    = os.environ["VALUES_FILE"]
action  = os.environ["ACTION"]
dry     = os.environ["DRY_RUN"] == "1"
feats   = os.environ["FEATURE_LIST"].split()
allf    = os.environ["ALL_FEATURES"].split()

# The feature table is duplicated here rather than shelled back out to bash:
# one definition in each language is worse than one lookup, but shelling out
# per label is slower and harder to read. Keep the two in sync.
LABELS = {
    "gpu":        ["node-feature-discovery", "nvidia-gpu-operator"],
    "rhoai":      ["openshift-ai"],
    "maas":       ["openshift-ai", "connectivity-link", "openshift-ai-maas",
                   "openshift-ai-models", "leader-worker-set"],
    "lightspeed": ["openshift-lightspeed"],
    "mcp":        ["mcp-gateway"],
}
CONFIG   = {"maas": "openshiftAiModels"}
REQUIRES = {"maas": ["gpu"], "lightspeed": ["maas"]}

lines = open(path).read().split("\n")

def find_label(key):
    pat = re.compile(rf"^(\s+){re.escape(key)}:\s*'?(true|false)'?\s*(#.*)?$")
    for i, l in enumerate(lines):
        m = pat.match(l)
        if m:
            return i, m.group(1), m.group(2), (m.group(3) or "")
    return None

def config_present(key):
    # The config block is indented 6 under `    config:`; a top-level config
    # key therefore appears at exactly 6 spaces.
    return any(re.match(rf"^ {{6}}{re.escape(key)}:\s*$", l) for l in lines)

def label_state(key):
    f = find_label(key)
    return None if f is None else (f[2] == "true")

if action == "status":
    print(f"  {path}\n")
    for f in allf:
        states = {k: label_state(k) for k in LABELS[f]}
        missing = [k for k, v in states.items() if v is None]
        on      = [k for k, v in states.items() if v is True]
        off     = [k for k, v in states.items() if v is False]
        if missing:   verdict = "PARTIAL (labels absent)"
        elif not off: verdict = "on"
        elif not on:  verdict = "off"
        else:         verdict = "INCONSISTENT"
        print(f"  {f:<11} {verdict}")
        for k in missing: print(f"                 absent: {k}")
        if verdict == "INCONSISTENT":
            for k in on:  print(f"                 on:  {k}")
            for k in off: print(f"                 off: {k}")
        cfg = CONFIG.get(f)
        if cfg and not config_present(cfg):
            note = "required" if verdict == "on" else "needed before enabling"
            print(f"                 config.{cfg} ABSENT ({note})")
    sys.exit(0)

want    = action == "enable"
changes = []
problems = []

for f in feats:
    if want:
        for dep in REQUIRES.get(f, []):
            dep_off = [k for k in LABELS[dep] if label_state(k) is not True]
            if dep_off and dep not in feats:
                problems.append(
                    f"{f} requires {dep}, which is not fully enabled ({', '.join(dep_off)}). "
                    f"Add {dep} to the same command if that is what you want.")
    cfg = CONFIG.get(f)
    if want and cfg and not config_present(cfg):
        problems.append(
            f"{f} needs config.{cfg} in {path}, which is absent. The label alone "
            f"makes the policy apply nothing while reporting Compliant.")
    for key in LABELS[f]:
        found = find_label(key)
        if found is None:
            problems.append(f"label '{key}' ({f}) is not present in {path}; add it by hand first")
            continue
        i, indent, cur, comment = found
        if (cur == "true") == want:
            continue
        new = f"{indent}{key}: '{'true' if want else 'false'}'" + (f"  {comment}" if comment else "")
        changes.append((i, key, cur, "true" if want else "false", new))

if problems:
    print("Refusing to change anything:\n", file=sys.stderr)
    for p in problems: print(f"  - {p}", file=sys.stderr)
    sys.exit(1)

if not changes:
    print(f"  Already {'enabled' if want else 'disabled'}: {', '.join(feats)}")
    sys.exit(0)

for _, key, cur, new, _ in changes:
    print(f"  {key}: {cur} -> {new}")

if dry:
    print("\n  --dry-run: nothing written")
    sys.exit(1)

for i, _, _, _, newline in changes:
    lines[i] = newline
open(path, "w").write("\n".join(lines))
print(f"\n  Wrote {path}")
PYEOF

rc=$?
[ "$rc" -ne 0 ] && exit "$rc"

if [ "$ACTION" != "status" ]; then
    cat <<EOF

Values files are read by helm at install time and policies are read from Git,
so this change does nothing until both have happened:

    cd ${AUTOSHIFT_DIR} && git commit -am '...' && git push
    scripts/50-autoshift.sh bootstrap
EOF
fi
