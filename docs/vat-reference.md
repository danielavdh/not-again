# VAT reference

What the app does with VAT, per country, and which special cases it handles.
A lookup sheet, not a guide: to add or correct a VAT scheme, follow
[tier 2](tier-2-extending-countries.md#a-vat-scheme-the-tax_codes-section) and
use this file to check your work. For the catalogue fields, see the
[tax category reference](tax-category-reference.md).

Checked against the code on 12 November 2026.

<!-- toc -->

**Contents**

- [The five schemes](#the-five-schemes)
- [What every scheme shares](#what-every-scheme-shares)
- [How each return is shaped](#how-each-return-is-shaped)
- [Special cases](#special-cases)
- [Not covered](#not-covered)
- [Codes per country](#codes-per-country)
- [Where it lives in the code](#where-it-lives-in-the-code)
- [Traps when changing a VAT catalogue](#traps-when-changing-a-vat-catalogue)

<!-- tocstop -->

## The five schemes

| | GB | DE | NL | ES | CH |
|---|---|---|---|---|---|
| File | `gb_vat_2026.yml` | `de_vat_2026.yml` | `nl_vat_2026.yml` | `es_vat_2026.yml` | `ch_vat_2026.yml` |
| Authority | HMRC | ELSTER | Belastingdienst | AEAT | ESTV |
| Form | VAT100, 9 boxes | UStVA | Omzetbelasting | Modelo 303 | MWST-Abrechnung |
| Currency | GBP | EUR | EUR | EUR | CHF |
| Exchange rate for the return | HMRC monthly | Bundesbank (BMF monthly average), ECB as fallback | ECB daily | ECB daily | ESTV monthly, otherwise typed in with evidence |
| Flat rate | Flat Rate Scheme | — | — | — (módulos are not a percentage) | Saldosteuersatz |
| Prepayment on the return | — | Sondervorauszahlung, Kz 39 | — | — | — |
| Filing from the app | no | no | no | no | no |

No VAT return is filed from the app. The return is a screen and a CSV, and the
figures are typed into the authority's own site. The only connector,
`hmrc_mtd`, files income tax (see [tier 3](tier-3-hmrc.md)).

## What every scheme shares

- **Entering.** The user picks a code on an income or expense row and types the
  **gross**. `JournalEntry#derive_tax_legs` splits off the VAT into the
  scheme's control account, on the same side as the net. The bank line stays at
  the gross, so it matches the statement. The user may overwrite the VAT figure;
  more than the gross is refused.
- **Two control accounts per scheme and business:** *VAT on purchases (input)*,
  an asset, and *VAT on sales (output)*, a liability. Both are in the scheme's
  currency. They are created when the scheme is ticked, retired when it is
  unticked, and revived when it is ticked again. The `vat_role` column is what
  identifies them, never the name or code.
- **Rules at save** (`JournalEntry#tax_codes_are_usable`):
  - a sale code only on income, a purchase code only on expense
  - only a scheme the business files (a row that already had the code keeps it)
  - the code must be valid on the entry date
  - the entry must be in the scheme's currency, except a reverse charge, which
    posts nothing
- **One balance account per entry with income or expense rows.** The VAT lines
  don't count towards that limit (`single_balance_account_with_nominals`).
- **The return** (`Reports::VatReturn`):
  - groups by **code**, not by account
  - covers posted entries dated in the period; the entry date is the tax point
    (book against Debtors/Creditors for invoice basis, direct for cash basis)
  - shows every box, zeros included
  - adds up totals as the catalogue declares (`includes` / `subtracts`)
  - shows a by-account table, for checking
  - shows **unassigned** VAT: amounts in the control accounts on entries with
    income or expense rows that no code explains. Entries with only balance
    accounts (paying the VAT, transfers) are not counted.
- **Currency.** The VAT lines are already in the scheme's currency. The net
  amounts are translated when the report runs, per date, at the authority's
  rate (`db/exchange_rate_rules.yml`). Nothing is converted at save.
- **Paying.** Payments and refunds are ordinary transfers between the bank and
  *VAT on sales*, any amount, linked to no return. The transfer form offers
  *VAT on sales* as "VAT payment" and "VAT refund", and not *VAT on purchases*.
- **Final.** "Mark as final" on a return (`Reports::VatReturnFinal`) stores its
  CSV under `vat_returns/<report_id>/` in the tier-2 bucket (`VatReturnStorage`,
  figures' fingerprint in the filename), sets `reports.finalized_at`, and books a
  clearing entry (`journal_entries.vat_report_id`) on the period's last day:
  the posted input VAT moves onto *VAT on sales*; on a flat-rate return the
  difference to the flat amount goes to the flat-rate income account
  (`vat_role: flat_rate`, created with the first report that has a %). Coded
  entries of a final period are locked (`JournalEntry#final_vat_report`).
  Reopening asks whether the return was submitted, removes the clearing entry
  and keeps the file.

## How each return is shaped

The same code mechanism fills forms of very different shapes. These are the
differences a code must respect:

| | Output VAT | Purchase net | Notes |
|---|---|---|---|
| GB | all of it in box 1 | box 7 | Box 6 includes 8, box 7 includes 9, box 3 = 1 + 2. Boxes 2, 8, 9 are Northern Ireland only. |
| DE | **no box**: only the net (Kz 81, 86); the tax goes to a feeder for Kz 83 | none | Kz 83 = feeders − Vorsteuer. Mixing a net and a tax Kennzahl is the most common mistake on the form. |
| NL | paired with its net in the same rubriek (1a, 1b, 1c) | none (only 5b, the VAT) | So a rubriek is two categories with one `export_column`. |
| ES | paired per rate (07/09 for 21 %) | per kind: domestic, capital goods, import, intra-EU | A reverse charge puts its base in two casillas through a feeder. |
| CH | per rate: Leistungen and Steuer under one Ziffer | none | Ziffer 200 is **worldwide** turnover; 220–280 deduct the non-taxable part. |

A **feeder** is a category with no `export_column`. It carries a figure to a
total but is not a box itself, so the return doesn't show it.

## Special cases

| Case | Where | How it works |
|---|---|---|
| **Reverse charge** | GB services, construction, postponed import, NI acquisitions; DE §13b, EU acquisitions; NL domestic, EU, non-EU; ES ISP, AIB; CH Bezugsteuer | `reverse_charge: true`. **Nothing is posted.** The return computes rate × translated net and counts it as owed (`reverse_tax_category_key`) and reclaimed (`tax_category_key`). Because nothing is posted, it can be paid from an account in any currency. |
| **The amount is the VAT** | GB C79, DE EUSt, NL import VAT at customs, ES importación, CH Einfuhrsteuer | Rate 0, a tax box, no net box (`TaxCode#amount_is_tax?`). The whole amount goes to *VAT on purchases*. |
| **Flat rate** | GB, CH (only schemes whose catalogue has `flat_rate_label`) | A percentage on the **report**, not on the business. Turnover including VAT × rate goes to the scheme's boxes (CH: Ziffer 323; GB: boxes 6 and 1). Purchases reclaim nothing. A code's `flat_rate` says what happens to it: none means inside the scheme, `normal` means boxes as usual, `declare_only` means output half only, `excluded` means nothing. The return also shows the normal-rules figures for comparison, and doesn't report the control-account gap as unassigned. The bookings don't change: the VAT lines are still the real VAT. |
| **Prepayment** | DE (`prepayment_category: sondervorauszahlung`) | A figure typed on the **report**, not a booking. Added to Kz 39 and subtracted from the amount to pay. The payment itself is booked by the user. |
| **Rate changes** | DE 16 %/5 % in Jul–Dec 2020; CH 7.7 → 8.1 % in 2024 | A second row with the same `key` and a later `valid_from`; the old row gets a `valid_to`. Entries resolve the code by their date. CH files old rates in their own Ziffern (`_alt`). |
| **0 % vs exempt vs outside the scope** | all | Different codes, different boxes, or no box at all (GB `sale_outside_scope`, NL `verkoop_vrijgesteld`, ES `venta_exenta`). A code with no box records a decision and reaches nothing. |
| **Credit notes, refunds** | all | A minus sign flips the row's side, and the VAT flips with it. |
| **Partial deduction** | all | The split button divides the **gross** between the expense account (keeps the code) and a private account (no code; the server refuses one). VAT is derived from the business part only. |
| **Two schemes in one business** | e.g. a UK business also registered in Germany | Each scheme has its own control accounts and return. The code list shows a flag per scheme. |
| **Gift between businesses** | all | The receiving entry can't carry a code. The donor may still reclaim on their own row. |
| **VAT as income/expense** (`vat_accounts: nominal`) | none yet | Built for a German EÜR filer, whose VAT is Betriebseinnahme/-ausgabe. Not used: it is a property of the taxpayer, and a catalogue describes the form. |

## Not covered

Stated in the catalogue headers:

- **DE:** Land- und Forstwirtschaft, §13b sub-cases Kz 73/74, the
  Berichtigungs-Kennzahlen 64/65/69.
- **ES:** recargo de equivalencia, régimen simplificado, criterio de caja,
  rectificación and regularización, cuotas a compensar, OSS, carburantes.
- **CH:** 205, 225, 410, 415/420, 900/910 (235 and 280 are shown but fed by no
  code).
- **NL:** private use (1d) has a box but no code.

Not stated anywhere yet:

- **GB:** Annual Accounting Scheme interim payments; the 1 % first-year
  flat-rate discount (type the reduced rate on the report).
- **Small-business exemptions** (DE Kleinunternehmer, NL KOR, CH below the
  threshold): such a business files no VAT return, so it doesn't tick the
  scheme.

## Codes per country

`out` = sale, `in` = purchase. RC = reverse charge. Rate changes are listed
once with the current rate; the YAML holds every period.

**GB** (19 rows): out `sale_standard` 20 %, `sale_reduced` 5 %, `sale_zero`,
`sale_exempt`, `sale_outside_scope` (no box), `sale_services_outside_uk`,
`sale_export`, `sale_dispatch_ni_eu`, `sale_reverse_charge_construction`; in
`purchase_standard`, `purchase_reduced`, `purchase_zero`, `purchase_no_vat`,
`purchase_reverse_charge_services` RC, `purchase_reverse_charge_construction`
RC (20 % and 5 %), `purchase_acquisition_ni_eu` RC, `purchase_import_postponed`
RC, `purchase_import_c79` (amount is VAT).

**DE** (32 rows): out `verkauf_19`, `verkauf_7`, `verkauf_16`/`verkauf_5`
(2020 only), `verkauf_ig_lieferung`, `verkauf_steuerfrei_mit_vorsteuerabzug`,
`verkauf_steuerfrei_ohne_vorsteuerabzug`, `verkauf_13b`, `verkauf_eu_b2b`,
`verkauf_nicht_steuerbar`; in `einkauf_19`, `einkauf_7`, `einkauf_16`/`einkauf_5`
(2020), `einkauf_ohne_vorsteuer`, `einfuhrumsatzsteuer_code` (amount is VAT),
`ig_erwerb_19/7/16/5_code` RC, `einkauf_13b` RC, `einkauf_13b_drittland` RC.
Codes 19 % and 7 % carry `datev_bu` keys for the DATEV export.

**NL** (17 rows): out `verkoop_hoog` 21 %, `verkoop_laag` 9 %, `verkoop_nul`,
`verkoop_verlegd_binnenland`, `verkoop_buiten_eu`, `verkoop_dienst_buiten_eu`
(no box), `verkoop_binnen_eu`, `verkoop_afstandsverkopen_eu`,
`verkoop_vrijgesteld` (no box); in `inkoop_hoog`, `inkoop_laag`,
`inkoop_geen_btw`, `inkoop_verlegd_binnenland` RC, `inkoop_buiten_eu` RC,
`inkoop_binnen_eu` RC (21 % and 9 %), `invoer_btw_douane` (amount is VAT).

**ES** (18 rows): out `venta_21`, `venta_10`, `venta_4`, `venta_0`,
`venta_exenta` (no box), `venta_intracomunitaria`, `venta_exportacion`,
`venta_no_sujeta`, `venta_isp`; in `compra_21`, `compra_10`, `compra_4`,
`compra_sin_iva`, `compra_inversion_21`, `importacion` (amount is VAT),
`adquisicion_intracomunitaria_21/10` RC, `compra_isp_21` RC.

**CH** (19 rows): out `verkauf_normal` 8.1 %, `verkauf_reduziert` 2.6 %,
`verkauf_beherbergung` 3.8 % (each with a pre-2024 row), `export`,
`leistung_ausland`, `ausgenommen`; in `einkauf_normal`, `einkauf_reduziert`,
`einkauf_investition`, `einkauf_ohne`, `bezugsteuer` RC (`declare_only` under
the Saldosteuersatz), `einfuhrsteuer` (amount is VAT, `excluded` under the
Saldosteuersatz).

## Where it lives in the code

| What | Where |
|---|---|
| Catalogues (boxes and codes) | `db/tax_categories/<cc>_vat_<year>.yml` |
| Loading them; moving or retiring rows that left the file | `TaxCategoryLoader` (`#prune_tax_codes`), `bin/rails tax_categories:load`, `TaxCodeRetirementNotificationJob`, `Maintenance::WeeklyCheck#retired_tax_codes` |
| Header facts (currency, labels, flat rate, prepayment) | `TaxSchemeConfig` |
| A code: rate maths, validity, the dropdown | `TaxCode` |
| Control accounts: create, retire, revive, find | `Account.resolve_vat_account`, `Entity#sync_vat_control_accounts` |
| Splitting the VAT off at save | `JournalEntry#derive_tax_legs`, `TaxLegDerivation` (controllers) |
| Save rules | `JournalEntry#tax_codes_are_usable`, `#single_balance_account_with_nominals`, `#vat_leg_currency_matches_the_balance_leg`; `Account#tax_code_problem` |
| The return | `Reports::VatReturn`, `reports/vat_return.html.erb` |
| Flat rate and prepayment on a report | `Report`, `ReportGroup#flat_rate?`, `ReportGroup#prepayment_category`, `reports/_report-modal.html.erb` |
| Exchange rates per scheme | `db/exchange_rate_rules.yml` (keyed by scheme slug, e.g. `de_vat`) |
| Tests | `test/models/journal_entry_vat*_test.rb`, `entity_vat_control_accounts_test.rb`, `test/services/reports/vat_return_test.rb`, `tax_category_loader_codes_test.rb`, `report_flat_rate_test.rb` |

## Traps when changing a VAT catalogue

- **A changed `valid_from` is a new row.** The loader identifies a code row by
  `key` + `valid_from`. When a row disappears from the file (a corrected date,
  a period split, a removed code), its entries move to the row of the same key
  that covers their date, if that row has the same rate, direction, reverse
  charge and "amount is VAT". Entries that don't fit stay on the old row, which
  is kept and marked `retired_at`. It is never offered for a new pick, the
  bookkeepers are emailed once, and the Monday maintenance report lists it until
  nothing uses it; the next load then deletes it. A load never fails over this.
- **A rate changed on the same row corrects the past.** Same `key` and
  `valid_from` updates the row in place: entries saved again are re-derived at
  the new rate, and a reverse charge reports at the new rate at once. Right for
  a transcription mistake; for a change in the law, add a row.
- **Every `*_category_key` must be a category in the same file.** The loader
  refuses a typo; without that check the figure would never reach the return.
- **A flat rate exists only where the header names it** (`flat_rate_label`).
  Without it the report form doesn't offer one, and `Report` refuses a value
  sent anyway. Its boxes come from `flat_rate_net_category` and
  `flat_rate_tax_category`, or else from the first ordinary sale code.
- **A prepayment exists only where the header names its box**
  (`prepayment_category`). Same rule on the report form and in `Report`.
- **Don't offer two codes that reach the same boxes at the same rate.** The user
  would get a choice with no consequence.
- **Update the guards in the same commit:** `db/tax_catalogue_snapshot.yml`
  (`bin/rails tax_categories:snapshot`), the country and scheme lists in
  `test/services/tax_scheme_config_test.rb`, and an entry in
  `db/exchange_rate_rules.yml`.
- **After editing, load it locally** (`bin/rails tax_categories:load`). A
  development database that has missed loads drifts from production without any
  error.
