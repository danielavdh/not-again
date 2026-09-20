# Known limitations — what has to be true before someone else runs this

What's still open, with enough about the closed ones to explain what a code
comment or another doc means when it points at them by number — a handful do,
so those numbers stay reserved even once there is nothing left to say. Gaps in
the numbering (3, 4, 10, 11, 12, 14) are normal: those were closed with
nothing left open, and nothing points at them any more.

Not every item below is the same kind of open. Some are an architectural ceiling —
nothing to build, only to manage (§6). Some were decided against on purpose, and are
revisitable if the trade-off ever changes (§2, §7, §8's no-PDF/no-import line). One is
deliberate policy, not a gap (§8's receipts line). The rest are genuinely not built
yet, each with a TODO marking it (§9, §15).

Three deployment shapes are in scope, and the trade between them runs backwards from what
people expect — the most private is the least safe:

| | Confidentiality | Reliability |
|---|---|---|
| Own laptop, one person | perfect | worst: one disk, no redundancy |
| Own server, own businesses | perfect | your backup discipline |
| Someone else's server, shared | operator reads everything | best: someone competent is watching |

<!-- toc -->

**Contents**

- [1. Storage never falls back to the filesystem in production](#1-storage-never-falls-back-to-the-filesystem-in-production)
- [2. Filesystem storage is served without authentication in development](#2-filesystem-storage-is-served-without-authentication-in-development)
- [5. Path randomness protects less than it looks like](#5-path-randomness-protects-less-than-it-looks-like)
- [6. The master key, and the succession risk behind it](#6-the-master-key-and-the-succession-risk-behind-it)
- [7. Backup age is not shown to bookkeepers](#7-backup-age-is-not-shown-to-bookkeepers)
- [8. Getting the data out](#8-getting-the-data-out)
- [9. Docker Compose for people who are not developers](#9-docker-compose-for-people-who-are-not-developers)
- [13. Terms an admin actually agrees to](#13-terms-an-admin-actually-agrees-to)
- [15. Breach notice to affected admins is a promise, not a mechanism](#15-breach-notice-to-affected-admins-is-a-promise-not-a-mechanism)

<!-- tocstop -->

---

## 1. Storage never falls back to the filesystem in production

Closed. Production raises at boot if no S3 bucket is configured
(`config/initializers/00_object_storage.rb`), and `.kamal/hooks/pre-connect`
checks the real bucket before a deploy even starts. `test/object_storage_guard_test.rb`
fails if a filesystem fallback is ever reintroduced into the production branch
of `shrine.rb` — such a fallback would be both unauthenticated (§2) and wiped
on every deploy, so it is refused outright rather than allowed as a degraded
mode.

## 2. Filesystem storage is served without authentication in development

Open, and accepted. `public/uploads` in development has no auth check —
anyone who can reach the dev server can read it directly. `config/puma.rb`
binds loopback (`127.0.0.1`) outside production, so on an ordinary developer
machine nothing here is reachable by anyone but the person who started
`bin/dev`. The exposure is real only if someone deliberately overrides the
bind to `::` to test from a phone, or runs `bin/dev` itself as a production
server instead of deploying properly — both already-unsafe choices a fix here
would not meaningfully guard against. Decided not to build authenticated file
serving for development.

## 5. Path randomness protects less than it looks like

Closed — folded into §7's weekly check rather than fixed on its own terms.
Uploaded files get a random 16-character path segment, which stops someone
guessing a file's URL — but does nothing once a bucket answers
`ListObjectsV2` with no credentials at all, since that hands out every key
directly. Rather than try to make a public bucket harmless, `Maintenance::WeeklyCheck`
verifies weekly that every configured bucket (receipts, tax archive, backups)
refuses that anonymous listing request in the first place
(`bucket_privacy`). If every bucket stays private, path randomness never has
to matter.

## 6. The master key, and the succession risk behind it

Losing `config/master.key` costs less than it looks like — the Scaleway keys,
SMTP credentials and HMRC OAuth tokens it protects are all independently
recoverable from their own providers, and `secret_key_base` only costs
everyone a re-login. The genuine, unresolved case is **succession**: if the
key is gone *and* nobody can get into the underlying accounts (the operator
dies, or leaves, and the login dies with them), there is no recovery. That is
a people problem, not a software one — keep the key backed up, and know who
else can get into your provider accounts.

## 7. Backup age is not shown to bookkeepers

Decided, not built. Only the operator sees backup health (a weekly email from
`Maintenance::WeeklyCheck`) — a bookkeeper with no server access has nothing
to act on from a number they cannot change, so it is not shown to them. If
that judgement ever needs revisiting, this is where.

## 8. Getting the data out

A one-click CSV of every account exists — year-end and on-demand, per entity
or family — described in `docs/maintenance.md`. Two things it deliberately does
not cover:

- **No PDF, and no import-format for another product.** CSV only — it
  describes the books, it does not restore them into this app or any other
  automatically.
- **Receipts are not in the archive, and not separately backed up.** A
  receipt exists in two places once uploaded — the admin's own copy and the
  live bucket — and keeping the source for the statutory retention period is
  the admin's own responsibility, the same as it would be for a paper
  receipt. They do have their own way out, though, separate from the books
  archive: a bulk zip download from the receipts index
  (`ReceiptsController#download_selected`) — tick the ones you want ("select
  all this page", the same convention as a bank statement page).

## 9. Docker Compose for people who are not developers

<!-- TODO: build a docker-compose.yml (or adapt .devcontainer/docker-compose.yml) that lets someone run this with only Docker installed, no Ruby/PostgreSQL locally -->
Not built. Ruby and PostgreSQL are the entire remaining barrier to running
this without being a developer; `docker compose up` would remove both, and
there is already a `Dockerfile` and a `.devcontainer/docker-compose.yml` to
build from. SQLite is not a shortcut to the same goal: `btree_gist`, jsonb
columns and `ILIKE` (case-insensitive only for ASCII under SQLite — would
quietly fail to match ä, ö, ł, ñ) all depend on PostgreSQL.

## 13. Terms an admin actually agrees to

Closed. `terms_agreed_version` / `terms_agreed_at` on `Admin`, gated at first
sign-in for every admin who can reach the accounts app — including one
already in the database when this shipped, not only new ones — and emailed
as a copy. Not gated for an admin with no entity links and no sudo access:
`Authentication#require_terms_agreement` returns before checking, the same
as every other gate here, since there is nothing behind them to agree to
consent for. That state is reachable and supported — an admin who left
their last business keeps their account — not an oversight. The public
demo is a separate, explicitly named exemption.

## 15. Breach notice to affected admins is a promise, not a mechanism

Open. `/legal` states that the people running the installation will contact
an affected admin directly if a security incident touches their data — but
nothing sends that notice automatically; it rests on the operator remembering
to, by hand, during an incident. This matters beyond courtesy: under GDPR
Article 33(2) the operator is usually the *processor*, who must notify the
admin (the *controller*) without undue delay — the admin's own 72-hour
deadline to their Data Protection Authority runs from there, so a late
notice eats into it.

<!-- TODO: build the breach-notice mailer — sudo-triggered, one confirmation step so it can't fire by accident, a record of what was sent/when/to whom -->
Not built: a sudo-triggered mailer to the affected admin(s), with a
confirmation step and a record of what was sent, when, and to whom.
