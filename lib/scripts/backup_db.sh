#!/bin/bash
# Nightly database backup to S3-compatible object storage, with daily / weekly /
# monthly / yearly rotation.
#
# Takes its target as arguments rather than hardcoding one, because this server
# runs more than one app and a script that names one of them keeps succeeding
# while the other silently has no backups at all.
#
#   backup_db.sh <container> <db_user> <db_name> <bucket> <aws_profile> [prefix]
#
# S3_ENDPOINT overrides the endpoint (defaults to Scaleway Paris).
#
# Example crontab:
#   0 3 * * * /root/backup_db.sh not-again-db not_again_user not_again_production not-again-db-backups not-again not-again >> /root/backup.log 2>&1
#
# The arguments exist because one server can host more than one app, and a
# script that hardcodes one of them keeps reporting success while the others
# silently have no backups at all. Add a line per app, staggered by a few
# minutes so two pg_dumps do not run at once.
#
# The profile matters: each Scaleway project has its own key, and one project's
# key cannot see the other's buckets. Omit it and the upload fails with
# AccessDenied rather than writing to the wrong place — noisy, not silent.
set -e

if [ $# -lt 5 ]; then
  echo "usage: $0 <container> <db_user> <db_name> <bucket> <aws_profile> [prefix]" >&2
  exit 64
fi

CONTAINER_NAME="$1"
DB_USER="$2"
DB_NAME="$3"
BUCKET_NAME="$4"
AWS_PROFILE_NAME="$5"
PREFIX="${6:-$DB_NAME}"

# The S3 endpoint. Overridable because this script is not Scaleway-specific and
# the rest of the app is not either — the app reads it from credentials, but this
# runs on the HOST via cron, outside the container, so it cannot see them.
# Set it in the cron line: S3_ENDPOINT=https://s3.example.com /root/backup_db.sh …
ENDPOINT="${S3_ENDPOINT:-https://s3.fr-par.scw.cloud}"
AWS=/usr/local/bin/aws
S3="s3://$BUCKET_NAME"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_FILE="/root/${PREFIX}_backup_$TIMESTAMP.dump"
FNAME="${PREFIX}_backup_$TIMESTAMP.dump"

# The local dump goes even if we abort part way. Without this, a failed run
# leaves a half-written multi-hundred-megabyte file on the root disk, and the
# next failure leaves another.
trap 'rm -f "$BACKUP_FILE"' EXIT

# Not an error: this lets a cron line be scheduled BEFORE the app it backs up
# exists, so nobody has to remember to add it on deploy day. It starts working by
# itself the moment the container is there. Exit 0, so cron stays quiet.
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
  echo "$CONTAINER_NAME is not running — nothing to back up yet, skipping."
  exit 0
fi

echo "Starting backup of $DB_NAME from $CONTAINER_NAME..."

# ⚠️ On the 1st, the sign-in log is left out of the dump.
#
# sign_in_events records who tried to log in — personal data, kept 90 days in the
# database. The 1st-of-month dump is the file that also becomes the monthly and
# the yearly copy, and yearly copies are kept ten years. Without this, a 90-day
# retention rule would quietly be a ten-year one.
#
# The other 29 days keep it, so a backup from shortly before a break-in still has
# the evidence in it — which is the only time anyone wants it from a backup.
# 1 January is the 1st of a month, so this one condition covers yearly too.
#
# --exclude-table-DATA, never --exclude-table: the first keeps the CREATE TABLE
# and drops the rows, so a restore is completely ordinary. The second omits the
# table, and because schema_migrations still comes across with the migration
# marked as run, db:migrate will NOT recreate it — leaving you writing DDL by
# hand in the middle of a real restore.
DUMP_OPTS=()
if [ "$(date +%d)" = "01" ]; then
  echo "First of the month — excluding sign_in_events data from this dump."
  DUMP_OPTS+=(--exclude-table-data=sign_in_events)
fi

# no -t: a TTY can corrupt the binary -F c dump with carriage returns
docker exec "$CONTAINER_NAME" pg_dump -U "$DB_USER" -F c "${DUMP_OPTS[@]}" "$DB_NAME" > "$BACKUP_FILE"

# ⚠️ Check the dump before uploading it. pg_dump can exit 0 having written
# nothing useful — a container starting up, a database not yet created — and an
# empty file uploaded over a good one is the classic way a backup system reports
# success for months and then has nothing when you need it.
#
# A custom-format dump always begins with the five bytes PGDMP.
if [ ! -s "$BACKUP_FILE" ]; then
  echo "ABORT: dump is empty — nothing uploaded, yesterday's backup left intact" >&2
  exit 1
fi
if [ "$(head -c 5 "$BACKUP_FILE")" != "PGDMP" ]; then
  echo "ABORT: dump does not look like a pg_dump custom archive — nothing uploaded" >&2
  exit 1
fi
echo "Dump looks valid ($(du -h "$BACKUP_FILE" | cut -f1))."

echo "Uploading daily copy..."
$AWS s3 cp --profile "$AWS_PROFILE_NAME" "$BACKUP_FILE" "$S3/daily/$FNAME" --endpoint-url "$ENDPOINT"

if [ "$(date +%u)" = "7" ]; then
  echo "Sunday — uploading weekly copy..."
  $AWS s3 cp --profile "$AWS_PROFILE_NAME" "$BACKUP_FILE" "$S3/weekly/$FNAME" --endpoint-url "$ENDPOINT"
fi

if [ "$(date +%d)" = "01" ]; then
  echo "First of the month — uploading monthly copy..."
  $AWS s3 cp --profile "$AWS_PROFILE_NAME" "$BACKUP_FILE" "$S3/monthly/$FNAME" --endpoint-url "$ENDPOINT"
fi

# Kept 10 years, spanning the longest statutory retention period, so that losing
# the database and its recent backups together cannot destroy records still
# under it.
#
# Deleting from the live database is NOT propagated into any tier. Data ages out
# instead — roughly twelve months for daily/weekly/monthly, ten years here — and
# backups are restored only for disaster recovery, so deleted data does not
# re-enter the live system in normal operation. Do not add scrubbing to
# "complete" an erasure: it defeats this tier's purpose, and the ageing-out is
# what makes the position defensible without it.
if [ "$(date +%m-%d)" = "01-01" ]; then
  echo "First of January — uploading yearly copy..."
  $AWS s3 cp --profile "$AWS_PROFILE_NAME" "$BACKUP_FILE" "$S3/yearly/$FNAME" --endpoint-url "$ENDPOINT"
fi

echo "Backup complete: $FNAME"
