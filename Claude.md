### CORE ARCHITECTURE & CONSTRAINTS
- **Stack:** Rails 8.1 hosted on Hetzner.
- **Memory:** All database operations MUST be memory-conscious. 
    - **Rule:** Use SQL/ActiveRecord for calculations and filtering. Avoid loading large collections into Ruby memory for processing.
- **Frontend Philosophy:** No Turbo, No Stimulus, No Bootstrap. 
    - **JavaScript:** Vanilla JS only (except TomSelect). Follow the existing delegate pattern and centralized `attachListeners` in `scripts/index.js`.
    - **CSS:** DartSass with custom mixins. No unnecessary classes or IDs. If an element doesn't have specific styling or JS attached, keep it clean.
	  - **NO HTML IN JAVASCRIPT.** Markup belongs in ERB partials. JS fetches a server-rendered partial (fetch(url, { headers: { Accept: 'text/html' } })) and injects it — see the add-account modal in accounts.js — or clones a <template> written in ERB — see posting-template. Never build markup with template strings. The only exception is data with no server-side record yet (e.g. rows for an unsaved posting), and even then build DOM nodes and set textContent, never innerHTML.
