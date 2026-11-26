# Known limitations

What is still open, and why. Not every item is the same kind of open. One is an
architectural ceiling — nothing to build, only to manage (§2). Some were decided
against on purpose, and are revisitable if the trade-off ever changes (§1, §3,
§4's no-PDF/no-import line). One is deliberate policy, not a gap (§4's receipts
line). The rest are genuinely not built yet, each with a TODO marking it (§5,
§6), and §7 lists what the VAT mechanism deliberately leaves out.

Three deployment shapes are in scope, and the trade between them runs backwards from what
people expect — the most private is the least safe:

| | Confidentiality | Reliability |
|---|---|---|
| Own laptop, one person | perfect | worst: one disk, no redundancy |
| Own server, own businesses | perfect | your backup discipline |
| Someone else's server, shared | operator reads everything | best: someone competent is watching |

<!-- toc -->

**Contents**

- [1. Filesystem storage is served without authentication in development](#1-filesystem-storage-is-served-without-authentication-in-development)
- [2. The master key, and the succession risk behind it](#2-the-master-key-and-the-succession-risk-behind-it)
- [3. Backup age is not shown to bookkeepers](#3-backup-age-is-not-shown-to-bookkeepers)
- [4. Getting the data out](#4-getting-the-data-out)
- [5. Docker Compose for people who are not developers](#5-docker-compose-for-people-who-are-not-developers)
- [6. Breach notice to affected admins is a promise, not a mechanism](#6-breach-notice-to-affected-admins-is-a-promise-not-a-mechanism)
- [7. VAT: what is deliberately not built](#7-vat-what-is-deliberately-not-built)

<!-- tocstop -->

---

## 1. Filesystem storage is served without authentication in development

Open, and accepted. `public/uploads` in development has no auth check —
anyone who can reach the dev server can read it directly. `config/puma.rb`
binds loopback (`127.0.0.1`) outside production, so on an ordinary developer
machine nothing here is reachable by anyone but the person who started
`bin/dev`. The exposure is real only if someone deliberately overrides the
bind to `::` to test from a phone, or runs `bin/dev` itself as a production
server instead of deploying properly — both already-unsafe choices a fix here
would not meaningfully guard against. Decided not to build authenticated file
serving for development.

## 2. The master key, and the succession risk behind it

Losing `config/master.key` costs less than it looks like — the Scaleway keys,
SMTP credentials and HMRC OAuth tokens it protects are all independently
recoverable from their own providers, and `secret_key_base` only costs
everyone a re-login. The genuine, unresolved case is **succession**: if the
key is gone *and* nobody can get into the underlying accounts (the operator
dies, or leaves, and the login dies with them), there is no recovery. That is
a people problem, not a software one — keep the key backed up, and know who
else can get into your provider accounts.

## 3. Backup age is not shown to bookkeepers

Decided, not built. Only the operator sees backup health (a weekly email from
`Maintenance::WeeklyCheck`) — a bookkeeper with no server access has nothing
to act on from a number they cannot change, so it is not shown to them. If
that judgement ever needs revisiting, this is where.

## 4. Getting the data out

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

## 5. Docker Compose for people who are not developers

<!-- TODO: build a docker-compose.yml (or adapt .devcontainer/docker-compose.yml) that lets someone run this with only Docker installed, no Ruby/PostgreSQL locally -->
Not built. Ruby and PostgreSQL are the entire remaining barrier to running
this without being a developer; `docker compose up` would remove both, and
there is already a `Dockerfile` and a `.devcontainer/docker-compose.yml` to
build from. SQLite is not a shortcut to the same goal: `btree_gist`, jsonb
columns and `ILIKE` (case-insensitive only for ASCII under SQLite — would
quietly fail to match ä, ö, ł, ñ) all depend on PostgreSQL.

## 6. Breach notice to affected admins is a promise, not a mechanism

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

## 7. VAT: what is deliberately not built

The VAT mechanism records and reports; it does not file, and four things are out
of scope rather than unfinished.

**VAT on the private half of a split.** A `%` split's private row carries no VAT
code. The Dutch return has `privégebruik` boxes and Germany has *unentgeltliche
Wertabgabe*; both need rules this app does not hold. Book the private portion
gross.

**No invoice/payment distinction.** A VAT line is reported in the period of its
**entry date**, and nothing more, so the basis follows the bookkeeping: book the
payment for a cash basis, book the invoice against Creditors/Debtors for an
invoice basis — which the easy manual documents under *Cash basis versus accrual
basis*, and which the one-balance-account relaxation already allows (an expense
with a code settled against a creditor saves and derives correctly).

What is genuinely missing is any record of which basis a set of books is on, so
nothing detects the same cost entered once as an invoice and once as a payment —
which would report its VAT twice. The bank entry form is also payment-shaped, so
invoice-basis entries go through the journal entry form.

**Partial exemption and pro-rata recovery.** The app records what you may
reclaim; it does not work out how much that is. Input tax attributable to
taxable supplies goes in at the invoice figure, input tax attributable to exempt
supplies goes in as zero and the whole gross stays in the cost. The *residual*
pool — input tax used for both — is apportioned on the period's totals with an
annual adjustment, and that calculation is the business's, not ours.

One known inaccuracy: where VAT is irrecoverable, box 7 carries the gross,
while HMRC asks for the value excluding VAT.

**Foreign-currency invoices.** A **reverse charge** may be paid from an account
in any currency. It posts nothing: the return works both halves out from the
net, translated at the rate that country's law accepts for the entry date,
exactly as every other tax report translates. Nothing is converted when an entry
is saved. If no accepted rate is held for that date, the return says so.

Any **other** VAT code posts a line into a control account, which holds the
scheme's currency, so it is refused on an entry in another currency. In
practice this means a supplier established in your own country who chooses to
invoice in a foreign currency — rare. Goods from abroad are import VAT, which
has its own codes; services from abroad are a reverse charge. Book the gross
with no code and record the VAT, which the invoice must state in your currency
anyway, as its own entry.

**VAT on a cross-entity gift.** The receiving side of a cross-entity
transaction cannot carry a VAT code. That is not an arbitrary restriction: the
app models the transaction as a **gift / capital contribution**, which is not a
taxable supply, so no VAT arises on it. The receiver holds no invoice in their
own name and so has nothing to reclaim.

A **recharge** is a different transaction in law — an onward supply, with the
payer issuing their own VAT invoice to the receiver — and the receiver *does*
recover the VAT on it. The app cannot record that through the cross-entity
button, because it models a gift, not a sale between two of your businesses.
Record it as what it is: an ordinary sale in the paying business (income +
output VAT) and an ordinary purchase in the receiving one (expense + input
VAT), settled by a transfer. Two normal entries, no special mechanism — two
entities never shared one entry anyway.

**When the payer is not registered.** The paragraph above assumes the payer can
issue a VAT invoice. If they cannot, the deciding fact is **whose name is on the
supplier's invoice**:

- Invoice in the **receiver's** name, the payer merely settled it: the receiver
  holds a valid VAT invoice for a supply to their own business and **recovers
  normally**. Nothing about who paid changes that.
- Invoice in the **payer's** name: the supply was to an unregistered person, who
  can neither reclaim it nor charge it onward. **The VAT is lost to both sides.**

So the practical advice is the first one: have the invoices made out to the
business whose expense it is.

**And then the refusal above is resting on a premise the app cannot check.** The
receiving side is refused a VAT code because "the receiver holds no invoice in
their own name" — true of a gift of goods, false whenever the invoice was
addressed to the receiver from the start, which is the correct way to arrange it.
The app has no invoice record, so it cannot tell the two apart. Today the way
round it is to book the receiving side as its **own ordinary entry** (expense
with a purchase code, credited to the equity bridge), which is accepted because
the refusal only fires on a posting that is `cross_entity_linked?`. The cost is
that the two sides are no longer linked to each other.

Which of the two a given payment actually is, and whether it is instead a
disbursement, is a facts-and-circumstances question for an accountant. The app
takes no view.

**Construction businesses: CIS is not handled, and that is disqualifying.** The
catalogue carries the UK domestic reverse charge for building and construction
services, which may give the impression the app suits a construction business. It
does not. The Construction Industry Scheme — the contractor deducting 20% or 30%
from a subcontractor's labour, monthly returns, the subcontractor reclaiming it —
is a separate withholding regime that this app models in no way at all. On the
advice of a practising accountant in the sector (2026-10-15): *"CIS is a legal and
integral part of construction and cannot be ignored."* Treat the reverse-charge
codes as serving a non-construction business that occasionally receives such an
invoice, not as construction support. The reduced-rate (5%) domestic reverse
charge is also real in practice and is not shipped.

**Simplified schemes other than a flat percentage** (Spanish *régimen
simplificado*, which is index-based; the EU farmers' flat-rate scheme). The UK
Flat Rate Scheme and the Swiss Saldosteuersatz are built: see
[vat-reference.md](vat-reference.md).

**Margin schemes** are a different matter and genuinely not built: VAT is charged
on the margin rather than the price, so the derivation itself differs.

**Filing.** The return is a screen and a CSV. HMRC VAT MTD and Dutch Digipoort
are separate connectors, not built.
