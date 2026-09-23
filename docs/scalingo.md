# Deploying to Scalingo

The hosted route: nothing installed on your own computer, no terminal, no server to maintain. You will need **a domain name** — the email service only sends from a domain you own.

This page is written against Scalingo (the server) and Scaleway (files and email), both EU-based. Any provider that can build the app from its code on GitHub, store files and send email works the same way.

⚠️ **Written September 2026.** Control panels get redesigned, so buttons move and menus get renamed. The shape of each task stays the same: create a thing, restrict it, take a key.

**This path cannot file directly to HMRC.** Digital submission needs the app
to be registered with HMRC from one server address that never changes, which
this path doesn't have — see [tier-3-hmrc.md](tier-3-hmrc.md). Tagging,
reports and the tax export all work regardless; you would just file the
figures yourself.

None of "Getting started" in the main [README](../README.md) applies here — nothing
to install, nothing to download, nothing to run on your own computer.

<!-- toc -->

**Contents**

- [Is this for you?](#is-this-for-you)
- [What you will end up with](#what-you-will-end-up-with)
- [Before you start](#before-you-start)
- [Step 1 — the receipt store (Scaleway)](#step-1--the-receipt-store-scaleway)
- [Step 2 — email (Scaleway)](#step-2--email-scaleway)
- [Step 3 — deploy](#step-3--deploy)
- [Step 4 — your own web address](#step-4--your-own-web-address)
- [When something goes wrong](#when-something-goes-wrong)
- [What it costs](#what-it-costs)
- [What you are trusting](#what-you-are-trusting)

<!-- tocstop -->

## Is this for you?

You keep your books in an app. You use a smartphone. You have never typed a command
into a terminal and would rather not start now. You are willing to pay a monthly fee
to have someone else run the machine, and to own a domain name.

This path is mostly clicking and copy-pasting. Set aside an undisturbed hour the
first time — most of it is waiting, or filling in a form.

## What you will end up with

Two accounts:

- **Scalingo** — runs the app and its database.
- **Scaleway** — holds your uploaded receipt files (the app itself cannot store them permanently), and sends the app's email: password resets, invitations, the tax export.

Both are European. Scaleway has a free tier; Scalingo needs a card.

## Before you start

- **A GitHub account.** Free — [github.com](https://github.com), *Sign up*. Scalingo uses it to sign you in and to find the app's code. You never have to use GitHub beyond signing in.
- **A domain name**, e.g. `yourdomain.com`, and access to its DNS settings at your registrar. The email service only sends from a domain you own. Buy one first if you don't have one — any registrar will do.
- **An authenticator app** on your phone — Google Authenticator, 1Password, Aegis, whichever. The app asks for a second factor at your first sign-in and every one after.
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

## Step 2 — email (Scaleway)

*About 15 minutes of work, then a wait of minutes to hours.*

Without this, nobody can reset a forgotten password and the tax export can't be emailed.

⚠️ **Do items 1 and 2 below before anything else**, then go back and work through Step 1 while the DNS records spread. Verification is the only part of this guide you cannot hurry.

Use the same Scaleway project as Step 1.

1. Console → **Domains & Web Hosting** → **Transactional Email** → add your domain.
2. Scaleway shows four records. Add each one at your registrar's **DNS settings** (type, name, value — copy them exactly), then wait until Scaleway marks the domain verified. That can take minutes or hours.
3. **IAM → Applications** → create one, e.g. `smith-books-mail`. **IAM → Policies** → give it `TransactionalEmailFullAccess`, for this project only. Then **API keys** → generate a key for that application and copy the **secret key** — it is shown once.

	A separate application, so this key can send mail and nothing else. If it ever leaks, your receipts stay out of reach.
4. **Project settings** → copy the **project ID**. Not the organisation ID.

Write down: project ID, secret key, and a sender address on your domain for `MAIL_FROM`, e.g. `no-reply@yourdomain.com`. It needs no mailbox.

⚠️ **`MAIL_FROM` is not optional here.** Left blank, the app sends as `no-reply@` your Scalingo address, which Scaleway will refuse.

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
		| `SMTP_ADDRESS` | `smtp.tem.scaleway.com` |
		| `SMTP_PORT` | `587` |
		| `SMTP_USERNAME` | the project ID from Step 2 |
		| `SMTP_PASSWORD` | the secret key from Step 2 |
		| `MAIL_FROM` | the sender address on your domain from Step 2 — **not optional**, see the warning there |
		| `OWNER_USERNAME` | the name of your first account, e.g. `daniela`. It is created when the app starts — there is no sign-up page |
		| `OWNER_PASSWORD` | its password, at least 8 characters. Anyone with access to this Scalingo app can read it here, so change it once you are in |
		| `OWNER_EMAIL` | optional, but without it that account can never reset its own password |
		| `SERVICE_NAME` | your business name — appears on the app's legal page |
		| `CONTACT_NAME`, `CONTACT_EMAIL`, `CONTACT_TRADING`, `CONTACT_STREET`, `CONTACT_CITY`, `CONTACT_COUNTRY` | your own details — also on the legal page; required in Germany, honest practice everywhere |

	- **Optional, leave blank unless you know you want it:** `ASSET_HOST` (a service that makes the app's images and styling load faster for visitors far away — not needed for ordinary use).
	- **Already filled in, correctly:** `REPO_URL` — leave it as it is unless you're deploying your own fork of the code instead of following this guide as written.

4. Click **Create**. Scalingo builds and starts the app — about 5 to 8 minutes. The page shows a log; you don't need to read it.

5. When it says the app is running, open `https://smith-books.osc-fr1.scalingo.io` and sign in with `OWNER_USERNAME` and `OWNER_PASSWORD`. There is no sign-up page: that account was created as the app started, and it is the only way in.

6. You are asked to set up the **second factor**: the page shows a QR code, you scan it with your authenticator app and type the six digits back. From now on every sign-in asks for a fresh six digits.

7. Change that password (your name, top right → your admin page), since it is still readable in Scalingo's Environment page.

8. That first account is the **owner** — see [what "owner" means](../README.md#about-sudo). Add a second, ordinary admin for your own day-to-day bookkeeping, and give it the entities (businesses) it keeps.

---

## Step 4 — your own web address

*Optional, and can be done later.*

1. Use the domain from Step 2 (we currently use Hostinger as registrar. Moving to another later is not a big deal).
2. Scalingo dashboard → your app → **Settings → Domains** → add `books.yourdomain.com`. It shows you a target, something like `smith-books.osc-fr1.scalingo.io`.
3. At your domain registrar, find the **DNS settings** for your domain — usually  under something called "DNS", "DNS management" or "Name servers" once you've  clicked into the domain itself. Every registrar's screen looks different, but  they all ask for the same three things when you add a record: a **type**, a  **name**, and a **value** (some call it "target", "points to" or "content" —  same thing). <br />Add one with: type=CNAME, name=`books`, value=`smith-books.osc-fr1.scalingo.io` (from step 2) <br />Leave anything else (TTL, priority) at whatever it defaults to. This is a  **CNAME record** — it tells the internet "when someone looks for  `books.yourdomain.com`, send them to this Scalingo address instead." Changes  can take anywhere from a few seconds to a few hours to take effect  everywhere; if it doesn't work immediately, wait and try again before  assuming something's wrong.
4. Back in Scalingo, wait for the green tick. It is issuing the **certificate** — the thing that makes your address start with `https` and show a padlock in the browser. This happens automatically; the tick just means it's done.
5. Scalingo → app → **Environment** → change `APP_HOST` to `books.yourdomain.com`. Environment changes trigger a restart.

---

## When something goes wrong

- **Deploy failed.** Scalingo → your app → **Deploy** → open the last deployment's log and scroll to the bottom. Almost always a wrong storage key from Step 1, or a `CONTACT_*` field left empty — production refuses to start with those blank. Fix the value under **Environment**, then **Deploy → Manual deploy**.
- **Page won't load, says "Blocked host".** The app only answers to the one address you told it to expect, as a security measure — and the address in your browser doesn't match it. Go to Scalingo → your app → **Environment** and check `APP_HOST`: it should be typed exactly as the address you're trying to visit, with no `https://` and no trailing slash — e.g. `smith-books.osc-fr1.scalingo.io`, or `books.yourdomain.com` if you've set up your own address in Step 4.
- **The app is running but you cannot sign in.** The owner account is created by the deploy, from `OWNER_USERNAME` / `OWNER_PASSWORD`. If you left them blank, the deploy log's last lines say so. Fill them in under **Environment**, then **Deploy → Manual deploy**, which creates the account.
- **Receipts won't upload.** One of the Scaleway values from Step 1 is wrong. Re-check the bucket name, region, endpoint and both keys against your notes — a fresh key is quick to generate if in doubt.
- **Password resets or the tax export never arrive by email.** Check three things under **Environment**: `MAIL_FROM` is on the domain Scaleway verified in Step 2; `SMTP_USERNAME` is the project ID, not the organisation ID; the application from Step 2 has its `TransactionalEmailFullAccess` policy. Scaleway → **Transactional Email** → your domain shows whether mail was sent or refused.

## What it costs

<!-- TODO: figures below are provisional — Scalingo's smallest server + database    tier starts around €25/month and is not expected to be enough for real use;    revisit and confirm once we know actual resource requirements. Also confirm    whether a free trial period currently exists before stating one here. -->

- **Scalingo:** from around €25/month for the smallest app and database — likely more once real usage is accounted for. You choose and pay for the size of each separately, so it scales with what you actually need.
- **Scaleway (file storage):** free under 75 GB.
- **Scaleway (email):** a free monthly allowance, far more than this app sends.

## What you are trusting

Scalingo holds your database, Scaleway holds your receipt files. Both protect the data while it sits on their servers, but it isn't on hardware you own or control — you're trusting their security, not just your own. In exchange, you never have to keep a server's software up to date yourself, and if a hard drive fails, that's their problem to fix, not yours.

⚠️ **Those backups are of the database only.** Receipts and tax filings live in your Scaleway bucket, and nothing copies them anywhere else — that is yours to decide about, see [maintenance.md](maintenance.md).

**Database backups are automatic — nothing to set up.** Every paid Scalingo plan (which is what this guide uses) includes daily backups of your database by default: the last 7 days, kept automatically, plus 7 days of [point-in-time recovery](https://doc.scalingo.com/databases/about/backup-policies). No add-on, no extra cost, no cron job to remember — unlike some other hosting platforms, where backups are something you have to switch on yourself.
