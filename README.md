# Not Again

Self-hosted double-entry bookkeeping for sole traders and micro-businesses — VAT is the next feature to be added. Multi-currency, with tax categories for the UK, Germany, Switzerland and the Netherlands, and **built to be extended**.

Rails 8. No SaaS, no subscription. Your books live in your database, on your server, and **nothing a visitor's browser loads comes from anyone else** — no CDN fonts, no analytics, no trackers.

The server side does talk to services you choose: object storage for the receipts, an SMTP provider for mail, and the tax authorities' own published rate feeds.

<!-- toc -->

**Contents**

- [What it does](#what-it-does)
- [Who this is for](#who-this-is-for)
- [Getting started](#getting-started)
    - [If you are using a hosted service (Scalingo)](#if-you-are-using-a-hosted-service-scalingo)
    - [What you need](#what-you-need)
    - [First install](#first-install)
- [Run it locally](#run-it-locally)
    - [If you are planning to run your books from localhost, please take note:](#if-you-are-planning-to-run-your-books-from-localhost-please-take-note)
    - [Setup locally](#setup-locally)
    - [Running the tests](#running-the-tests)
    - [The demo — it does not exist until you make it](#the-demo--it-does-not-exist-until-you-make-it)
- [Run it in production](#run-it-in-production)
    - [What you need](#what-you-need-1)
    - [Do these in order](#do-these-in-order)
    - [Set up the services (step 1)](#set-up-the-services-step-1)
    - [Configuration (steps 2 and 3)](#configuration-steps-2-and-3)
    - [`.kamal/secrets` (step 4)](#kamalsecrets-step-4)
    - [Deploying (step 5)](#deploying-step-5)
    - [Make your account on the server (step 6)](#make-your-account-on-the-server-step-6)
    - [Backups (step 7)](#backups-step-7)
- [Documentation](#documentation)
    - [One more command, only if you will push commits](#one-more-command-only-if-you-will-push-commits)
    - [The server is yours, and so is what is on it](#the-server-is-yours-and-so-is-what-is-on-it)
    - [Stack](#stack)

<!-- tocstop -->

### What it does

- **Double-entry bookkeeping** with full journal entry support
- **Multi-currency** accounts with monthly FX rate translation and explicit variance reporting, from the published rates of the ECB, HMRC, the Bundesbank and the Swiss ESTV — all monthly, plus the ECB's daily series where a country's rules ask for it
- **Tax export** — a transactions listing with receipt links and a tax-category CSV in the authority's own boxes, plus an optional accountant format (DATEV today; adding one is a single file)
- **Receipt management** — upload, compress and link photos, scans and PDFs to postings, including from a phone by someone who can do nothing else
- **Entity-scoped access control** — co-admins, read-only and upload-only roles, OTP
- **Multi-entity** — up to 100 businesses or households in one install, each with a two-digit code; group them into families for consolidated reports, or link a payment across separate businesses with a two-sided cross-entity entry
- **Reports** — custom reports over any accounts you choose, profit/loss, balance sheet, trial balance and tax summaries per entity, over any date range, plus an assisted year-end close
- **Your books, portable any time** — a one-click CSV of every account, generated automatically at each year-end close and on demand for the year to date; describes the books openly (any spreadsheet, any other bookkeeping software), not a restore file for this app specifically — see "Reports" on the dashboard
- **Locale-aware** — en / de / es / nl, and any language can be added

---

### Who this is for

- Bookkeepers and small practices keeping books for several clients in one install, instead of paying per client
- Freelancers and sole traders with bank accounts in more than one currency, cross-border trade, or both
- Small businesses needing multi-currency accounting with proper FX handling
- Rails developers who want to extend this Rails 8 codebase

It was built with Europe in mind — the tax catalogues, the FX rules and the filing model all follow European practice — but nothing in it is Europe-only.

**It is bookkeeping, not business management:** No invoices, no quotes, no customers, no suppliers, no payments, no bank feeds, no payroll, no inventory, no budgets. **VAT is not supported yet** (next on agenda though) — the six tax schemes that ship cover self-employment and rental income, and MTD filing to HMRC covers Self Assessment and Property.

⚠️  Digital submission to HMRC requires HMRC's approval, applied for separately by each installation — see [docs/tier-3-hmrc.md](docs/tier-3-hmrc.md)

**Three ways to run this**

- **On your own computer**, for yourself alone — see [Run it locally](#run-it-locally). Cost: 0
- **Hosted for you** — see [docs/scalingo.md](docs/scalingo.md), a few clicks and a card. The machine is theirs; they maintain it. Cost: from €25/month <!-- TODO: Scalingo's smallest server+database tier; not going to be enough — revisit once we know real requirements -->
- **On a server you rent** — see [Run it in production](#run-it-in-production). More involved, you maintain. Our instructions are detailed, but if you have never used the terminal, it may not be for you. You could hire someone to set it up for you and do the maintenance. Cost: €5+/month.

---

## Getting started

### If you are using a hosted service (Scalingo)

None of this applies to you — nothing is installed or run on your own computer. Go straight to [docs/scalingo.md](docs/scalingo.md) and **stop reading here**.

### What you need

- **Ruby 3.4.7** — pinned in `.ruby-version` and in the `Gemfile`, so bundler will refuse a different one
- **PostgreSQL 14 or newer** — 17 is what production runs
- **ImageMagick** — receipt thumbnails and image compression
- **Ghostscript** — PDF receipt compression
- **Docker** — only if you will host this app on a server
- **aws CLI** — ditto, for restore drills

Running the app *locally* needs no accounts with anybody — no server, no object storage, no email provider.

**If any of this is unfamiliar**, this README is meant to be enough on its own: hand it to Claude, Claude Code, or whichever assistant you trust, and ask it to walk you through the install. ⚠️ Two rules if you do — never paste `config/master.key`, your credentials file, or any provider key into a chat window; and read the warning in step 3 before letting anything change the `Gemfile`.

### First install

Skip **to step 4** if you already run Rails apps.

**1. The tools.** On a Mac, install [Homebrew](https://brew.sh) first if you have not got it — run the command, on their front page. Then:

```bash
xcode-select --install                    # Apple's build tools, if you have never needed them
brew install imagemagick ghostscript
brew install --cask postgres-app          # a normal Mac app, with a Start button
brew install --cask docker-desktop        # only if you will host this app on a server
brew install awscli                       # only for restore drills, and pulling backups down locally
```

(`brew install postgresql@17` works too, if you would rather have no app icon. Remember which you chose — step 3 differs.)

`xcode-select --install` also gives you **git**, which step 4 needs to download the code. If `git --version` answers, you already have it.

On Debian or Ubuntu:

```bash
sudo apt install git curl build-essential libpq-dev imagemagick ghostscript postgresql postgresql-contrib
sudo apt install docker.io                # only if you will host this app on a server
sudo apt install awscli                   # only for restore drills, and pulling backups down locally
```

`postgresql-contrib` is not optional: the app uses two extensions that live there — `btree_gist`, which enforces that no two exchange rates for the same currency pair cover the same dates, and `pg_stat_statements`. Without it the database setup fails with "could not open extension control file".

Now start PostgreSQL: open Postgres.app and click Initialize, or run `brew services start postgresql@17`, or `sudo systemctl start postgresql`. Nothing below works until it is running.

**Steps 2 and 3 add lines to `~/.zshrc`**, the file your terminal reads when it opens — step 2 always, step 3 only on a Mac. Run each once; running it again just adds a duplicate. On bash the file is `~/.bash_profile`.

**2. Ruby 3.4.7.** Use a version manager to install extra Ruby versions. If you have not got one, [mise](https://mise.jdx.dev) is the easiest:

```bash
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
source ~/.zshrc
mise use -g ruby@3.4.7                # builds Ruby — several minutes, and quiet
ruby -v                               # must say 3.4.7
```
⚠️ The second line is what makes your terminal use mise. Skip it and `ruby -v` still shows the old Ruby.

**3. Let PostgreSQL be found.** ⚠️ **The step that catches people.**

This app builds its PostgreSQL connector from source, because the ready-made one crashes on Macs. Building it needs `pg_config`, a small program that comes with PostgreSQL, and your terminal has to be able to find it.

**Postgres.app** — the first line is permanent, the second applies it to the window you have open, the third checks it:

```bash
echo 'export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
pg_config --version                       # any version — it just has to answer
```

**Homebrew PostgreSQL** — Homebrew deliberately does not put versioned PostgreSQL on your `PATH`, so this needs the same treatment:

```bash
echo 'export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
pg_config --version
```

(On an Intel Mac, `/usr/local` instead of `/opt/homebrew`.)

**Debian or Ubuntu** — `libpq-dev` already did it. Check with `pg_config --version`.

⚠️ If the next step fails with pages of errors about `pg`, this is why: `pg_config` cannot be found. **Do not delete `force_ruby_platform: true` from the `Gemfile`, and do not let an assistant delete it for you.** That silences the error and replaces it with a crash every time the app talks to the database — far harder to work out.

**4. Get the code.** Put it wherever you keep projects — `~/Sites`, `~/code`, `~/projects`, whatever you use. There is no convention outside macOS, so pick one:

```bash
mkdir -p ~/Sites && cd ~/Sites
git clone https://github.com/danielavdh/not-again.git
cd not-again
```

**5. Open a second terminal tab.** ⌘T in Terminal or iTerm; ctrl-shift-T on most Linux ones. `cd` it into the same folder — `pwd` in this tab prints the path to copy.

You want two because the app occupies one of them:

- **First tab** runs the app (once you have started on "Run it locally"), and stays running. Watch requests scroll past, and errors being thrown at you.
- **Second tab** is for everything else — `git`, `bin/rails …`, and later `kamal`.

`git` and `kamal` only work inside the app folder. `ssh root@<your server>` works from anywhere, because it is only a network connection — but once you are on the server, everything you type happens **there**. Type `exit` when you are done, or the next command lands on the wrong machine.

---

## Run it locally

### If you are planning to run your books from localhost, please take note:

- **Exchange rates** are not fetched automatically — run `bin/rails exchange_rates:fetch`.
- **Email** needs SMTP credentials added before it will send anything — until then, a password reset or an export fails loudly rather than silently.
- **Two-factor (OTP)** is not enforced locally — only in production.
- **The legal pages** show placeholder contact details unless you set `CONTACT_*`/`SERVICE_NAME` yourself.
- **Receipts and filing archives** are stored on local disk, not object storage.

### Setup locally

Once the code is cloned and you are in its folder:

```bash
bin/setup
```

That does the lot: installs the gems, creates the app's encrypted settings file, prepares the database, **asks you to choose a username and password** for the first account, and starts the app at **http://localhost:3000**.

After that, `bin/dev` is what starts it, every time.

`bin/setup` is safe to run again — it skips whatever is already done.

⚠️ It creates `config/master.key`, which is the only thing here that cannot be replaced. **Back it up somewhere that is not this computer.**

If you would rather run the steps yourself, or something fails and you want to see where:

```bash
bundle
EDITOR=true bin/rails credentials:edit	# creates config/master.key, opens no editor
bin/rails db:prepare
bin/rails install:owner			# the first account. Refuses once one exists
bin/dev											# http://localhost:3000
```

`install:owner` exists because every page needs a login and only a logged-in owner can add people — so a brand-new copy has no other way in.

<a id="about-sudo"></a>
<font color="#0000cc">
That first admin is **sudo** — the owner of the installation. Sudo is not simply an admin with more buttons:

- **Sudo sees every entity's books**, whether or not it has been given access to them.
- **Only sudo can create full-access admins.**
- **Only sudo assigns entities to full-access admins.** 
- **Sudo is a column**, so a second owner is made by ticking the box on their admin page, and there can be as many as you like. The last one cannot be removed — neither deleted nor demoted — because an installation with no owner cannot be administered at all.
- A full-access admin can add co-admins to their own businesses, as `read_only` or `upload_receipts`.
- Admin access is per entity, not global: an admin reaches the businesses they have been linked to, and nothing else.

**Create a separate admin for your own day-to-day bookkeeping.** Sudo sees every entity and every admin-management screen — useful for running the installation, not for just doing the books. Add yourself as a regular full-access admin and work from there instead.
</font>

**Use `bin/dev`, not `bin/rails server`.** Three things must run together — the app, a stylesheet rebuilder, and a worker for slow jobs. `bin/dev` starts all three; `bin/rails server` starts the app alone, and the other two silently never happen.

Leave that terminal window open. Closing it stops the app.

Email is the exception: it really does try to send mail, using whatever mail settings are in the settings file. Without email settings, anything that sends an email — a password reset, an export — stops with an error rather than failing quietly, because `config/environments/development.rb` sets `raise_delivery_errors = true`.

Once you have mail settings — [Email — Brevo](docs/provider-setup.md#4-email--brevo) covers getting them — add them with `EDITOR="nano -w" bin/rails credentials:edit`. The `smtp:` block is shown under [Configuration](#configuration-steps-2-and-3).

⚠️ That is a YAML file, so **indentation is not decoration**: two spaces, spaces and never tabs, and every key under `smtp:` lined up with the others. A misaligned line is not a warning — it stops the app from starting.

Password reset is an email, so it only works once `smtp:` is in your credentials. Until then these are the way back in:

```bash
bin/rails install:reset_password   # asks for a username, then a new password
bin/rails install:reset_otp        # clears the second factor; they enrol again next sign-in
```

### Running the tests

```bash
bin/rails test          # unit and integration
bin/rails test:system   # system tests — NOT included in the line above
```

The system tests drive a real browser, so a green `bin/rails test` may not have exercised any JavaScript at all.

### The demo — it does not exist until you make it

`/demo` is a public door: anyone who opens it is signed straight in, with no password, as a read-only account on one made-up set of books. **A fresh clone has no demo**, so the landing page shows no demo button and `/demo` offers no way in.

```bash
bin/rails demo:seed        # opens the door
bin/rails demo:destroy     # closes it and removes everything it made
bin/rails demo:reset       # both, in that order
```

Not running this is a complete and correct installation. If you *do* run it, entity `99` ("Bąk & Partners", nine months of invented books) and three passwordless admins arrive **in the same database as your real books**, and appear in your entity list, your dashboards and every backup from then on. Pass `DEMO_ENTITY_CODE=98` if `99` is already yours.

The demo admins (standard, pro and upload only) cannot reach real books.

Fetch the exchange rates for the demo with `bin/rails exchange_rates:fetch`.

---

## Run it in production

The local install is a real way to keep books on your own computer, just for yourself. If you want to make the app available for **other people**, you need to run it on a server.

### What you need

Three accounts, none of which has to be with the providers named here:

| What | Why | Suggested |
|---|---|---|
| A server | to run it | Hetzner (DE), Scaleway (FR), OVH (FR), Infomaniak (CH) |
| S3-compatible object storage | receipts and filing archives | Scaleway (FR), OVH (FR), Infomaniak (CH) |
| An SMTP provider | password resets, export notices | Brevo (FR), Scaleway TEM (FR), Infomaniak (CH) |

Optionally a CDN — Bunny (SI) — and DNS from ClouDNS (BG) or your registrar. If you want to thank the author: keep all of it in Europe.

### Do these in order

Each one is explained below.

1. **[Set up the services](#set-up-the-services-step-1)** — server, DNS, storage, email, and a GitHub token
2. **[Make your `config/deploy.yml`](#configuration-steps-2-and-3)** — copy the example, fill it in
3. **[Fill in credentials](#configuration-steps-2-and-3)** — the storage and mail secrets
4. **[Write `.kamal/secrets`](#kamalsecrets-step-4)** — the three values that must never enter the image
5. **[Deploy](#deploying-step-5)**
6. **[Make your account on the server](#make-your-account-on-the-server-step-6)** — the server's database is empty; nothing can log in yet
7. **[Set up the backups](#backups-step-7)** — a separate job, on the server itself 

### Set up the services (step 1)

The reference installation at not-again.eu uses Hetzner for the server, Scaleway for the S3 buckets, Brevo for email, Bunny as an asset host and ClouDNS for DNS. **[docs/provider-setup.md](docs/provider-setup.md) walks through each one**, screen by screen — including encrypting the volume the database sits on, and the GitHub token the deploy needs.

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

### Configuration (steps 2 and 3)

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

smtp:        # example uses brevo
  server:   <smtp-relay.brevo.com>
  port:     <587>
  username: <xxxxxxxxx@smtp-brevo.com (login=username)>
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

### `.kamal/secrets` (step 4)

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

### Deploying (step 5)

Deployment uses [Kamal](https://kamal-deploy.org): it packages the app up, pushes it to a container registry, and installs it on your server over SSH. GitHub's `ghcr.io` is free and is what `config/deploy.yml` expects.

⚠️ **Docker has to be running on your own computer** — Kamal builds the image here and sends the result. Installed in step 1; open Docker Desktop and leave it running. (The `installs Docker` below is about the *server*, which Kamal does handle.)

**Run these from your own computer, in the project folder — not on the server.** `bundle` installed Kamal, which is why it is `bundle exec`:

```bash
bundle exec kamal setup      # first time: installs Docker, starts the database, deploys
bundle exec kamal deploy     # every time after that
```

`setup` takes a while and says a lot. If it stops on the certificate, it is almost always DNS: the domain is not yet pointing at the server. That is part of step 1.

Migrations and the tax catalogues load by themselves, from the pre-deploy hook.

### Make your account on the server (step 6)

The server has its own database and it is empty, so nothing can log in yet.

**From your own computer, in the project folder** — not on the server:

```bash
bundle exec kamal app exec -i --reuse "bin/rails install:owner"
```

It asks for a username and password. Then open your domain and sign in; you will be asked to set up a second factor.

### Backups (step 7)

Nothing backs the database up on its own. `lib/scripts/backup_db.sh` is provided for it, and it needs three things set up first.

**1. The bucket, with its lifecycle rules.** Both done during
[provider setup](docs/provider-setup.md) — the third bucket, and a rule per prefix so old dumps
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

Those five arguments, and where each comes from:

| | |
|---|---|
| `not-again-db` | the database container — your `service:` name from `deploy.yml`, plus `-db` |
| `not_again_user` | `POSTGRES_USER` in `deploy.yml` |
| `not_again_production` | `POSTGRES_DB` in `deploy.yml` |
| your backup bucket | `s3.backup_bucket` in credentials |
| your profile | the name you chose in step 2 |

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
[docs/maintenance.md](docs/maintenance.md).

⚠️ **This only covers the database.** Receipts, tax filings and the year-end/on-demand books archives all live in object storage, separately from what `pg_dump` reaches. Restore the database on its own and it points at documents that have to still be there.

**Receipts are deliberately not backed up further — decided, not an oversight.** A receipt already exists in two independent places (the admin's own copy, and the live bucket), and keeping the source document for the statutory period is the admin's responsibility, not this app's — see [docs/self-hosting-legal.md](docs/self-hosting-legal.md). A third copy would not meaningfully reduce risk.

**Tax filings and the archive CSVs are different — nobody but this app holds a copy of those.** An optional script, `lib/scripts/mirror_to_second_provider.sh`, mirrors the database backups, the tax filings, and the archives to a second provider under separate credentials — protecting against the primary account itself being lost or compromised, which a second bucket in the same account does not. See [docs/maintenance.md](docs/maintenance.md).

---

## Documentation

**[docs/](docs/README.md) is the full map**, grouped by whether you are running the app,
extending it, or looking something up. The essentials:

| | |
|---|---|
| [docs/concepts.md](docs/concepts.md) | The model everything is built on — read this first |
| [docs/scalingo.md](docs/scalingo.md) | Hosted on Scalingo — no terminal, no server, click by click |
| [docs/provider-setup.md](docs/provider-setup.md) | Self-hosted: setting up the server, DNS, storage, email and CDN, click by click |
| [docs/maintenance.md](docs/maintenance.md) | What has to keep happening once it is live, and by whom |
| [docs/self-hosting-legal.md](docs/self-hosting-legal.md) | What EU product-liability and cyber-resilience law expects, and what changes if you charge |
| [docs/known-limitations.md](docs/known-limitations.md) | The self-hosting risks worked through — resolved and still-open |
| [SECURITY.md](SECURITY.md) | How to report a security problem, and what is by design rather than a defect |
| [CONTRIBUTING.md](CONTRIBUTING.md) | House style |

### One more command, only if you will push commits

```bash
git config core.hooksPath .githooks
```

**Not needed to run the app.** It enables `pre-push`, which refuses to push when anything secret has become tracked — `.kamal/secrets`, a `master.key`, a stray `.pem`, `config/deploy.yml`. The setting is per-clone, and git will not do it for you.

### The server is yours, and so is what is on it

**The person running the server can read the books.** That is true of every hosted accounting product; the difference here is that you choose who that person is. Sudo can open any entity — see [Run it locally](#run-it-locally).

**Encrypt the disk the database sits on, and do it before the first deploy** — see step 1. Kamal will otherwise happily put PostgreSQL on a plain volume. These are somebody's financial records kept for years: an encrypted volume and a firewall exposing only 22, 80 and 443 are the baseline.

If you keep books for other people — even four friends, unpaid — you are a GDPR processor under Article 28, which wants a written agreement with each of them, reasonable security (Article 32) and breach notification (Article 33). The written-agreement part is built in: every admin, including the people whose books you keep, is shown the terms and has to agree the first time they sign in, and gets a copy by email. If you ever charge for hosting, there is more beyond this one document — see [docs/self-hosting-legal.md](docs/self-hosting-legal.md).

**Update the `/legal` page.** It ships with the **reference installation's**
wording. The identity — name, address, contact, service name, hostname — fills
in from `CONTACT_*` / `SERVICE_NAME` / `APP_HOST`. Everything else is your legal
document now, and needs your eye:

- **"Where your data is stored"** — it names Hetzner, Scaleway, OVH and Brevo.
  Change it to your own providers and their locations. Plain text in
  `app/views/help/legal_{en,de,nl,es}.html.erb`.
- **"How long we keep it"**, **"Your rights"** — written for EU/UK/CH. If your
  users or you are elsewhere, check the wording fits.
- **"If we hold data for your business"** — the Article 28 processor section.
  Only relevant if you keep books for other people; read it if you do.

### **Stack**

- Ruby on Rails 8, importmap-managed vanilla JS, Dart-Sass
- PostgreSQL
- Shrine for receipts, with ImageMagick + Ghostscript compressing anything over 2MB down to that ceiling
- No Bootstrap and no framework JS in the app itself — see `app/javascript/scripts/` for the house style. Turbo and Stimulus are in the bundle, but only because `mission_control-jobs` (the `/jobs` dashboard) depends on them; nothing this app renders uses either.

**No runtime dependencies.** The app serves every asset it uses; nothing is fetched from a CDN, a font host or a package registry while it runs. That is what makes it work on a private network, survive someone else's outage, and keep a Content-Security-Policy naming only your own origins.
TomSelect and the fonts are vendored for exactly that reason; they and everything the container image bundles are listed in [THIRD-PARTY.md](THIRD-PARTY.md).

**Built with extensive use of Claude (Anthropic) as a development collaborator.**
