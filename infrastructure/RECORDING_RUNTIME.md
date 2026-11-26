# Tutor and coaching recording runtime

Application changes are reviewed in LMS_v2 PR #808. Use the existing session
worker; do not create another original-video uploader or migrate old coaching
recordings. New coaching meetings start at 26 November 2026, 00:00 in the LMS
business timezone. Coaches uses library 822010, one DE region and standard 720p.

Keep the three BUNNY_LIVE_STREAM_* and three BUNNY_COACH_STREAM_* values in the
existing Secrets Manager JSON. Store these three controls there as explicit
strings, initially `false`:

```
BUNNY_LIVE_RECORDING_UPLOADS_ENABLED
BUNNY_COACH_RECORDING_UPLOADS_ENABLED
BUNNY_RECORDING_DIRECT_FETCH_ENABLED
```

Never commit values or export a development environment over production. When
regenerating private Terraform variables, use `env_to_tfvars.py --production-env`
with a fresh private production reference: existing production values take
precedence and ECS maps the resulting key names through `app_secret_keys`.

For scoped reconciliation without a broad Terraform apply, from this folder:

```
python scripts/wire_recording_settings.py
python scripts/wire_recording_settings.py --apply --expected-plan <plan_sha256> --backup-dir <private-directory>
```

Review the read-only plan first. It adds only missing secret references to the
existing APIs, night API and session worker. Images, commands, roles, desired
counts, schedules and secret values are preserved. It refuses conflicting
settings, overlapping worker replacement and in-progress deployments. Retain
the private task-definition backup for rollback; wait for services to stabilize.

Activate only after the merged application release passes CI/CD, the overlapping
VPS original uploader is drained/disabled, and scoped tutor/coach recordings are
verified. Refresh ECS tasks after changing Secrets Manager values. Confirm one
GUID/import per source, the tutor week/component, the coach Quality occurrence,
captions and token rejection. Do not delete old journal rows to retry a failure.

Worker resources remain 1 vCPU / 3 GiB / 50 GiB until direct transfer and existing
non-video duties have been measured. A code change alone does not reduce this
always-on charge. No new uploader service or scheduler is provisioned here.
