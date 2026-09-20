# Exchange rate sources

<!-- toc -->

**Contents**

- [Adding a rate source](#adding-a-rate-source)
- [Authority rules](#authority-rules)
- [Nothing is fetched unattended unless something wants it](#nothing-is-fetched-unattended-unless-something-wants-it)
- [Daily sources](#daily-sources)
- [Why these feeds, and not a rate API](#why-these-feeds-and-not-a-rate-api)

<!-- tocstop -->

## Adding a rate source

If none of the four default rate sources is what you need for the tax authorities that are relevant to the running of your app, you can add your own sources. This involves 3 steps, of which only the first is always needed.

**1. Declare it** in `db/exchange_rate_sources.yml`. The real ECB entry shown as example here:

```yaml
ecb:
  label: ECB
  base: EUR
  display_default: true
  display_fallback: true
  frequency: monthly
  semantics: month_end_spot
  url: https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml
  parser: ecb_xml
  history_url: https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist-90d.xml
  archive_url: https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.xml
  earliest: "1999-01-04"
```

- **`label`** — what the user sees. (The internal key is on first line, `ecb`, here).
- **`base`** — the currency this feed publishes AGAINST.
- **`display_default`** — a report shown in this currency (EUR, here) reads this source by default. Only use `true` once per currency.
- **`display_fallback`** — the source a report cross-rates through when its own display currency is the base of no source at all (a UAH or USD report, say). **Exactly one source in the whole file should set this** — a test enforces that.
- **`frequency`** — `daily` or `monthly`. What **one fetch returns**, and therefore the validity span each stored row gets.
- **`semantics`** — what the number **is**, which `frequency` doesn't say: a month-end **spot** rate and a monthly **average** are both "monthly" and are different figures — German VAT law asks specifically for the average, not the ECB's own `month_end_spot`.
- **`url`** — the feed's normal endpoint. May contain `%{year}`, `%{month}` (not zero-padded) or `%{month2}` (zero-padded) — publishers disagree: HMRC's own files are `monthly_csv_2026-8.csv` and `2026-08` is a 404 there, while the Bundesbank wants the opposite (have a look in the file directly).
- **`parser`** — resolves to a class by name (`ecb_xml` → `Rates::EcbXmlParser`) — see step 2.
- **`history_url` / `archive_url`** — read further back than `url` reaches, cheapest first (the 90-day file above is 0.1 MB, the archive 7.8 MB). **A source declaring neither of these, and with no `%{...}` in `url` either, can only ever answer for the current period** — ESTV, further down, is the real example of exactly that.
- **`earliest`** — a **quoted string**, not a YAML date (`YAML.safe_load_file` doesn't permit one) — the archive's first day, so the nightly gap-filler doesn't ask for 1995 forever.

Two more fields exist but aren't in this example, because ECB doesn't need them: 

- **`short_label`** (the Bundesbank and `ecb_daily` entries both set one — `label` alone doesn't fit the report's currency dropdown) and 
- **`fallback_url`** (declared and read by the fetcher, but no shipped source currently uses it — for a feed with a "latest" endpoint as well as dated ones).

**2. Write the parser** — skip this if an existing one in `app/services/rates/` already fits (check
there first). If not:

- **Pick a name.** This is the value you wrote after `parser:` in step 1 — `bnb_xml`, in our example. One name, used in three places: the YAML, the file, the class — steps b and c below.
- **Copy the template to that name:**

		cp app/services/rates/example_parser.rb.template \
		   app/services/rates/<name>_parser.rb
		
		`<name>` is whatever you picked in (a) — `app/services/rates/bnb_xml_parser.rb` here.

- **Open the new file and rename the class.** It still says `class ExampleParser` — change it to `<name>`, camelized: `class BnbXmlParser`. This one rename **is the entire wiring.** `ExchangeRateFetcher#parser_for` builds `"Rates::#{name.camelize}Parser"` straight from the `parser:` string in the YAML and looks up that constant — get the class name right and Rails' own autoloading finds it. There is no separate registry file, no array, no third place that also needs to know your parser exists — only (a) and (c) have to agree.
- **Fill in the one method the template leaves as `raise NotImplementedError`:**

		def self.parse(body, requested_date:)
		  # => { rates: { "EUR" => 1.9558 }, valid_from: Date, valid_to: Date }
		  # => nil           to REFUSE — wrong shape, no rates, or no period declared
		  # => :no_data_yet  the response is fine and does not reach that period
		end

	It may also return an **array of those hashes**, which is how a daily source answers: one file holds every published day, so a single request yields hundreds of one-day spans. Monthly parsers return a single hash and are unaffected.

	`:no_data_yet` matters more than it looks: a month-average source is empty until its month ends, and treating that as a failure emails somebody every night for a week.

	Three rules:

	- **Normalise before returning.** Switzerland's ESTV quotes weak currencies per **100 units** (`<waehrung>100 CNY</waehrung>`), so its parser divides by 100 and returns the rate for one unit. Nothing downstream — storage, translation, reports, submissions — ever learns that a feed did this. Whatever your central bank does strangely, it stops in your parser.
	- **Take the period from the FEED, not the caller**, (read what period the response itself declares) and return `nil` rather than guess if it does not say what period it covers. Guessing (e.g. "1 August must mean July") risks storing a real month's rates under the wrong label.
	- **Test against the live feed, not only a fixture.** `Net::HTTP` returns `ASCII-8BIT` regardless of the charset header, so a feed's charset-flagged content (HMRC's `Currency Units per £1` header, for instance) arrives as raw bytes — a fixture built from a Ruby string won't catch that.

That is the whole extension point. `ExchangeRateFetcher` never learns your feed exists: it
makes a request, asks the registry which parser to use, and writes rows.

**3. Schedule it** in `config/recurring.yml`, under the `production:` key — one entry per source, `class: FetchExchangeRatesJob`, `args: ['bnb']`, `schedule:` a cron string timed to when the publisher actually releases. Skip this and the source still works (declared, fetchable by hand, readable by anything that asks) — it's just never reached unattended except by the nightly gap-filler.

## Authority rules

`db/exchange_rate_sources.yml` says what a source **is**. `db/exchange_rate_rules.yml` says what a country's tax law will **accept**, which is a different question and has no business in the other file. It is keyed by **country**, not by authority: an exchange rate rule is national law, and §16(6) UStG applies whether you file through ELSTER or on paper.

```yaml
# example
pl:
  accepts:      [nbp, ecb]              # ordered — preferred first, fallback after
  date_basis:   preceding_publication   # transaction_date | preceding_publication
  election:     none                    # none | consistent | per_tax_period
  unpublished_currency: manual_with_evidence
  schemes:                              # optional: override one field for one tax
    vat:
      accepts:  [nbp]
```

**Every country with tax category files must appear here, and only a test will show if it is missing.** Without an entry, `accepted_sources` returns nothing, and a *tax report* for that country silently falls back to the tier 1 rule instead — converted at a rate the authority never named, with no error anywhere.

The reverse is fine, though: an entry here doesn't need a tax category file to already exist. Germany's `umsatzsteuer` scheme already declares `[bundesbank, ecb]`, with no tax category file for it yet — harmless, since nothing can select a scheme with no file at all, so the entry simply can't fire until the file does exist (same not-yet-live state as the two fields further down).

The seam is one argument: `ExchangeRate.translator(..., scheme:)` — **with a scheme it is a tax report and this file decides the rate that is accepted by its tax authority; without a scheme it is an ordinary report, tier 1 chooses rates automatically, admin can override. The reports always show which source was used for a conversion.**

- `accepts:` is an ordered preference list — and it's allowed to leave real gaps

	The list is tried, for the dates a report actually covers; the first source wins that is holding the required rates, and the report shows which source answered. Switzerland's list is `accepts: [estv]` — one source, and ESTV only ever holds the *current* month, so an older period simply gets no accepted rate at all.

	**What happens when no accepted source covers a period a tax report needs: an error, never a silent substitute.** `ExchangeRate::RateUnavailable` is raised even when a rate from some *other*, unaccepted source is sitting in the database for that exact pair and date — proven directly by a test (`rate_rule_config_test.rb`, "a period no accepted source covers produces no rate at all"). The report catches it and blanks its **entire** converted column — not just the one missing figure — rather than show a total silently understated by the gap, plus a flash message linking to the rates page. The business can enter the real published rate by hand — the compliant answer anyway, since the authority's own history is public; only its API is limited.

- `date_basis:` — which day the rate is keyed to

	- `transaction_date` — the rate covering the day of the transaction. The default, and what you want unless the law says otherwise.
	- `preceding_publication` — the last rate published *before* that day.

	Two reasons to need the second. Some laws simply say so: Poland keys to the publication before the tax point. And **any country reading a daily feed needs it whatever the wording**, because a transaction on a Saturday, a Sunday or a public holiday has no rate of its own at all.

	With a **monthly** source the two are indistinguishable — one span covers every day of the month, so the fallback never fires. Every source shipped here is monthly, so this field matters the moment the first daily source is added, not before.

Two fields in the example above aren't live yet: `election:` and `unpublished_currency:`. Declared and documented, but nothing in the app calls either one — writing `election: per_tax_period` instead of `none` changes nothing today. Write them anyway when you know the law's answer, so it's on record for whoever wires them up (`date_basis:` sat in this exact state until 2026-08-22).

## Nothing is fetched unattended unless something wants it

A source in this file is one the app **can** read. Each declared source gets its own schedule
entry in `config/recurring.yml`, timed to when that publisher actually releases — roughly
**monthly**, not nightly. The one job that runs nightly is the shared gap-filler,
`FillRateGapsJob`, which fetches whatever the books need and the database lacks. Either way, a
source is only pulled at all when something actually asks for it:

- **tier 1 displays through it** — it is a `display_default` for some currency, or the
  `display_fallback`. True regardless of which countries exist, even none: a report converts
  before any tax rule is involved.
- **a country's rule names it** in `db/exchange_rate_rules.yml`.

Otherwise shipping a source would mean every installation fetching it every month, for ever, for
countries it has never heard of. `ecb_daily` is exactly that case — it exists for the Netherlands'
`omzetbelasting` scheme, and it is ~250 periods a year rather than 12. Declared, readable,
fetchable by hand, and untouched by the schedule until a rule names it.

The **manual fetch button is not governed by this.** An admin asking for a specific source and month gets it, if it is available. Only unattended work is restricted by what is actually required.

## Daily sources 

The one fact that makes everything below make sense: **a daily feed's ordinary endpoint holds only today.** There is no way to ask it for one specific day in the past — the ECB's own `url` is *today only*. The only way to reach a past day is a *different* file that returns many days at once (`history_url`, 90 days; `archive_url`, back to 1999). Fetching one day at a time is simply not an option the feed offers.

Two consequences follow from that, and both are the opposite of what you'd guess:

**The fetch unit is still a month, same as a monthly source.** "Fetch July" means "grab whichever file covers July and store every day it contains" — so a daily source reaches for `history_url` or `archive_url` even for the *current* month, because its ordinary `url` returns only today and storing that one day would leave the rest of the month silently empty, looking like a completed fetch.

**A gap is counted by month, never by day.** No publisher quotes on a Saturday, so "does every day have a rate" would flag every weekend and public holiday as a gap — about 104 false alarms a year, none of them fillable. A past month holding any published day counts as fetched; the current month never counts as covered, since it's still accruing days and re-checking it costs one cheap request.

(Which day's rate applies to a transaction that falls on a day with no rate at all is a separate, *tax* question — see `date_basis` above.)

**Why both `ecb` and `ecb_daily` exist, rather than one:** they're different numbers, not two views of the same one. `ecb` collapses a month to its last published day and lets that stand for the whole month; `ecb_daily` keeps every day as its own span. Storing only the daily series would silently change every figure in every report already saved — a monthly report would start converting each posting at its own day's rate instead of the month's closing rate. A new daily source may need the same pair, if anything reads it both ways.

**Volume, worth knowing before backfilling:** ~250 periods a year against 12 for a monthly source. Several years of history is tens of thousands of rows. Measure a backfill rather than assume it's cheap.

## Why these feeds, and not a rate API

The rate sources are not a convenience — they are a compliance choice, and a contributor who replaces them with something more convenient needs to know that.

**Each source is there because some tax authority accepts it.** A figure converted at an ECB reference rate, an HMRC monthly rate, an ESTV average or a Bundesbank monthly average is defensible to the tax office that publishes it. The same figure converted at a commercial provider's mid-market rate on the same day is not — even when it is closer to the truth. A rate API would be easier to integrate and would fail exactly where it matters.

That is also why rates are stored with their `source` and their validity span rather than fetched live: a figure can always be traced back to which authority's published rate produced it, years later, when someone asks.

**Nothing is hardcoded to the four shipped sources.** The feed URL, parser, base currency, frequency and history route are all declared in `db/exchange_rate_sources.yml` (above); `config/recurring.yml` holds one schedule entry per source, because publishers release at genuinely different times of the month; and `FetchExchangeRatesJob` retries with `retry_on FetchError, wait: 1.hour, attempts: 3`. `ExchangeRateFetcher` — the piece that actually runs — knows none of their names.
