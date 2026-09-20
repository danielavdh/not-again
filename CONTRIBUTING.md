# Contributing

## House style

The conventions here are deliberate and consistent, and a patch that ignores them will look wrong even where it works.

**No framework JavaScript.** No Turbo, no Stimulus, no Bootstrap. Vanilla JS only, with TomSelect as the single exception. Listeners are centralised — `attachListeners` in `app/javascript/scripts/index.js`, using the delegate pattern — rather than scattered per page. Read `backend.js`, `scripts/index.js`, `scripts/utils.js` and `scripts/accounts.js` before writing any.

**No HTML in JavaScript.** Markup belongs in ERB. A script that needs new markup either fetches a server-rendered partial —

```js
fetch(url, { headers: { Accept: 'text/html' } })
```

— see the add-account modal in `accounts.js`, or clones a `<template>` written in ERB, see the posting template. Never build markup with template strings. The one exception is data with no server-side record yet, such as rows for an unsaved posting, and even then: build DOM nodes and set `textContent`, never `innerHTML`.

**No utility classes.** An element gets a class or an id only when something actually uses it — an SCSS mixin, or a listener in `index.js`. Spacing and layout live in the SCSS, using the existing variables and mixins: `@new_edit_view_form` for forms, `@backend_table` for data tables, `@tom_select`, `@crud_navigation` and `@date_select` for those components. Prefer semantic elements (`<nav>`, `<main>`, `<section>`, `<header>`) over classed `<div>`s, and prefer a `role=` attribute over swapping a tag, because a tag swap silently changes what the SCSS and the JS are selecting.

**Queries stay in the database.** Calculations and filtering are done in SQL or ActiveRecord, not by loading a collection into Ruby and iterating it. Reports here run over years of postings across several entities and currencies; the difference is not stylistic. `test/integration/query_budget_test.rb` pins the query count on the heaviest pages, so an accidental N+1 fails the suite rather than being noticed in production.

**Logic belongs in models and controllers.** Not in views, and not in helpers either — a helper is still a view. Before writing one, ask whether a model, a controller or a service should own it. Standard Rails.

---

### External dependencies

None at runtime. The app serves every asset it uses; nothing is fetched from a CDN, a font host or a package registry while it runs. That is deliberate — it is what makes the app work on a private network, survive someone else's outage, and keep a Content-Security-Policy that names only your own origins.

Two sets of third-party assets are vendored to make that true: **TomSelect** (below) and the **fonts** in `app/assets/fonts/`. Both, with their licences and everything the container image bundles, are itemised in [`THIRD-PARTY.md`](THIRD-PARTY.md).

TomSelect and both halves of it:

| Asset | Where it lives | How it loads |
|---|---|---|
| TomSelect JS (ESM, v2.3.1) | `vendor/javascript/tom-select.js` | pinned in `config/importmap.rb`, imported on demand |
| TomSelect CSS (Bootstrap5 theme) | `app/assets/stylesheets/tom-select.bootstrap5.min.css` | `stylesheet_link_tag` in the views that need it |

The JS is genuinely lazy: it is not in the layout, and `app/javascript/scripts/tomselect_helper.js` calls `await import('tom-select')` only when a page actually contains a select to enhance. The stylesheet is pulled in per view by a `content_for :head` block, in the six views that use it — bank entry, transfer entry, journal entry new/edit, the entity form, and the admin page.

The Bootstrap5 theme is a structural base only; the visual styling is fully overridden by the project's own `@mixin tomselect` in `app/assets/stylesheets/backend/_config.scss`. Upgrading TomSelect therefore means replacing both vendored files and re-checking that mixin — there is no version number in a URL to bump.

---

## Licensing — read this before your first pull request

not-again ships under **AGPL-3.0** (see `LICENSE`). Contributions, though, are accepted **inbound under a broader grant** — see [`CLA-individual.md`](CLA-individual.md) for the full text. In short: you keep your copyright, but you grant the project the right to relicense your contribution under any license it chooses, including a more permissive one, in the future.

**Why**: AGPL → a more permissive license is a decision the project can only make with *every* contributor's agreement, or it can't be made at all — one unreachable person blocks it forever. The CLA settles that in advance, once, at contribution time, rather than requiring it be tracked down later.

**How to sign it**: open your pull request as normal. A bot will comment asking you to confirm. Reply with exactly:

```
I have read the CLA Document and I hereby sign the CLA
```

That's the whole process — no separate form, no email. It only has to be done once; the bot remembers.

---
