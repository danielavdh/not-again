# Run it on your own server

Running it for other people — on a server you rent and maintain. For running it
on your own machine, or on a hosted platform instead, see the
[README](../README.md).


<!-- toc -->

**Contents**

- [What you need](#what-you-need)
- [The seven steps](#the-seven-steps)
- [Set up the services (step 1)](#set-up-the-services-step-1)
- [Configuration (steps 2 and 3)](#configuration-steps-2-and-3)
- [`.kamal/secrets` (step 4)](#kamalsecrets-step-4)
- [Deploying (step 5)](#deploying-step-5)
- [Make your account on the server (step 6)](#make-your-account-on-the-server-step-6)
- [Backups (step 7)](#backups-step-7)

<!-- tocstop -->

## What you need

Three accounts, none of which has to be with the providers named here:

| What | Why | Suggested |
|---|---|---|
| A server | to run it | Hetzner (DE), Scaleway (FR), OVH (FR), Infomaniak (CH) |
| S3-compatible object storage | receipts and filing archives | Scaleway (FR), OVH (FR), Infomaniak (CH) |
| An SMTP provider | password resets, export notices | Scaleway TEM (FR), Infomaniak (CH) |

Optionally a CDN — Bunny (SI) — and DNS from ClouDNS (BG) or your registrar. If you want to thank the author: keep all of it in Europe.

## The seven steps

1. **[Set up the services](#set-up-the-services-step-1)** — server, DNS, storage, email, and a GitHub token
2. **[Make your `config/deploy.yml`](#configuration-steps-2-and-3)** — copy the example, fill it in
3. **[Fill in credentials](#configuration-steps-2-and-3)** — the storage and mail secrets
4. **[Write `.kamal/secrets`](#kamalsecrets-step-4)** — the three values that must never enter the image
5. **[Deploy](#deploying-step-5)**
6. **[Make your account on the server](#make-your-account-on-the-server-step-6)** — the server's database is empty; nothing can log in yet
7. **[Set up the backups](#backups-step-7)** — a separate job, on the server itself 

## Set up the services (step 1)

The reference installation at not-again.eu uses Hetzner for the server, Scaleway for the S3 buckets and email, Bunny as an asset host and ClouDNS for DNS. **[docs/provider-setup.md](provider-setup.md) walks through each one**, screen by screen — including encrypting the volume the database sits on, and the GitHub token the deploy needs.

When you come back, you have (and must have):

- a server, running Ubuntu, that you can ssh root@ into without a password
- its firewall allowing only 22, 80 and 443
- cryptsetup, unzip, curl and the AWS CLI installed on it
- an encrypted volume, mounted at the database's folder, and proven to remount by itself
- A records for your domain and www pointing at that server
- private buckets: one for receipts, one for backups, plus one for filings if you want to file digitally
- a sending domain verified at your mail provider, with its DKIM and DMARC records in DNS
- optionally, a CDN pull zone with cdn.yourdomain resolving to it

**Things you will need next:**

- the server's IP address ==> goes into deploy.yml
- your domain, and www  ==> goes into deploy.yml — proxy: host: and APP_HOST 
- your GitHub username  ==> goes into deploy.yml — in image name and registry
- a GitHub token (write:packages) ==> .kamal/secrets
- storage access key and secret ==> credentials
- the storage region, endpoint and bucket ==> credentials
- SMTP server, port, login and key ==> credentials
- the CDN hostname, if you made one ==> deploy.yml — ASSET_HOST
- the LUKS passphrase and the rails master.key ==> on a safe piece of paper

## Configuration (steps 2 and 3)

**2 - Environment variables.** First make the file, by copying the example:

```bash
cp config/deploy.example.yml config/deploy.yml
```

Replace every `<placeholder>` in it; everything else is a working default. Your copy is gitignored, so your server address and domain stay out of the repository.

It holds the things that differ between installations and are not secret. They live under `env: clear:`.

| Variable | Required | What it is |
|---|---|---|
| `APP_HOST` | **yes** | The hostname this installation answers to, e.g. `books.example.eu`. Mailers have no request to infer it from, so the app refuses to boot without it rather than send links to nowhere. |
| `SERVICE_NAME`, `CONTACT_*` | **yes** | Who runs this installation. The legal pages and terms name *you*; production refuses to boot with them unset, because an Impressum with holes in it is worse than a deployment that stops. |
| `DB_HOST` `DB_USER` `DB_NAME` | no | Already right in `config/deploy.yml` for the database Kamal sets up alongside the app. Change them only to point at a database somewhere else. The password is not among them — it comes from `POSTGRES_PASSWORD` in `.kamal/secrets`. `DATABASE_URL` is deliberately not used. |
| `ASSET_HOST` | no | A CDN hostname. Unset means the app serves its own assets, which is a perfectly good way to run it. |
| `WEB_CONCURRENCY` `JOB_CONCURRENCY` `RAILS_MAX_THREADS` | no | Sizing. Defaults are fine on a small server. |
| `SOLID_QUEUE_IN_PUMA` | no | Runs background jobs inside the web process, so there is no separate worker to keep alive. |

Everything written `<like this>` in the example is a placeholder that must be replaced. Everything else is a real, working value.

**3 - Credentials** — anything secret, plus settings meaningless when separated from a secret.
`bin/rails credentials:edit` opens `config/credentials.yml.enc` in a text editor. `bin/setup` already created it and `config/master.key` alongside it; what follows is what to add.

⚠️ It opens whatever `$EDITOR` says, and stops with "No $EDITOR to open file in" if you have not set one. Put one in front if you need to — `EDITOR="nano -w" bin/rails credentials:edit`, saving with ctrl-O and closing with ctrl-X.

```yaml
secret_key_base: <already generated for you>

s3:           # any S3-compatible provider (scaleway/paris in this example)
  bucket:        <app-files>          # REQUIRED — for receipts. Create it yourself
  backup_bucket: <app-db-backups>     # for the database backup, check below
  tax_bucket:    <app-tax>            # only if you submit tax digitally from app (hmrc), otherwise omit.
  region:        <fr-par>
  endpoint:      <https://s3.fr-par.scw.cloud>
  access_key:    <access key>
  secret_key:    <secret key>

smtp:        # example uses Scaleway Transactional Email
  server:   <smtp.tem.scaleway.com>
  port:     <587>
  username: <your Scaleway project ID>
  password: <xsmtpsib-very-long-number (smtp-key=password)>

active_record_encryption:            # bin/rails db:encryption:init generates these
                                     # only needed if filing to HMRC; omit otherwise
  primary_key:            …
  deterministic_key:      …
  key_derivation_salt:    …

hmrc:                                # only if filing to HMRC; omit entirely otherwise
  sandbox:    { client_id: …, client_secret: … }
  production: { client_id: …, client_secret: … }
  vendor:     { license_id: …, public_ip: … }
```

**The bucket names above are examples — choose your own.** What matters is that they exist before you deploy; nothing creates them for you.

- **receipts** (`bucket`) — **required.** Every uploaded receipt and its thumbnail.
- **database backups** (`backup_bucket`) — see [Backups](#backups-step-7). The backup script writes to this bucket. A weekly report reads it to confirm the backups are real. Optional in the sense that the app runs without it, but the books carry statutory retention periods measured in years.
- **the filing archive** (`tax_bucket`) — **only if you submit returns digitally from the app**, which today means HMRC. Tagging accounts, running reports and producing the tax export do not need it — so an installation that files on paper, or through an accountant, can skip this bucket.

Keep all buckets private.

**`active_record_encryption` is only needed if you file to HMRC.** It encrypts the OAuth tokens on `Taxpayer` (`access_token`, `refresh_token`). Omit the `hmrc:` block and you can omit these keys too.

## `.kamal/secrets` (step 4)

This file is not in the repository — make it yourself, at `.kamal/secrets`, with three lines:

```
KAMAL_REGISTRY_PASSWORD=<a GitHub token with write:packages permission>
RAILS_MASTER_KEY=<the whole contents of config/master.key>
POSTGRES_PASSWORD=<a long random password, your choice>
```

They are read from **your own computer** when you deploy.

⚠️ Choose `POSTGRES_PASSWORD` now and do not change it later. PostgreSQL sets it the first time it starts on an empty disk and ignores it afterwards, so a changed password leaves the app unable to connect for reasons that point nowhere near the cause.

**Back up `config/master.key` somewhere that is not the server and not the laptop that made it.**
Without it, `credentials.yml.enc` can never be read again.

Losing it is bad but not fatal. Almost nothing in that file is irreplaceable: you can issue fresh storage and SMTP keys from the providers' own consoles, re-authorise HMRC, and generate a new `secret_key_base` — which signs everyone out and does no other harm.

But that recovery only works while you can still log in to the provider accounts. If one person holds both the master key and every provider login, and that person is gone, nobody can rebuild the installation. So write down who else can get into the hosting and storage accounts — that is the larger risk, not the file.

## Deploying (step 5)

Deployment uses [Kamal](https://kamal-deploy.org): it packages the app up, pushes it to a container registry, and installs it on your server over SSH. GitHub's `ghcr.io` is free and is what `config/deploy.yml` expects.

⚠️ **Docker has to be running on your own computer** — Kamal builds the image here and sends the result. Installed in step 1; open Docker Desktop and leave it running. (The `installs Docker` below is about the *server*, which Kamal does handle.)

**Run these from your own computer, in the project folder — not on the server.** `bundle` installed Kamal, which is why it is `bundle exec`:

### The first deploy, in four commands

```bash
bundle exec kamal accessory boot db          # the database, on its own encrypted volume
bundle exec kamal deploy --skip-hooks        # the app, and the settings it needs on the server
bundle exec kamal app exec "bin/rails db:migrate"
bundle exec kamal app exec "bin/rails tax_categories:load"
```

**Not `kamal setup`.** That would boot the database for you, but before the encrypted volume is
mounted where PostgreSQL will write — see step 1. Booting the accessory yourself is the same work
in the right order.

The last two commands are what the pre-deploy hook does by itself every other time. It cannot do
them now: it reads a settings file on the server that only a finished deploy puts there.

⚠️ The FIRST command reports success even when the database then fails to start. Check before going
on — [Check the database actually started](provider-setup.md#check-the-database-actually-started).

If it stops on the certificate, that is DNS: the domain is not pointing at the server yet. Step 1.

### Every deploy after that

```bash
bundle exec kamal deploy
```

Migrations and the tax catalogues run by themselves, from the pre-deploy hook.

### Two things that are already set up for you

- **`context: .`** is in `config/deploy.example.yml`, so your copy has it. Keep it. Kamal otherwise
  builds from a fresh clone of the repository, which does not contain `config/credentials.yml.enc`
  — that file is yours, made on your own machine. Without it the app starts and stops at the first
  secret it needs, saying `S3 object storage is not configured for production` while your S3
  settings are perfectly fine.
- **`.kamal/hooks/pre-build`** is in the repository. It refuses to build from a dirty or unpushed
  checkout, which is the guarantee `context: .` gives up. If it stops you: commit, push, deploy.

## Make your account on the server (step 6)

The server has its own database and it is empty, so nothing can log in yet.

**From your own computer, in the project folder** — not on the server:

```bash
bundle exec kamal app exec -i --reuse "bin/rails install:owner"
```

It asks for a username and password. Then open your domain and sign in; you will be asked to set up a second factor.

## Backups (step 7)

Nothing backs the database up on its own. `lib/scripts/backup_db.sh` is provided for it, and it needs three things set up first.

**1. The bucket, with its lifecycle rules.** Both done during
[provider setup](provider-setup.md) — the third bucket, and a rule per prefix so old dumps
expire instead of accumulating. Its name goes in credentials as `s3.backup_bucket`.

**2. The AWS CLI, configured.** It is installed on the server already, from provider setup. Log into the server and give it your storage keys:

```bash
ssh root@<your server>
aws configure --profile <a name you choose>
```

It asks four things: your **access key**, your **secret key**, a **region** (`fr-par` if you used Scaleway Paris), and an output format — type `json`.

Use a profile name rather than the default, so that a server running two apps cannot upload one app's backup into the other's bucket. Remember the name; you need it in step 3.

**3. The script, on the server.** It lives in this repository, and the server has no copy. **From your own computer, in the project folder:**

```bash
scp lib/scripts/backup_db.sh root@<your server>:/root/
ssh root@<your server> chmod +x /root/backup_db.sh
```

**Run it once by hand before trusting it.** Back on the server:

```bash
ssh root@<your server>
/root/backup_db.sh not-again-db not_again_user not_again_production <your backup bucket> <your profile>
```

Those arguments, and where each comes from:

| | |
|---|---|
| `not-again-db` | the database container — your `service:` name from `deploy.yml`, plus `-db` |
| `not_again_user` | `POSTGRES_USER` in `deploy.yml` |
| `not_again_production` | `POSTGRES_DB` in `deploy.yml` |
| your backup bucket | `s3.backup_bucket` in credentials |
| your profile | the name you chose in step 2 |
| a name for the files | optional sixth argument; defaults to the database name. Only worth setting when one server backs up two apps, so `js22_backup_…` and `not-again_backup_…` are tellable apart in the bucket |

It should print that it dumped, checked and uploaded. Look in the bucket and see the file. If it is not there, fix it now rather than discovering it in six months.

**Then schedule it**, still on the server. `cron` is Linux's built-in scheduler:

```bash
crontab -e
```

The first time, it asks which editor to use — choose `nano` if you are unsure. Paste this at the bottom, with your own five arguments, then save with ctrl-O and close with ctrl-X:

```
0 3 * * * S3_ENDPOINT=https://s3.fr-par.scw.cloud /root/backup_db.sh not-again-db not_again_user not_again_production <bucket> <profile> >> /root/backup.log 2>&1
```

That runs it every night at 03:00. Change `S3_ENDPOINT` if your storage is not Scaleway Paris.

With `s3.backup_bucket` set in credentials, the weekly report checks the backups are really there — their age, their size, and whether one has suddenly shrunk. See
[docs/maintenance.md](maintenance.md).

⚠️ **This only covers the database.** Receipts, tax filings and the year-end/on-demand books archives all live in object storage, separately from what `pg_dump` reaches. Restore the database on its own and it points at documents that have to still be there.

**Receipts are deliberately not backed up further — decided, not an oversight.** A receipt already exists in two independent places (the admin's own copy, and the live bucket), and keeping the source document for the statutory period is the admin's responsibility, not this app's — see [docs/self-hosting-legal.md](self-hosting-legal.md). A third copy would not meaningfully reduce risk.

**Tax filings and the archive CSVs are different — nobody but this app holds a copy of those.** An optional script, `lib/scripts/mirror_to_second_provider.sh`, mirrors the database backups, the tax filings, and the archives to a second provider under separate credentials — protecting against the primary account itself being lost or compromised, which a second bucket in the same account does not. See [docs/maintenance.md](maintenance.md).

---
