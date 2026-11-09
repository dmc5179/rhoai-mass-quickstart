# Plan: park and resume the cluster on a schedule

Status: **plan only, not started** (2026-11-08; revised the same day after
research). Nothing here is implemented.

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

## Options compared (researched 2026-11-08)

| Option | How it finds instances | Code to maintain | Verdict |
|---|---|---|---|
| **A.** Scheduler universal target `ec2:stopInstances` / `startInstances` (the shape Gemini suggested) | A fixed list of instance IDs in the schedule | None | **No.** Our IDs change: machines get replaced, the GPU set scales, spot workers come and go. One call covers every listed instance, so a single spot instance (which can't be stopped) fails the lot |
| **B.** Scheduler universal target `ssm:startAutomationExecution`, running the AWS-managed `AWS-StopEC2Instance` / `AWS-StartEC2Instance` runbooks against a **tag** | `Targets: [{Key: "tag:kubernetes.io/cluster/<infraID>", Values: ["owned"]}]`, resolved on every run | None: AWS-managed runbooks | **Recommended** |
| **C.** Systems Manager Quick Setup *Resource Scheduler* | Tag key and value you choose | None | Works, but it's console-oriented and creates its own State Manager plumbing. It is harder to script, review and tear down with the cluster |
| **D.** Scheduler invoking a Lambda (the first draft of this plan) | Tag, in code | A Python function | Most control (ordering, spot termination, a 24-hour guard), but it's code we'd own. Keep it as the fallback if B can't handle spot cleanly |

## Design (option B)

```
EventBridge Scheduler (America/New_York)
  rhoai-park    cron(0 19 ? * MON-FRI *)  ──► ssm:startAutomationExecution
  rhoai-resume  cron(0 7 ? * MON-FRI *)        DocumentName: AWS-StopEC2Instance | AWS-StartEC2Instance
                                               TargetParameterName: InstanceId
                                               Targets: tag:kubernetes.io/cluster/<infraID> = owned
                                               MaxConcurrency: 100%   MaxErrors: <see spot>
                                               Parameters.AutomationAssumeRole: rhoai-power-automation
```

- Each tagged instance gets its own automation run, so one failure doesn't
  stop the rest. The installer and the Machine API put that tag on every
  cluster machine, so GPU and spot workers added later are picked up
  automatically.
- **Order:** none. The OpenShift 4.22 graceful-restart procedure says to
  "start all cluster machines" and then check nodes and CSRs. It doesn't
  require a start order on a cloud. Its control-plane-last note is about the
  API VIP on platforms that have one.
- **Two IAM roles:**
  - `rhoai-power-scheduler`, assumed by `scheduler.amazonaws.com`: allows
    `ssm:StartAutomationExecution` on the two runbooks, and `iam:PassRole` on
    the automation role only;
  - `rhoai-power-automation`, assumed by `ssm.amazonaws.com`: allows
    `ec2:StopInstances` and `ec2:StartInstances` **only on instances
    carrying the cluster tag** (`aws:ResourceTag` condition), plus
    `ec2:DescribeInstances`.

  That is much tighter than Gemini's `instance/*`.
- **Spot (once implemented).** `StopInstances` fails on one-time spot
  instances, so with B each spot instance's run fails on its own and the
  instance keeps running and billing. Two ways to handle it:
  1. allow those errors (`MaxErrors`) and have a third schedule terminate spot
     instances using a small custom runbook. The MachineHealthCheck replaces
     them on resume;
  2. or move to option D for parking only.

  Decide when spot is built. Until then nothing in the cluster is spot.
- **The 24-hour rule.** OpenShift says to confirm the cluster has been
  installed for at least 24 hours before shutting it down, while certificates
  complete their first rotation. The install script for the schedules refuses
  to enable them until `clusters/<name>/metadata.json` is 24 hours old.
- **After resume.** The docs say CSRs may need manual approval if
  certificates expired while the cluster was off, which isn't expected for
  overnight or weekend parking. Check the expiry date before a long shutdown:
  `oc -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}'`.
  `checkup.sh` should flag pending CSRs.
- **Confirmed on this account (2026-11-08):** `AWS-StopEC2Instance` and
  `AWS-StartEC2Instance` exist, each taking `InstanceId` (StringList) and
  `AutomationAssumeRole`. The Scheduler API answers, and IAM allows creating
  schedules and roles.

## Steps

1. **`scripts/power-schedule.sh {install|status|remove|run-now park|resume} [--dry-run]`**:
   - reads the infra ID from `clusters/<name>/metadata.json`;
   - creates or updates the two roles and the schedule group `rhoai`, with the
     two schedules from `cluster.env` (`POWER_PARK_CRON`,
     `POWER_RESUME_CRON`, `POWER_TZ`, default `America/New_York`;
     `POWER_SCHEDULE_ENABLED`);
   - `run-now` calls `aws ssm start-automation-execution` with the same input,
     to test without waiting for the cron.

   It follows the repo conventions: `lib-logging.sh`, `--dry-run`, and reuse
   rather than duplicate.
2. **`cluster-power.sh status`** lists the schedules and their next run.
   **`90-destroy-cluster.sh`** calls `power-schedule.sh remove`.
3. **Prove it:**
   - install with the schedules disabled;
   - `run-now park --dry-run`, then a real `run-now park` and `run-now resume`;
   - check `aws ssm describe-automation-executions` shows one execution per
     instance;
   - check `checkup.sh` is green after resume;
   - then enable the schedules.
4. **Docs:** `docs/operations.md` and the runbook.

## Sources

- [Using universal targets in EventBridge Scheduler](https://docs.aws.amazon.com/scheduler/latest/UserGuide/managing-targets-universal.html): ARN format `arn:aws:scheduler:::aws-sdk:service:apiAction`, `Input` shaped like the API request, no read-only actions.
- [SSM StartAutomationExecution API](https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_StartAutomationExecution.html): `Targets` (one item), `TargetParameterName`, `MaxConcurrency`, `MaxErrors`.
- [Systems Manager Quick Setup Resource Scheduler](https://docs.aws.amazon.com/systems-manager/latest/userguide/quick-setup-scheduler.html): option C.
- [re:Post: start/stop scheduling with EventBridge Scheduler and SSM Automation](https://repost.aws/articles/ARRCWqUo-CRwGq1ws2uwdsEQ/how-to-automate-start-stop-scheduling-for-non-production-aws-resources-using-eventbridge-scheduler-and-ssm-automation): the two-role pattern.
- [OpenShift 4.22 Backup and restore: graceful shutdown and restart](https://access.redhat.com/documentation/en-us/openshift_container_platform/4.22/html-single/backup_and_restore/index): the 24-hour rule, start all machines, CSRs.

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
