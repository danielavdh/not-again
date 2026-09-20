#!/bin/bash
# Mirrors ONE bucket/prefix to a second, independent object-storage provider —
# see docs/known-limitations.md §8 and docs/maintenance.md. Entirely optional:
# nothing in the app requires this to exist, and the app never reads from it.
#
# Provider-agnostic on purpose — everything specific to a provider (endpoint,
# profile, bucket name) is an argument, not something written into this file.
# Started against Hetzner, moved to OVH once Hetzner's flat per-hour billing
# turned out to cost far more than this app's actual (tiny) data volumes
# justify — nothing in this script changed either time.
#
# WHY A SECOND PROVIDER AT ALL: the primary provider's own redundancy protects
# against a disk failing, not against something being deleted by mistake, or
# the account itself being lost, suspended or compromised. A second copy under
# entirely separate credentials is the only thing that survives that.
#
# WHY NOT RECEIPTS: already covered by two independent copies — the admin's
# own, and the primary bucket's. A third copy is not proportionate; see the
# receipts-retention note in docs/self-hosting-legal.md. This is why the
# receipts bucket is never mirrored whole — only ever the archives/ prefix
# inside it, explicitly, per call. Get that prefix wrong and this quietly
# starts backing up receipts nobody asked it to.
#
# HOW: two `aws s3 sync` calls through a persistent local staging directory,
# not one cross-endpoint call — the AWS CLI's --endpoint-url applies to the
# whole command, so a single sync cannot address two different providers at
# once. rclone can talk remote-to-remote directly, but that is a second tool
# this app does not otherwise depend on; two aws calls costs nothing new.
#
# The staging directory is REUSED across runs, not a fresh mktemp each time —
# source prefixes here (daily/ backups especially) only ever grow, never
# shrink, so a throwaway directory would re-download the entire history every
# single run instead of just the one new file since last time.
#
#   mirror_to_second_provider.sh <src_bucket> <src_profile> <src_endpoint> \
#                                <dst_bucket> <dst_profile> <dst_endpoint> \
#                                [prefix]
#
# Example crontab — one line per (bucket, prefix) pair, staggered so two syncs
# never overlap. Database backups mirror daily/ and yearly/ only: a closed
# year's daily granularity has no recovery value once that year's yearly dump
# and archive CSV exist, so weekly/monthly are deliberately left unmirrored.
#
#   15 4 * * * /root/mirror_to_second_provider.sh \
#     not-again-db-backups scaleway https://s3.fr-par.scw.cloud \
#     not-again-mirror ovh https://s3.sbg.io.cloud.ovh.net/ daily/
#   20 4 * * * ... not-again-db-backups ... not-again-mirror ... yearly/
#   25 4 * * * ... not-again-tax        ... not-again-mirror ... (no prefix — mirror it whole)
#   30 4 * * * ... not-again-shrine     ... not-again-mirror ... archives/
#
# A lifecycle rule on the destination bucket (expiration only, see
# docs/maintenance.md) should prune the mirrored daily/ prefix after ~75 days;
# this script never passes --delete, so pruning is the lifecycle rule's job,
# never this one's.
#
# ⚠️ Object Lock retention (Governance mode, on the long-lived uploads —
# yearly/, the tax bucket, archives/ — never daily/) is NOT wired in here yet.
# The destination bucket already has Object Lock enabled with no bucket-wide
# default, so nothing is locked until something explicitly asks for it via
# `aws s3api put-object-retention` after the sync. Deliberately left out of
# this first version rather than shipped unverified: unlike the sync itself
# (tested end to end against the real OVH bucket), put-object-retention's
# behaviour on OVH specifically has not been.
set -e

if [ $# -lt 6 ]; then
  echo "usage: $0 <src_bucket> <src_profile> <src_endpoint> <dst_bucket> <dst_profile> <dst_endpoint> [prefix]" >&2
  exit 64
fi

SRC_BUCKET="$1"; SRC_PROFILE="$2"; SRC_ENDPOINT="$3"
DST_BUCKET="$4"; DST_PROFILE="$5"; DST_ENDPOINT="$6"
PREFIX="${7:-}"

AWS=/usr/local/bin/aws
STAGING="/root/.mirror-staging/${SRC_BUCKET}/${PREFIX}"
mkdir -p "$STAGING"

SRC="s3://${SRC_BUCKET}/${PREFIX}"
DST="s3://${DST_BUCKET}/${PREFIX}"

echo "Pulling $SRC -> $STAGING ..."
$AWS s3 sync --profile "$SRC_PROFILE" --endpoint-url "$SRC_ENDPOINT" "$SRC" "$STAGING"

echo "Pushing $STAGING -> $DST ..."
$AWS s3 sync --profile "$DST_PROFILE" --endpoint-url "$DST_ENDPOINT" "$STAGING" "$DST"

echo "Mirrored $SRC -> $DST ($(du -sh "$STAGING" | cut -f1))"
