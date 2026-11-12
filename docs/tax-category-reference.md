# Tax category reference

Every tax catalogue the app ships, and every field a catalogue file can hold.
A lookup sheet: the how-to is [tier 2](tier-2-extending-countries.md), and
what the app does with VAT is in the [VAT reference](vat-reference.md).

Checked against the code on 12 November 2026.

<!-- toc -->

**Contents**

- [Two kinds of catalogue](#two-kinds-of-catalogue)
- [The shipped catalogues](#the-shipped-catalogues)
- [Header fields](#header-fields)
- [Category fields](#category-fields)
- [Code fields (VAT only)](#code-fields-vat-only)
- [Loading](#loading)
- [The guards](#the-guards)

<!-- tocstop -->

## Two kinds of catalogue

| | Income tax (and similar) | VAT (`kind: vat`) |
|---|---|---|
| A category is | a line of the form an **account** is tagged with | a box of the return |
| Filled from | the tagged accounts' balances | the **codes** on postings |
| Tagged where | the scheme's report group page, or the account form (leaf income/expense accounts only) | never: VAT boxes are kept out of the tagging dropdown |
| Suggestions | from `keywords`, by `TaxCategoryGuesser` | none |
| Output | tax report, CSV, emailed export; HMRC submission where a connector exists | the return on screen and as CSV |

## The shipped catalogues

| File | Country | Authority | Form | Currency | Tax year or period | Categories | Kind | Connector | Form watched |
|---|---|---|---|---|---|---|---|---|---|
| `gb_self_employment_2026.yml` | GB | HMRC | SA103 | GBP | to 5 April | 18 (2 income, 15 expenses, 1 other) | income tax | `hmrc_mtd` | file and index |
| `gb_property_2026.yml` | GB | HMRC | SA105 | GBP | to 5 April | 13 (4 / 8 / 1) | income tax | `hmrc_mtd` | file and index |
| `gb_vat_2026.yml` | GB | HMRC | VAT100 | GBP | set on the report | 10 boxes, 19 code rows | VAT | — | — |
| `de_euer_2026.yml` | DE | ELSTER | Anlage EÜR | EUR | calendar | 46 (8 / 38) | income tax | — | file only |
| `de_vermietung_2026.yml` | DE | ELSTER | Anlage V | EUR | calendar | 17 (8 / 9) | income tax | — | no (checksum, no URL) |
| `de_vat_2026.yml` | DE | ELSTER | UStVA | EUR | set on the report | 27, 32 code rows | VAT | — | — |
| `nl_winst_2025.yml` | NL | Belastingdienst | Winst uit onderneming (XBRL) | EUR | calendar | 38 (12 / 26) | income tax | — | no (no document) |
| `nl_vat_2026.yml` | NL | Belastingdienst | Omzetbelasting | EUR | set on the report | 21, 17 code rows | VAT | — | — |
| `ch_selbst_2026.yml` | CH | ESTV | OR Art. 959b (statute, no form) | CHF | calendar | 13 (5 / 8) | income tax | — | no (statute) |
| `ch_vat_2026.yml` | CH | ESTV | MWST | CHF | set on the report | 29, 19 code rows | VAT | — | — |
| `es_vat_2026.yml` | ES | AEAT | Modelo 303 | EUR | set on the report | 33, 18 code rows | VAT | — | — |

Spain has a VAT catalogue only; there is no Spanish income-tax catalogue yet.
The original forms are in `docs/tax-forms/` (the Dutch ones as readable
extracts).

## Header fields

`TaxSchemeConfig` reads these from every file. The slug is always
`<country_code>_<scheme>` (e.g. `de_vat`), and everything else hangs off it.

| Field | Required | For | Meaning |
|---|---|---|---|
| `country_code` | yes | all | two letters, lowercased |
| `scheme` | yes | all | a word, unique within the country |
| `tax_year` | yes | all | the year the catalogue's tax year **ends** in |
| `country_label` | yes (test) | all | the country's own name; every file of a country must agree |
| `authority` | yes | all | who you file with |
| `scheme_label` | yes (test) | all | the authority's name for the form, never translated |
| `report_name` | yes | all | the report group's visible name |
| `currency` | yes (test) | all | must exist in the installation |
| `position` | no | all | order within the country |
| `tax_year_ends` | no | all | `MM-DD`, only if not 31 December; every file of a country must agree |
| `form_code` | no | all | the authority's reference; names archived submissions |
| `source` | no | all | `form_year`, `url`, `sha256`, `index_url`, `local`; drives the monthly form watch |
| `connector` | no | income tax | filing integration, e.g. `hmrc_mtd`; requires `api_field` on every row |
| `submission_name` | with `connector` | income tax | the programme's name, e.g. "MTD property" |
| `kind` | VAT | VAT | `vat`: boxes come from codes, not tagging |
| `no_tax_label` | no | VAT | the form's word for "no VAT" ("Keine USt") |
| `vat_accounts` | no | VAT | `nominal` puts the control accounts on the P&L; unused so far |
| `flat_rate_label` | no | VAT | **its presence means the scheme has a flat rate** |
| `normal_rules_label` | no | VAT | the authority's name for the ordinary basis |
| `flat_rate_net_category`, `flat_rate_tax_category` | no | VAT | the boxes the flat rate files to (CH); otherwise the first ordinary sale code's |
| `prepayment_category` | no | VAT | the box a prepayment is deducted in (DE Kz 39); its presence puts the field on the report form |

All labels are in the authority's language and never go into locale files.

## Category fields

Allowed keys (`TaxCategoryLoader::ALLOWED_ROW_KEYS`); anything else is refused.

| Field | Meaning |
|---|---|
| `key` | required; snake_case, in the form's language, unique in the file |
| `label` | the box's wording on the form |
| `export_column` | the authority's box number; **blank makes it a feeder** (carries a figure, not shown) |
| `section` | `income`, `expenses` or `other`; income tax only, blank for VAT |
| `api_section` | only if a submission files the figure elsewhere than `section` |
| `api_field` | the submission's field name; required on every row under a connector |
| `includes` | boxes this one totals; checked to exist in the file; any depth |
| `subtracts` | boxes this one deducts (DE Kz 83, NL 5c, ES 46) |
| `keywords` | words in the form's language for suggesting a tag |
| `notes` | long wording, shown under the select |
| `position` | display order |

## Code fields (VAT only)

Allowed keys (`TaxCategoryLoader::ALLOWED_CODE_KEYS`). A code row is identified
by **`key` + `valid_from`**.

| Field | Meaning |
|---|---|
| `key` | required; the same key for each rate period |
| `rate_bps` | required; basis points, 2000 = 20 % |
| `direction` | required; `input` (we paid it) or `output` (we charged it) |
| `valid_from` | required; quoted date |
| `valid_to` | optional; how a code ends (a law change) |
| `label` | the form's own wording |
| `net_category_key` | box for the net |
| `tax_category_key` | box for the VAT on the code's own side |
| `reverse_tax_category_key` | box for the other side of a reverse charge |
| `reverse_charge` | `true`: nothing posted, the return computes both sides |
| `flat_rate` | blank (inside the scheme), `normal`, `declare_only` or `excluded` |
| `datev_bu` | the DATEV tax key, for the German accountant export |
| `position` | order in the dropdown |

Rate 0, a `tax_category_key` and no `net_category_key` make a code whose
amount **is** the VAT (import VAT paid at the border).

## Loading

`bin/rails tax_categories:load` loads every file, one transaction per file. It
runs from `db/seeds.rb`, the pre-deploy hook (after `db:migrate`, under
`set -e`), and by hand.

- **The file is the catalogue.** A category key missing from the file is
  deleted for that country, scheme and year; accounts tagged with it are
  emailed about (`TaxCategoryRemovalNotificationJob`).
- **A code row missing from the file** (also a changed `valid_from`): its
  entries move to the row of the same key covering their date, if it books
  them the same way. What can't move stays on the old row, kept as retired:
  the bookkeepers are emailed once (`TaxCodeRetirementNotificationJob`), the
  Monday report lists it, and a later load deletes it once nothing uses it.
  See [VAT reference](vat-reference.md#traps-when-changing-a-vat-catalogue).
- **Categories are versioned by year file, codes by date.** A form the
  authority changed gets a new year file; a transcription mistake is corrected
  in place. Codes may appear in one file per scheme only.
- **Reports use the catalogue of the period**: the newest year file at or
  before the period's tax year.

## The guards

| Test | Fails when |
|---|---|
| `tax_catalogue_snapshot_test.rb` | a key's section, api_section, export_column or api_field changed, or a file is new; re-snapshot with `bin/rails tax_categories:snapshot` |
| `tax_scheme_config_test.rb` | the countries or schemes differ from the literal lists in the test |
| `rate_rule_config_test.rb` | a country has catalogues but no entry in `db/exchange_rate_rules.yml` |
| `tax_category_loader_test.rb`, `tax_category_loader_codes_test.rb` | a file breaks the loader's rules |
| `report_flat_rate_test.rb`, `report_modal_flat_rate_test.rb` | a flat rate or prepayment is offered or accepted where the header doesn't name one |
