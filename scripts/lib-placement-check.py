#!/usr/bin/env python3
"""Find Placements that can never match this cluster.

Used by checkup.sh. Reads $OC and $MC from the environment.

A policy whose Placement does not match has no compliance status at all, so it
shows up in no list of NonCompliant policies and looks healthy from every
angle. Simply listing unplaced policies is useless, though, because most are
unplaced for the good reason that they are switched off.

What is worth reporting is a Placement where every predicate matches except
one. That means the policy was enabled deliberately and still cannot be
placed — the signature of a predicate that is wrong rather than a feature that
is off. A `cluster-type: spoke` predicate on a self-managed hub is exactly
this shape, and cost a long afternoon before it was spotted.
"""
import json
import os
import subprocess
import sys

OC = os.environ.get("OC", "oc")
MC = os.environ.get("MC", "")
NS = os.environ.get("POLICY_NS", "policies-autoshift")


def get(*args):
    try:
        out = subprocess.run([OC, *args, "-o", "json"],
                             capture_output=True, text=True, timeout=90).stdout
        return json.loads(out) if out.strip() else {}
    except Exception:
        return {}


def matches(expr, labels):
    key, op = expr.get("key"), expr.get("operator")
    vals, cur = expr.get("values", []), labels.get(expr.get("key"))
    if op == "Exists":
        return cur is not None
    if op == "DoesNotExist":
        return cur is None
    if op == "In":
        return cur in vals
    if op == "NotIn":
        return cur not in vals
    return True          # unknown operator: do not guess, do not report


def main():
    if not MC:
        return 0
    labels = (get("get", "managedcluster", MC).get("metadata") or {}).get("labels", {})
    if not labels:
        return 0

    findings = []
    for pl in get("get", "placement", "-n", NS).get("items", []):
        name = pl["metadata"]["name"]
        for pred in pl.get("spec", {}).get("predicates") or []:
            sel = (pred.get("requiredClusterSelector") or {}).get("labelSelector") or {}
            exprs = sel.get("matchExpressions") or []
            if len(exprs) < 2:
                continue
            # Split the predicate into the on/off switches and everything else.
            # An expression of the form `In ['true']` is an enablement label:
            # it failing just means the feature is switched off, which is not
            # a defect and is most of what is unplaced on any cluster.
            #
            # The defect worth reporting is the opposite shape — every
            # enablement label satisfied, so the operator of this cluster
            # asked for the feature, and some *other* predicate making it
            # unplaceable anyway. `cluster-type: spoke` on a self-managed hub
            # is exactly that, and is invisible everywhere else.
            def is_switch(e):
                return e.get("operator") == "In" and e.get("values") == ["true"]

            switches = [e for e in exprs if is_switch(e)]
            others = [e for e in exprs if not is_switch(e)]
            if not switches or not others:
                continue
            if not all(matches(e, labels) for e in switches):
                continue                      # feature is off; nothing to say
            for e in others:
                if not matches(e, labels):
                    findings.append(
                        f"{name}: enabled, but needs {e.get('key')} "
                        f"{e.get('operator')} {e.get('values', [])} "
                        f"and cluster has {labels.get(e.get('key'))!r}")

    for line in sorted(set(findings))[:10]:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
