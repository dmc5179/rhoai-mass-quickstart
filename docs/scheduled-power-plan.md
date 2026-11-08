# Plan: park and resume the cluster on a schedule

Status: **plan only, not started** (2026-11-08). Nothing here is
implemented.

## Goal

Stop paying for compute outside working hours without anyone remembering to
run `scripts/cluster-power.sh`. For example, park at 19:00 and resume at 07:00
US Eastern on weekdays, and stay parked all weekend.

## Why Amazon EventBridge Scheduler

EventBridge Scheduler runs a target on a cron or rate schedule, with a time
zone, and needs nothing running in the cluster. That matters, because the
cluster is off half the time. A Kubernetes CronJob cannot turn its own cluster
back on.

**Checked on account 130382331273 (RHDP `sandbox141`, us-east-2) on
2026-11-08:**

- the Scheduler API answers (`aws scheduler list-schedule-groups` returns the
  `default` group, with no schedules yet);
- an IAM simulation for the admin user allows `scheduler:CreateSchedule`,
  `scheduler:CreateScheduleGroup`, `iam:CreateRole`, `iam:PassRole`,
  `iam:PutRolePolicy`, `lambda:CreateFunction`, `ec2:StopInstances`,
  `ec2:StartInstances` and `ec2:DescribeInstances`.

The simulation covers the user's IAM policies but not any organization
service control policy RHDP may apply. The first real create (step 4 below,
as a disabled schedule) is the final proof.

## Design

```
EventBridge Scheduler  ──(cron, America/New_York)──►  Lambda "rhoai-power"
   rhoai-park    Mon–Fri 19:00                          {"action": "park"}
   rhoai-resume  Mon–Fri 07:00                          {"action": "resume"}
```

**Why a Lambda rather than Scheduler's direct EC2 target.** Scheduler can call
`ec2:StopInstances` directly (a "universal target"), but only with a fixed
list of instance IDs. Our instance IDs change: machines get replaced, the GPU
MachineSet scales, and spot workers come and go. The Lambda finds the
cluster's instances by tag (`kubernetes.io/cluster/<infraID>: owned`) every
time, the same way `cluster-power.sh` does.

**What the Lambda does.** It mirrors `cluster-power.sh`, so there is one
behaviour whichever way the cluster is parked:

| Action | Order |
|---|---|
| park | Stop workers (including GPU), then the control plane. Spot instances can't be stopped (the Machine API creates one-time spot requests), so they are **terminated**; see below |
| resume | Start the control plane, wait for the instances to be running, then start workers |

**Spot instances.** The rules decided 2026-11-08 are that the control plane is
never spot and at least 2 workers are never spot. Those are stopped and
started normally. Spot workers and a spot GPU are terminated at park time. On
resume, their Machines are gone, so they need replacing:

- Option A: a MachineHealthCheck on the spot MachineSets, which the OpenShift
  docs recommend for spot anyway. It deletes the dead Machines and the
  MachineSet recreates them. No cluster access is needed from AWS.
- Option B: scale the spot MachineSets to zero before parking, and back up on
  resume. This needs cluster API access, which the Lambda doesn't have.

The plan uses Option A. It has to be proven on the cluster.

## Steps

1. **`scripts/power-schedule.sh {install|status|remove|run-now} [--dry-run]`**,
   following the repo's script conventions (`lib-logging.sh`, `--dry-run`,
   reuse rather than duplicate). It creates:
   - IAM role `rhoai-power-lambda`: allows `ec2:DescribeInstances`, and
     `ec2:StopInstances`, `ec2:StartInstances` and `ec2:TerminateInstances`
     conditioned on the cluster tag, plus CloudWatch Logs;
   - Lambda `rhoai-power` (Python, boto3), with the infra ID as an
     environment variable read from `clusters/<name>/metadata.json`;
   - IAM role `rhoai-power-scheduler`: `lambda:InvokeFunction` on that
     function only;
   - schedule group `rhoai`, with two schedules built from `cluster.env`
     settings: `POWER_PARK_CRON`, `POWER_RESUME_CRON`, `POWER_TZ`
     (default `America/New_York`).
2. **Safety rules in the Lambda:**
   - Do nothing during the first 24 hours after install. The cluster's
     certificates rotate then, and OpenShift's graceful shutdown guidance
     says not to shut down in that window.
   - Park only if every instance is in a steady state.
   - Resume is idempotent.
   - A `"dryRun": true` input logs what it would do and changes nothing.
3. **This repo's other scripts:**
   - `cluster-power.sh status` shows the schedules and their next run.
   - `cluster-power.sh` and the Lambda share the same tag selection and
     ordering.
   - `90-destroy-cluster.sh` calls `power-schedule.sh remove`, so schedules
     don't fire against a deleted cluster.
   - `checkup.sh` warns about pending CSRs after a resume (see below).
4. **Prove it:**
   - install with the schedules disabled, then `run-now --dry-run`;
   - enable a park 10 minutes ahead and a resume 20 minutes ahead;
   - check `checkup.sh` is green afterwards.
5. **Docs:** `docs/operations.md` (parking on a schedule, what resume looks
   like) and a line in the deploy runbook.

## Optional extras

- **RDS:** the same schedules can stop and start the MaaS database
  (`rds:StopDBInstance`). AWS restarts a stopped RDS instance after 7 days, so
  this only helps for overnight and weekend parking.
- **The NAT gateway** can't be stopped and bills hourly. Deleting and
  recreating it is possible but changes the VPC stack. Not planned.

## Things to verify on the cluster

- **CSRs after resume.** If the cluster is parked long enough for node
  certificates to expire, nodes come back needing CSR approval
  (`oc get csr`, then approve). AWS can't do that, so `checkup.sh` should flag
  pending CSRs and the docs should give the command.
- **The MachineHealthCheck** replaces terminated spot Machines on resume, and
  doesn't fight the termination handler during a real interruption.
- **The schedule time zone** handles daylight saving correctly
  (`America/New_York` in Scheduler, not a fixed UTC offset).
