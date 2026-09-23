# Documentation

The [main README](../README.md) covers what the app is, and running it on your own
machine. These are the deeper documents.

## Run it

| | |
|---|---|
| [scalingo.md](scalingo.md) | Hosted on Scalingo — no terminal, no server. Click by click |
| [self-hosting.md](self-hosting.md) | On a server you rent: the seven steps from accounts to first sign-in |
| [provider-setup.md](provider-setup.md) | Self-hosted: setting up the outside services — server, DNS, object storage, email, optional CDN — click by click, plus the GitHub token the deploy needs |
| [maintenance.md](maintenance.md) | What has to keep happening once it is live, and by whom: scheduled jobs, backups, the weekly report |
| [self-hosting-legal.md](self-hosting-legal.md) | A developer's reading of the EU product-liability and cyber-resilience rules — what the app already does, and what changes if you charge for hosting. Not legal advice |
| [known-limitations.md](known-limitations.md) | The self-hosting risks worked through: what each is, how it was resolved, what is still open |
| [CRA/](CRA/) | Cyber Resilience Act pack for an operator who sells hosting — a declaration of conformity to publish, and two documents to keep. Explained in [self-hosting-legal.md](self-hosting-legal.md) |

## Extend it

| | |
|---|---|
| [concepts.md](concepts.md) | The model everything else is built on — the words, what one set of books holds, the bookkeeping and FX reasoning. **Read first.** |
| [tier-1-extending-languages-currencies.md](tier-1-extending-languages-currencies.md) | Adding a language or a currency. No schema change; a currency needs no developer |
| [tier-2-add-rate-source.md](tier-2-add-rate-source.md) | Adding an exchange-rate source: declaring the feed, writing a parser, scheduling it, and which authority accepts it |
| [tier-2-extending-countries.md](tier-2-extending-countries.md) | Adding a country: writing, loading and correcting the tax catalogue files, with a worked example |
| [tier-3-extending-filing.md](tier-3-extending-filing.md) | Digital submission (tier 3) — the connector architecture, and writing a new one |
| [tier-3-hmrc.md](tier-3-hmrc.md) | The one connector that exists today: applying to HMRC, and the field-mapping proof |

## Reference

| | |
|---|---|
| [tax-forms/](tax-forms/) | The authority forms themselves — the PDFs and transcriptions the catalogues were built from |
