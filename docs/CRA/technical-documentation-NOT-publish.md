# Technical documentation

Technical name: **Annex VII** of Regulation (EU) 2024/2847 (the Cyber Resilience Act), required by **Article 31**. Search either term and you land on the primary source, not a summary.

⚠️ **Never publish this.** Article 31 requires it kept on file — available to your market surveillance authority on request, for 10 years or the support period, whichever is longer. Nobody sees it unless asked.

## Where to actually read the requirement

- [cyberresilienceact.eu/annexes.html](https://www.cyberresilienceact.eu/annexes.html) — the Annex VII text, laid out readably
- [cvdportal.com/glossary/annex-vii-technical-file](https://cvdportal.com/glossary/annex-vii-technical-file) — guidance on what the technical documentation must contain (explanatory, not a fillable template)

## What this repo already gives you for it

Annex VII asks, among other things, for a description of the product, how each essential requirement is met, and evidence of your vulnerability-handling process. This repo already has the raw material for most of that — assemble from it rather than starting blank:

- The two tables in [self-hosting-legal.md](../self-hosting-legal.md) — "how each Annex I requirement is met," already filled in against the actual code
- [SECURITY.md](../../SECURITY.md) — the vulnerability-handling process Annex VII asks you to describe
- The SBOM CI produces on every push — the bill-of-materials component
- The README and `docs/concepts.md` — the product description

## What it does not give you

The one genuinely unavoidable part: a **risk assessment specific to your own deployment**. That has to reflect your actual judgement about your actual installation, not boilerplate. Nobody can write that for you in advance.

⚠️ Also live and unsettled: the harmonised standards Annex VII expects you to cite against are not fully finalised as of writing. Even a careful write-up here is against a moving target right now.
