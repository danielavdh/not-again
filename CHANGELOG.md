# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] — 2026-11-26

The first release. It has been keeping real books in production since September
2026.

### What is in it

- **Double-entry bookkeeping** — journal entries, plus deposit, withdrawal and
  transfer forms on each bank account's ledger.
- **Multi-currency, translated at report time.** Only balance-sheet postings
  carry a currency; every report translates by its own rules, at the rate for
  the entry's date. Published rates from the ECB, HMRC, the Bundesbank and the
  Swiss tax authority (ESTV), monthly, plus the ECB's daily rates where a
  country's rules ask for them.
- **Multi-entity** — up to 100 businesses or households in one install,
  families for consolidated reports, and payments linked across businesses.
- **Reports** — profit and loss, balance sheet, trial balance, custom reports,
  an assisted year-end close, and a CSV of the whole books at any time.
- **Tax reports** for eleven forms: self-employment for the UK, Germany,
  Switzerland and the Netherlands; rental income for the UK and Germany; VAT
  for the UK, Germany, Switzerland, the Netherlands and Spain.
- **VAT** — a VAT code on each line of an entry, the VAT split worked out
  on save, reverse charge, flat-rate returns (UK, Switzerland), the German
  prepayment (Kz 39). A return can be marked final once submitted: its CSV is
  kept, the entries of the period are locked, and the two VAT accounts are
  cleared for the period. Payments and refunds are ordinary transfers.
- **Receipts** — photos, scans and PDFs, compressed and linked to postings.
- **Access per entity** — full access and read-only, both with two-factor
  sign-in, and upload-only for receipts, without it.
- **Tax export** — transactions with receipt links and a CSV in the
  authority's boxes; DATEV as an accountant's format.
- **Languages** — English, German, Spanish and Dutch.
- **Filing to HMRC (MTD Income Tax)** — built and connected to HMRC's sandbox.
  Each installation needs its own approval from HMRC, which is not granting new
  production access until early 2027. See `docs/tier-3-hmrc.md`.

### Not built

See `docs/known-limitations.md`.

### Upgrading

1.0.0 starts a clean migration history: the earlier migrations are one,
`db/migrate/20261113100000_initial_schema.rb`. A database already at that
version is left alone. An install from the repository before this release that
has not been updated since cannot migrate to it — please open an issue.

[Unreleased]: https://github.com/danielavdh/not-again/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/danielavdh/not-again/releases/tag/v1.0.0
