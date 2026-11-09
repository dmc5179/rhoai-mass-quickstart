#!/usr/bin/env bash
#
# spot-check.sh - measure whether spot instances are worth it in this region,
#                 before choosing a zone and instance types for phase 10.
#
# Usage: scripts/spot-check.sh [--workers <type,...>] [--gpus <type,...>] [--dry-run]
#
#   --workers  Worker instance types to compare. Default: AWS_WORKER_TYPE from
#              cluster.env plus m6i.4xlarge, m6a.4xlarge, m7i.4xlarge.
#   --gpus     GPU instance types to compare. Default: GPU_INSTANCE_TYPE plus
#              g6.xlarge, g5.xlarge.
#   --dry-run  Print the AWS queries it would make and stop.
#
# Read-only. It creates nothing, and needs no cluster. For the region in
# secrets/aws.env it reports:
#
#   1. On-demand price (AWS Pricing API) and current spot price per zone
#      (describe-spot-price-history) for each type.
#   2. Spot placement scores per zone (get-spot-placement-scores), 1 to 10, for
#      the number of instances the plan would actually request. AWS computes
#      the score against THIS account's spot quota too, so a low score on a
#      fresh or sandbox account can mean "quota" rather than "no capacity".
#   3. The account's spot vCPU quotas (Service Quotas), so that case is visible.
#   4. Hourly cost of the default layout three ways: all on-demand; workers on
#      spot except two (docs/spot-instances-plan.md keeps at least two
#      on-demand workers and the control plane always on-demand); and that plus
#      the GPU node on spot.
#
# The VPC is single-zone by design (VPC_AZ), so the zone it picks matters more
# than usual: a spot MachineSet has no fallback to on-demand or to another zone.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}"; }

WORKERS=""; GPUS=""; DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --workers) WORKERS="$2"; shift 2 ;;
        --gpus)    GPUS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "spot-check.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

. "${ROOT}/cluster.env"
. "${ROOT}/bin/ocp-env.sh"
. "${ROOT}/scripts/lib-logging.sh"
start_logging "spot-check" "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

# Credentials and region from secrets/aws.env, as in phase 10.
if [ -f "${ROOT}/secrets/aws.env" ]; then
    # shellcheck disable=SC1091
    . "${ROOT}/secrets/aws.env"
fi
REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-}}"
[ -n "$REGION" ] || { echo "Error: no AWS region; set AWS_DEFAULT_REGION in secrets/aws.env." >&2; exit 1; }

dedupe() { tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -; }
WORKERS="$(printf '%s' "${WORKERS:-${AWS_WORKER_TYPE},m6i.4xlarge,m6a.4xlarge,m7i.4xlarge}" | dedupe)"
GPUS="$(printf '%s' "${GPUS:-${GPU_INSTANCE_TYPE},g6.xlarge,g5.xlarge}" | dedupe)"

# How many instances the plan would request on spot, for the placement score.
SPOT_WORKERS=$(( AWS_WORKER_REPLICAS > 2 ? AWS_WORKER_REPLICAS - 2 : 1 ))

echo "==> Region ${REGION}${VPC_AZ:+, configured zone ${VPC_AZ}}"
echo "    Worker types: ${WORKERS}   (placement score for ${SPOT_WORKERS} instance(s))"
echo "    GPU types:    ${GPUS}   (placement score for 1 instance)"
echo "    Layout: ${AWS_CONTROL_PLANE_REPLICAS}x ${AWS_CONTROL_PLANE_TYPE} control plane, ${AWS_WORKER_REPLICAS}x ${AWS_WORKER_TYPE} workers, 1x ${GPU_INSTANCE_TYPE} GPU"

if [ "$DRY_RUN" -eq 1 ]; then
    cat <<EOF

--dry-run: would run, all read-only:
    aws ec2 describe-availability-zones --region ${REGION}
    aws pricing get-products --region us-east-1 --service-code AmazonEC2 (per type, Linux, shared, on-demand)
    aws ec2 describe-spot-price-history --region ${REGION} --product-descriptions Linux/UNIX (last hour)
    aws ec2 get-spot-placement-scores --region ${REGION} --single-availability-zone (per type)
    aws service-quotas get-service-quota --service-code ec2 --quota-code L-34B43A08 / L-3819A6DF
EOF
    exit 0
fi

aws sts get-caller-identity >/dev/null 2>&1 || {
    echo "Error: AWS credentials are not valid. Check secrets/aws.env:" >&2
    aws sts get-caller-identity 2>&1 | sed 's/^/       /' >&2
    exit 1
}

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# The zone that matters is the one the VPC is in. With VPC_AZ empty, phase 10
# lets the template pick, so read it back from the stack if one exists.
if [ -z "${VPC_AZ:-}" ] && [ -n "${VPC_STACK_NAME:-}" ]; then
    VPC_AZ="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$VPC_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='AvailabilityZone'].OutputValue" --output text 2>/dev/null || true)"
    [ "$VPC_AZ" = "None" ] && VPC_AZ=""
    [ -n "$VPC_AZ" ] && echo "    Zone ${VPC_AZ} read from stack ${VPC_STACK_NAME}"
fi
ALL_TYPES="$(printf '%s,%s,%s' "$AWS_CONTROL_PLANE_TYPE" "$WORKERS" "$GPUS" | dedupe)"

aws ec2 describe-availability-zones --region "$REGION" --output json > "${WORK}/azs.json"

# On-demand prices. The Pricing API lives in us-east-1 whatever the region.
: > "${WORK}/ondemand.jsonl"
for t in ${ALL_TYPES//,/ }; do
    aws pricing get-products --region us-east-1 --service-code AmazonEC2 --output json \
        --filters Type=TERM_MATCH,Field=instanceType,Value="$t" \
                  Type=TERM_MATCH,Field=regionCode,Value="$REGION" \
                  Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
                  Type=TERM_MATCH,Field=tenancy,Value=Shared \
                  Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
                  Type=TERM_MATCH,Field=capacitystatus,Value=Used \
        2>"${WORK}/pricing.err" \
        | T="$t" python3 -I -c '
import json, os, sys
best = vcpu = None
for item in json.load(sys.stdin).get("PriceList", []):
    p = json.loads(item)
    for term in p.get("terms", {}).get("OnDemand", {}).values():
        for dim in term["priceDimensions"].values():
            usd = float(dim["pricePerUnit"].get("USD", 0))
            if usd > 0 and (best is None or usd < best):
                best, vcpu = usd, int(p["product"]["attributes"].get("vcpu", 0))
print(json.dumps({"type": os.environ["T"], "usd": best, "vcpu": vcpu if best else None}))' >> "${WORK}/ondemand.jsonl" \
        || echo "{\"type\": \"$t\", \"usd\": null, \"vcpu\": null}" >> "${WORK}/ondemand.jsonl"
done
[ -s "${WORK}/pricing.err" ] && echo "    (Pricing API: $(head -1 "${WORK}/pricing.err"))"

# Current spot prices: the newest entry per type and zone in the last hour.
# shellcheck disable=SC2046
aws ec2 describe-spot-price-history --region "$REGION" --output json \
    --product-descriptions Linux/UNIX \
    --start-time "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
    --instance-types $(printf '%s,%s' "$WORKERS" "$GPUS" | tr ',' ' ') > "${WORK}/spot.json"

# Placement scores, per type, for the count the plan would request.
: > "${WORK}/scores.jsonl"
for t in ${WORKERS//,/ } ${GPUS//,/ }; do
    n=1; [[ ",${WORKERS}," == *",${t},"* ]] && n="$SPOT_WORKERS"
    aws ec2 get-spot-placement-scores --region "$REGION" --output json \
        --instance-types "$t" --target-capacity "$n" --single-availability-zone \
        --region-names "$REGION" 2>/dev/null \
        | T="$t" python3 -I -c 'import json,os,sys; print(json.dumps({"type": os.environ["T"], "scores": json.load(sys.stdin).get("SpotPlacementScores", [])}))' \
        >> "${WORK}/scores.jsonl" \
        || echo "{\"type\": \"$t\", \"scores\": null}" >> "${WORK}/scores.jsonl"
done

# Spot vCPU quotas: standard (A, C, D, H, I, M, R, T, Z) and G/VT.
quota() {
    aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code "$1" \
        --query 'Quota.Value' --output text 2>/dev/null || echo "?"
}
Q_STD="$(quota L-34B43A08)"
Q_GPU="$(quota L-3819A6DF)"

python3 -I - "$WORK" <<PYEOF
import json, os, sys
w = sys.argv[1]
region, cfg_az = "${REGION}", "${VPC_AZ}"
workers, gpus = "${WORKERS}".split(","), "${GPUS}".split(",")
cp_type, cp_n = "${AWS_CONTROL_PLANE_TYPE}", int("${AWS_CONTROL_PLANE_REPLICAS}")
wk_type, wk_n = "${AWS_WORKER_TYPE}", int("${AWS_WORKER_REPLICAS}")
gpu_type = "${GPU_INSTANCE_TYPE}"
q_std, q_gpu = "${Q_STD}", "${Q_GPU}"

azs = json.load(open(os.path.join(w, "azs.json")))["AvailabilityZones"]
az_name = {a["ZoneId"]: a["ZoneName"] for a in azs}
zones = sorted(a["ZoneName"] for a in azs if a.get("ZoneType", "availability-zone") == "availability-zone")
rows = list(map(json.loads, open(os.path.join(w, "ondemand.jsonl"))))
od = {d["type"]: d["usd"] for d in rows}
vcpu = {d["type"]: d.get("vcpu") for d in rows}
spot = {}
for h in sorted(json.load(open(os.path.join(w, "spot.json")))["SpotPriceHistory"], key=lambda h: h["Timestamp"]):
    spot[(h["InstanceType"], h["AvailabilityZone"])] = float(h["SpotPrice"])   # newest wins
scores = {}
for d in map(json.loads, open(os.path.join(w, "scores.jsonl"))):
    for s in d["scores"] or []:
        scores[(d["type"], az_name.get(s["AvailabilityZoneId"], s["AvailabilityZoneId"]))] = s["Score"]

def money(v): return f"\${v:.3f}" if v is not None else "  n/a "

def table(title, types):
    print(f"\n{title}  (spot \$/h, placement score 1-10; * = configured zone)")
    hdr = f"  {'type':<14}{'on-demand':>10}  " + "  ".join(f"{z + ('*' if z == cfg_az else ''):>16}" for z in zones)
    print(hdr)
    for t in types:
        cells = []
        for z in zones:
            p, s = spot.get((t, z)), scores.get((t, z))
            if p is None:
                cells.append(f"{'not offered':>16}")
            else:
                disc = f"-{100 - 100 * p / od[t]:.0f}%" if od.get(t) else ""
                cells.append(f"{money(p) + ' ' + disc + ' s' + (str(s) if s is not None else '?'):>16}")
        print(f"  {t:<14}{money(od.get(t)):>10}  " + "  ".join(cells))

table("Workers", workers)
table("GPU", gpus)

print(f"\nSpot vCPU quotas in {region}: standard (M, C, R ...) {q_std}, G and VT {q_gpu}")
# AWS scores placement against this account's quota as well as capacity, so
# say which one a low score reflects.
def short(q, need):
    try: return need and float(q) < need
    except ValueError: return False
need_std = max(wk_n - 2, 1) * (vcpu.get(wk_type) or 0)
need_gpu = vcpu.get(gpu_type) or 0
for label, q, need in (("standard", q_std, need_std), ("G and VT", q_gpu, need_gpu)):
    if short(q, need):
        print(f"  The {label} quota ({q}) is below the {need} vCPUs the plan requests: low scores here are the quota. Raise it in Service Quotas.")
if not short(q_std, need_std) and not short(q_gpu, need_gpu):
    print("  Both quotas cover the plan, so low placement scores reflect spot capacity, not this account's limits.")

# Cost of the default layout. Spot uses the cheapest offered zone, or the
# configured zone when VPC_AZ is set (the VPC is single-zone).
def spot_for(t):
    cands = {z: p for (tt, z), p in spot.items() if tt == t and (not cfg_az or z == cfg_az)}
    if not cands: return None, None
    z = min(cands, key=cands.get); return cands[z], z

need = [cp_type, wk_type, gpu_type]
if any(od.get(t) is None for t in need):
    print("\nCost comparison skipped: no on-demand price for " + ", ".join(t for t in need if od.get(t) is None))
    sys.exit(0)
cp = cp_n * od[cp_type]
wk_spot_n = max(wk_n - 2, 0)
ws, wz = spot_for(wk_type); gs, gz = spot_for(gpu_type)
a = cp + wk_n * od[wk_type] + od[gpu_type]
print(f"\nHourly cost, {cp_n}x {cp_type} + {wk_n}x {wk_type} + 1x {gpu_type} (EC2 only; no EBS, NAT or ELB):")
print(f"  {'all on-demand':<44}\${a:7.2f}/h   \${a * 730:8.0f}/month")
if ws is not None:
    b = cp + 2 * od[wk_type] + wk_spot_n * ws + od[gpu_type]
    print(f"  {(str(wk_spot_n) + ' spot worker(s), 2 on-demand (' + wz + ')'):<44}\${b:7.2f}/h   \${b * 730:8.0f}/month   saves \${(a - b) * 730:.0f}")
    if gs is not None:
        c = b - od[gpu_type] + gs
        print(f"  {('... and the GPU node on spot (' + gz + ')'):<44}\${c:7.2f}/h   \${c * 730:8.0f}/month   saves \${(a - c) * 730:.0f}")
    else:
        print(f"  ... GPU on spot: {gpu_type} has no spot price{' in ' + cfg_az if cfg_az else ''}")
else:
    print(f"  spot workers: {wk_type} has no spot price{' in ' + cfg_az if cfg_az else ''}")
if wk_spot_n == 0:
    print("  With AWS_WORKER_REPLICAS <= 2, every worker stays on-demand under the plan's rule.")
print("\nSpot prices move; a single reading is a snapshot. Parking (cluster-power.sh) still beats any discount for idle time.")
PYEOF
