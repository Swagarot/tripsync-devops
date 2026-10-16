# TripSync backups and how to restore them

A CronJob (`tripsync-backup`, chart `templates/backup.yaml`) runs every night at
03:30 Israel time and writes to a volume on the NFS server (`nfs-client`
StorageClass, PVC `tripsync-backups`, folder under `/srv/nfs/k3s` on the NFS box):

| Path | What | Kept |
|---|---|---|
| `db/tripsync-YYYY-MM-DD.dump` | `pg_dump -Fc` of the whole database | 14 days |
| `photos/current/` | mirror of the Garage bucket `tripsync-photos` | always the latest |
| `photos/deleted/YYYY-MM-DD/` | photos deleted in the app that day | 30 days |
| `LAST_RUN.txt` | time of the last successful run, sizes | |

Alerts: `TripsyncBackupMissing` (no success for 26 h) and the built-in
`KubeJobFailed`. Limitation: the NFS server is in the same building as the
cluster, so this does not survive losing the building (fire, theft, surge).
An offsite copy (e.g. Cloudflare R2, 10 GB free) would close that gap.

## Run a backup now

```sh
kubectl --context default -n tripsync create job --from=cronjob/tripsync-backup backup-manual-$(date +%s)
kubectl --context default -n tripsync logs -f job/<that name> --all-containers
```

## Restore the database

Restoring replaces data, so stop the backend first (it would keep writing):

```sh
kubectl --context default -n tripsync scale deploy/tripsync-backend --replicas=0
# A throwaway pod with the backups mounted and the Postgres tools:
kubectl --context default -n tripsync run restore --rm -it --image=postgres:18.6-alpine \
  --overrides='{"spec":{"containers":[{"name":"restore","image":"postgres:18.6-alpine","stdin":true,"tty":true,
  "command":["sh"],"env":[{"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"tripsync-secrets","key":"postgres-password"}}}],
  "volumeMounts":[{"name":"b","mountPath":"/backups"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"tripsync-backups"}}]}}'
# inside the pod:
ls /backups/db
pg_restore -h tripsync-postgres -U tripsync -d tripsync --clean --if-exists /backups/db/tripsync-YYYY-MM-DD.dump
exit
kubectl --context default -n tripsync scale deploy/tripsync-backend --replicas=1
```

`--clean --if-exists` drops each table before recreating it from the dump. To
look before you leap, restore into a separate database first
(`createdb -h tripsync-postgres -U tripsync restore_check` and `-d restore_check`).

## Restore photos

A ready-made Job copies the mirror back into the bucket:

```sh
kubectl --context default -n tripsync apply -f docs/restore-photos-job.yaml
kubectl --context default -n tripsync logs -f job/tripsync-restore-photos
kubectl --context default -n tripsync delete job tripsync-restore-photos
```

It uses `rclone copy` (not `sync`): it only adds files missing from the bucket and
never deletes anything. A photo deleted by mistake is under
`photos/deleted/<date>/photos/<id>/`: set the Job's `SOURCE` to
`/backups/photos/deleted/<date>`. Its database row was soft-deleted, so after
copying the files back, clear its `deleted_at` (or restore the database dump).
