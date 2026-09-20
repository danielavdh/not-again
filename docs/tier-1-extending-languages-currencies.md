# Adding a language or a currency

None of these needs a schema change, and adding a currency needs no developer at all.

<!-- toc -->

**Contents**

- [Adding a currency](#adding-a-currency)
- [Adding a language](#adding-a-language)
    - [The normal path: a custom language, sudo, no deploy](#the-normal-path-a-custom-language-sudo-no-deploy)
    - [Adding or updating a *system* language: a developer, needs a deploy](#adding-or-updating-a-system-language-a-developer-needs-a-deploy)
    - [Keeping a new custom language's starting text in sync](#keeping-a-new-custom-languages-starting-text-in-sync)
    - [`number:` — the gem carries it, but look at it anyway](#number--the-gem-carries-it-but-look-at-it-anyway)

<!-- tocstop -->

## Adding a currency

**Not a code change.** A full-access admin adds one on the currencies screen — code, symbol, done — and it takes effect immediately: dropdowns, the fetcher, `parse_to_cents`, no restart, no deploy.

If the currency has no distinct symbol, use the code with a trailing space, as CHF does: `CHF `.

**Display order is a rule, not a field.** Nothing is pinned — `Currency.ordered` sorts every currency an account actually uses first, alphabetically, then everything else, alphabetically. A currency promotes itself the moment an account is opened in it.

**Once a POSTING rests on a currency, its code and symbol stop being editable** (sudo excepted) — an account alone does not lock it, only a posting does (`Currency#settled?`). Editing the code anyway cascades to every account, posting and rate that carries it (`#migrate_dependents_to_new_code`), so a genuine correction is no longer destructive; the lock exists for the case a cascade should not silently paper over — two different codes that happened to look similar, not the same currency at all.

**Saving a currency starts a background check.** It asks each rate source in turn whether it publishes the new currency, emails you the answer, and immediately fetches one period from every source that said yes. Most rates can also be fetched manually.

**The app has four default rate sources: ECB, HMRC, the Swiss ESTV, and the Bundesbank**. Each publishes its rates against one **base currency**: EUR for the ECB, GBP for HMRC, CHF for ESTV, EUR again for the Bundesbank.

**Cross-rating** fills in a pair no source states directly, by combining two it does. If a source publishes GBP→UAH and GBP→EUR, the app derives EUR→UAH from those two — computed at the moment it's needed. <br />
Tax reports always use the rates from their accepted authority. If no rate is available, none is calculated, and a message tells you so.

⚠️ **A currency with no rate raises.** `ExchangeRate::RateUnavailable` names the pair and the date.

If a currency isn't published by any of the four sources, you can enter one by hand, from wherever you trust — that rate applies to one entity's books only, not the whole installation, and a note records where the figure came from.

ECB publishes about 30 currencies (fetched monthly — a genuinely daily ECB feed exists as a separate configured source, `ecb_daily`, but nothing schedules it), HMRC about 170 (fetched monthly) — a currency missing from ECB is usually still reachable through HMRC.

⚠️ **A reachable currency is a tier 1 answer, and it does not carry over to tier 2.** "The ECB publishes RON" settles whether you can keep books and read reports in lei — not whether Romania's tax authority *accepts* an ECB rate on a filed figure, and authorities usually do not. See [authority rules](tier-2-add-rate-source.md#authority-rules). Germany: a euro profit and loss reads the ECB, but a German VAT return wants the Bundesbank monthly average that §16(6) UStG names. Assume a country's tax layer wants its own national central bank until you have read the rule and found otherwise.

Two formatting rules make any currency outside western Europe work without code changes:

- **Symbol placement is a property of the chosen NUMBER FORMAT, not the UI language.** `CurrencyConfig.format_cents` reads `NumberFormat::FORMATS` (via `number_format(locale)[:symbol]`), so `"%n %u"` puts the symbol after the number for whichever number format is in effect — no code changes needed. The locale's own `number.currency.format` is only the fallback (`NumberFormat.from_locale`), used when a UI language has no `DEFAULT_FOR` entry of its own (Bulgarian, Romanian, Ukrainian, Polish, the Nordic languages). An admin can still override the derived format with their own choice, in their profile.
- **`parse_to_cents` reads what people actually write, regardless of their display format.** Locale-independent: space thousands, non-breaking spaces, and any symbol or code in `SYMBOLS` — `лв.`, `CHF`, `zł` — are stripped before the digits are read; whichever of `.`/`,` sits rightmost is taken as the decimal separator. The strip pattern is **derived from `SYMBOLS`**, longest match first.

## Adding a language

Two ways, and they need different people.

### The normal path: a custom language, sudo, no deploy

**Only sudo, on the `/languages` screen — data, not code.** 

1. Show or hide one of the shipped languages: tick/untick "show in menu"
2. Add a new language: Click "new language": This prefills every textarea with the English text, so you can copy it and have it translated. 
	- `yml_content` with a full copy of `config/locales/en.yml` (first line swapped for a placeholder for you to fill)
	- and the four content fields written in Textile, not HTML: 
		- `easy_manual_textile`, 
		- `pro_manual_textile`, 
		- `legal_textile`, 
		- `terms_textile`.

	Each field has a copy button and an AI-translator prompt written next to it — paste the prompt, paste the field into the translator, paste the AI's reply back in. **`[EMAIL]`, `[WEBSITE]`, `[STREET]` and the other bracketed tokens are not text — leave them exactly as they are.** They're filled in from this installation's own contact details at render time (`ContactPlaceholders`), so a translator changing or dropping one breaks the real address on the legal page, not just the wording.

	**YML WARNING:** if you have never worked with a yaml file: indentation = spaces, not tabs, and one wrong space - a missing colon, a missing " breaks to whole thing. If you are tearing your hair out: throw everything away, that will bring back the english text, and you can start with a clean copy. Editing the yaml content in a text editor helps. And regular saving, even of partial improvements.

	**Draft first, always.** Nothing is public until *released* — sudo can preview the translated pages (help docs included), to catch problems and to improve the language. A custom language that shares a language code with a shipped language will override the shipped language the moment it's *released*.
	
	None of this needs a restart. The routing constraint (`config/routes.rb`) is deliberately just `/[a-z]{2}/`, not built from a fixed list — it would otherwise need a restart every time sudo released a new language.

### Adding or updating a *system* language: a developer, needs a deploy

The available languages are the ones this app ships and maintains, they are human reviewed. If you want to add one:

1. **`config/locales/<code>.yml`** — copy `en.yml`, replace `en:` on line 1 with `<code>:`, translate.
2. **`config/initializers/locale.rb`** — add `['Български', 'bg']` to `LANGUAGES` (watch the comma pattern!). `I18n.available_locales` is **derived** from this list — which locales the `rails-i18n` gem loads real date/number data for, and which appear in the switcher, both come from here.
3. **`app/views/help/*_<code>.html.erb`** — four hand-written pages: `easy_manual_`, `pro_manual_`, `legal_`, `_terms_text_`. Prose in their own language, not a template translation.
4. **`db/seeds.rb`** — add the row so the switcher and routing gate actually see it; mirror it in `test/fixtures/languages.yml` too, or the test suite won't.

**This needs a restart:** `LANGUAGES` is a Ruby constant read at boot, and the gem's per-locale data only loads for what's in it at that point.

**A system language missing one of its 4 files falls back to English** — `test/controllers/manuals_test.rb` checks file existence directly and names whatever's missing, so this is caught before it ships. A custom language's fallback is by design rather than an accident to catch: `fill_blank_fields_with_english!` only ever fills a field that's actually blank, so there's nothing left unfilled to fall back on.

### Keeping a new custom language's starting text in sync

`db/default_en_help_files/*.textile` prefills a new custom language's four content fields — extracted once from `app/views/help/*_en.html.erb`, not read live. Edited the English guides meaningfully? Re-run it:

```
bin/rails help_docs:extract_textile_help_text
```

Read the diff before committing. It's a one-way, lossy conversion (HTML → Textile) — fails loudly on ERB it doesn't recognise, but can't judge wording. No automation forces this on every change: a slightly stale prefill costs nothing the normal human-correction pass wouldn't fix anyway.

Check the font, not just the translation, either way: Romanian needs the **comma-below** forms of `ș ț ă â î`, not the cedilla lookalikes many fonts substitute — a glyph can exist in the right slot and still be the wrong glyph.

### `number:` — the gem carries it, but look at it anyway

The `rails-i18n` gem ships a `number:` block per locale — separators, grouping, symbol position, no work needed. What it doesn't guarantee is that the block is *right*: community translations have shipped `separator`/`delimiter` swapped, silently. Check it: `bin/rails runner 'p I18n.t("number.currency.format", locale: :bg)'`, against what the language actually writes.

The **number-format picker** (`app/lib/number_format.rb`) can override this per admin — the `number:` block is only the default. Both the screen and CSV exports follow whichever is in effect (`CurrencyConfig.format_cents_csv`/`csv_separator`), so a comma decimal still forces a `;` CSV separator.
