# Digital submission (tier 3) — connectors and filing

Tagging accounts with tax categories is every country (tier 2). Filing to an
authority over an API is tier 3 — a separate concern with its own machinery.
This is that machinery, described generally; see [tier-3-hmrc.md](tier-3-hmrc.md)
for the one connector that exists today.

<!-- toc -->

**Contents**

- [Tax categories vs. digital submission — two separate concerns](#tax-categories-vs-digital-submission--two-separate-concerns)
    - [Account tagging (all countries)](#account-tagging-all-countries)
    - [Digital submission (tier 3) — one connector exists today](#digital-submission-tier-3--one-connector-exists-today)
- [How filing works](#how-filing-works)
    - [Submission storage layout](#submission-storage-layout)
    - [The submission sequence](#the-submission-sequence)
    - [The `connector` bridge](#the-connector-bridge)
    - [The filing service interface](#the-filing-service-interface)
    - [The filing controller](#the-filing-controller)
    - [Reaching the filing pages, and authority naming](#reaching-the-filing-pages-and-authority-naming)
    - [A note on session and OAuth state](#a-note-on-session-and-oauth-state)
- [Adding digital submission for a new country](#adding-digital-submission-for-a-new-country)
    - [What a connector consists of, on disk](#what-a-connector-consists-of-on-disk)
    - [The wiring — two steps](#the-wiring--two-steps)
    - [The build — five things the registry cannot give you](#the-build--five-things-the-registry-cannot-give-you)
    - [Naming reads itself](#naming-reads-itself)

<!-- tocstop -->

## Tax categories vs. digital submission — two separate concerns

### Account tagging (all countries)

Adding a new country or scheme for **bookkeeping purposes** — account tagging, P&L categorisation, and CSV export — requires only a YAML file:

```
db/tax_categories/<cc>_<scheme>_<year>.yml
```

Once loaded (`bin/rails tax_categories:load`), income and expense accounts can be tagged with category keys and the tax CSV export works automatically. This path is fully open and needs no code changes.

This is all that currently exists for Germany (`euer`, `vermietung`), Switzerland (`selbst`), and the Netherlands (`winst`). Adding a new scheme for those countries, or for a new country entirely, is a YAML-only operation as long as digital submission is not required.

### Digital submission (tier 3) — one connector exists today

**Digital submission** — connecting to a tax authority's API, reading filing obligations, and posting quarterly updates — is a separate and significantly larger concern than tagging. Today exactly one connector is built, for the United Kingdom via HMRC Making Tax Digital (MTD). See [tier-3-hmrc.md](tier-3-hmrc.md) for what that connector consists of, its HMRC-specific mechanics (cumulative quarterly updates, fraud prevention headers), and how to apply to HMRC for credentials.

## How filing works

### Submission storage layout

Every successful submission is archived as a standalone HTML document — a permanent, human-readable record of exactly what was sent, independent of whatever the authority's own portal shows later. Storage is deliberately regime-agnostic (`Filing::Storage`, not tied to the HMRC namespace) so the same archive would serve a future VAT or EUER filing without changing.

The backend is the `:tax_filings` Shrine storage registered in `config/initializers/shrine.rb`, alongside the receipt `:store`/`:cache` storages — one place for all object-storage config. It is used directly as a filename-keyed store (`.upload`/`.open`), not through a Shrine attacher, since these files are app-generated and keyed deterministically rather than attached to a model.

- **Production:** Scaleway Object Storage (S3-compatible), bucket `<your-bucket>-tax` (separate from the receipts bucket), region `fr-par`, **private**.
- **Development / test:** local filesystem under `public/tax_submissions/`.

Object keys follow a deterministic, human-navigable layout:

```
{entity_code}/{group}/{YY-MM-DD}-{form}-{CC}.html
# e.g. 71/MTD/26-06-30-SA103-GB.html
```

| Segment | Meaning |
|---|---|
| `entity_code` | Owning entity — the top-level folder, so all of an entity's filings sit together |
| `group` | Filing regime family: `MTD`, `VAT`, `EUER` |
| `YY-MM-DD` | The period **end** date. Keyed on the end (not a quarter number) so each cumulative submission stays a distinct file — see [Cumulative quarterly updates](tier-3-hmrc.md#cumulative-quarterly-updates-2025-26-onwards) |
| `form` | The real tax-form reference, from `form_code:` in the scheme's [tax category file](tier-2-extending-countries.md#the-header) — `SA103`, `SA105`, `AnlageV` — not an internal code. A scheme declaring none is filed under its slug |
| `CC` | Country code |

Object storage has no real folders: the `/` separators render as a folder tree in the Scaleway console automatically, so you create only the bucket, never the folders. The key is deterministic, so re-submitting the *same* period overwrites its own archive rather than accumulating duplicates; different quarters (different end dates) each keep their own file.

Because the bucket is private, the confirmation email can't just link to it directly — it links through a short-lived **signed token** instead: `sgid`, binding entity + scheme + period, ~30-day expiry, appended to the view URL (`GET /entities/:id/filing/view?…&sgid=…`). The token authenticates the request on its own (`FilingController#authorize_view`), so the recipient opens the exact archived document without logging in — the same shape as the tax-export receipt links (a link that authenticates itself, no session needed), though built on a different underlying mechanism: `Rails.application.message_verifier`, not the `signed_id` receipts use. A logged-in admin with edit rights can also open it from the periods page, no token needed.

### The submission sequence

`submit` on a filing service runs in two stages, so a later failure can never undo the irreversible call to the authority:

1. **Post to the authority** (`Hmrc::Client#submit_quarterly_update`, for the one connector that exists), inline. On failure nothing else runs and the user sees an explicit error.
2. **Render the submission HTML** inline (it needs view context), then **hand storage + notification to a background job** — `Filing::ArchiveAndNotifyJob`, enqueued with `perform_later`.

That job archives to storage (`Filing::Storage.upload`) and, **only once that succeeds**, sends the confirmation email (`AdminMailer#filing_submitted`, `deliver_now`) — sequential on purpose so the emailed view link always resolves to an already-stored document. Because it runs after the authority call has already returned, a storage or mail failure is retried by the job on its own, never touching the (already irreversible) submission.

### The `connector` bridge

The `connector` key in each YAML header is the bridge between account tagging and digital submission. It declares which filing mechanism, if any, applies to a scheme:

```yaml
# gb_self_employment_2026.yml
country_code: gb
scheme: self_employment
tax_year: 2026
connector: hmrc_mtd   # once connected, shows a "<submission_name> — submissions" link on the tax setup page

# de_euer_2026.yml
country_code: de
scheme: euer
tax_year: 2026
# connector omitted — account tagging and CSV export only, no filing page
```

`TaxSchemeConfig` reads all YAML headers the first time it's asked anything, then caches the result in memory. No migration is needed when a new `connector` is introduced — only a restart, to pick up the changed file.

`EntitiesHelper#scheme_filing_path` uses that map to decide which link (if any) to show on the entity's tax setup page for each scheme.

### The filing service interface

`Filing::Base` defines the interface every filing service must implement:

```ruby
connect_url(callback_uri:, state:)    # → URL for the authority's login page
handle_callback(params:, redirect_uri:) # → exchanges code, stores tokens on entity
disconnect                            # → clears tokens from entity
periods                               # → { obligations:, preview:, error:, report_periods:, business:, filed: }
submit(period_id:, view_url:, &renderer) # → submits period, stores HTML, sends email
view_html(period_id:)                 # → returns stored HTML string
report_period(period_id)              # → [start_date, end_date] actually covered by a submission
```

`Filing::Base.for(connector, entity:, scheme:, admin:, taxpayer: nil)` is the factory — it returns the correct service instance based on `connector`. `taxpayer` is only passed for `connect`/`disconnect`, where there is no scheme to read one through. The filing controller calls this and never knows which authority it is talking to.

### The filing controller

`FilingController` is a single generic controller for all filing interactions — OAuth connection management and submission — for any scheme and any country. It handles seven actions:

| Action | Route | What it does |
|---|---|---|
| `connect` | `GET /entities/:id/filing/connect?connector=hmrc_mtd` | Starts OAuth; redirects to authority |
| `callback` | `GET /entities/filing_callback` | One endpoint for every authority; exchanges code for tokens |
| `disconnect` | `DELETE /entities/:id/filing/disconnect?connector=hmrc_mtd` | Clears tokens |
| `periods` | `GET /entities/:id/filing/periods?scheme=self_employment` | Shows filing obligations |
| `report` | `POST /entities/:id/filing/report?scheme=…&period_id=…` | Opens the scheme's tax report over exactly the period an obligation covers |
| `submit` | `POST /entities/:id/filing/submit` | Submits a period to the authority |
| `view` | `GET /entities/:id/filing/view` | Displays a stored submission HTML |

`report` is a POST, not a GET, deliberately — it writes (finds or creates the report). It used to be a GET, and reports appeared that nobody had asked for, just from a link being followed.

**One callback endpoint serves every authority** — the connector is read from the session, never from the path. It carries **no locale**: the language is stashed in the session by `connect` and restored by `callback`, because a locale segment would spend one of an authority's registration slots per language, and HMRC allows five in total.

The URI sent to an authority comes from `Filing::Base.registered_callback_path`, which a connector overrides if its authority holds an older registration. A redirect URI differing from the registered one by a single character is refused, so that is a fact about the authority's account rather than about the app — which is why it lives on the connector.

### Reaching the filing pages, and authority naming

The tax setup page (`edit_tax`) is the hub: it holds the country/scheme form at the top and a per-country submission `<section>` lower down — connect/disconnect and, once connected, a "**submission_name** — submissions" link per scheme. That section's id is **country-derived**: `id="<cc>_connection"` (e.g. `gb_connection`), so it abstracts without an authority-specific rename.

An admin reaches it from the **dashboard**, where every entity they have full
access to carries a tax row. That row shows one next step and no dead ends:

| state | button |
|---|---|
| no schemes ticked | **Tax Setup** |
| schemes, but no taxpayer chosen | **Edit** |
| taxpayer chosen, not yet connected | **Edit** + **Connect to \<authority\>** |
| connected | **Edit** + **\<scheme\> — submissions** |

Not the admin's own page: tax setup is a setting *of a business*, and the
dashboard is the only place an entity reliably appears (`/entities` is
sudo-only).

`Entity#filing_offers` decides it, and the two halves are keyed
differently on purpose. **Connect is per authority** — one login covers every
scheme behind it, so two GB schemes must not grow two identical buttons.
**Submissions are per scheme**, and named after the scheme, because a button
labelled by authority alone did grow twice and led to two different pages.

The authority **name** is not domain data on any model: it comes from the
catalogue header, via `TaxSchemeConfig.authority_for_connector`. That is
what keeps user-facing wording authority-agnostic — messages and buttons
interpolate `%{authority}` rather than hardcoding "HMRC", so the German, Dutch
and Spanish translations stay right for ELSTER and ESTV.

The submissions button appears only once a taxpayer is **connected**, because
the submissions page asks the authority what periods it expects, and without a
token there is nothing to ask. Ticking a scheme used to be enough, which left
an entity that only exports its figures staring at a button that could never
list anything.

### A note on session and OAuth state

The OAuth state token, entity ID, and `connector` are stored in the Rails session during the connect flow and consumed on callback. This is standard OAuth CSRF protection. One known limitation: if a user opens two browser tabs and starts OAuth for two different entities simultaneously, the second connect overwrites the first's session state. The first callback will then fail with a state mismatch (safe, explicit failure — the user reconnects). In practice this is unlikely: OAuth flows take seconds and connecting two entities simultaneously serves no purpose.

## Adding digital submission for a new country

This is a substantial undertaking, and the YAML file alone is not sufficient. **Wiring it in is two steps; the other five are the actual build.** Before starting, read [Finding the original scheme](tier-2-extending-countries.md#finding-the-original-scheme) and [What tier 3 will never include](concepts.md#what-tier-3-will-never-include) — a scheme reaches tier 3 only if the figures it sends are nothing but the ledger, summed.

**Only one connector has ever actually been built and connected: HMRC.** Everything below is real, working machinery — but it is proven by that one case, not by several. A second country is still design, not experience yet. Every "pattern: `Hmrc::X`" below means "the only example that exists," not "the normal case."

### What a connector consists of, on disk

Worked through for the Dutch **btw-aangifte**, the strongest next candidate on the tax side: 27 elements, entirely the ledger summed, and its structure is already extracted in `docs/tax-forms/VAT/`. Its *authentication* is a different story — Digipoort uses PKIoverheid certificates, not OAuth, which is exactly the one shape `Base` does not yet support (see the ⚠️ under Authentication, below). So the file layout below is real and worth copying; step 3 as written is not — a Digipoort connector would need a certificate-based setup control this app has not built yet, not just a different `connect_url` body.

**You create these. All new, all yours:**

```
app/services/filing/digipoort.rb          the connector — Filing::Digipoort
app/services/digipoort/                   its own namespace, the same shape as Hmrc's
  auth.rb                                       certificates, or OAuth
  client.rb                                     the API calls and their parsing
  payload_builder.rb                            reads api_field / api_section off the catalogue
app/views/filing/digipoort/               anything only THIS authority shows
  _panels.html.erb                              reached only through #panel_partial
db/tax_categories/nl_omzetbelasting_2026.yml  the scheme, carrying `connector: digipoort`
```

**You edit exactly two lines:**

```
app/services/filing/base.rb     CONNECTORS = %w[hmrc_mtd digipoort]
db/exchange_rate_rules.yml          the scheme's rate rule — for Dutch VAT, ecb_daily
```

**Optional, and only if the authority actually asks:**

```
app/javascript/scripts/tax.js       a browser collector, if it wants browser-side data
app/javascript/scripts/index.js     one line in BROWSER_COLLECTORS
config/credentials.yml.enc          keys, client ids, certificates
config/recurring.yml                a healthcheck, if the sandbox is worth watching
config/locales/                   ONLY for words that are the authority's own vocabulary,
                                    namespaced like filing.hmrc.* — never for generic ones
```

**You touch none of these, and a test enforces it:**

```
app/controllers/filing_controller.rb      resolves connectors, never reaches into one
app/views/filing/*.erb                    the shared pages
app/services/filing/storage.rb            the submission archive
app/mailers/admin_mailer.rb                   filing_submitted interpolates %{authority}
config/routes.rb                              one callback endpoint serves every authority
app/models/taxpayer.rb                    identifiers are jsonb; no migration per country
```

`test/services/filing/authority_neutrality_test.rb` derives the authority list from the tax category files and fails if any name appears outside its own connector's territory — so your authority is covered by it the day your YAML lands, without anyone remembering to add it.

### The wiring — two steps

1. **Write the connector.** `app/services/filing/<connector>.rb`, subclassing `Filing::Base`.
	
	**Seven methods you must implement**, because no default can be right: `connect_url`, `handle_callback`, `disconnect`, `periods`, `submit`, `view_html`, `report_period`.
	
	⚠️ **Read `base.rb` for their exact contracts before writing any of them.** This page tells you what a connector is for; the file tells you what each method must return, and the shapes are not guessable. `periods` in particular must hand back a specific hash — obligations, preview, error, report_periods, business, filed — which the shared view renders directly, so a connector returning something merely reasonable fails at render time rather than at the boundary. Every method there carries a comment saying what it is for and what it may assume.
	
	**Two constants**: `AUTHORITY_KEY` (the key stored on `Taxpayer` — several services at one authority share a login, so they share a taxpayer) and `IDENTIFIERS` (what that authority calls the taxpayer: HMRC wants `%w[nino]`).

	**Six hooks with working defaults**, overridden only if your authority needs them:

	| hook | default | override when |
	|---|---|---|
	| `.prepare_request` | does nothing | the authority wants something from the HTTP request — HMRC's fraud prevention headers |
	| `.browser_collector` | `nil` | it wants something only the browser knows; return the name of a script in `tax.js` |
	| `.registered_callback_path` | `/entities/filing_callback` | the authority holds an older registration. **Record the exact registered URIs in a comment** — one wrong character is refused |
	| `#panel_partial` | `nil` | the page must show something only this authority has; put it in `app/views/filing/<connector>/` |
	| `#businesses_by_scheme` | `{}` | the authority issues per-business identifiers to choose between |
	| `.normalise_identifier` / `.valid_identifier?` | strip / accept | you know the format — HMRC will not match `"ab 12 34 56 c"` |

2. **Add the `connector` to `Filing::Base::CONNECTORS`**, and `connector: <name>` to the scheme's YAML header.

	That is the whole of it. **Controllers, routes and views need no changes** — they resolve the connector through the registry. `test/services/filing/authority_neutrality_test.rb` keeps it that way: it derives the list of authorities from the tax category files and fails if any is named outside its own connector's files. Your authority is covered by it the day your YAML lands.

	**Speak the app's vocabulary at your edge, not HMRC's.** Translate the authority's own codes where you parse its response, the way `Hmrc::Client` turns `"F"`/`"O"` into `Filing::Base::STATUS_FULFILLED` / `STATUS_OPEN` and `typeOfBusiness` into our scheme slugs. Every shared view reads the app's words; nothing downstream should ever have to learn a second alphabet.

	**`periods` may have to invent its obligations.** HMRC publishes what it expects and when, so `periods` fetches them. Most authorities do not — the deadlines are in statute with no endpoint — so that connector computes them from a calendar and returns the same shape. `Filing::Base` deliberately makes no assumption either way.

	**The class name *is* the `connector`**: `Filing::HmrcMtd` ↔ `hmrc_mtd`. The only other place that string appears is the catalogue header, and it is derived from the class name rather than repeated, so those cannot drift apart.

	`CONNECTORS` and the YAML headers are deliberately two separate lists. A catalogue may declare an authority nobody has built a connector for — the header describes the country's reality, `CONNECTORS` describes ours. Until the connector exists the scheme simply stops at tier 2 and is offered no connect button. That is what lets a country arrive at tier 2 and gain submission later.

### The build — five things the registry cannot give you

1. **Authentication.** Every authority differs: HMRC uses OAuth 2.0 with Government Gateway, ELSTER uses certificates, the Dutch Digipoort uses PKIoverheid certificates. Pattern: `Hmrc::Oauth`.

	⚠️ **The one shape `Base` still assumes is a browser redirect.** `connect_url(callback_uri:, state:)` and `handle_callback(params:, redirect_uri:)` are OAuth's round trip, and the tax setup page renders a Connect link that follows it. A certificate-based authority has no such journey — you upload a certificate, you are not sent anywhere and nothing comes back — so that connector would need a different setup control, not just different method bodies.

	This is named rather than fixed on purpose: designing a second auth shape before building one is how you get an abstraction that fits neither. Everything else on this page is genuinely authority-agnostic and enforced by `authority_neutrality_test`; this is the known exception.

	Finding an authority that genuinely is OAuth-shaped, the way HMRC is, would settle whether that assumption in `Base` generalises at all — nobody has checked. Whoever wants that answer gets to go and check it.

2. **API client** — obligations endpoint, submission endpoint, response parsing, and whatever headers the authority demands. Pattern: `Hmrc::Client`.

3. **Payload builder** — the authority's expected JSON or XML. HMRC uses `periodIncome` / `periodExpenses` hashes; others differ. Pattern: `Hmrc::PayloadBuilder`, which reads `api_field` and `api_section` from the catalogue rows. **You may not need `api_field` at all** — ELSTER transmits by Kennzahl, which `export_column` already holds. HMRC is the odd one out in inventing separate JSON names for boxes that already have numbers.

4. **Credentials** — API keys, client IDs or certificates in `credentials.yml.enc`.

5. **Stored identifiers.** Tokens and whatever the authority uses to identify the taxpayer go on `Taxpayer` — one row per admin per authority, tokens encrypted, everything else in a jsonb `identifiers` bag. Nothing queries that bag; it is carried to the API and back, so an authority wanting a Steuernummer needs no migration. HMRC stores `{"nino" => …}`. Identifiers that belong to a *business* rather than a person go on the tax report group instead — see [How the filing pieces fit](concepts.md#how-the-filing-pieces-fit).

	The bag is deliberately **not** encrypted: these numbers identify, they do not grant. A NINO is on your payslips and your accountant has it, and knowing one files nobody's return — the *token* does that, which is why only the tokens are encrypted. Anything a future connector stores that grants access, such as an ELSTER certificate password, needs its own encrypted column.

### Naming reads itself

The authority's display name comes from `authority:` in the scheme's header, and the tax setup page derives its anchor from the country code (`de_connection`). Buttons and confirmation messages interpolate `%{authority}`, so they read correctly with no wording changes. German VAT, for instance, would file the **Umsatzsteuervoranmeldung** via **ELSTER**, and both the button and the stored filenames would say so. (The *annual* Umsatzsteuererklärung is out of scope by design — see [What tier 3 will never include](concepts.md#what-tier-3-will-never-include).)

Account tagging and CSV export work throughout, whether or not digital submission is ever implemented.

---
