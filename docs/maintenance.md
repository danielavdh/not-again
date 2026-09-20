# Maintenance — what has to keep happening

Everything this app needs done on a recurring basis, and by whom. Written 2026-08-25.

Three roles, because self-hosting splits them:

- **automatic** — a scheduled job inside the app; nobody has to remember
- **operator** — whoever runs the server; may not be a developer
- **developer** — whoever maintains the code

Companion document: `docs/known-limitations.md` — what has to be true before somebody else can run this.

<!-- toc -->

**Contents**

- [Automatic — `config/recurring.yml`](#automatic--configrecurringyml)
- [The weekly report](#the-weekly-report)
    - [If the report says a backup shrank](#if-the-report-says-a-backup-shrank)
- [Operator](#operator)
    - [Database backups — `lib/scripts/backup_db.sh`](#database-backups--libscriptsbackup_dbsh)
    - [Mirroring to a second provider — optional, `lib/scripts/mirror_to_second_provider.sh`](#mirroring-to-a-second-provider--optional-libscriptsmirror_to_second_providersh)
    - [Restore drill — twice a year, on your own machine](#restore-drill--twice-a-year-on-your-own-machine)
    - [Server](#server)
    - [Memory — watch for it, don't chase it](#memory--watch-for-it-dont-chase-it)
    - [The master key](#the-master-key)
    - [Secret rotation](#secret-rotation)
- [Developer](#developer)
    - [Every push — CI](#every-push--ci)
    - [Weekly — Dependabot](#weekly--dependabot)
    - [Rails and Ruby upgrades](#rails-and-ruby-upgrades)
    - [PostgreSQL major versions](#postgresql-major-versions)
    - [Tax catalogues — annually, per country](#tax-catalogues--annually-per-country)
    - [Tax forms](#tax-forms)
- [Calendar-driven, per entity](#calendar-driven-per-entity)
    - [Year-end archive](#year-end-archive)
    - [Retention sweep](#retention-sweep)
- [Event-driven](#event-driven)
- [Known gaps](#known-gaps)

<!-- tocstop -->

---

## Automatic — `config/recurring.yml`

Already running, listed here so nobody rebuilds them or assumes they exist when they don't.

| Job | When | What it does |
|---|---|---|
| `fetch_hmrc_exchange_rates` | 03:00 on the 1st | HMRC publishes ahead of the month it names |
| `fetch_ecb_exchange_rates` | 20:00, 28th–31st | month-end spot rate; the job refuses any day but the last |
| `fetch_estv_exchange_rates` | 04:00 on the 26th | Swiss monthly average, complete around the 25th |
| `fetch_bundesbank_exchange_rates` | 04:00 on the 3rd | published on the first working day of the following month |
| `fill_rate_gaps` | 05:00 daily | the safety net under all four — fills whatever the books need and the database lacks |
| `tax_form_watch` | 06:00 on the 2nd | German Vordrucke appear Aug/Sep, HMRC SA1xx Nov/Dec; silent unless a form changed |
| `entity_retention_sweep` | 05:00 on the 1st | surfaces orphaned entities whose retention has elapsed, for a human to confirm |
| `archive_sweep` | 05:30, Jan 1 only | the safety net under closing and the on-demand button — anyone who never does either still gets one permanent archive for the year before last (a full year's grace, since nobody has last year done on Jan 1) |
| `hmrc_sandbox_healthcheck` | Mondays 04:00 | exercises the HMRC sandbox and validates the fraud-prevention headers; returns immediately unless sandbox credentials are configured |
| `session_sweep` | hourly at :42 | sessions never expire on their own; removes demo sessions quiet for an hour and upload-only ones quiet for a year |
| `sign_in_event_sweep` | 04:30 daily | drops sign-in records older than 90 days — personal data, kept only while it serves its purpose |
| `clear_solid_queue_finished_jobs` | hourly at :12 | queue table hygiene |
| `maintenance_report` | Mondays 07:00 | the weekly check below — the only one of these that watches the others |

---

## The weekly report

`MaintenanceReportJob` emails the sudo admin — falling back to `CONTACT_EMAIL` — the result of `Maintenance::WeeklyCheck`:

| Check | What it looks at |
|---|---|
| Backups | the newest object under `daily/` in `scaleway.backup_bucket`: its age, its size, and whether it suddenly shrank |
| Bucket privacy | every configured bucket (receipts, tax archive, backups) refuses an anonymous, credential-less `ListObjectsV2` — flags any that answers instead of refusing |
| Exchange rates | periods `Rates::GapFinder` still reports missing after 30 days of nightly fill attempts |
| Background jobs | `SolidQueue::FailedExecution` — jobs that errored and gave up |
| Sign-ins | attempts in the last 7 days: how many succeeded, how many failed, how many were stopped by the second factor |

Three things about it are deliberate and should not be tidied away:

**It emails every week, pass or fail.** Something that writes only when it finds a problem cannot tell you it has stopped running: silence means "all well" and "the scheduler is dead" at the same time. Because the report always arrives, a Monday *without* one is itself the alarm. Changing this to "only mail when something is wrong" removes the only check on the checker.

**Every check asks about the world, not about the code.** Not "did the backup job run" but "how old is the newest object in the bucket". A job can run to completion, report success, and produce nothing — which is precisely how a backup system reports success for months and then has nothing.

**There is no "are the workers alive" line**, because it could only ever say yes: the mail cannot be sent unless the scheduler fired and a worker ran it.

Set `scaleway.backup_bucket` in credentials to the bucket `backup_db.sh` uploads to. There is no fallback on purpose — a guessed name could read some empty bucket and report the backups healthy.
Left unset, the check says the backups are not being watched rather than passing silently.

A gap it does **not** close: it tells the maintainer, not the bookkeepers. See
`known-limitations.md` §7.

### If the report says a backup shrank

The line reads *"newest is X, down from Y — dump may be incomplete"*. Work through it in this order.

**1. Look at the date of the newest backup.** If it is the **1st of a month**, this is probably expected: `backup_db.sh` leaves `sign_in_events` out of the 1st-of-month dump, because that file also becomes the monthly and the yearly copy, and yearly copies are kept ten years. A 90-day retention rule cannot survive being written into a ten-year file. On an ordinary installation the difference is a fraction of the total and will not trip a 50% threshold — but on a small installation under sustained attack the sign-in log can outgrow the books, and then it will.

**2. If the date is anything else, look inside the dump.** Nothing has been deleted — the object is still in the bucket, and the previous days are too:

```
aws s3 cp --profile <profile> s3://<bucket>/daily/<file> . --endpoint-url <endpoint>
pg_restore -l <file> | grep "TABLE DATA" | wc -l      # how many tables carry data
pg_restore -l <file> | grep "TABLE DATA"              # and which
```

Do the same for the previous day's file and compare. A dump missing whole tables is a real incident; a dump that is merely smaller usually means data was legitimately removed — an entity purged, a retention sweep, a year archived.

**3. Nothing was overwritten.** The alarm is advisory: it reports, it does not delete or replace anything. `backup_db.sh` refuses to upload an empty file or one that is not a `PGDMP` archive, and leaves the previous night's copy intact when it does — so the older backups are all still there while you work out what happened.

---

## Operator

### Database backups — `lib/scripts/backup_db.sh`

Runs `pg_dump -F c` inside the database container, uploads to S3-compatible object storage, and keeps a tiered set: daily always, weekly on Sundays, monthly on the 1st, yearly on 1 January (ten years, matching the longest statutory retention).

It takes its target as arguments, so one script serves several apps on one server:

```
backup_db.sh <container> <db_user> <db_name> <bucket> <aws_profile> [prefix]
```

The profile matters when each app's storage lives in its own project with its own key: omitting it means the upload fails with AccessDenied rather than quietly writing to the wrong place. A cron line can be added before the app it backs up exists — the script exits 0 with a note when its container is not running, so nothing has to be remembered on deploy day.

**The dump is verified before upload** — non-empty, and beginning with the five bytes `PGDMP` that mark a custom-format archive. `pg_dump` can exit 0 having written nothing useful, and an empty file uploaded over a good one is how a backup system reports success for months and then has nothing.

**Pruning is a lifecycle rule on the bucket**, not the script's job: 30 days for `daily/`, 90 for `weekly/`, 365 for `monthly/`, 3653 for `yearly/`.

**A failed run is caught by the weekly report**, not by the script. `set -e` exits nonzero and cron mails root, which on a bare server goes nowhere — so the check is made from the other end, against the bucket's newest object, where a run that never happened and a run that failed look the same and are both wrong.

**Receipts are deliberately not backed up at all — decided, not an oversight.** This only dumps Postgres; the receipt files themselves live in object storage. A receipt already exists in two independent places — the admin's own copy (a phone, a scanner, wherever the original came from) and the live bucket — and retaining the source document for the statutory period is the admin's responsibility, not this app's; see `docs/self-hosting-legal.md`. A third copy would not meaningfully reduce risk. Tax filings and the year-end/on-demand books archives (`known-limitations.md` §8) are different: nobody but this app has a copy of those, so they ARE mirrored — see below.

### Mirroring to a second provider — optional, `lib/scripts/mirror_to_second_provider.sh`

Database backups, tax filings, and the archive CSVs, mirrored to a second object-storage provider under entirely separate credentials — recommended if losing the primary provider's account (not just a disk) would be a real problem, which for ten years of someone's actual books it usually is. Scaleway's own redundancy already covers hardware failure; it does nothing for an account-level loss, and neither does a second bucket in the same account.

**Not receipts.** The archive CSVs share a bucket with receipts (`ObjectStorage::BUCKET` / `not-again-shrine`) — the script must be pointed at the `archives/` prefix specifically, never the bucket whole, or it silently starts mirroring receipts nobody decided to back up.

Any S3-compatible provider works — the script takes endpoint, profile and bucket as arguments, nothing provider-specific is written into it. **OVH Object Storage** is what this install actually uses: pure per-GB billing with no monthly minimum (unlike Hetzner, whose flat per-hour fee costs far more than this app's actual data volumes justify — checked and reversed after building the Hetzner version first), no egress fees as of January 2026, and already a listed provider in this app's own README. EU region: Strasbourg (SBG).

**Set up once** (verified end to end against a real OVH bucket, 2026-09-04/05):

1. Create a Public Cloud project, then an Object Storage container in an EU region — Strasbourg or Gravelines, **1-AZ, not 3-AZ**: the extra redundancy is pointless on top of already having two separate providers.
2. **Enable versioning** — cheap, and turns a delete into a recoverable marker rather than the object actually vanishing.
3. **Enable Object Lock at bucket creation** — it cannot be added later, only at creation, so this is the one moment to decide. Leave the **bucket-wide default retention disabled**: a blanket default would block the lifecycle rule below from ever actually deleting `daily/`. Locking stays per-object, applied only to the long-lived uploads (`yearly/`, the tax bucket, `archives/`) — not yet wired into the script <!-- TODO: wire Object Lock retention into mirror_to_second_provider.sh -->, see its own header comment.
4. Create an Object Storage user for S3 credentials; save the Access Key and Secret Key immediately, they are typically shown once.
5. A lifecycle rule on the destination bucket, scoped to prefix `daily/`, expiring current versions after 75 days, cleaning up incomplete multipart uploads after 7 days. Leave `yearly/`, the tax bucket, and `archives/` unexpired.
6. Add the destination profile: `aws configure --profile ovh` (region `sbg`), same as the primary already is. Verify with `aws s3 ls --profile ovh --endpoint-url https://s3.sbg.io.cloud.ovh.net/` — empty output with no error means it works.

⚠️ **These credentials do not go into `credentials.yml.enc`.** The Rails app never touches this bucket — only this standalone script does, via its own AWS CLI profile on whichever machine runs it.

**Cron, one line per (bucket, prefix) pair** — see the script's own header for the full example:

```
15 4 * * * /root/mirror_to_second_provider.sh not-again-db-backups scaleway https://s3.fr-par.scw.cloud not-again-mirror ovh https://s3.sbg.io.cloud.ovh.net/ daily/
20 4 * * * /root/mirror_to_second_provider.sh not-again-db-backups scaleway https://s3.fr-par.scw.cloud not-again-mirror ovh https://s3.sbg.io.cloud.ovh.net/ yearly/
25 4 * * * /root/mirror_to_second_provider.sh not-again-tax        scaleway https://s3.fr-par.scw.cloud not-again-mirror ovh https://s3.sbg.io.cloud.ovh.net/
30 4 * * * /root/mirror_to_second_provider.sh not-again-shrine     scaleway https://s3.fr-par.scw.cloud not-again-mirror ovh https://s3.sbg.io.cloud.ovh.net/ archives/
```

Database backups mirror `daily/` and `yearly/` only — once a year closes, its yearly dump and that entity's archive CSV already describe it; the daily granularity from a now-closed year has no further recovery value, so `weekly/`/`monthly/` are left unmirrored on purpose.

**Not yet done:**

<!-- TODO: wire the four cron lines above onto the production server — waiting on first deploy -->
- Wiring the actual cron lines above onto the production server (waiting on first deploy).
<!-- TODO: add Object Lock retention (aws s3api put-object-retention, Governance mode) to mirror_to_second_provider.sh for the long-lived uploads, and verify put-object-retention's behaviour on OVH specifically -->
- Adding Object Lock retention (`aws s3api put-object-retention`, Governance mode) to the script for the long-lived uploads — the sync itself is tested and working; that follow-up call's behaviour on OVH specifically has not been verified yet.

### Restore drill — twice a year, on your own machine

**Not the server.** Restoring into a scratch database on the same box that runs the real one risks resource contention and touching the wrong database, for a task that exists only to prove recoverability. Do it on your own laptop instead — pull the dump down, restore it locally, throw it away.

**1. Pull the newest dump down**, using the same credentials the app itself uses — no separate AWS profile needed, since `credentials.yml.enc` already has them:

```bash
eval "$(bin/rails runner 'puts "export AWS_ACCESS_KEY_ID=#{ObjectStorage::ACCESS_KEY}"; puts "export AWS_SECRET_ACCESS_KEY=#{ObjectStorage::SECRET_KEY}"; puts "export BUCKET=#{ObjectStorage::BACKUP_BUCKET}"; puts "export ENDPOINT=#{ObjectStorage::ENDPOINT}"')"
aws s3 ls "s3://$BUCKET/daily/" --endpoint-url "$ENDPOINT"   # find the newest
aws s3 cp "s3://$BUCKET/daily/<newest-file>" . --endpoint-url "$ENDPOINT"
```

**2. Restore it into a scratch database** and check that it opens, that the row counts are plausible, and that a receipt resolves. Half an hour, and it is the only evidence any of the above works — a verified dump proves the file is well-formed, never that it can be brought back.

### Server

OS security updates, disk space, the LUKS volume unlocking after a reboot, TLS certificates (kamal-proxy renews them, so this is a "confirm it happened" rather than a task), fail2ban and `rack_attack` logs.

### Memory — watch for it, don't chase it

Ruby processes are prone to RSS creep from allocator fragmentation — normal,
well-known, not specific to this app. `jemalloc` is already built into the
`Dockerfile` (`libjemalloc2` installed, `LD_PRELOAD` set at the image level),
which is the standard fix for the classic glibc-fragmentation cause, so
there is nothing to set up. If memory still climbs and never settles, it is
worth watching for.

⚠️ **The obvious check gets the wrong process.** With Thruster fronting the
app, `PID 1` inside the container is `thrust` (a Rust binary), not Puma —
checking `/proc/1/...` for RSS, or for jemalloc, gives a false reading every
time. Get the real host-side PIDs first, then read the *host's* own procfs
(`docker exec` cannot see them — a different PID namespace):

```bash
docker top not-again-web                              # host-side PIDs
grep VmRSS /proc/<host-pid>/status                     # a specific process
docker stats --no-stream not-again-web                 # the trustworthy total
```

Use the `docker stats` total, not a sum of individual processes' RSS — Puma's
workers and Solid Queue's supervised children are forked, so they share huge
swaths of the same loaded code as copy-on-write pages, and adding up their
RSS figures counts that shared memory once per process instead of once.

**Plateauing is normal**, whatever level it settles at — a new deploy, more
data, more background jobs all shift the baseline without that being a leak.
**Climbing with no plateau, over several days, is the real signal.** If
capping ever turns out to be necessary: the `puma_worker_killer` gem
(graceful, restarts one worker past a memory threshold) or a deliberately
scheduled `kamal app boot` via cron at a quiet hour — never a full server
reboot for this.

### The master key

`config/master.key` backed up somewhere that is not the server and not the laptop it was generated on. See `known-limitations.md` §6 for what its loss actually costs — less than folk wisdom suggests, but the **succession** case is real: if only one person can get into the Scaleway account, the books have a single point of failure that is a human being.

### Secret rotation

Scaleway keys, SMTP credentials, `secret_key_base`. No fixed schedule proposed; rotate on personnel change and on any suspected exposure.

---

## Developer

### Every push — CI

`brakeman` against `config/brakeman.ignore`, `bundler-audit check --update`, `bin/importmap audit`, and the full test suite including system tests. Green is the baseline; a red CI is the alarm, and treating it as noise defeats the whole arrangement.

### Weekly — Dependabot

Grouped into one PR per ecosystem, majors kept separate. Security advisories are never grouped and arrive on their own, which is the point of the grouping.

### Rails and Ruby upgrades

On the normal cadence. One thing rides along: `bundle update rails-i18n` alongside Rails, since Rails' own strings (dates, numbers, currency formats, errors) now come from that gem rather than files copied into `config/locales/` — which holds only the app's own strings now. Propshaft / importmap behaviour is also worth re-checking because there is no build step to catch drift.

### PostgreSQL major versions

`postgres:17` is pinned in the Kamal accessory. A major bump needs `pg_upgrade` or a dump/restore, and it is the single most dangerous routine operation on the system. Do it after a verified restore drill, never before.

### Tax catalogues — annually, per country

Corrected in place, never by year file; the loader prunes; load **after** migrate — the pre-deploy hook does both, in that order.

### Tax forms

`TaxFormWatchJob` reports changes; acting on them is manual and seasonal — German forms Aug/Sep, HMRC Nov/Dec.

---

## Calendar-driven, per entity

### Year-end archive

One undeletable CSV per **calendar year** per **scope** (a family `g<id>`, or a
solo entity code), written when the last member with activity has closed through
that year — or by `ArchiveSweepJob` on 1 Jan for year `current - 2` if nobody
has. `Archives::YearEnd` is the trigger brain; `EntityGroupMembership` (a
complete per-entity timeline) decides which scope owns which days. See
`known-limitations.md` §8.

### Retention sweep

Automatic, monthly. It never deletes on its own: it emails the sudo admin — falling back to `CONTACT_EMAIL` — a review list of the entities whose retention period has elapsed. Deletion stays a deliberate, sudo-confirmed act.

---

## Event-driven

| Event | What has to happen |
|---|---|
| Deploy | `kamal deploy`; migrations run via the pre-deploy hook; watch the first request |
| New admin | invited by an owner; entity access is granted per entity, not globally |
| Admin leaves | `lib/tasks/offboarding.rake`; check whether an entity is left orphaned |
| Entity closed | `EntityPurgeService`, subject to the retention policy |
| New country or scheme | two YAML files, possibly one Ruby class: `db/tax_categories/<cc>_<scheme>_<year>.yml` and a country block in `db/exchange_rate_rules.yml` |
| New language | one line in `config/initializers/locale.rb`, one file in `config/locales/` (the app's strings — Rails' own come from the `rails-i18n` gem), three manual pages in `app/views/help/` |
| Security report | the address in `/.well-known/security.txt`, which is generated from `CONTACT_EMAIL` |

---

## Known gaps

- **Receipts have no backup separate from the live bucket, by design** — not planned, see the "Database backups" section above for why.
<!-- TODO: schedule the mirror_to_second_provider.sh cron lines on the production server, waiting on first deploy -->
- **The second-provider mirror (tax filings, database backups, archive CSVs) is built and tested but not yet scheduled on the production server** — waiting on first deploy. See "Mirroring to a second provider" above.
<!-- TODO: run a real restore drill, as part of the data migration into this app (a full dump-and-load already exercises the same path) -->
- No restore has been tested. Planned as part of the data migration into this app, which is a full dump-and-load and so exercises the same path with something real at stake.
- No visible "last backup" or "last archive" date for the people who depend on them. The weekly report tells the maintainer; the bookkeepers still cannot see it. `known-limitations.md` §7.
