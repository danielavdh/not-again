# Concepts — the model this app is built on

What the words mean, what one set of books can hold, and the reasoning behind the bookkeeping decisions. Read this before extending anything.

<!-- toc -->

**Contents**

- [The model](#the-model)
    - [Nothing is locked — write access is the safeguard](#nothing-is-locked--write-access-is-the-safeguard)
- [Account coding](#account-coding)
- [Recording transactions](#recording-transactions)
- [Splitting a posting](#splitting-a-posting)
- [Receipts](#receipts)
    - [Linking to postings](#linking-to-postings)
- [Reports and exchange rates](#reports-and-exchange-rates)
    - [Translation variance](#translation-variance)
- [Closing a year](#closing-a-year)
- [Reconciliation](#reconciliation)
- [Admin access levels](#admin-access-levels)
- [Entities, families, and cross-entity entries](#entities-families-and-cross-entity-entries)
- [Tax — categories, schemes, and the three tiers](#tax--categories-schemes-and-the-three-tiers)
    - [The words](#the-words)
    - [What tier 3 will never include](#what-tier-3-will-never-include)
    - [What you are adding](#what-you-are-adding)
- [Filing](#filing)
    - [How the filing pieces fit](#how-the-filing-pieces-fit)
    - [Who may use a taxpayer](#who-may-use-a-taxpayer)
- [Contributor notes](#contributor-notes)

<!-- tocstop -->

---

## The model

Six objects, and one invariant that ties them together.

**Account** (`Account`) a name, a 6-digit code, and a type: **asset, liability, equity** (the balance sheet) or **income, expense, personal** (the P&L, called *nominal* here). Accounts form a parent/leaf tree; only leaves hold postings. A balance-sheet account carries a currency; a nominal account must not — it takes the currency of the entry it appears in.

**Journal entry** (`JournalEntry`) a dated set of postings that balance: debits equal credits, *per currency*. `posted` means balanced and ready to report — not locked. `closing_entry` marks a year-end.

**Posting** (`Posting`) one line of a journal entry: an account, an amount, and a side (debit or credit). A receipt attaches here.

**Entity** (`Entity`) a business or a household. Everything belongs to one. An entity has no foreign key on its accounts: an account belongs to an entity because digits 2–3 of its code say so.

**Family** (`EntityGroup`) entities grouped so they can share accounts; one journal entry may involve several members; they consolidate (balance sheet, P&L and trial balance include every member). An entity may be in one family or none.

**Report group** (`ReportGroup`) a set of accounts saved to report on. A `Report` is a report group plus a date range. There are standard reports (balance sheet, P&L and trial balance), custom reports (choose any accounts from a family or entity and arrange them as you please) and tax reports (carry a `tax_scheme`).

**The invariant:** any entry that touches the P&L has exactly one balance-sheet account (`single_balance_account_with_nominals`). That is what lets a nominal posting have no currency of its own — there is always exactly one balance leg to borrow it from (`Posting.currency_join_sql`).

Reports are assembled live from postings over any date range — nothing is stored as a "balance". On top of the ledger sit three optional layers: **tax categories** tag accounts and roll up into **schemes** and **connectors** (below); **exchange rates** translate multi-currency figures; **receipts** hang off postings.

### Nothing is locked — write access is the safeguard

Self-hosted, usually entered by the person whose data it is or their bookkeeper. Nothing here is locked: a closed year stays as editable as any other, and reports are no exception — any admin with write access (full access or full access pro) can correct a figure directly, in the report itself, with no reversal entry and no audit trail of who changed what.

That makes write access the real safeguard, not the software. Think carefully about who gets it — full access or full access pro — and give everyone else who needs to see the books read-only access instead. Read-only access, or an export (PDF or signed CSV), is how you make sure someone's copy of the books stays unchanged.

---

## Account coding

Accounts use a 6-digit code (`app/models/concerns/account_coding.rb`):

| Position | Meaning | Example |
|---|---|---|
| 1   | Type — 1 Asset, 2 Liability, 3 Equity, 4 Income, 5 Expense, 6 Personal | **5**04102 is an expense account |
| 2–3 | Entity (matches `entities.code`) | 5**04**102 is entity/business/household 04 |
| 4   | Subcategory — a rough grouping, yours to define | 504**3**02 could be 'Office Costs' |
| 5–6 | Fine detail | 5043**02** could be 'Computer and Digital Supplies' |

Positions 1–3 are **fixed** ; positions 4–6 can be chosen **freely**. Accounts sort by code, so your numbering *is* your reading order.<br /> 
Use parent accounts (e.g. 504300) to group accounts visually. Parent accounts don't hold postings, but they show the total of their children's amounts.

---

## Recording transactions

**Two interfaces, one model.**

- **Bank entries and transfers** (`accounts_controller.rb`) — the guided path. Reached from the ledger of a balance account. Day-to-day bookkeeping without needing to know double-entry.
- **Journal entries** (`journal_entries_controller.rb`) — the raw interface, every posting under your control, no guardrails. Only for admins who have enabled "full access pro" (self-selected).

Both write to the same `JournalEntry` and share the same validations. The controller code for the two looks duplicated — params, form helpers, CSV — and is, deliberately: they are different products on one model, and the duplication is what keeps the guided path simple. DRY and don't come crying.

**The balance-account shape.** The guided UI enforces it: a bank entry has exactly one balance-sheet posting; a transfer or currency exchange has exactly two. The raw interface allows more — a same-currency compound entry with three or more balance postings is valid double-entry and is allowed. (A cross-currency entry with 3+ balance postings fails `balanced?` and cannot be posted.) The ledger spots a compound entry — 3+ balance postings — and links its rows straight to the raw journal-entry form.<br />
If there are nominal postings only 1 balance account is allowed (and required) in a journal entry.

**Summarise, don't import.** There is no bank or card import, deliberately. Add up a month's travel, post one bank entry for the total against the travel account; do the same for subsistence, supplies, and so on. The result is a ledger you can read — one line per category per period, not a hundred raw card lines. To work from a downloaded statement: open it in a spreadsheet, add an account-code column, sum by code, enter those totals. For recurring entries, the **copy** button on any bank entry brings last month's in for you to adjust and re-post. If per-line auto-assignment is a hard requirement, this is not the right tool.

---

## Splitting a posting

Use of home, car, phone: a mixed business/private cost, split at entry time the way a careful accountant does it by hand. Every non-balance posting row has a `%` button that opens a modal: it takes the account, a business-use percentage (pre-filled from the account's `deduction_percentage`, sets and resets automatically), and a destination account for the private portion (usually a type-6 drawings account). Apply writes the business amount back to the row and injects a second row for the private portion. Both sides are real postings; the P&L shows only the business portion. Re-opening the `%` button edits the split but does not remove the injected row — tick its destroy box first. Doing it by hand (two accounts, book each portion) is always available; the feature just automates a fixed, recurring ratio.

**VAT** is designed, not built. Similar idea.

---

## Receipts

Receipt files over 2 MB are compressed before storage and **the oversized original is not kept** — the compressed version becomes the stored file. Images go to JPEG q80, max 2000×2000; PDFs through Ghostscript. Up to 20 MB is accepted, over that is rejected at upload. Receipts need to be readable, not archival — and the *source* document is the admin's to retain for the statutory period, the same as a paper receipt, not something this app takes over (see [self-hosting-legal.md](self-hosting-legal.md)).

A PDF's first page is rendered to an image for the thumbnail and preview. If that rendering fails (an encrypted or malformed PDF), the upload still succeeds — it just shows the placeholder preview.

### Linking to postings

Linked from the posting side only, two ways: on a new posting, the bank entry form carries an `existing_receipt_id` hidden field populated by JS, and `Posting#link_existing_receipt` sets the FK as an `after_create` callback; on an existing posting, linking and unlinking go through AJAX calls to `ReceiptsController#link`/`#unlink`, triggered from the posting UI rather than a form. Unlinking is also available from the receipt index. A receipt never initiates the connection — there is no way to link from the receipt side.

---

## Reports and exchange rates

Reports run against live data over any date range.

Exchange rates are stored as **validity spans** — a `valid_from`/`valid_to` pair per currency pair per source. A monthly rate is a span covering the month, a daily rate a span covering the day; the lookup is identical, so resolution is a property of the publisher, not the code. Each amount in a report is translated at the rate whose span contains the posting's date.

A hand-entered rate always belongs to **one entity** — a business's own elected rate, which several authorities allow (a Swiss group rate, a documented German `Tageskurs`). It wins over the published series where it covers the date. The published series is shared by every entity; only a system admin may change it.

Four sources, each fetched from its publisher's own feed and declared as data in `db/exchange_rate_sources.yml` (base currency, frequency, meaning, history, parser class):

| source | base | figure | history |
|---|---|---|---|
| **ECB** | EUR | month-end spot | ~30 currencies, daily back to 1999 |
| **HMRC** | GBP | fixed for the month ahead | ~170 currencies, from 2021 |
| **ESTV** (CH) | CHF | monthly average | current month only — no history, ever |
| **Bundesbank** | EUR | monthly average of ECB dailies | for German `Umsatzsteuer` |

Adding more is a block of YAML each, plus a parser class — `RateSourceConfig` is the only reader. Fetches have explicit timeouts (10s/15s); a daily `FillRateGapsJob` backfills anything the books need and the database lacks. Fetch timing is deliberate: ECB stores only on the last day of the month (dated to that day); HMRC runs on the 1st though the figure was published the previous Thursday, so the stored date matches the month it applies to. Exhausted retries email the sudo admin; rates can always be fetched and/or entered by hand meanwhile.

⚠️ **Two parser traps, both found the hard way.** `Net::HTTP` returns `ASCII-8BIT` whatever the charset header says, so a header containing `£` matched nothing until `fetch_url` forced UTF-8 — and the unit test passed throughout, because it used a Ruby string. And ESTV ignores every date parameter and serves the current month regardless. Hit the real feed before believing a parser works.

### Translation variance

Shown in the display currency, a trial balance's translated debit total will not equal its translated credit total — a debit posted in January and a credit posted in March are translated at different monthly rates, even though the entry balanced in its own currency. This is expected. The app makes it explicit: an **Exchange Rate Variance** line and an **Adjusted Totals** row that bring the two sides back into agreement. The figure is the sum of translation differences across the period's cross-currency transfers, plus the sub-cent rounding from translating each account separately — both belong on the same line.

The only entry that can genuinely be cross-currency is a 2-posting balance-sheet transfer — `balanced?` gives every nominal posting the currency of the entry's balance leg, so nothing else carries a variance. Such a transfer is balanced on shape alone (one debit, one credit, both positive, both balance accounts), with **no check on the rate its amounts imply**: the right rate is whatever the bank settled at, and a validation would need an oracle. Two softer guards instead — the implied rate shows under the second amount as you type, and on save, if it is more than 50 % off the published rate for that pair and date, a confirmation names the gap in report terms ("about £120 of extra profit") before you commit. You can still say yes; sometimes the bank really did that.

## Closing a year

Closing moves income and expenses into a retained-earnings equity account, so the new year starts from zero and the balance sheet balances. The balance sheet's "Current Period Net Profit / (Loss)" line is the un-closed P&L sitting in nominal accounts — normal during the year, zero once closed.

**Assisted.** The reports page offers a close action. The first close asks for your fiscal-year pattern (calendar, 6 Apr–5 Apr, 1 Apr–31 Mar, or your own day and month); after that each close is a confirmation, oldest-first through any backlog. The pattern is never stored — it lives in the closing entries, each of which records its `period_start`/`period_end`; the dashboard's "closed up to" reads the latest. Unfinished years cannot be closed; empty periods are stepped over.

**Manual.** Pro users can post the closing entry by hand — debit each income account and credit each expense account to Retained Earnings, in one compound entry. It is then on you to keep the pattern consistent; nothing checks it, and hand-made entries carry no `closing_entry` flag, so they never appear in "closed up to".

**Multi-currency.** Either close each currency into its own retained-earnings account, or translate everything at the year-end rate into one entry and book the rounding to a currency-translation-adjustment equity line. The compound form supports both. The assisted flow creates a retained-earnings account per currency on demand.

You can also never formally close, and use date-filtered reports instead.

---

## Reconciliation

The accounts index has an **R** button on every balance-account leaf. It opens a modal: you enter a statement date and the balance from your bank statement, and the app shows its own computed balance for that date and the difference. **Nothing is saved** — no reconciliation record, no period lock, no cleared-transaction marking. It exists to catch a data-entry error against an authoritative external number. Confirm they match, close the modal, carry on.

---

## Admin access levels

| Level | Can do | OTP required |
|---|---|:---:|
| Upload only | Upload (and delete) receipts, assign them to an entity if >1 | no |
| Read only | View accounts, reports, journal entries; download csvs, print pdfs, trigger tax export | yes |
| Full access | The above + create, edit, post, delete | yes |
| Full access pro | Full access + the raw journal-entry flow | yes |
| Sudo | Global — sees and can act on every entity, creates admins and grants them full access by assigning entities to them. Never has entities assigned to itself; sudo is a meta/management role. See [README](../README.md#about-sudo). | yes |

Full access pro is self-selected: admin ticks 'show journal entries' on their profile page.

OTP is off in development and test by design (`Admin.otp_required?` returns `Rails.env.production?`). To exercise the flow locally, change that method temporarily — try not to scatter environment checks elsewhere.

---

## Entities, families, and cross-entity entries

**Entities.** The app is multi-entity — digits 2–3 of every account code identify the business or household. Each entity keeps its own accounts and files its own return, and by default a journal entry stays within one entity.

**Families.** Entities can be grouped into a family (`EntityGroup`) — a household plus a sole trade, two related businesses. A family consolidates (balance sheet, P&L, trial balance expand to every member) and relaxes the single-entity rule to a **per-family** one: `postings_same_group`, not `postings_same_entity`, so one journal entry may contain postings of several members (entities) that share a family, e.g. a couple with a shared bank account, and each is self-employed and fills in their own tax returns.

**Cross-entity entries.** Two entities in *different* families cannot share an entry. When one pays a cost belonging to the other, the app records **two single-entity entries** joined by a shared `cross_entity_link_id` (the split-posting `deduction_pair_id` pattern, across entries). The bridge is **drawings ↔ capital**, never a due-to/due-from or a loan:

- **JE₁ (payer):** Dr `6xx` gift/drawings · Cr `1xx` bank — the owner draws money out (post-tax).
- **JE₂ (payee):** Cr `3xx` capital · Dr `5xx` expense (or Cr `4xx` income) — the owner introduces capital, which the entity spends.

The real leg is **nominal only** — a balance-account movement would be a transfer or a loan, self-contained. Capital carries the bank's currency. This keeps it tax-clean for a common owner: payee gets the deduction, payer deducts nothing, capital-in is not income. The pair is created in one transaction and behaves as one: edit from the payer side, deleting the payer cascades to the payee, deleting the payee severs the link. Model backstops enforce the mirror (equal amount, opposite side, different entity), the nominal-only real leg and the currency match. See `app/controllers/concerns/cross_entity_journal_entries.rb`, `Posting`, `JournalEntry`.

**Offboarding is not deletion.** `EntityPurgeService` removes data with `delete_all`, which bypasses the cascade callback — so when a payer entity is purged after its retention period, the payee's linked entry is **left intact** in its own books, its orphaned link going inert. We never one-side a still-active entity's accounts a decade later. `test/services/entity_purge_service_test.rb` fails loudly if the purge is ever changed to a callback-firing `destroy`.

---

## Tax — categories, schemes, and the three tiers

The app grew in three stages, and the extension model still follows them:

| Tier | What it adds | What it takes |
|:---:|---|---|
| **1** | Speaks your language and your money | A locale file, a currency entry. No country involved. |
| **2** | Speaks your country's tax vocabulary | A tax-category YAML per country / scheme / year, plus the rate its authority accepts |
| **3** | Files on your behalf | A filing connector implementing `Filing::Base` |

**Language, currency and country are independent axes.** Adding Italian is not adding Italy; a Swiss entity may keep its books in German; accounts are multi-currency regardless. Tier 2 → tier 3 is a real dependency — you cannot submit what you have not categorised — but tier 1 is orthogonal to both.

Where a scheme sits is one fact: whether its YAML carries a `connector:` key. `gb_self_employment_2026.yml` has one and reaches tier 3; `de_euer`, `de_vermietung`, `ch_selbst`, `nl_winst` do not and stop at tier 2 — categorise, report, export.

### The words

**Scheme** — one *return* (a form a taxpayer files). `gb_property` is SA105, `vermietung` is Anlage V. One YAML per scheme per year in `db/tax_categories/`, whose header names its country, authority, currency and — if fileable — connector. "Per year" means: **add a new year file only when the form itself changes**; a 2024 scheme may hold good through 2030.

**Category** — one *box* on that form. A row under `categories:` in the YAML. Accounts are tagged with a category; a report sums each box. `section:` is the one field in the app's own vocabulary rather than the form's, and is one of `income`, `expenses`, `other`.

**Connector** — the code that *submits* to one service (auth, client, payload). A class in `app/services/filing/`, e.g. `Filing::HmrcMtd`. Named in the scheme's header, stored nowhere else.

**Taxpayer** — a taxpayer *as one authority knows them*: their number and their permission for the app to act. Owned by an admin, chosen per tax report group.

**Tax report group** — the set of accounts that make one submission, plus the identifier that authority uses for that business. A `ReportGroup` with a `tax_scheme`.

There is **no country object** anywhere — adding Poland means adding a Polish scheme, and the country falls out of its `country_code:` header. An **authority** (HMRC, ELSTER) is likewise just a string; only a connector is real code.

### What tier 3 will never include

**The app does not file annual tax returns.** The rule is not "periodic yes, annual no" — it is *what the number is made of*. A periodic VAT or MTD update is submittable because it is nothing but the ledger, summed. An annual return needs facts that are not in the books: other income, personal circumstances, reliefs, loss elections.

Germany shows both sides: the **Umsatzsteuervoranmeldung** is periodic and pure ledger — can be tier 3. The **Umsatzsteuererklärung** is annual and reconciling — tier 2, you export it and file it yourself.

This limits *submission*, not output. A full-year tax CSV for your accountant or your own return is exactly what tier 2 is for, with no restriction.

### What you are adding

**A category** — the authority added a box, or one was missing. Add a row to the scheme's `categories:`, run `bin/rails tax_categories:load`. Edit **in place** to correct our own transcription; write a **new year file** when the form itself changed — see [Years](tier-2-extending-countries.md#years-forward-only-and-correctable-in-place). The loader upserts by key, deletes keys you removed, and emails anyone whose accounts used them. Fields: [Each category row](tier-2-extending-countries.md#each-category-row).

**A scheme** — a return the app does not know. Write one YAML and load it: no constant to register, no list to extend. `TaxSchemeConfig` derives countries, schemes, authorities, currencies and connectors from the headers. A scheme in a new country also needs one entry in `db/exchange_rate_rules.yml` naming the rate its tax law accepts — a test refuses a country without one. Omit the connector header and it stops at tier 2, the normal case. Worked example: [Adding a country](tier-2-extending-countries.md#adding-a-country--a-worked-example).

**A connector** — the app should file a scheme, not export it. The substantial one, and the only real *build*: auth flow, API client, payload format, obligations model. [Adding digital submission](tier-3-extending-filing.md#adding-digital-submission-for-a-new-country).

---

## Filing

Tagging, reports and exports need none of this. It applies only when the app files for you.

```
tax report group -> taxpayer -> HMRC
  its accounts      their number (NINO)
  its business id   the token, and when it expires
  its scheme -> YAML -> connector
```

Read as: *these accounts, filed as this business, under this taxpayer's number, with this permission, by this code.*

### How the filing pieces fit

**The accounts in one scheme must belong to one taxpayer.** They are summed into one submission under one number, so they must be one person's. The report group *is* the set of accounts that gets sent.

**A taxpayer (database) row is one person at one authority.** Someone filing in the UK and in Germany has two numbers and two permissions — two rows, nothing linking them, and filing never needs them linked (a group has one scheme → one authority → one taxpayer).

**A taxpayer is set up by an admin, and is chosen per tax scheme (tax report group).** A person with several businesses authorises once and picks the same taxpayer for each scheme with the same authority.

**The per-business identifier belongs to the tax report group; the person's number (NINO, Steuernummer) belongs to the taxpayer.** Some authorities run several businesses under one taxpayer — where they do, each business has its own identifier, and it sits on the group. HMRC, which the app files with today, works this way: it issues a business ID per trade, so a shop and a rental property are one number and two business IDs. SA105 asks for a count of properties and a total — one UK property business however many buildings. SA103F asks for a business name, address and its own accounting dates — one per trade.

So one entity can hold a UK property business, a UK trade and a German trade at once — three groups, three (or two) identifiers, one HMRC taxpayer and one German one. It cannot hold two UK trades: the app keeps one tax report group per entity per scheme, so a second trade needs a second entity. Business IDs are never typed — the app fetches them from the authority after you connect.

### Who may use a taxpayer

An entity can have several admins, so a tax report group may be reached by an admin who does not own the taxpayer behind it. **The choice: anyone with edit rights on the entity may submit, but the identifiers stay visible only to the taxpayer's owner.** The permission was granted for these books, so a colleague working them should be able to file; a NINO is personal data, and the code needs it, not the person clicking — so it is masked for everyone else. Revisit here if a contributor needs it broader; nothing else depends on it.

---

## Contributor notes

**Internationalisation scope.** Every view a regular user reaches is translated (en, de, nl, es). Sudo-only views — the entities index/new/edit, the account delete button, similar admin screens — are intentionally English: sudo is a system-level capability and whoever holds it is assumed comfortable with English. A proper open-source system-admin role would need those translated; the locale files are under `config/locales/`.

**Accessibility.** Target: WCAG 2.1 AA (an HMRC requirement for MTD software).

- **Landmarks:** `role="main"` is added to the content `<div>` in each layout rather than swapping the tag to `<main>` — semantically identical for assistive tech, but it does not risk tag-qualified SCSS/JS (there is a lot of `#main` CSS). Audit CSS/JS before changing any element's tag.
- **`lang`:** `<html lang="<%= I18n.locale %>">` in every layout.
- **Icon-only controls** (homepage nav panes, modal `×`, unlabelled inputs) carry `aria-label`. No visual tooltips — the same text is the accessible name.
- **High-contrast mode:** built entirely on the existing CSS custom properties — every colour is already a `--var` (`shared/_colors.scss`), so high contrast is one `@mixin palette-high-contrast` that re-defines them, no second stylesheet. It applies in two ways: automatically under `@media (prefers-contrast: more)`, and explicitly via a class on `<html>`. Three states, not a boolean: `high-contrast` forces it on, `contrast-normal` forces it *off* even when the OS asks for more contrast, and unset follows the OS. The toggle `POST`s `/contrast`, which stores a year-long cookie that `contrast_class` turns into the class each layout renders server-side — so there is no flash on load. The palette is generated to pass AA and checked with a contrast script.

