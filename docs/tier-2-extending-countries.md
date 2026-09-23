# Adding a country — tax catalogues and categories

How to add tax support for a new country — one YAML file transcribing the authority's own form, no Ruby required for the usual case. Covers writing that file, loading it, and keeping it correct, with Poland worked through end to end. A rate source is a separate concern covered in [Exchange rate sources](tier-2-add-rate-source.md).

<!-- toc -->

**Contents**

- [Finding the original scheme](#finding-the-original-scheme)
    - [What to commit](#what-to-commit)
    - [The rule underneath all of this](#the-rule-underneath-all-of-this)
- [Catalogue](#catalogue)
    - [The header](#the-header)
    - [Each category row](#each-category-row)
    - [Provenance, and watching for changes](#provenance-and-watching-for-changes)
    - [Loading](#loading)
- [Years, forward-only and correctable in place](#years-forward-only-and-correctable-in-place)
- [Account-form dropdown](#account-form-dropdown)
- [Auto-assignment — suggestions from keywords](#auto-assignment--suggestions-from-keywords)
- [Adding a country — a worked example](#adding-a-country--a-worked-example)
    - [What will fail, and what to do about it](#what-will-fail-and-what-to-do-about-it)
    - [What you do NOT need](#what-you-do-not-need)
- [Tax category depth and inheritance](#tax-category-depth-and-inheritance)
- [Email tax export](#email-tax-export)
- [Adding an accountant format](#adding-an-accountant-format)
- [Where accounts get tagged](#where-accounts-get-tagged)
- [Filename convention](#filename-convention)

<!-- tocstop -->

## Finding the original scheme

Everything else in this document assumes you have the authority's own description of what goes in the return. Getting it is the first step and usually the longest, because **it is not the same kind of document in each country** &mdash; and knowing which situation you are in decides how the catalogue is built.

Four routes, all of them live in this repository:

**A numbered form.** The best case. Britain's SA105 and Germany's Anlage EÜR are PDFs with box numbers on them, so `label` is the box's printed wording and `export_column` is its number or Kennzahl. Download it, put it in `docs/tax-forms/`, transcribe it box by box.

**No form at all.** Switzerland has no federal form with income and expense boxes &mdash; income tax on the self-employed is assessed cantonally, and the cantonal forms ask for a single figure with the breakdown attached. So the categories come from the statute that prescribes that breakdown, OR Art. 959b Abs. 2, and `export_column` cites the provision (`959b:2.4`) because there is no box number to quote.

**The form is a schema.** The Netherlands files online only; the authoritative definition of the return is the XBRL taxonomy it is transmitted in. The structure is real and complete, it just is not printed anywhere. Extracting it means joining three linkbases that XBRL deliberately keeps apart &mdash; presentation says *what and in what order*, labels say *what each element is called*, and they meet only through opaque locator ids. The element names then serve as `export_column`, and would double as `api_field` if a connector were ever built, which is unnecessary as one files online to start with.

**A form that is too coarse.** Spain's Modelo 130 looks promising and has three boxes: income, deductible expenses, net. It is a payment on account, not a breakdown. The real categories are in the annex to the ministerial order approving Modelo 100, published in the BOE. Check that a form actually has the granularity you need before building on it.

### What to commit

Whatever you found, commit something the next person can check your transcription against, in `docs/tax-forms/`. A PDF where there is one. Where there is not, commit a **readable extract** naming the exact source version &mdash; see `nl-winstaangifte-resultatenrekening-nt20.md`, which is 12 KB and lists every element in the taxonomy's own order with its own labels.

⚠️ **A huge source download must not get committed.** The Dutch taxonomy, for instance, is 1.7 GB of XBRL, and git cannot forget a blob once it has one. `docs/tax-forms/gitignored/` exists for exactly this — drop the download there, read it, extract what you need into a real, committed file, then delete it.

### The rule underneath all of this

**Never from memory, never from a summary, never from a blog post explaining the form.** Use what the authority itself publishes. The whole catalogue mechanism assumes its contents are a faithful transcription of a real document; everything downstream &mdash; the report, the accountant's CSV, a submission &mdash; inherits any error you introduce here, and inherits it silently.

## Catalogue

The available categories per country / scheme / year are defined as YAML in `db/tax_categories/` (Below the list of the shipped files):

```
db/tax_categories/
├── gb_self_employment_2026.yml
├── gb_property_2026.yml
├── de_euer_2026.yml
├── de_vermietung_2026.yml
├── ch_selbst_2026.yml
└── nl_winst_2025.yml
```

**Each file is built from the authority's actual form**, and the original it was built from is kept in `docs/tax-forms/` so the next person can check the work rather than trust it &mdash; `SA103F_2026.pdf`, `SA105_2026.pdf`, `anlage-euer-2025.pdf`, `anlage-v-…-2025.pdf`, `ch-zh-hilfsblatt-a.pdf`, and for countries that publish no PDF a readable extract instead. See [Finding the original scheme](#finding-the-original-scheme).

**Warning:** We try to catch a reissued form automatically — see [Provenance, and watching for changes](#provenance-and-watching-for-changes) — but no authority publishes anything reliable to check against, so for several schemes nothing is available to watch. Whoever adds a scheme owns checking it against the real form every year; the automation is a bonus, not a guarantee.

### The header

```yaml
country_code: de           # two letters, lowercased
scheme: vermietung         # slug, unique across ALL countries — see below
tax_year: 2026
authority: ELSTER          # who you file with
position: 20               # display order within the country (optional)
scheme_label: "Vermietung und Verpachtung (Anlage V)"   # what the SCHEME is called
report_name: "DE-Vermietung"   # the tax report's visible name, never translated
currency: EUR              # what this scheme's figures are denominated in
tax_year_ends: "04-05"     # OMIT for a calendar year — see below
form_code: SA105           # the authority's reference for the form (optional)
connector: hmrc_mtd        # OMIT unless the app can submit this scheme digitally
submission_name: "MTD property"  # OMIT unless connector is set — see below
```

Scheme names are unique per country. The slug is made up of [country_code]_[scheme]. That is what lets a slug name its own country, authority, currency and connector, and it is why one entity can carry schemes from several countries at once without anything having to ask where the business "is".

**`currency:`** must be a currency the installation actually has — add it first, if not yet available. A test refuses a scheme filing in one nobody knows. A tax report wants to show its final total in the scheme's currency.

**`tax_year_ends:`** is the day the country's tax year ends, as `MM-DD`. **Omit it unless the tax year is not the calendar year** — Germany, Switzerland and the Netherlands declare nothing, Britain declares `"04-05"`. The rule everywhere is the same: *a tax year is named by the year it ends in*. So a German date in 2028 is tax year 2028, and a British date in July 2028 is tax year 2029, because it falls in the year ending 5 April 2029. A calendar year is genuinely a year ending 31 December (Ireland), India (03-31) or Australia (06-30) etc.

It belongs to the **country**, so every file for one country must declare the same value; a test fails if two disagree.

**`form_code:`** is the authority's own reference for the form these figures feed — `SA103`, `SA105`, `AnlageV`. It names the [archived submission document](tier-3-extending-filing.md#submission-storage-layout), so a stored file says what it belongs to in the authority's language rather than in ours. Optional; a scheme without one is archived under its slug.

**Four names.** It looks like duplication and is not:

| field | example | where it is used |
|---|---|---|
| `scheme_label` | `"UK Property (SA105)"` | the authority's name for its form/scheme |
| `report_name` | `"GB-property"` | what we call the report group for this scheme |
| `submission_name` | `"MTD property"` | the authority's programme name (MTD, VAT) plus what we send |
| `form_code` | `SA105` | authority's own reference for the form; names the [archived submission document](tier-3-extending-filing.md#submission-storage-layout) |


`scheme_label` used to be a locale key, `acc.tax.scheme.<slug>`, in four language files. It carried the *same five strings four times* — the German entry read "Vermietung und Verpachtung (Anlage V)" and so did the English, the Dutch and the Spanish. Anyone filling in an Anlage V is looking at a form that says Anlage V. Moving it here means a contributor names their scheme in their own file, in their own language, instead of needing four locale files edited by someone else.

### Each category row

```yaml
  - key: umgelegte_kosten          # snake_case, in the scheme's OWN language
    label: "Umgelegte Kosten"      # the box's wording ON THE FORM
    export_column: "52"            # the authority's own identifier for the box
    api_field: premisesRunningCosts # only if the scheme submits digitally
    section: expenses              # income | expenses | other — nothing else
    api_section: income            # OMIT unless the payload files it elsewhere — see below
    position: 150
    keywords: [grundsteuer, müllabfuhr, hausgeld]   # optional, helps with the suggestions
    notes: "Z. B. Grundsteuer, Müllabfuhr … — Zeilen 73 bis 75"
```

Each field has exactly one job:

| field | is | example |
|---|---|---|
| `label` | the box's wording on the form, in the form's language, **never translated** | `"Umgelegte Kosten"` |
| `export_column` | the authority's identifier for the box | `"52"`, `"15"`, `"959b:2.1"` |
| `api_field` | the field name a digital submission uses. **Required on every row of a scheme that declares a connector** — the payload builder skips a row without one, so the figure would vanish between the report and the authority and the submission would still be accepted. A test enforces it | `premisesRunningCosts` |
| `section` | what the figure **is** — see below | `income` |
| `api_section` | where the payload files it, only when that differs from `section` — see below | `income` |
| `keywords` | words that mean this box, for auto-suggestion — see [Auto-assignment](#auto-assignment--suggestions-from-keywords) | `[grundsteuer, hausgeld]` |
| `notes` | the long wording, the line number, the caveats | shown under the select in the UI |

#### `section` — the one field that is *not* in the form's language

`section` is **exactly one of `income`, `expenses`, `other`**. The loader refuses anything else, by name, and tells you where the form's own word belongs instead.

It answers our structural question about the row — does this figure add to income, subtract as expenditure, or neither — and that question has the same three answers everywhere, because it is double-entry rather than tax law. `other` is not a dustbin: it is for a figure that appears on the form and drives neither total. Tax deducted at source is the live case — money a payer already handed to the authority on your behalf, which must be reported and would falsify the return counted as either of the others.

So this is the single field in a tax category file written in the app's vocabulary rather than the authority's. Everything else — `label`, `key`, `export_column`, `keywords` — is in the form's own language, and stays that way.

`api_section` takes the same three values, and exists for one situation: where a submission files a figure somewhere other than what it *is*. HMRC files tax deducted at source inside the income object although it is not income. Blank means "same as `section`", which is almost always right.

Labels are never translated, deliberately. A box has one name — the one printed on its own form. Keys are native too (`mieteinnahmen`, `nettoerloese`), so a catalogue contributed without labels still reads in its own language.

**Accounts vs tax categories.** Where the form puts several kinds of cost in one box, that is one category with several accounts pointing at it — Grundsteuer, Hausversicherung and Hausgeld are all Kennzahl 52. Where the *API* is finer than the paper, follow the API, because that is what actually gets filed: SA103F box 24 is one box, but HMRC wants advertising and business entertainment as separate fields, so you have to add two categories (two rows in the yml files, and 2 accounts in your books) sharing a box number.

### Provenance, and watching for changes

A catalogue is a **transcription of a real document**, so it records which one:

```yaml
source:
  form_year: 2026        # the edition transcribed — NOT tax_year, see below
  url:       "https://assets.publishing.service.gov.uk/media/…/SA105_2026_v0.1.pdf"
  sha256:    "83daac11…"
  index_url: "https://www.gov.uk/government/publications/self-assessment-uk-property-sa105"
  local:     "docs/SA105_2026.pdf"
```

TaxFormWatchJob checks monthly. Silent unless the form actually changed. No news, no new file — keep using the one you have, the app is happy to use a 2026 file until 2050 if nothing changes. Three findings will send you an email:

| finding | means |
|---|---|
| **changed** | the file at `url` no longer matches `sha256` — the authority reissued it |
| **newer_year** | `index_url` lists an edition later than `form_year` |
| **gone** | `url` returns 404 or 410 — the address moved, or the form was withdrawn |

A timeout or DNS failure is **not** reported. That is the network, not the form.

**Why `form_year` and not `tax_year`.** They differ, and the difference is the point. The German catalogues say `tax_year: 2026` but were built from the **2025** Vordruck, because that is the newest that exists — the BMF publishes each year's in the August or September of that year. Comparing against `tax_year` would mean the 2026 Vordruck appearing was *not* "greater than 2026", so the one event worth catching would never fire.

**Why a bounded look-ahead.** The check asks whether the page mentions any of `form_year + 1 … + 5`, in the forms authorities actually use (`2027`, and HMRC's `2026 to 2027`). Taking "the highest four-digit number on the page" would latch onto a reference number and report the year 4015.

**Every key is optional**, and gaps are declared rather than faked:

- **Switzerland has no `source` at all** — its categories come from OR Art. 959b, which is statute. There is no form to watch.
- **The Netherlands has no `source` at all either** — the return is filed online from an XBRL taxonomy, not a document at a URL. See [The form is a schema](#finding-the-original-scheme).
- **Anlage V has no `url`** — the BMF's canonical address for it is not known, so `check_file` never runs; only a checksum of the local copy is recorded, unused until a URL is added. Supply one and the watch starts working with no other change.
- **Neither German catalogue has an `index_url`** — the BMF publishes at a fresh dated URL each year and `formulare-bfinv.de` is a JavaScript app that cannot be read. So of the six schemes, only the two British ones get both checks; EÜR gets the file check alone; Vermietung, Selbst and Winst get neither.

### Loading

```bash
bin/rails tax_categories:load
```

Idempotent, and re-run whenever you change a YAML. **The file is the catalogue, not an addition to it**: a key you remove from the file is deleted from the database — but only within its own `country_code`/`scheme`/`tax_year`. Rename the scheme itself and the loader prunes the new name, not the old one; the old rows aren't "removed," they're simply never looked at again, and stay in the database until someone deletes them by hand.

Loaded in exactly three places, **none of them a user's request**:

| | when |
|---|---|
| `db/seeds.rb` | a fresh install, and `db:reset` |
| `.kamal/hooks/pre-deploy` | every deploy, right after `db:migrate` |
| the rake task above | by hand, after editing a file |

**What happens to accounts tagged with a key you removed.** They keep the key and therefore do **not** appear in the "needs tagging" list (`Account.unmapped_for_tax` looks for a blank key). `Reports::TaxCsv` and the HMRC payload builder both skip a category they cannot resolve — `next if cat.nil?` — so the figure leaves the return without an error. The account's own edit form shows the key labelled `(retired)`, but only if you happen to open that account.

So removing a key is announced instead: `TaxCategoryRemovalNotificationJob` emails every bookkeeper with full access to an affected entity, listing **their** accounts and asking them to re-tag. If nothing was using the removed keys, nobody hears anything.

When you run the task **by hand**, read what it prints: a `removed N stale category row(s)` line means keys disappeared from a file. That is the only place a category row is ever deleted.

⚠️ **On a deploy, read the output too** — `kamal deploy --verbose`. Kamal hides hook output otherwise, and a deploy that deletes categories looks exactly like one that does not. The hook runs `db:migrate` first and the loader second, under `set -e`, so a failing migration stops the deploy instead of being masked by a load that succeeds.

## Years, forward-only and correctable in place

There are two reasons a catalogue changes, and they are handled differently. Getting this wrong is the one catalogue mistake that cannot be undone, so it is worth the paragraph:

**We transcribed it wrong** — a typo, a box that does not exist, three keys where the form has one. Then **correct the file in place**. The key was never valid, and inventing a new year file would record a rule change that never happened.

**The authority changed the form** — then **write a new year file** and leave the old one alone. `gb_self_employment_2029.yml`, not an edit to `2026`. The old rows survive, so a period you have already filed still resolves against the rules that applied to it. Editing the old file instead would delete those rows, and the record of what the rules used to be goes with them.

The year in the filename is the year the tax year **ends** in, following the authority's own convention: `2029` is 6 April 2028 to 5 April 2029 for a British scheme, and the calendar year 2029 for a German one.

Reports and submissions resolve against **the catalogue as it stood for the period being reported** — `TaxCategory.for_period`, which takes the year from the period's end date via `tax_year_for`. A 2026 export uses 2026's boxes even once 2027 exists. `resolve` walks back to the newest catalogue at or before the year asked for, so you can skip every year in which nothing moved.

Past exports must not crash, but are not guaranteed to match later schemas. That is fine, and it is why in-place correction is safe.

## Account-form dropdown

Mass assignment happens on the [tax report group page](#where-accounts-get-tagged). You can reassign an individual account on its edit form. The select

- appears only on **leaf** income / expense accounts of an entity subscribed to a scheme,
- shows the entity's schemes for the **latest** catalogue year, grouped by section, each option reading `52 — Umgelegte Kosten`,
- carries each category's `notes` as a `data-note` attribute, which `tax.js` shows as a hint line under the select,
- if the account is tagged with a key that has since gone, that retired key appears at the top labelled as such, so it is visible rather than silently blank.

Built by `TaxCategory.grouped_options`, the same method the report group page uses to offer the same choices in bulk. One method on purpose, so the two never drift apart.

## Auto-assignment — suggestions from keywords

The app can pre-fill tax categories by reading an account's **name** and matching it against the `keywords:` on each category. **This needs no Ruby**: a new country's suggestions come from its own tax category file, like everything else about it.

```yaml
  - key: kfz_versicherung
    label: "Kfz-Versicherung"
    keywords: [kfz versicherung, autoversicherung, fahrzeugversicherung]
```

One class does it for every country — `TaxCategoryGuesser`. It scores each category as `[how many keywords hit, how many characters they covered]`, so the **more specific box wins**: "Kfz-Versicherung" matches both `versicherung` and `kfz versicherung`, and the longer phrase is the one that means it.

Three rules worth knowing before you write keywords:

- **A tie is no answer.** Two categories fitting equally well is exactly when a confident wrong guess is expensive, so nothing is suggested.
- **Keywords under four characters must match a whole word.** `rate` as a substring finds "corporate"; `miete` as a substring finds "Büromiete", which is the point in a language that builds compounds.
- **Write them in the FORM's language, never the user's.** A German Vermietung box is not "service charges" in any language. An account named in one language will not match a catalogue written in another, and that is an accepted limit rather than a gap — what you call your own accounts is your business.

Suggestions are only ever *proposals*, confirmed on the form. Categories with no keywords simply never suggest anything, which is a perfectly good place to start.

## Adding a country — a worked example

Say you want Poland. There is no constant to register, no country list to extend, no locale key to add, and no view or controller to touch. `TaxSchemeConfig` reads every header in `db/tax_categories/` and derives the countries, schemes, authorities, currencies and connectors from them; nothing about a country is hardcoded anywhere in the app.

| What | Where | Ruby? |
|---|---|---|
| The country's boxes | `db/tax_categories/pl_pit36_2026.yml` | no |
| Which rate its authority accepts | `db/exchange_rate_rules.yml` | no |
| The feed that publishes that rate | `db/exchange_rate_sources.yml` | no |
| How to read that feed | `app/services/rates/<name>_parser.rb` | **yes**, ~60 lines |
| The currency itself | the currencies screen, in the app | no |

That Ruby row is the real limit. Every feed's XML or CSV is shaped differently, and YAML can't describe an arbitrary shape — the five feeds here each needed their own small parser. You only skip writing one if a feed you already have happens to publish exactly what the new authority accepts, which is worth checking, but rarely true.

**1. Get the real form** — see [Finding the original scheme](#finding-the-original-scheme) above, which is the longest part of the job and the part that decides everything else. For Poland that is PIT-36 with załącznik PIT-B, from podatki.gov.pl. Put it in `docs/tax-forms/` so the next person can check your work.

**2. Write `db/tax_categories/pl_pit36_2026.yml`:**

```yaml
country_code: pl
scheme: pit36                 # a plain word, distinct within Poland's own files — becomes the slug pl_pit36 automatically
tax_year: 2026
authority: "Krajowa Administracja Skarbowa"
position: 10
report_name: "PL-PIT-36"
currency: PLN

 # No connector: the app tags accounts and exports a CSV for the accountant.
 # Direct submission to e-Deklaracje would be a separate build — see below.
categories:
  - key: przychody
    label: "Przychody"           # exactly as the form says it
    export_column: "…"           # the form's own box or line number
    section: income
    position: 10
    notes: "…"
```

**3. Make sure the currency exists** — add it on the currencies screen; any full-access admin can. See [Adding a currency](tier-1-extending-languages-currencies.md#adding-a-currency). A test refuses a scheme that files in a currency the installation does not have.

**4. Say which exchange rate the country's tax authority accepts**, in `db/exchange_rate_rules.yml`:

```yaml
pl:
  accepts:      [nbp, ecb]      # ordered: preferred first, fallback after
  date_basis:   preceding_publication
  election:     none
  unpublished_currency: manual_with_evidence
```

**This step is not optional and a test enforces it.** Without an entry, `accepted_sources` returns nothing, and a figure you *submit* falls back silently to the rule for a report you merely *look at* — converted at a rate the authority never named, with no error anywhere. See [Authority rules](tier-2-add-rate-source.md#authority-rules).

If no source you already have publishes what that authority accepts, you also need a rate source — see [Adding a rate source](tier-2-add-rate-source.md#adding-a-rate-source). **This is the one part of adding a country that is Ruby**, and it is usually needed: most authorities require their own national central bank's rate, not the ECB's.

**5. Load it:**

```bash
bin/rails tax_categories:load
```

Poland now appears in the entity's tax-scheme picker. Tag accounts, and the tax report, the accountant's CSV and the emailed export all work.

**6. Optionally, `keywords:` on your category rows**, so accounts get suggestions. No code — see [Auto-assignment](#auto-assignment--suggestions-from-keywords). Write them in Polish, because that is the language the form and the accounts are in.

### What will fail, and what to do about it

Three guards stand between a new country and the rest of the app, and **all three are meant to fail** the first time.

**1. The rules guard.** Load a catalogue for a country with no entry in `db/exchange_rate_rules.yml` and `rate_rule_config_test` fails with:

> `pl has tax category files but no entry in db/exchange_rate_rules.yml. Without one, a SUBMISSION silently falls back to tier 1's base-matching.`

Write the rules entry. This is the guard doing the single most useful thing in the set — the failure it prevents is a filed figure converted at a rate the authority never named, and no error anywhere.

**2. The catalogue snapshot.** `db/tax_catalogue_snapshot.yml` records the section, api_section, export_column and api_field of every key, and `TaxCatalogueSnapshotTest` fails on anything it has not seen:

> `New catalogue files are not in the snapshot: nl_winst_2025.yml.`

```bash
bin/rails tax_categories:snapshot
```

Commit the snapshot **in the same commit as the catalogue**, so the diff shows what moved and why. The snapshot exists so that a later change to an existing key cannot pass unnoticed: if one moves, the suite asks whether the authority changed the form (write a new year file) or whether the original transcription was wrong (correct it in place and re-snapshot).

**3. Two tests that pin the known countries and schemes as a literal list.** `TaxSchemeConfig.countries` and `.all_schemes` themselves derive from the catalogue headers, same as everywhere else — but `test/services/tax_scheme_config_test.rb` asserts their result against a hardcoded `%w[...]` array right in the test, once for each:

```ruby
assert_equal %w[ch de gb nl], TaxSchemeConfig.countries
assert_equal %w[ch_selbst de_euer de_vermietung gb_self_employment gb_property nl_winst],
             TaxSchemeConfig.all_schemes
```

Add your country and scheme to both arrays. The point is that a country landing in the app by accident — a stray file, a typo — fails a test instead of quietly working.

Nothing else breaks. No view, no controller, no helper, no locale file, no migration.

You will also be held to these — they pass on their own if the header is right:

- a scheme slug must be unique across all countries
- `currency:` must be one the installation has
- `scheme_label:` must be present, and not merely the humanised slug
- `tax_year_ends:` is optional — omit it for a calendar year — but if declared, it must be a real `MM-DD`, and every file for one country must agree on it
- every category's `section` must be `income`, `expenses` or `other`

### What you do NOT need

An accountant format. Every entity already gets the transactions listing and the tax-category CSV; a country-specific format is a separate, optional thing, and most countries have no standard to implement. See [Adding an accountant format](#adding-an-accountant-format).

Digital submission. Poland's e-Deklaracje, Norway's Altinn and Germany's ELSTER are each their own build — an OAuth or certificate flow, a payload format, an obligations model. Omitting `connector` gets you everything except the submit button, and that is the normal case: **the app's job is bookkeeping in a genuinely international way, and handing an accountant a file they recognise.** Direct filing is a bonus for the countries that have it.

If you do want it, see [Adding digital submission for a new country](tier-3-extending-filing.md#adding-digital-submission-for-a-new-country). 

## Tax category depth and inheritance

Accounts have at most one level of parent — the `parent_cannot_be_grandparent` validation prevents deeper nesting. Tagging does not walk that tree at all: only leaves carry a category, so `effective_tax_category_key` is the account's own key or nothing.

## Email tax export

A tax report's CSV button renders differently from a custom report's: rows group by `tax_category_key`, section totals, and a NET row, instead of the plain account list.

Column layout:

```
Section | Category key | Label | Reference | Amount (display currency)
```

`Label` is the box's wording on the form and `Reference` is the authority's identifier for it — Kennzahl `52` against Anlage V, box `15` against SA103F, `959b:2.1` against the Obligationenrecht. An accountant reads the pair and finds the line. Implemented in `Reports::TaxCsv`.

Email tax export sends two files always, and optionally a third.

**Always:**

1. **Transactions listing** — one row per posting, with a signed link to each receipt (30 days, no login needed).
2. **Tax-category CSV** — the table above. Short report only.
3. **Backup**: When the email is sent, a dated copy is stored as a backup. It can be downloaded from the report's row on the reports/index page (`TaxExportStorage`). A new copy is made only when the CSV's content actually changes.

**Optionally, add a format your accountant asked for by name.** That is what `acc_entities.accountant_export` is: not "which export", but "which *extra* file". Blank is the common case, and it means the two standard files are enough — the dropdown says **Standard CSV**, if you **add DATEV**, a DATEV output travels alongside the standard files.

## Adding an accountant format

**Add one file:** `app/services/accountant_exports/<slug>.rb`, subclassing `Base`:

```ruby
module AccountantExports
  class YourFormat < Base
    def self.label    = "…"   # shown in the dropdown, never translated — it's a product name
    def self.filename = "…"   # fixed — no entity, no dates, ever: Datev.filename is "EXTF_Buchungsstapel.csv"

    def generate
      # the real work: postings/entity/start_date/end_date are available here,
      # built into a file — usually a CSV, the way Datev#generate does it
    end
  end
end
```

**Edit one file:** `app/services/accountant_exports/base.rb` — add the slug to `FORMATS`.

Nothing else. The entity setting, the dropdown on the tax setup page and `TaxExportJob` all read the registry off those two files.

`FORMATS` is an explicit array rather than `Base.subclasses`, because Rails autoloads: a class nobody has referenced yet does not exist yet, so `subclasses` returns whatever happens to be loaded at that moment.

**Why DATEV is the only one.** It is the German and Austrian standard, and it is also the closest thing accountancy has to a lingua franca elsewhere — Swiss packages such as bexio and Banana import it. Switzerland has **no national exchange format**: what is standardised there is the chart of accounts (Kontenrahmen KMU/Käfer), the VAT rates and Swiss-QR, not a file. So there is nothing to implement for CH, and inventing a plausible-looking "Swiss format" would be worse than offering none.

## Where accounts get tagged

On the scheme's own tax report group page: accounts already tagged on one side, untagged income and expense accounts on the other, with a suggested category where a reasonable guess can be made. Choose a category (only accounts you want in the scheme), click **+** in the left corner. This confirms your choice and moves the account across. `Account.unmapped_for_tax` is still the query — single SQL, no in-Ruby filtering — but it now only decides which of two notices you get after saving your scheme list.

## Filename convention

`db/tax_categories/<country>_<scheme>_<year>.yml`, e.g. `de_vermietung_2026.yml`. Every loading path (`db/seeds.rb`, the pre-deploy hook, `tax_categories:load`) discovers files by glob and upserts each by its YAML header (`country_code` / `scheme` / `tax_year`) — the header, not the filename, is authoritative, so a scheme slug that doesn't line up with the filename (e.g. `gb_property`) doesn't cause a silent skip.

---
