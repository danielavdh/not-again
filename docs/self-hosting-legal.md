# What the law now expects of software

⚠️ **This is not legal advice.** It is a developer's reading of two EU regulations, written to save you from meeting them for the first time in an email from someone's lawyer. Nothing here has been checked by anyone qualified, and there is no case law yet — both instruments are still coming into force. Treat it as a map of what to ask about, not an answer.

<!-- toc -->

**Contents**

- [The two laws](#the-two-laws)
- [What this app already does](#what-this-app-already-does)
    - [Part I — security properties](#part-i--security-properties)
    - [Part II — vulnerability handling](#part-ii--vulnerability-handling)
- [What is still missing](#what-is-still-missing)
- [If you hold other people's financial data](#if-you-hold-other-peoples-financial-data)
- [If you charge people to use it](#if-you-charge-people-to-use-it)

<!-- tocstop -->

## The two laws

The **Product Liability Directive** (EU 2024/2853) was rewritten in 2024 to treat software as a product, carrying the same liability for defects that a toaster does. Member states must put it into national law by **9 December 2026**.

The **Cyber Resilience Act** adds security obligations — vulnerability handling, incident reporting, conformity assessment — with reporting duties beginning around **September 2026**.

Both carve out open source **supplied outside a commercial activity**. Give software away and you are an exempt developer.

## What this app already does

The list below is the Cyber Resilience Act's Annex I, which is the prescriptive one. The Product Liability Directive is about liability for defects rather than a checklist, so it has no equivalent table.

**Nothing here is required of you while you supply this non-commercially.** It is here so that if you ever do charge, you know what you start with and what is missing.

### Part I — security properties

| Requirement | State | Where |
|---|---|---|
| No known exploitable vulnerabilities at release | **built in** | `brakeman`, `bundler-audit check --update` and `bin/importmap audit` run on every push |
| Secure by default configuration | **built in** | OTP forced in production; no demo unless you seed it; buckets private; no default account, and `install:owner` refuses once one exists |
| Protection from unauthorised access | **built in** | login on every page, access granted per entity, three roles, OTP, sign-in rate-limited to 10 attempts in 3 minutes |
| Confidentiality of data | **built in** | TLS 1.2+ for all traffic; the database encrypted at rest — by default on [Scalingo](scalingo.md), a setup step on your own server ([provider setup](provider-setup.md)); Active Record encryption on the HMRC OAuth tokens; the credentials file is itself an encrypted file |
| Integrity of data and configuration | **built in** | CSRF protection on every form, signed cookies, and a database-level constraint that makes overlapping exchange-rate periods impossible |
| Data minimisation | **built in** | bookkeeping data only. No analytics, no trackers, nothing a visitor's browser fetches from anyone else. The one thing kept beyond the books is the sign-in record — IP address and user agent, for 90 days, for the security reason in the row below. A session ends at logout or when its second factor lapses; demo sessions are swept hourly |
| Resilience to denial of service | **partly** | the three public endpoints are rate-limited. There is nothing broader, and nothing at the network layer beyond your firewall |
| Minimise attack surface | **built in** | no invoicing, CRM, payments or bank feeds by design; a Content-Security-Policy naming only your own origins; modern browsers only; on your own server, a minimal firewall — 22, 80, 443 ([provider setup](provider-setup.md)); nothing to lock down on [Scalingo](scalingo.md) |
| Record security-relevant events | **built in** | `SignInEvent` records sign-ins, failed sign-ins and failed second factors, reported weekly and swept at 90 days. Scoped to authentication: modification of data is not recorded, because a journal entry is already its own record |
| Secure deletion of data | **built in** | `EntityPurgeService`, the monthly retention sweep, and the offboarding task |

### Part II — vulnerability handling

| Requirement | State | Where |
|---|---|---|
| Address vulnerabilities without delay | **built in** | Dependabot weekly, grouped per ecosystem; security advisories arrive on their own |
| Regular testing and review | **built in** | the full suite plus system tests, on every push |
| A contact address for reports | **built in** | `/.well-known/security.txt`, generated from your `CONTACT_EMAIL` |
| Free security updates | **built in** | inherent to how this is distributed |
| Secure distribution of updates | **built in** | This project distributes *source*. Each operator builds their own — an image pushed to their own registry on the developer version, a slug [Scalingo](scalingo.md) builds from the repository. There is no shared prebuilt binary to tamper with, and the transport is TLS throughout. Nothing is signed and nothing needs to be; sign a build only if you ever hand one to someone else |
| Software bill of materials | **built in** | CI writes an SPDX JSON document on every push, from `Gemfile.lock`. Covers the Ruby side; not the JavaScript pinned in `config/importmap.rb` |
| A coordinated disclosure policy | **built in** | [SECURITY.md](../SECURITY.md) — where to report, what happens next, and what is by design rather than a defect |
| Public disclosure of fixed vulnerabilities | **built in** | published as GitHub Security Advisories, per [SECURITY.md](../SECURITY.md) |

## What is still missing

One row above says **partly**: denial of service. The three public endpoints are rate-limited per IP, and there is nothing broader — a distributed attack is a hosting problem, not one this application can answer. Everything else in both tables is built.

---

## If you hold other people's financial data

**You may be a data processor — whether or not you charge.** Holding someone else's books on your server, for free or for money, can make you a processor under GDPR and them the controller. Article 28(3):

| Duty | Status | Where |
|---|---|---|
| (a) Process only on the controller's instructions | Built in | the software has no other channel — it only does what a signed-in admin does through it |
| (b) Confidentiality of authorised persons | Stated | `/legal` — "If we hold data for your business" |
| (c) Article 32 security measures | Built in | the security table above; restated in `/legal` |
| (d) Sub-processors disclosed | Built in, edit for your setup | `/legal` "Where your data is stored" names Hetzner, Scaleway, OVH and Brevo — the reference installation's. It is plain text in `app/views/help/legal_*.html.erb`; adapt it (and the retention and jurisdiction wording) to your own providers, the same as the Impressum |
| (e) Assist with data-subject rights | Built in | an admin can already review, correct and export their own data. Erasure specifically is limited by Art. 17(3)(b) while a statutory retention period applies — not a gap, the law itself |
| (f) Assist with security/breach obligations | Stated, manual | `/legal` commits to telling the affected admin directly; no automated notification yet — an operator action today, tracked in [known-limitations.md](known-limitations.md) §15 |
| (g) Delete or return data at the end | Built in | deletion: the monthly retention sweep, `EntityPurgeService`. Return: self-service, not proactive — tax export (CSV, DATEV) any time; a full books CSV per entity/family, one click, at each year-end close or on demand (§8); receipts bundle-download, selected on the receipts index |
| (h) Demonstrate compliance, allow audits | Built in | the source is open — compliance is checked by reading it, not taken on trust — plus the SBOM and CI security scans on every push |

`/legal` covers both roles now: the existing privacy notice for a self-hoster keeping their own books, and a new "If we hold data for your business" section addressing Article 28 directly for admins whose books someone else holds. The written record — who, what version, when, emailed as a copy — is built: two columns on `Admin`, gated at first sign-in for every admin, including one already in the database when this shipped. See [known-limitations.md](known-limitations.md) §13.

**Receipts are the one category deliberately not covered by (g)'s "return", and not backed up server-side either — stated on `/legal`, not left implicit.** A receipt already exists in two independent places once uploaded — the admin's own copy, and the live bucket — and keeping the source document for the statutory retention period is the admin's own obligation under ordinary bookkeeping law, the same as it would be for a paper receipt, not something this software takes over. See §8's closing note in [known-limitations.md](known-limitations.md).

### How long you must keep it, and why erasure does not apply

Art. 17(3)(b) exempts data held under a legal retention obligation from the right to erasure, and
bookkeeping records are exactly that. Deleting a business's books on request would put that
business — and you — in breach of tax law. This is why (e) above says erasure is limited rather
than missing.

The period is the entity's tax country's:

| Country | Records | Period | Basis |
|---|---|---|---|
| GB | self-assessment business records | 5 years from the 31 January filing deadline of the tax year | HMRC record-keeping rules |
| DE | books, records, vouchers | 10 years for books and records; vouchers 8 years since 2025 | § 147 AO / § 257 HGB |
| CH | books, records, vouchers | 10 years | Art. 958f OR |
| not set | — | 10 years, the longest period, as a safe default | — |

`Entity::RETENTION_YEARS` is a flat **10** rather than a lookup, so a British entity is kept five
years longer than the law requires. Over-retention is the safe direction, and the purge is
sudo-confirmed either way — but it is a deliberate choice, not an oversight.

The period applies to the **whole** entity dataset, books and receipts together: a receipt is a
legally retained voucher, not a disposable attachment.

### Deletion and backups

Deleting from the live database does not reach into backups, and is not meant to. Backups are
restored only for disaster recovery, so deleted data does not re-enter the live system in normal
operation; it ages out of the rotation instead — within about twelve months for the daily, weekly
and monthly tiers, and within ten years for the yearly one, which exists so that losing the
database and its recent backups together cannot destroy records still under statutory retention.

⚠️ **Do not add backup scrubbing to "complete" an erasure.** It would defeat the yearly tier's
whole purpose, and the ageing-out above is what makes the position defensible without it.

## If you charge people to use it

⚠️ **Read this before you invoice anybody.**

Running this for other people free is not a commercial activity. Charging — hosting, support, a paid tier, even cost recovery — makes you an *economic operator* under the CRA and the Product Liability Directive. This is worth an hour with someone qualified before you send any bills.

**1. Software or bookkeeping?** You are selling software, not doing tax work — unless you personally enter your customers' transactions for them on this app. In most countries that is a separate, licensed activity (in Germany, the Steuerberatungsgesetz) with its own rules this page doesn't cover.

**2. CRA paperwork**, once you charge — four things. Templates for three of them are in [docs/CRA/](CRA/), ready to fill in; the file names say the publication rule so it can't be missed:

- [**technical-documentation-NOT-publish.md**](CRA/technical-documentation-NOT-publish.md) — Annex VII, Article 31. The one genuine writing project: a risk assessment specific to your own deployment, which nobody can template in advance. Never published — kept on file, shown only if your market surveillance authority asks.
- [**conformity-assessment-NOT-publish.md**](CRA/conformity-assessment-NOT-publish.md) — Annex VIII module A self-assessment. Already effectively done: the two tables above **are** the check. Only the attestation is missing. Never published, same rule as the technical documentation.
- [**eu-declaration-of-conformity-FILL-and-publish.md**](CRA/eu-declaration-of-conformity-FILL-and-publish.md) — Annex V, Article 28, plus the declared support period (Article 13(8)). **Must be published**, per Article 13(20): it has to accompany the product. Fill it in, convert to PDF, and upload it as sudo from `/legal` — the app has a place built for exactly this, and the page becomes the address to point at.

**CE marking** — the physical/graphic mark that normally goes with the declaration. For a self-hosted web service with nothing shipped in a box, whether it applies the way it would to a physical device is a genuine open question, not answered here.

**3. If something goes wrong, once you charge** — two different things, two different people to tell.
Easy to mix up, so here they are side by side:

| What happened | Who you tell | How | Deadline |
|---|---|---|---|
| A vulnerability in the app is being actively exploited | ENISA + your national CSIRT | the **ENISA Single Reporting Platform** — one form, notifies both | 24h early warning, 72h with detail, 14d final report |
| Personal data has leaked or been exposed | Your own national Data Protection Authority | that authority's own portal — every country has a different one, there is no single EU site | 72h |

⚠️ **If the leaked data belongs to books you hold for someone else, your own duty is usually the
simpler of the two.** GDPR Article 33 puts the DPA report on the *controller* — the admin whose data
it is; the processor's job (Article 33(2)) is to tell them, fast, so their clock can start.
`/legal`'s "we will tell you directly" line is that commitment. You only file with a DPA yourself for data that is genuinely
yours — your own admin accounts, this installation's own infrastructure.

Both rows need someone to actually notice first. This app's own tooling — `brakeman`,
`bundler-audit`, Dependabot, the weekly sign-in report — helps with that, and
[SECURITY.md](../SECURITY.md) gives a stranger a channel to tell you privately. Neither can be the
person who files either report once notified — that has to be a human, you or someone you've
specifically arranged.

There is also a separate law (Product Liability Directive) that can make you liable if the software causes real damage through a defect — similar to being sued over a faulty product — and a disclaimer in your terms does not reliably get you out of that.
