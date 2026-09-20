# Deploying to Scalingo

The hosted route: nothing installed on your own computer, no terminal, no server to maintain. This page is specific to Scalingo because that is what makes the deploy button below work — but nothing about the app requires it. Any provider that can build this app from its code (hosted on GitHub) and give you cloud storage for files plus a way to send email works the same way; Scalingo (hosted server), Scaleway (file storage) and Brevo (email) are simply the ones this page is written against, and all three are EU-based, which is why they were picked over the larger US platforms.

**This path cannot file directly to HMRC.** Digital submission needs the app
to be registered with HMRC from one server address that never changes, which
this path doesn't have — see [tier-3-hmrc.md](tier-3-hmrc.md). Tagging,
reports and the tax export all work regardless; you would just file the
figures yourself.

None of "Getting started" in the main [README](../README.md) applies here — nothing
to install, nothing to download, nothing to run on your own computer. Skip straight
to Step 1 below.

<!-- toc -->

**Contents**

- [Is this for you?](#is-this-for-you)
- [What you will end up with](#what-you-will-end-up-with)
- [Before you start](#before-you-start)
- [Step 1 — the receipt store (Scaleway)](#step-1--the-receipt-store-scaleway)
- [Step 2 — email (Brevo)](#step-2--email-brevo)
- [Step 3 — deploy](#step-3--deploy)
- [Step 4 — your own web address](#step-4--your-own-web-address)
- [When something goes wrong](#when-something-goes-wrong)
- [What it costs](#what-it-costs)
- [What you are trusting](#what-you-are-trusting)

<!-- tocstop -->

## Is this for you?

You keep your books in an app. You use a smartphone. You have never typed a command
into a terminal and would rather not start now. You are willing to pay a monthly fee
to have someone else run the machine.

This path is mostly clicking and copy-pasting. Set aside an undisturbed hour the
first time — most of it is waiting, or filling in a form.

## What you will end up with

Three accounts:

- **Scalingo** — runs the app and its database.
- **Scaleway** — holds your uploaded receipt files. The app itself cannot store them permanently.
- **Brevo** — sends the app's email: password resets, and the tax export when you ask for it by email. Set it up — without it a forgotten password can only be reset from the Scalingo console.

All three are European, and all have a free tier to start on except Scalingo
itself, which needs a card.

## Before you start

- **A GitHub account.** Free — [github.com](https://github.com), *Sign up*. Scalingo uses it to sign you in and to find the app's code. You never have to use GitHub beyond signing in.
- **Pen and paper**, or a notes app. You will collect about ten values along the way and paste them all into one form at the end; writing them down as you go is calmer than switching tabs to look each one up again.

---

## Step 1 — the receipt store (Scaleway)

*About 20 minutes — the fiddliest step, go slowly.*

1. [scaleway.com](https://www.scaleway.com) → **Sign up**. Confirm the email. Activating the account needs a card, but Object Storage is free under 75 GB, and receipts are small — you will not be charged to start, and possibly a couple of cents later.

2. In the Scaleway console: **Storage → Object Storage → Create bucket**. (A "bucket" is just a named storage space for your files — think of it as a folder, but one that lives in the cloud instead of on a computer.) 

	- **Name:** something unique — bucket names are shared across all of Scaleway, so add something like your surname, e.g. `smith-books-receipts`.
	- **Region:** Paris — `fr-par` (just means which of Scaleway's data centres holds your files; Paris is the closest to most users).
	- **Visibility:** Private.
	- Create.

3. Make a key so the app can prove it's allowed to read and write your bucket — think of it as a password just for the app, not for you. Top right, click your organisation name → **API Keys** → **Generate an API key**.

	- Description: `not-again`.
	- Generate. It shows an **Access key** and a **Secret key** — two halves of that password. The secret is shown **once**. Write both down now.

4. Write down (copy/paste) these four values — you need all of them in Step 3:

	| | value |
	|---|---|
	| Bucket name | what you typed in 2 |
	| Region | `fr-par` |
	| Endpoint (the web address the app uses to reach your bucket) | `https://s3.fr-par.scw.cloud` |
	| Access key / Secret key | from 3 |

---

## Step 2 — email (Brevo)

*About 10 minutes.*

Without this, a forgotten password can only be reset by someone with console
access, and the tax export can't be emailed.

1. [brevo.com](https://www.brevo.com) → free account.
2. Left menu → **SMTP & API** → the **SMTP** tab. ("SMTP" is just the technical name for the settings that let an app send email — Brevo's menu uses the term directly, so it's worth knowing what it stands for even though you won't need to understand it beyond this page.) Note down:

	- Server: `smtp-relay.brevo.com`
	- Port: `587`
	- Login: the email address shown
	- **SMTP key** — click to generate one, then copy it.
3. Left menu → **Senders, Domains & Dedicated IPs → Senders** → **Add a sender** — use an address you can receive mail at, and follow the verification link Brevo emails you.

⚠️ **This verified address must be typed into Step 3 as `MAIL_FROM`, exactly.** The
app does not pick it up automatically — left unset, it tries to send as
`no-reply@` your Scalingo address instead, which nobody can verify (there's no
real mailbox there to receive Brevo's confirmation link), and Brevo will refuse
to send it. So: write the sender address down now, and use it for `MAIL_FROM`
below, not just the address you registered Brevo with.

Write down: server, port, login, SMTP key, verified sender address (for `MAIL_FROM`).

**If you already have your own domain name** and plan to use it for your app (see Step 4), you can follow [Email — Brevo in provider setup](provider-setup.md#4-email--brevo) instead — it authorises your whole domain rather than one address, which is a few more steps. Not required; the steps above work without one.

---

## Step 3 — deploy

*About 10 minutes, plus 5–8 minutes waiting.*

1. Click the button below — this is the actual button, not just a description of one:<br /> [![Deploy on Scalingo](https://cdn.scalingo.com/deploy/button.svg)](https://dashboard.scalingo.com/create/app?source=https://github.com/danielavdh/not-again#main) <br />If it doesn't work for any reason, go straight to:<br /> `https://dashboard.scalingo.com/create/app?source=https://github.com/danielavdh/not-again#main`.
2. Pick an **app name** — lowercase, e.g. `smith-books`. Your address becomes `smith-books.osc-fr1.scalingo.io`.
3. A form appears listing every setting. Three kinds of field:

	- **Already filled in, generated** — `SECRET_KEY_BASE` and the three `ACTIVE_RECORD_ENCRYPTION_*` keys. **Leave these exactly as they are.** They protect your data; the form generated strong random values for you.
	- **You must fill in:**

		| field | what to put |
		|---|---|
		| `APP_HOST` | your app name + `.osc-fr1.scalingo.io`, e.g. `smith-books.osc-fr1.scalingo.io` |
		| `S3_BUCKET` | your bucket name (from your notes) |
		| `S3_REGION` | `fr-par` |
		| `S3_ENDPOINT` | `https://s3.fr-par.scw.cloud` |
		| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | from your notes |
		| `SMTP_ADDRESS` | `smtp-relay.brevo.com` |
		| `SMTP_PORT` | `587` |
		| `SMTP_USERNAME` / `SMTP_PASSWORD` | from your Brevo notes |
		| `MAIL_FROM` | the exact address you verified as a sender in Step 2 — **not optional**, see the warning there |
		| `SERVICE_NAME` | your business name — appears on the app's legal page |
		| `CONTACT_NAME`, `CONTACT_EMAIL`, `CONTACT_TRADING`, `CONTACT_STREET`, `CONTACT_CITY`, `CONTACT_COUNTRY` | your own details — also on the legal page; required in Germany, honest practice everywhere |

	- **Optional, leave blank unless you know you want it:** `ASSET_HOST` (a service that makes the app's images and styling load faster for visitors far away — not needed for ordinary use).
	- **Already filled in, correctly:** `REPO_URL` — leave it as it is unless you're deploying your own fork of the code instead of following this guide as written.

4. Click **Create**. Scalingo builds and starts the app — about 5 to 8 minutes. The page shows a log; you don't need to read it.

5. When it says the app is running, open `https://smith-books.osc-fr1.scalingo.io`.<br />**Register** — the first account is the owner, we don't recommend you use it for your day to day bookkeeping (see [the README](../README.md#about-sudo) for what "owner" means and why). Write the password down somewhere durable, then log in and create your admin(s) and give them entities (businesses).

---

## Step 4 — your own web address

*Optional, and can be done later.*

1. Buy a domain if you don't already have one — any registrar (we currently use Hostinger. It's a constantly changing landscape, and moving to someone else is not a big deal anymore).
2. Scalingo dashboard → your app → **Settings → Domains** → add `books.yourdomain.com`. It shows you a target, something like `smith-books.osc-fr1.scalingo.io`.
3. At your domain registrar, find the **DNS settings** for your domain — usually  under something called "DNS", "DNS management" or "Name servers" once you've  clicked into the domain itself. Every registrar's screen looks different, but  they all ask for the same three things when you add a record: a **type**, a  **name**, and a **value** (some call it "target", "points to" or "content" —  same thing). <br />Add one with: type=CNAME, name=`books`, value=`smith-books.osc-fr1.scalingo.io` (from step 2) <br />Leave anything else (TTL, priority) at whatever it defaults to. This is a  **CNAME record** — it tells the internet "when someone looks for  `books.yourdomain.com`, send them to this Scalingo address instead." Changes  can take anywhere from a few seconds to a few hours to take effect  everywhere; if it doesn't work immediately, wait and try again before  assuming something's wrong.
4. Back in Scalingo, wait for the green tick. It is issuing the **certificate** — the thing that makes your address start with `https` and show a padlock in the browser. This happens automatically; the tick just means it's done.
5. Scalingo → app → **Environment** → change `APP_HOST` to `books.yourdomain.com`. Environment changes trigger a restart.

---

## When something goes wrong

- **Deploy failed.** Scalingo → your app → **Deploy** → open the last deployment's log and scroll to the bottom. Almost always a wrong storage key from Step 1, or a `CONTACT_*` field left empty — production refuses to start with those blank. Fix the value under **Environment**, then **Deploy → Manual deploy**.
- **Page won't load, says "Blocked host".** The app only answers to the one address you told it to expect, as a security measure — and the address in your browser doesn't match it. Go to Scalingo → your app → **Environment** and check `APP_HOST`: it should be typed exactly as the address you're trying to visit, with no `https://` and no trailing slash — e.g. `smith-books.osc-fr1.scalingo.io`, or `books.yourdomain.com` if you've set up your own address in Step 4.
- **Receipts won't upload.** One of the Scaleway values from Step 1 is wrong. Re-check the bucket name, region, endpoint and both keys against your notes — a fresh key is quick to generate if in doubt.
- **Password resets or the tax export never arrive by email.** `MAIL_FROM` doesn't exactly match the address you verified in Step 2 — check it under **Environment**. A personal address on a large provider (Gmail, Outlook, Yahoo) can also cause trouble even once verified, since Brevo isn't authorised to send as that domain in the provider's own eyes; an address on a domain you actually control tends to work more reliably.

## What it costs

<!-- TODO: figures below are provisional — Scalingo's smallest server + database    tier starts around €25/month and is not expected to be enough for real use;    revisit and confirm once we know actual resource requirements. Also confirm    whether a free trial period currently exists before stating one here. -->

- **Scalingo:** from around €25/month for the smallest app and database — likely more once real usage is accounted for. You choose and pay for the size of each separately, so it scales with what you actually need.
- **Scaleway (file storage):** free under 75 GB.
- **Brevo (email):** free under 300 emails/day.

## What you are trusting

Scalingo holds your database, Scaleway holds your receipt files. Both protect the data while it sits on their servers, but it isn't on hardware you own or control — you're trusting their security, not just your own. In exchange, you never have to keep a server's software up to date yourself, and if a hard drive fails, that's their problem to fix, not yours.

**Database backups are automatic — nothing to set up.** Every paid Scalingo plan (which is what this guide uses) includes daily backups of your database by default: the last 7 days, kept automatically, plus 7 days of [point-in-time recovery](https://doc.scalingo.com/databases/about/backup-policies). No add-on, no extra cost, no cron job to remember — unlike some other hosting platforms, where backups are something you have to switch on yourself.
