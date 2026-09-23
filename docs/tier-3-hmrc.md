# HMRC — digital submission (tier 3)

The one filing connector that exists today. General connector architecture is in
[tier-3-extending-filing.md](tier-3-extending-filing.md); this page is what is
specific to HMRC — what the connector consists of, applying for credentials, its
MTD-specific mechanics, and the field-mapping proof.

<!-- toc -->

**Contents**

- [What this connector consists of](#what-this-connector-consists-of)
- [Applying to HMRC](#applying-to-hmrc)
- [Cumulative quarterly updates (2025-26 onwards)](#cumulative-quarterly-updates-2025-26-onwards)
- [Fraud prevention headers (mandatory)](#fraud-prevention-headers-mandatory)
- [Field mapping — verified correct](#field-mapping--verified-correct)
    - [How it was checked](#how-it-was-checked)
    - [Self-employment — 18 of 18 correct](#self-employment--18-of-18-correct)
    - [UK property — 13 of 13 correct](#uk-property--13-of-13-correct)
    - [The two mappings that route against intuition, and are right](#the-two-mappings-that-route-against-intuition-and-are-right)
    - [The nastiest trap in UK property tax — handled](#the-nastiest-trap-in-uk-property-tax--handled)
    - [Fields we do not send, and why each is fine](#fields-we-do-not-send-and-why-each-is-fine)
    - [Structural notes](#structural-notes)
    - [Sources](#sources)

<!-- tocstop -->

## What this connector consists of

| Component | Location | What it does |
|---|---|---|
| OAuth flow | `app/services/hmrc/oauth.rb` | Connects the entity to HMRC via Government Gateway login |
| API client | `app/services/hmrc/client.rb` | Fetches obligations, submits quarterly updates |
| Payload builder | `app/services/hmrc/payload_builder.rb` | Converts bookkeeping totals into the JSON structure HMRC expects |
| Submission storage | `app/services/filing/storage.rb` | Archives the submitted HTML to object storage for audit — regime-agnostic (`Filing::Storage`), would serve a future VAT/EUER filing unchanged |
| Filing service | `app/services/filing/hmrc_mtd.rb` | Implements the `Filing::Base` interface for HMRC MTD |
| Filing controller | `app/controllers/filing_controller.rb` | Generic HTTP layer; dispatches to the right filing service |
| Views | `app/views/filing/` | Periods page, preview, submission record |
| Mailer | `AdminMailer#filing_submitted` | Confirmation email after a successful submission, to any authority |
| Fraud prevention headers | `app/services/hmrc/fraud_prevention_headers.rb` + the collector inside `app/javascript/scripts/tax.js` | HMRC-mandated `Gov-Client-*` / `Gov-Vendor-*` headers on every call — see below |
| Credentials | `hmrc.sandbox.*`, `hmrc.production.*`, `hmrc.vendor.*` in `credentials.yml.enc` | OAuth client id/secret (sandbox and production) and vendor identity for the fraud prevention headers |
| API field mapping | `api_field` on each catalogue row | Maps a category to the exact JSON field HMRC expects, deliberately not a separate mapping file — a second list of category keys could silently drift from the catalogue and omit one |

## Applying to HMRC

<!-- TODO: write the walk-through together — Developer Hub screens, the production
     credentials application and what HMRC asks to see, plus not-again.eu's own
     dated status. The facts below are checked against the code and can stand
     meanwhile. -->

⚠️ **Not written yet** — the walk-through through HMRC's own screens is still to do. What is
settled, and true of any installation:

- **Every installation applies for itself.** Credentials identify *you* as the vendor, so they do
  not transfer from this one, and there is nothing to copy into your own build.
- **Two sets exist, sandbox and production**, held in `credentials.yml.enc` as `hmrc.sandbox.*`
  and `hmrc.production.*`. The app decides which it is by whether a production client id is
  present (`Hmrc::Config::SANDBOX`), so a sandbox installation needs no flag of its own.
- **There is no environment-variable fallback for the client id and secret**, deliberately —
  `Hmrc::Config.client_id` raises without them. Filing therefore belongs to the self-hosted
  route; the [hosted route](scalingo.md) cannot file, which is what that page's opening warning
  says.
- **The vendor identity for the fraud-prevention headers is separate** (`hmrc.vendor.*`) and
  appears in every call — see [Fraud prevention headers](#fraud-prevention-headers-mandatory).

## Cumulative quarterly updates (2025-26 onwards)

From tax year 2025-26, HMRC MTD quarterly updates are **cumulative**: each submission carries the totals for the whole tax year *to date* (tax-year start → the quarter's end date), and each submission supersedes the previous one. A correction to an earlier quarter is simply picked up by the next cumulative update — no resubmission, no explanation, unlike MTD VAT (which stays per-period).

`Filing::HmrcMtd#cumulative_start` derives the range for a given quarter:

- **2025-26 onward:** the start is read from HMRC's own obligations — the earliest period start in the same tax year, classified by *end* date so a 1 April calendar-quarter start isn't misfiled into the prior year — falling back to the computed 6 April boundary if obligations are unavailable. The payload, the archived HTML, and the periods-page preview all use this cumulative range, so all three match exactly what HMRC receives.
- **2024-25 and earlier:** unchanged — each submission covers only its own quarter.

The 2025-26 boundary and tax-year arithmetic live in one place, `Hmrc::TaxYear`, shared by the client (endpoint selection) and the filing service (date range).

Standard quarters run 6 April–5 July and so on; calendar quarters run 1 April–30 June and so on, and only benefit a business whose accounting period runs 1 April to 31 March. We consume whatever periods the Obligations API returns, so a customer already on calendar quarters is served correctly today.

Making the *election*, however, is something only software can do. HMRC's service guide is explicit that it cannot be done through HMRC online services: quarterly updates default to standard, and the only route to calendar is a `Create and Amend Quarterly Period Type for a Business` call (`PUT …/details/{nino}/{businessId}/{taxYear}`, body `{"quarterlyPeriodType": "standard"|"calendar"}`), which must be made before the tax year's first quarterly update and locks for that year afterwards. Not yet offered: the app only reads whatever quarterly period type HMRC already has on file (for display), it never sets one.

## Fraud prevention headers (mandatory)

HMRC legally requires a set of **fraud prevention headers** (`Gov-Client-*` / `Gov-Vendor-*`) on every MTD API call, describing where the request originated. Production access is not granted until HMRC has reviewed sandbox traffic and confirmed the headers are present and accurate.

This app uses the **"web application via server"** connection method (16 headers). They are assembled by `Hmrc::FraudPreventionHeaders` and attached in `Hmrc::Client#request_json` — deliberately **inside the HMRC client only**, so no other authority's client (a future ELSTER/ESTV integration) ever sends them.

| Source | Headers |
|---|---|
| Collected in the browser (`scripts/tax.js` → `gov_client_data` cookie; Device-ID persisted in `localStorage`) | device ID, browser user-agent, timezone, screens, window size |
| Set server-side (request + session + config) | connection method, public IP + port + timestamp, user IDs, multi-factor (`TOTP`, read from the OTP-verified session), and the `Gov-Vendor-*` set |

Vendor identity lives in `Hmrc::Config` — `PRODUCT_NAME`, `SOFTWARE_VERSION` (bump per release), and two credentials:

```yaml
hmrc:
  vendor:
    public_ip: 203.0.113.10    # this server's public IP → Gov-Vendor-Public-IP + the "by=" of Gov-Vendor-Forwarded
    license_id: <optional>     # falls back to a stable hash of product+version if unset
```

Validate against HMRC's own checker before applying for production:

```
bin/rails hmrc:fph_validate
```

It scores the current headers via HMRC's Test Fraud Prevention Headers API and prints `VALID_HEADERS` or a per-header list of problems. Run it **inside the deployed container** (`kamal app exec` locally, or `docker exec` on the server) so the outbound IP matches `Gov-Vendor-Public-IP`, and subscribe the developer-hub app to *Test Fraud Prevention Headers* first.

## Field mapping — verified correct

**Date:** 2026-08-18
**Question asked:** does every figure we send land in the box HMRC expects?
**Answer: yes.** All 31 mappings verified against HMRC's own JSON schemas. No corrections needed.

This was the one review worth doing before applying for production access, because the failure it
looks for is silent: a submission accepted with money in the wrong box produces no error, no
warning, and the wrong tax.

### How it was checked

Not against the rendered developer-hub pages, which are incomplete for the cumulative endpoints —
against the machine-readable schemas HMRC publishes:

- `hmrc/self-employment-business-api` →
  `resources/public/api/conf/5.0/schemas/createAmendCumulativePeriodSummary/request.json`
- `hmrc/property-business-api` →
  `resources/public/api/conf/6.0/schemas/uk_property_cumulative_summary_create_and_amend/def1/request.json`

Our side: `db/tax_categories/gb_self_employment_2026.yml` and `gb_property_2026.yml` (the
`api_field` and `api_section` keys), routed by `Hmrc::PayloadBuilder`.

### Self-employment — 18 of 18 correct

`periodIncome`: `turnover`, `other`, `taxTakenOffTradingIncome`
`periodExpenses`: `costOfGoods`, `paymentsToSubcontractors`, `wagesAndStaffCosts`,
`carVanTravelExpenses`, `premisesRunningCosts`, `maintenanceCosts`, `adminCosts`,
`businessEntertainmentCosts`, `advertisingCosts`, `interestOnBankOtherLoans`, `financeCharges`,
`irrecoverableDebts`, `professionalFees`, `depreciation`, `otherExpenses`

Every name exact. The only field HMRC offers that we do not use is `consolidatedExpenses` — the
single-figure alternative for small businesses, deliberately out of scope.

### UK property — 13 of 13 correct

`income`: `periodAmount`, `premiumsOfLeaseGrant`, `reversePremiums`, `otherIncome`, `taxDeducted`
`expenses`: `premisesRunningCosts`, `repairsAndMaintenance`, `financialCosts`,
`residentialFinancialCost`, `professionalFees`, `costOfServices`, `travelCosts`, `other`

Every name exact. Wrapper key `ukProperty` for the cumulative model, `ukNonFhlProperty` for the
legacy per-period endpoint — both correct.

### The two mappings that route against intuition, and are right

`tax_taken_off` in BOTH schemes carries `section: other` but `api_section: income`. That is
deliberate and correct:

- `section` says what the figure IS — money already handed to HMRC on your behalf, not income —
  and keeps it out of the report's income total.
- `api_section` says where the PAYLOAD puts it, and HMRC files it inside the income object.

Confirmed against both schemas: `taxTakenOffTradingIncome` sits in `periodIncome`, `taxDeducted`
sits in `ukProperty.income`. If these two ever drift apart, reports and submissions will disagree
and neither will look wrong.

### The nastiest trap in UK property tax — handled

Residential finance costs (mortgage interest on a let home) are NOT deductible as an expense; they
get a basic-rate tax reducer instead. Commercial property finance costs are fully deductible. HMRC
has two separate fields and putting the money in the wrong one over-claims relief.

The catalogue handles it properly:

| key | label | box | api_field |
|---|---|---|---|
| `loan_interest` | Non-residential property finance costs | 26 | `financialCosts` |
| `residential_finance_costs` | Residential property finance costs | 44 | `residentialFinancialCost` |

Keywords route "mortgage interest" and "mortgage" to the residential one, "commercial mortgage" to
the other. Box references match SA105. Nothing to change.

### Fields we do not send, and why each is fine

**`periodDisallowableExpenses`** (self-employment, a whole top-level object) — expenses that are
genuinely business but not deductible for tax: depreciation, client entertaining.

**Investigated and dismissed.** HMRC's guidance is explicit: *"A quarterly update is not a tax
return and you do not need to make any accounting or tax adjustments before sending it."*
Disallowable expenses are listed as an END-OF-YEAR adjustment, made after the final quarterly
update. Our in-year-only scope lines up with that exactly.

⚠️ Worth keeping straight, because the two get confused: **private-use splitting is not the same
thing.** Splitting a phone or water bill 40/60 means only the business share ever becomes an
expense — the private share never enters the books at all. Disallowable means 100% business AND
still not deductible. The split does not cover depreciation or entertaining — and does not need to:
those are a year-end adjustment, same as disallowable expenses generally, not an in-year one.

**`residentialFinancialCostsCarriedForward`** — unused residential finance relief brought forward.
Also a year-end adjustment. Out of scope for the same reason.

**`consolidatedExpenses`** (both schemes) — deliberate scope choice.

**`rentARoom`** (property, in both income and expenses) — the only genuine coverage gap, and a
small one. Rent-a-Room income has no category, so someone letting a room in their own home has
nowhere obvious to put it. Note it is a NESTED object (`{ rentsReceived: ... }`), and
`PayloadBuilder` produces flat `field: amount` pairs only — so this is not a catalogue row away,
it needs the builder's shape to change. Low priority: reopen if a real user has Rent-a-Room income.

### Structural notes

- `PayloadBuilder` is field-agnostic — it reads `api_field` and `api_section` off the catalogue
  row and does no mapping of its own. Adding or correcting a box is a YAML edit, not a code
  change. That is the right shape and it is why this review was cheap.
- `next if amount.zero?` omits zero figures. Safe under the cumulative model, where each PUT
  replaces the whole year-to-date record, so an omitted field is an absent field is zero. It
  would NOT be safe under a merge-style API — worth remembering if a future authority merges.
- Top level, both schemas: nothing is required for self-employment; only `ukProperty` is required
  for property. So the nil-return fallbacks (`periodIncome: { turnover: 0.0 }` and
  `income: { periodAmount: 0.0 }`) are valid bodies, not workarounds.

### Sources

- https://raw.githubusercontent.com/hmrc/self-employment-business-api/main/resources/public/api/conf/5.0/schemas/createAmendCumulativePeriodSummary/request.json
- https://raw.githubusercontent.com/hmrc/property-business-api/main/resources/public/api/conf/6.0/schemas/uk_property_cumulative_summary_create_and_amend/def1/request.json
- https://www.gov.uk/guidance/use-making-tax-digital-for-income-tax/send-quarterly-updates
- https://www.gov.uk/guidance/use-making-tax-digital-for-income-tax/adjust-your-self-employment-and-property-income
