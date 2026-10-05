import Accounts from "scripts/accounts";
import { setupFlashMessages, delegate, isTouchDevice, showElementSmoothly, hideElementSmoothly, showTransientStatus, initModals, toggleLanguageBar, debounce } from "scripts/utils";
import { TaxMapping, TaxSetup, HmrcFraudPrevention } from "scripts/tax";
import TomSelectHelper from "scripts/tomselect_helper";
import CellSum from "scripts/cell-sum";

/* Authority-specific browser collectors, keyed by the name the server sends.
   See initAccounts below. */
const BROWSER_COLLECTORS = {
  hmrc_fraud_prevention: HmrcFraudPrevention
};

const vdh = {

//  get lang() {
//    return document.body.dataset.locale || "en";
//  },
  initBackend() {
	/* for small screen, to click away flash messages */
	setupFlashMessages();
	toggleLanguageBar();
	initModals();
	this.attachListeners();
	const loginName = document.getElementById("loginName");
    if (loginName) loginName.focus();
	if (/admins\/\d+$/.test(location.pathname)) {
	  /* Initialize TomSelect on all elements with data-tomselect in admin/show */
	  TomSelectHelper.init();
	}
  },
  initAccounts(){
	/* This used to be gated on the host matching "accounts", from when the app
	   lived on a subdomain of a larger site. There is one host now, and the
	   test was silently false everywhere else — including localhost. */
	{
		Accounts.init();
		TaxMapping.init();
		TaxSetup.init();
		CellSum.init();
		/* Browser-side data an authority requires, started ONLY where the server
		   says one is wanted, and looked up by NAME rather than tested for.

		   The server decides — Filing::Base.browser_collector returns the
		   name, the page carries it as data-browser-collector — so a business
		   filing in Germany, or filing nowhere at all, never runs HMRC's
		   fingerprint collector. It used to run on every page for everyone.

		   BROWSER_COLLECTORS is the registry, and the JS counterpart of
		   Filing::Base::CONNECTORS: it is the one place in generic code
		   that may name an authority, because naming it IS the wiring. A second
		   authority wanting browser data adds one line here and nothing else. */
		const el = document.querySelector('[data-browser-collector]');
		const collector = el && BROWSER_COLLECTORS[el.dataset.browserCollector];
		if (collector) collector.init();
  	}
  },
  attachListeners(){
	/* Safari: date picker doesn't close after selection — blur forces it */
	delegate(document, 'change', 'input[type="date"]', (e, input) => {
	  input.blur();
	});
	/* A select whose chosen option IS a URL — the tax-export backup picker */
	delegate(document, 'change', '[data-navigate-on-change]', (e, select) => {
	  if (select.value) window.location = select.value;
	});
	/* Year-end picker: reveal the day+month chooser only when "Other" is ticked */
	const yearEndPattern = document.querySelector('.form_year_end input[name="pattern"]');
	if (yearEndPattern) {
	  const customField = document.getElementById('year-end-custom');
	  const wantsCustom = () =>
	    document.querySelector('.form_year_end input[name="pattern"]:checked')?.value === 'other';
	  if (customField && !wantsCustom()) customField.classList.add('hidden'); // instant on load, no flash
	  delegate(document, 'change', '.form_year_end input[name="pattern"]', () => {
	    if (!customField) return;
	    wantsCustom() ? showElementSmoothly(customField) : hideElementSmoothly(customField);
	  });
	}
	/* Escape key triggers the cancel/back link in crud_navigation */
	document.addEventListener('keydown', (e) => {
	  if (e.key !== 'Escape') return;
	  if (CellSum.clear()) return;
	  const active = document.activeElement;
	  if (active && ['INPUT', 'TEXTAREA', 'SELECT'].includes(active.tagName)) return;
	  const nav = document.querySelector('.crud_navigation');
	  if (!nav) return;
	  const link = nav.querySelector('a, button');
	  if (link) link.click();
	});
	/* Submission viewer: fetch HTML from server, inject into dialog. Authority
	   agnostic — the button carries both the URL and the dialog's id. */
	delegate(document, 'click', '[data-action="view-submission"]', async (e, btn) => {
	  e.preventDefault();
	  const dialog = document.getElementById(btn.dataset.modal);
	  if (!dialog) return;
	  const content = dialog.querySelector('[data-submission-content]');
	  if (!content) return;
	  /* print the one being shown, not the one just submitted */
	  const print = dialog.querySelector('[data-submission-print]');
	  if (print) print.href = btn.dataset.url;
	  content.replaceChildren();
	  try {
	    const response = await fetch(btn.dataset.url, { headers: { 'X-Requested-With': 'XMLHttpRequest' } });
	    if (!response.ok) throw new Error(response.statusText);
	    content.innerHTML = await response.text();
	  } catch {
	    /* text, not markup — and translated, from the dialog's data attribute */
	    const failed = document.createElement('p');
	    failed.textContent = dialog.dataset.textError;
	    content.replaceChildren(failed);
	  }
	  dialog.showModal();
	});
	/* confirm message before deletes */
	delegate(document, "click", "[data-sure]", (e, button) => {
	  const message = button.dataset.sure;
	  if (!confirm(message)) {
	    e.preventDefault();
	    e.stopPropagation();
	  }
	});
	/* copy a field's current value to the clipboard — languages/_form's
	   yml_content and the four Textile fields, one button each, pointed at
	   its own field by data-target rather than a shared id. The status span
	   is the button's own next sibling (see languages/_copy_button) — a
	   silent clipboard write otherwise gives no feedback at all. */
	delegate(document, "click", "[data-action='copy-language-field']", (e, button) => {
	  const field = document.getElementById(button.dataset.target);
	  if (!field) return;
	  navigator.clipboard.writeText(field.value);
	  const status = button.nextElementSibling;
	  showTransientStatus(status, status?.dataset.copied);
	});
	/* system/custom language toggle: auto-submit on tick/untick, same as
	   the admin preference checkboxes below */
	delegate(document, 'change', "[data-action='toggle-language-menu']", (e, checkbox) => {
	  checkbox.closest('form').requestSubmit();
	});
	/* obscured form links reveal */
	if (isTouchDevice){
		delegate(document, "click", ".obscured", (e, div) => {
		  if (!div.classList.contains('revealed')) {
		    e.preventDefault();
		    div.classList.add('revealed');
		  }
		});
	}
	if (/(profile|admins)/.test(location.pathname)) {
		/* Grant form: the server renders the entity-access block for whoever the
		   identifier belongs to — ticks showing their CURRENT access — and the
		   block says on itself whether anybody was found and what their username
		   is, so the form can fill that in and the two fields agree without the
		   sender having to know it.
		   As it is TYPED, not on leaving the field: both fields are the only
		   things on the page, so there is nothing to move focus to and no reason
		   to click away. `input` rather than keyup so a paste or an autofill
		   counts. The debounce is the shared one, so a long address is one
		   request.
		   ONLY on the address, never on the username. The address is the
		   identity, so nothing about the block depends on the username — and
		   re-fetching replaces the whole block, which would wipe entity ticks
		   already made. A username that is somebody else's is reported by the
		   save instead. The username is still SENT, so a conflict already typed
		   shows up when the address changes. */
		delegate(document, 'input', '#admin_email_address', debounce((e) => {
		  const container = document.getElementById('entity-access-fields');
		  if (!container) return;
		  const emailField = document.getElementById('admin_email_address');
		  const nameField  = document.getElementById('admin_username');
		  const email = emailField?.value.trim() || '';
		  const name  = nameField?.value.trim() || '';
		  /* Ticks already made ride along: swapping the block in would otherwise
		     wipe them if the lookup lands after a quick hand. Sent only when
		     there are some — an empty list would read as "none ticked" and
		     override the ones the server derives from what this person holds. */
		  const ticked = Array.from(
		    document.querySelectorAll('input[name="entity_ids[]"]:checked')
		  ).map((box) => `entity_ids[]=${encodeURIComponent(box.value)}`);
		  const query = [
		    `email=${encodeURIComponent(email)}`,
		    `username=${encodeURIComponent(name)}`,
		    ...ticked
		  ].join('&');
		  fetch(`/admins/access_fields?${query}`, { headers: { Accept: 'text/html' } })
		    .then((r) => r.text())
		    .then((html) => {
		      container.outerHTML = html;
		      /* The address is the identity, so once it resolves THEIR username is
		         the only value this form can submit: it is filled in and locked.
		         Granting changes somebody's access, never their name — a field
		         that cannot be acted on should not invite typing. Unlocked again
		         as soon as the address stops naming anybody, which is when the
		         username becomes a new person's to be given.
		         Not overwritten while they are typing into it, so an unlock
		         followed by typing is never fought. */
		      const found = document.getElementById('entity-access-fields')?.dataset.username;
		      if (!nameField) return;
		      if (found && e.target !== nameField && nameField.value !== found) {
		        nameField.value = found;
		      }
		      nameField.readOnly = !!found;
		    })
		    .catch(() => {}); /* stays as server-rendered on any fetch failure */
		}, 350));
		/* Submitting the grant form will CREATE somebody when the block says so —
		   worth being told before it happens rather than after. Asked HERE
		   rather than armed on the button while typing, because a flag set then
		   is stale as soon as a box is ticked.
		   Only once the form could actually succeed: a username and at least one
		   business. Those are presence checks on the form's own fields, not a
		   copy of any rule — everything else is the server's to judge, and it
		   refuses to create before its own validations pass anyway.
		   The sentence is the server's, already interpolated; the answer goes in
		   a hidden field so the server has the consent too rather than trusting
		   the browser to have asked. */
		delegate(document, 'submit', '#grant_admin', (e, form) => {
		  const block  = document.getElementById('entity-access-fields');
		  const prompt = block?.dataset.createPrompt;
		  if (!prompt) return;

		  const named  = form.querySelector('#admin_username')?.value.trim();
		  const ticked = form.querySelector('input[name="entity_ids[]"]:checked');
		  if (!named || !ticked) return;

		  if (!confirm(prompt)) {
		    e.preventDefault();
		    return;
		  }
		  const consent = document.getElementById('confirm_create');
		  if (consent) consent.value = '1';
		});
		/* journal entries preference: auto-submit on tick/untick */
		delegate(document, 'change', '#admin_show_journal_entries', (e, checkbox) => {
		  checkbox.closest('form').requestSubmit();
		});
		/* report currency preference: auto-submit on change */
		delegate(document, 'change', '#admin_preferred_currency', (e, select) => {
		  select.closest('form').requestSubmit();
		});
		/* number format preference: auto-submit on change */
		delegate(document, 'change', '#admin_preferred_number_format', (e, select) => {
		  select.closest('form').requestSubmit();
		});
		/* high-contrast preference: auto-submit on change (server redirects back) */
		delegate(document, 'change', '#admin_high_contrast', (e, select) => {
		  select.closest('form').requestSubmit();
		});
	}
  }
};

export default vdh;