import { delegate, csrfToken as csrfMeta } from "scripts/utils";

/* Everything the tax side of the app does in the browser. Three separate things
 * that share nothing but a subject, kept in one file because each is short and
 * three files made the directory harder to read than the code.
 *
 *   TaxMapping          assigning accounts to tax categories — the two lists on
 *                       a report group's page, and the note under a select
 *   TaxSetup            the entity's tax setup page: the question a ticked
 *                       scheme asks, the taxpayer picker it fetches, the modal
 *   HmrcFraudPrevention the browser-side values HMRC's fraud prevention headers
 *                       require. HMRC's own spec, hence the name — nothing else
 *                       asks for these
 *
 * Each has its own init and its own guard, so a page that needs none of them
 * pays for none of them.
 */


const TaxMapping = {
  init() {
    if (!document.querySelector('[data-tax-mapping], [data-tax-note]')) return;
    this.attachListeners();

    /* On the account form there is one select and one account, so its note is
     * never ambiguous — show it straight away. Inside a list it would be forty
     * notes for forty rows, so there it waits until you touch a select. */
    document.querySelectorAll('[data-tax-note]').forEach(select => {
      if (!select.closest('[data-tax-mapping]')) this.showNote(select);
    });
  },

  attachListeners() {
    /* + adds an account to the scheme, matching the custom group's picker
     * beside it. There used to be a second surface — a checkbox in a dashboard
     * table — and its handling is gone with it. */
    delegate(document, 'click', 'button[data-tax-confirm]', (e, button) => {
      this.save(button);
    });

    /* Tax report page: changing an assigned account's category saves in place —
     * it stays on the assigned side, only its category changes. */
    delegate(document, 'change', '[data-tax-reassign]', (e, select) => {
      this.patch(select.dataset.url, select.value);
    });

    /* The box's own wording from the form, under whichever select you are
     * touching — and only that one. Forty rows each showing a sentence is not
     * help, it is wallpaper. */
    delegate(document, 'change', '[data-tax-note]', (e, select) => this.showNote(select));

    /* ...and × releases it, so another scheme may claim it. A blank category is
     * what unassigns, and the row crosses to the unassigned side. */
    delegate(document, 'click', '[data-tax-unassign]', (e, button) => {
      button.disabled = true;
      this.patch(button.dataset.url, '')
        .then(ok => {
          if (ok) this.moveRow(button.closest('li'), 'unassigned');
          else    button.disabled = false;
        });
    });
  },

  /* Both lists hold the same row: code, name, a category select, and one control.
   * Only that control and the select's value differ, so a row crosses by swapping
   * them rather than by reloading the page — assigning forty accounts should not
   * mean forty page loads. */
  moveRow(row, destination) {
    if (!row) return;
    const container = document.querySelector('[data-tax-mapping]');
    const list = container?.querySelector(
      destination === 'assigned' ? 'ul.tax-assigned' : 'ul.tax-unassigned'
    );
    if (!list) { window.location.reload(); return; }

    const select  = row.querySelector('select');
    const control = row.querySelector('[data-tax-confirm], [data-tax-unassign]');
    const url     = control?.dataset.url;
    const assigned = destination === 'assigned';

    /* Each control goes where _tax_assignment.html.erb puts it, and the two sides
     * differ: + opens a row so it comes first, × closes one so it sits after the
     * name and before the select. × used to be appended to the end instead, so a
     * row you had just moved carried its cross after the select — and after
     * showNote, after the hint too — while the same row looked right on reload. */
    control?.remove();
    if (assigned) {
      const button = this.unassignButton(url);
      select ? row.insertBefore(button, select) : row.appendChild(button);
    } else {
      row.prepend(this.confirmButton(url, select?.id));
    }

    if (select) {
      if (assigned) {
        select.dataset.taxReassign = 'true';
        select.dataset.url = url;
      } else {
        delete select.dataset.taxReassign;
        select.value = '';
      }
      this.showNote(select);
    }

    list.appendChild(row);
    this.updateCount(assigned ? 1 : -1, '[data-tax-assigned-count]');
    this.updateCount(assigned ? -1 : 1, '[data-tax-remaining]');
    this.clearPlaceholder(list);
  },

  /* The note lives on the chosen <option> as data-note, put there by
   * TaxCategory.grouped_options, so no request is needed to read it. Built
   * fresh each time rather than hidden and shown: an empty styled box waiting
   * under every select is exactly the thing that leaves a gap on the page. */
  showNote(select) {
    const existing = select.parentElement?.querySelector('p.tax-note');
    if (existing) existing.remove();

    const option = select.selectedOptions[0];
    const text   = option?.dataset.note;
    if (!text) return;

    const note = document.createElement('p');
    note.className   = 'tax-note';
    note.textContent = text;
    select.insertAdjacentElement('afterend', note);
  },

  /* Must match the button in _tax_assignment.html.erb exactly — class included,
   * or a row that crosses the lists loses its styling. */
  unassignButton(url) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'remove-account';
    button.dataset.taxUnassign = 'true';
    button.dataset.url = url;
    button.textContent = '×';
    return button;
  },

  /* Must match the button in _tax_assignment.html.erb exactly, class included. */
  confirmButton(url, selectId) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'add-account';
    button.dataset.taxConfirm = 'true';
    button.dataset.url = url;
    button.dataset.selectId = selectId || '';
    button.textContent = '+';
    return button;
  },

  /* "No accounts assigned yet" / "Every account has a category" sit beside an
   * empty list; once something lands there they are no longer true. */
  clearPlaceholder(list) {
    const hint = list.parentElement?.querySelector('p.hint + ul, p.hint');
    if (hint && hint.tagName === 'P' && list.children.length > 0 &&
        !hint.dataset.keep) hint.remove();
  },

  patch(url, combined) {
    const csrfToken = csrfMeta();
    return fetch(url, {
      method: 'PATCH',
      headers: { 'X-CSRF-Token': csrfToken, 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ tax_category_combined: combined }).toString()
    })
      .then(r => r.json())
      .then(data => !!data.ok)
      .catch(() => false);
  },

  /* Nothing is saved until a category has been chosen — the auto-assigner's
   * guess is only ever a suggestion sitting in the select. */
  save(button) {
    const select = document.getElementById(button.dataset.selectId);
    if (!select || !select.value) return;

    button.disabled = true;

    this.patch(button.dataset.url, select.value).then(ok => {
      if (ok) this.moveRow(button.closest('li'), 'assigned');
      else    button.disabled = false;
    });
  },

  updateCount(delta, selector) {
    const counter = document.querySelector(selector);
    if (!counter) return;
    const current = parseInt(counter.textContent, 10);
    counter.textContent = Math.max(0, current + delta);
  }
};


/* ────────────────────────────────────────────────────────────────── */


/* The tax setup page (entities#edit_tax).
 *
 * Ticking a scheme that can actually be FILED asks whether you submit from here
 * or only need the figures. On yes, that authority's taxpayer picker is fetched
 * and slotted into the form — nothing is saved. The page keeps its ONE Save,
 * which is the whole point: two commit points here once silently discarded an
 * unticked scheme, and a modal that saved would have brought that back.
 *
 * The question is per AUTHORITY, not per scheme: one login covers every scheme
 * behind it, so ticking property and self-employment asks once.
 */
const TaxSetup = {
  init() {
    if (!document.getElementById("filing-fields")) return;
    this.attachListeners();
  },

  attachListeners() {
    /* Only submittable schemes carry data-authority — the rest stop at tagging
     * and export, so there is nothing to ask.
     *
     * confirm(), not a block on the page: the question has to be answered before
     * anything else happens. A block further down can be walked past, and you
     * could then Save a return that files from the app with nobody to file it
     * for. Same convention as data-sure. OK opens the modal straight away, so by
     * the time you reach Save the whole setup is in. */
    delegate(document, 'change', '#entity-tax-schemes-field input[type="checkbox"]', (e, box) => {
      const key = box.dataset.authority;
      if (!key) return;

      /* Untick: if no other scheme of this authority is still ticked, its block
       * has nothing left to ask — take it off the page. Re-ticking fetches it
       * again. Cosmetic; Save and reload already rebuild from saved schemes. */
      if (!box.checked) {
        if (!document.querySelector(`[data-authority="${key}"]:checked`)) {
          this.pickerBlock(key)?.remove();
        }
        return;
      }

      /* Already on the page means already answered — one taxpayer per authority,
       * so one question. */
      if (this.pickerFor(key)) return;

      if (!confirm(box.dataset.submitQuestion)) return;
      this.addPicker(key);
    });

    /* The "Choose a taxpayer above" line is server-rendered from the taxpayer
     * SAVED on the groups, so it stays put when you pick one in the select
     * (nothing persists until the page's Save). Hide it the moment the select
     * has a value; show it again if you clear it. */
    delegate(document, 'change', '[data-taxpayer-picker]', (e, select) => {
      this.togglePendingHint(select.dataset.taxpayerPicker);
    });

    /* Beside a picker: change your mind later, or set up a second client. */
    delegate(document, 'click', '[data-taxpayer-add]', (e, button) => {
      this.openModal(button.dataset.url, button.dataset.taxpayerAdd);
    });

    /* In the modal: from the chooser to the add-a-taxpayer form. */
    delegate(document, 'click', '[data-taxpayer-new]', (e, button) => {
      this.loadModal(button.dataset.url);
    });

    /* In the modal: take the one already on file. Saves nothing — it fills the
     * picker, and the tax setup still waits for the page's one Save. */
    delegate(document, 'click', '[data-taxpayer-use]', (e, button) => {
      const chosen = document.getElementById('choose_taxpayer_id');
      const select = this.pickerFor(button.dataset.taxpayerUse);
      if (chosen && select) select.value = chosen.value;
      this.togglePendingHint(button.dataset.taxpayerUse);
      document.getElementById('add-taxpayer-modal')?.close();
    });

    delegate(document, 'click', '.add-taxpayer-cancel', () => {
      document.getElementById('add-taxpayer-modal')?.close();
    });

    /* Saves the TAXPAYER only — a record of its own. The scheme is still just a
     * tick until Save. */
    delegate(document, 'submit', '#add-taxpayer-modal form', async (e, form) => {
      e.preventDefault();
      const errors = document.getElementById('add-taxpayer-errors');
      try {
        const response = await fetch(form.action, {
          method: 'POST',
          headers: { Accept: 'application/json', 'X-CSRF-Token': this.csrfToken() },
          body: new FormData(form)
        });
        if (response.ok) {
          this.selectNewTaxpayer(await response.json());
          document.getElementById('add-taxpayer-modal')?.close();
        } else {
          const data = await response.json().catch(() => ({}));
          if (errors) {
            errors.textContent = (data.errors || ['—']).join('; ');
            errors.hidden = false;
          }
        }
      } catch (err) {
        console.error('taxpayer save failed', err);
      }
    });
  },

  /* The authority's block, server-rendered like every other partial this app
   * injects, then the modal on top of it. An empty reply means the scheme cannot
   * be filed or its authority is already here.
   *
   * The block is what POSTS the choice, so it has to exist before the modal can
   * fill it — which is why it is fetched first and not instead. */
  async addPicker(key) {
    const fields = document.getElementById('filing-fields');
    const box    = document.querySelector(`[data-authority="${key}"]:checked`);
    if (!fields || !box) return;

    try {
      const url = `${fields.dataset.url}?scheme=${encodeURIComponent(box.value)}`;
      const response = await fetch(url, { headers: { Accept: 'text/html' } });
      if (response.status === 204) return;

      fields.insertAdjacentHTML('beforeend', await response.text());
      this.openModal(this.pickerBlock(key)?.querySelector('[data-taxpayer-add]')?.dataset.url, key);
    } catch (err) {
      console.error('filing fields fetch failed', err);
    }
  },

  /* Always the chooser, never straight to the form: with nobody on file it shows
   * only "add", and with taxpayers on file you would otherwise be made to type a
   * client in again. */
  async openModal(url, key) {
    const modal  = document.getElementById('add-taxpayer-modal');
    const errors = document.getElementById('add-taxpayer-errors');
    if (!modal || !url) return;

    this._pendingAuthority = key;
    if (errors) errors.hidden = true;

    await this.loadModal(url);
    if (!modal.open) modal.showModal();
  },

  async loadModal(url) {
    const content = document.getElementById('add-taxpayer-content');
    if (!content || !url) return;

    try {
      const response = await fetch(url, { headers: { Accept: 'text/html' } });
      content.innerHTML = await response.text();
      content.querySelector('input[type="text"], select')?.focus();
    } catch (err) {
      console.error('taxpayer form fetch failed', err);
    }
  },

  /* An <option> is data with no server-side markup to fetch — built as a node
   * with textContent, never as a string of HTML. */
  selectNewTaxpayer(taxpayer) {
    const select = this.pickerFor(this._pendingAuthority);
    if (!select) return;

    const option = document.createElement('option');
    option.value = String(taxpayer.id);
    option.textContent = taxpayer.display_name;
    select.appendChild(option);
    select.value = option.value;
    this.togglePendingHint(this._pendingAuthority);
  },

  /* Show the "choose a taxpayer" line only while this authority's select is
   * blank. Nothing to do when the taxpayer is already saved — the server did
   * not render the line at all. */
  togglePendingHint(key) {
    const select = this.pickerFor(key);
    const hint   = document.querySelector(`[data-taxpayer-pending="${key}"]`);
    if (select && hint) hint.hidden = select.value !== '';
  },

  pickerFor(key)   { return document.getElementById(`filing_${key}_taxpayer_id`); },
  pickerBlock(key) { return this.pickerFor(key)?.closest('fieldset'); },
  csrfToken()      { return csrfMeta(); }
};


/* ────────────────────────────────────────────────────────────────── */

/*
 * Collects the browser-side values HMRC requires in its fraud prevention
 * headers (web-application-via-server connection method) and stores them in a
 * cookie, which the server reads on the next request to build the headers.
 *
 * Only the five browser-dependent values live here; the server sets the rest
 * (IPs, ports, vendor identity, timestamps). Device-ID must persist across
 * sessions, so it is kept in localStorage and reused.
 *
 * Spec: developer.service.hmrc.gov.uk/guides/fraud-prevention/connection-method/web-app-via-server/
 */
const HmrcFraudPrevention = {
  init() {
    try {
      this.writeCookie();
    } catch (e) {
      /* never let header collection break the page */
    }
  },

  deviceId() {
    let id = localStorage.getItem("gov_client_device_id");
    if (!id) {
      id = (crypto.randomUUID && crypto.randomUUID()) || this.uuidFallback();
      localStorage.setItem("gov_client_device_id", id);
    }
    return id;
  },

  uuidFallback() {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = (Math.random() * 16) | 0;
      return (c === "x" ? r : (r & 0x3) | 0x8).toString(16);
    });
  },

  timezone() {
    const offset = -new Date().getTimezoneOffset(); // minutes east of UTC
    const sign = offset >= 0 ? "+" : "-";
    const abs = Math.abs(offset);
    const hh = String(Math.floor(abs / 60)).padStart(2, "0");
    const mm = String(abs % 60).padStart(2, "0");
    return `UTC${sign}${hh}:${mm}`;
  },

  data() {
    return {
      device_id: this.deviceId(),
      user_agent: navigator.userAgent,
      timezone: this.timezone(),
      screens:
        `width=${screen.width}&height=${screen.height}` +
        `&scaling-factor=${window.devicePixelRatio || 1}&colour-depth=${screen.colorDepth}`,
      window_size: `width=${window.innerWidth}&height=${window.innerHeight}`,
    };
  },

  writeCookie() {
    const value = encodeURIComponent(JSON.stringify(this.data()));
    document.cookie = `gov_client_data=${value}; path=/; SameSite=Lax`;
  },
};

export { TaxMapping, TaxSetup, HmrcFraudPrevention };
