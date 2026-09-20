# Conformity assessment

For a default product like this one — not important, not critical — self-assessment applies: **Annex VIII, module A**, of Regulation (EU) 2024/2847. No notified body, no outside review. You go through Annex I and confirm each requirement is met.

⚠️ **Never publish this** — same rule as the technical documentation it belongs with. Article 31: kept on file, available on request, for 10 years or the support period, whichever is longer.

## The check itself

Already done. The two tables in [self-hosting-legal.md](../self-hosting-legal.md), under "What this app already does," **are** the Annex I check — Part I security properties, Part II vulnerability handling, one row per requirement, each marked built in / partly / stated.

## What is missing is only the attestation

Fill this in and keep it with the technical documentation:

---

I have assessed **[SERVICE_NAME]** against the essential cybersecurity requirements of Annex I, Regulation (EU) 2024/2847, as set out in the tables in `self-hosting-legal.md`, and confirm the product meets them to the extent stated there.

Assessed by: _____________________________

Date: _____________________________

---

`[SERVICE_NAME]` is a constant this app already has (`config/initializers/contact.rb`) — fill in
your installation's actual value.
