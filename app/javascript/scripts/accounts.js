import { showElementSmoothly, hideElementSmoothly, showTransientStatus, delegate, parseAmountToCents, formatAmountFromCents, csrfToken} from "scripts/utils";
import TomSelectHelper from "scripts/tomselect_helper";
import Receipts from "scripts/receipts";
import { setupReportGroupAccountSelector } from "scripts/accounts-drag-drop";

let filterTimeout = null;

const Accounts = {
	_modalListenersAttached: false,
	_splitSourceRow: null,
	_splitIsReEdit: false,
	async init(){
		/* If this is the popup_saved response inside an iframe, 
		 * notify parent and stop */
		if (document.body.dataset.popupSaved) {
		  window.parent.postMessage('saved', location.origin);
		  return;
		}
		/* Initialize TomSelect on all elements with data-tomselect */
		await TomSelectHelper.init();
		
		this.attachListeners();
		this.initModal();
		this.setupReconcileModal();
		this.setupSplitModal();
		this.setupAccountsFilter();
		this.setupJournalEntriesFilter();
		if (/(create|edit|update|copy)/.test(location.pathname)){
			const balanceEl = document.getElementById("balance-amount");
			if (balanceEl){
				this.calculateBankBalance();
			}
		}
		const parentSelectEl = document.getElementById('account_parent_id');
		if (parentSelectEl?.value) this.lockCurrencyFromParent(parentSelectEl);
		if (document.getElementById('transfer_entry_form')) {
		    this.updateTransferCurrencies();
		}
		this.groupPairedPostings();
		if (/(ledger|withdrawal|deposit|journal_entries|receipts)/.test(location.pathname) || document.getElementById('receipt-upload-modal')) {
		  Receipts.init();
		}
	},
	attachListeners(){
		delegate(document, "click", "#print-button", (e, btn) => {
			e.preventDefault();
			window.print();
		});
		/* accounts index: the type/currency/balance cells navigate to the ledger.
		   The name cell is already a real link; the actions cell has its own buttons. */
		delegate(document, 'click', 'td[data-href]', (e, cell) => {
			window.location.href = cell.dataset.href;
		});
		/* only show accounts from same account_type as potential parents */
		delegate(document, 'change', '#account_code', (e, input) => {
			const code = input.value;
			if (code.length < 1) return;

			const typeDigit = code.charAt(0);
			const parentSelect = document.getElementById('account_parent_id');
			if (!parentSelect) return;

			const previousParentId = parentSelect.value;
			/* Keep the blank option the server rendered rather than writing one
			   here — its label is translated (include_blank in the account form). */
			const blankOption = parentSelect.querySelector('option[value=""]');
			fetch(`/accounts/parents_for_type?type=${typeDigit}`)
			.then(r => r.json())
			.then(accounts => {
				parentSelect.replaceChildren();
				if (blankOption) parentSelect.append(blankOption);
				accounts.forEach(a => {
					const opt = document.createElement('option');
					opt.value = a.id;
					opt.textContent = `${a.code} - ${a.name}`;
					if (a.currency) opt.dataset.currency = a.currency;
					parentSelect.appendChild(opt);
				});
				if (previousParentId) parentSelect.value = previousParentId;
				this.lockCurrencyFromParent(parentSelect);
			});
		});
		/* Account form: lock currency to parent's when a parent is selected */
		delegate(document, 'change', '#account_parent_id', (e, select) => {
			this.lockCurrencyFromParent(select);
		});
		/* Split transaction hover - show details */
		delegate(document, 'mouseover', '.transaction-type-split', (e, span) => {
			const jeId = span.getAttribute('data-je-id');
			const details = document.getElementById(`split-${jeId}`);
			if (details) {
				showElementSmoothly(details);
			}
		});
		delegate(document, 'mouseout', '.transaction-type-split', (e, span) => {
			const jeId = span.getAttribute('data-je-id');
			const details = document.getElementById(`split-${jeId}`);
			if (details) {
				hideElementSmoothly(details);
			}
		});
		/* Add Posting Button Listener */
		delegate(document, 'click', '#add-posting, #add-bank-posting', (e, btn) => {
			e.preventDefault();
			
			const isBank = btn.id === 'add-bank-posting';
			const tableId = isBank ? 'bank-postings-table' : 'postings-table';
			const templateId = isBank? 'bank-posting-template' : 'posting-template';

			const tbody = document.querySelector(`#${tableId} tbody`);
			const template = document.getElementById(templateId);
			if (!tbody || !template) return;

			const index = new Date().getTime();
			const rowCount = tbody.querySelectorAll('tr').length;
			const rowClass = rowCount % 2 === 0 ? 'list-line-odd' : 'list-line-even'; 
    
			/* Replace the placeholder with the unique index */
			let html = template.innerHTML.replace(/NEW_INDEX/g, index);
			html = html.replace('posting-row', `posting-row ${rowClass}`);
			tbody.insertAdjacentHTML('beforeend', html);

			/* Initialize TomSelect on newly added elements */
			const newRow = tbody.lastElementChild;
			TomSelectHelper.initInContainer(newRow);
			
			if (isBank){
				const newSelect = newRow.querySelector('[data-tomselect]');
				if (newSelect){
					const instance = TomSelectHelper.getInstance(newSelect);
					if (instance){
						instance.on('change', () => this.calculateBankBalance())
					};
				}
				this.calculateBankBalance();
			}
		});
		/* Hide row when destroy checkbox is checked */
		delegate(document, 'change', '.posting-destroy', (e, checkbox) => {
		  const row = checkbox.closest('tr');
		  if (!row) return;
		  if (checkbox.checked) {
		    hideElementSmoothly(row);
		  }
		  if (document.getElementById('bank-postings-table')) {
		    this.calculateBankBalance();
		  }
		});
		/* Select all text when clicking into an amount cell */
		delegate(document, 'focusin', '.posting-amount', (e, input) => {
			setTimeout(() => input.select(), 0);
		});
		/* Leaving an amount field: show it back in the format the app actually
		   read, so "10" becomes "10.00" / "10,00" and a mistyped separator is
		   visible BEFORE saving, not after. Same parser the server uses
		   (parseAmountToCents mirrors CurrencyConfig#parse_to_cents) — WYSIWYG,
		   which is the point of audit finding M1. Readonly rows (cross-entity,
		   edited via the modal) are left alone; an unparseable value is left as
		   typed for the server to reject with a real error. */
		delegate(document, 'focusout', '.posting-amount', (e, input) => {
			if (input.readOnly || !input.value.trim()) return;
			const cents = parseAmountToCents(input.value);
			if (cents !== null) input.value = formatAmountFromCents(cents);
		});
		/* Open split modal when clicking the amount of a paired posting */
		delegate(document, 'click', '.posting-amount, input[data-amount-field]', (e, input) => {
		    const row = input.closest('tr');
		    const pairId = row?.querySelector('.posting-deduction-pair-id')?.value;
		    if (!pairId) return;
		    e.preventDefault();
		    row.querySelector('.split-btn[data-action="open-split-modal"]')?.click();
		});
		/* Bank Entry: Calculate running balance on input change */
		delegate(document, 'input', '.posting-amount, .posting-type, .posting-currency, .posting-destroy', (e, input) => {
			if (document.getElementById('bank-postings-table')) {
			    this.calculateBankBalance();
			}
		});
		/* Prevent Enter from submitting, instead calculate balance */
		delegate(document, 'keydown', '.form_bank_entry, .form_journal_entry, .form_transfer_entry', (e, form) => {
		  if (e.key === 'Enter' && e.target.tagName !== 'TEXTAREA') {
		    e.preventDefault();
		    if (e.target.classList.contains('posting-amount') || 
		        e.target.classList.contains('posting-amount-display')) {
		      if (document.getElementById('bank-postings-table')) {
		        this.calculateBankBalance();
		      }
		    }
		  }
		});
		/* Deleting an entry by emptying it: if every editable posting row is marked
		   for deletion (the bank line is a .balance-row, not a .posting-row, so it's
		   naturally excluded), submitting will delete the whole entry server-side —
		   confirm first. Only when a PERSISTED posting is being removed (not a fresh
		   new-entry form). */
		delegate(document, 'submit', '.form_journal_entry, .form_bank_entry', (e, form) => {
		    const rows = Array.from(form.querySelectorAll('.posting-row:not(.ce-mirror-row)'));
		    if (!rows.length) return;
		    const surviving = rows.filter(r => !r.querySelector('.posting-destroy')?.checked);
		    if (surviving.length) return; // something remains → normal save
		    const deletingPersisted = rows.some(r =>
		        r.querySelector('.posting-destroy')?.checked &&
		        r.querySelector('input[name*="[id]"]')?.value);
		    if (!deletingPersisted) return; // new-entry form, nothing to delete
		    const msg = form.dataset.emptyDeleteConfirm;
		    if (msg && !confirm(msg)) { e.preventDefault(); e.stopPropagation(); }
		});
	  	/* Transfer form: account selection changes */
	    delegate(document, 'change', '#journal_entry_from_account_id, #journal_entry_to_account_id', (e, select) => {
	      this.updateTransferCurrencies();
	    });
	    /* Transfer form: amount input changes */
	    delegate(document, 'input', '#journal_entry_transfer_amount_display, #journal_entry_target_amount_display', (e, input) => {
	      this.calculateTransferRate();
	    });
	    /* Transfer form: on submit, if the two amounts imply a rate wildly off
	       any published one, it is almost always a typo — a cross-currency
	       transfer auto-posts, and the gap then hides in a report as FX variance
	       / profit. Ask once; the user may still go ahead (their bank, their
	       rate). See CurrencyConfig / ExchangeRate.calculate_fx_variance. */
	    delegate(document, 'submit', '.form_transfer_entry', async (e, form) => {
	      if (form.dataset.fxConfirmed) { delete form.dataset.fxConfirmed; return; }
	      e.preventDefault();
	      const warning = await this.transferRateWarning(form);
	      if (warning && !confirm(warning)) return;
	      form.dataset.fxConfirmed = 'true';
	      form.requestSubmit();
	    });
		/* FX Calculator: auto-fetch rate on currency/date change */
		delegate(document, 'change', '#fx-from-currency, #fx-to-currency, #fx-rate-date', () => {
		    this.fetchFxRate();
		});
		/* FX Calculator: recalculate on amount or manual rate input */
		delegate(document, 'input', '#fx-start-amount, #fx-rate', () => {
		    this.calculateFxResult();
		});
		/* FX Calculator: copy result */
		delegate(document, 'click', '#fx-copy-result', (e, button) => {
		    const val = document.getElementById('fx-result')?.value;
		    if (!val) return;
		    navigator.clipboard.writeText(val);
		    const status = button.nextElementSibling;
		    showTransientStatus(status, status?.dataset.copied);
		});
		/* Report modal - open & close via hook, initModals called in index.js
		 * (and fetch rate for fx calculator)*/
		document.getElementById('fx-calculator')?.addEventListener('modal:before-open', (e) => {
		  e.preventDefault(); // if needed
		  this.fetchFxRate();
		});
		/* Show currency for balance accounts, S button for nominal accounts */
		delegate(document, 'change', 'select[name*="account_id"]', (e, select) => {
		    const row = select.closest('tr');
		    const option = select.querySelector(`option[value="${select.value}"]`);
		    const currency = option?.dataset.currency || '';
		    const deductionPct = option?.dataset.deductionPct || '';

		    /* A 601 gift bridge is not splittable — never (re)add a split button to it. */
		    const isGift = !!row?.querySelector('.posting-cross-entity-link-id')?.value;
		    const currencyCell = row?.querySelector('.posting-currency-display');
		    if (currencyCell) {
		        if (currency) {
		            currencyCell.textContent = currency;
		        } else if (isGift) {
		            currencyCell.querySelector('.split-btn')?.remove();
		        } else {
		            if (!currencyCell.querySelector('.split-btn')) {
		                /* Cloned from the row template rather than written here, so it is
		                   the same button the server renders — labelled %, with its title.
		                   The string this replaced said "S" and had no tooltip. */
		                const rowTemplate = document.getElementById('posting-template')
		                                 || document.getElementById('bank-posting-template');
		                const splitBtn = rowTemplate?.content.querySelector('.split-btn')?.cloneNode(true);
		                if (splitBtn) currencyCell.replaceChildren(splitBtn);
		            }
		            currencyCell.querySelector('.split-btn').dataset.deductionPct = deductionPct;
		        }
		    }
		    const splitColBtn = row?.querySelector('.split-col .split-btn');
		    if (splitColBtn) {
		        if (isGift) splitColBtn.remove();
		        else splitColBtn.dataset.deductionPct = deductionPct;
		    }
		});
		/* Trash button: remove new rows from DOM, mark existing rows for destruction */
		delegate(document, 'click', '[data-action="delete-posting-row"]', (e, btn) => {
		    const row = btn.closest('tr');
		    if (!row) return;
		    /* Trashing a 601 gift takes its whole JE₂ (both mirror rows) with it — the
		       capital-in loses its source. ASYMMETRIC: a JE₂ row does NOT drop the gift;
		       the gift drops JE₂. (Create flow: the mirror rows are new → removed here;
		       a persisted JE₂ isn't shown in edit yet — that's whole-entry delete.) */
		    const giftLinkId = row.querySelector('.posting-cross-entity-link-id')?.value;
		    if (giftLinkId) {
		        document.querySelectorAll(`.ce-mirror-row[data-ce-link-id="${giftLinkId}"]`)
		            .forEach(m => m.remove());
		    }
		    const idInput = row.querySelector('input[name*="[id]"]');
		    const isNew = !idInput || !idInput.value;
		    if (isNew) {
		        row.remove();
		    } else {
		        const destroyCheckbox = row.querySelector('.posting-destroy');
		        if (destroyCheckbox) {
		            destroyCheckbox.checked = true;
		            destroyCheckbox.dispatchEvent(new Event('change', { bubbles: true }));
		        }
		    }
		    if (document.getElementById('bank-postings-table')) this.calculateBankBalance();
		});
		/* Split modal: open */
		delegate(document, 'click', '[data-action="open-split-modal"]', async (e, btn) => {
		    e.preventDefault();
		    e.stopPropagation();
		    const modal = document.getElementById('split-modal');
		    if (!modal) return;
		    const row = btn.closest('tr');
		    /* A 601 gift bridge is not splittable — ignore any stray split click. */
		    if (row?.querySelector('.posting-cross-entity-link-id')?.value) return;
		    this._splitSourceRow = row;
		    const accountSelect = row?.querySelector('.posting-account');
		    const accountVal = accountSelect?.value || '';
		    const amountInput = row?.querySelector('.posting-amount, input[data-amount-field]');
		    this._splitIsReEdit = !!accountVal;

		    // Show first so TomSelect initialises with correct dimensions
		    modal.showModal();
		    await TomSelectHelper.initInContainer(modal);

		    const ts1 = TomSelectHelper.getInstance(document.getElementById('split-account-1'));
		    const ts2 = TomSelectHelper.getInstance(document.getElementById('split-account-2'));
		    ts1?.clear(true);
		    ts2?.clear(true);
		    document.getElementById('split-amount-1').value = '';
		    document.getElementById('split-amount-2').value = '';
		    document.getElementById('split-redundant-warning').hidden = true;

		    if (accountVal) ts1?.setValue(accountVal, true);

		    // If re-editing an existing pair: find paired row, sum both amounts as the total,
		    // pre-fill account 2 and percentage from the existing pair
		    const existingPairId = row?.querySelector('.posting-deduction-pair-id')?.value;
		    const pairedPairIdInput = existingPairId
		        ? Array.from(document.querySelectorAll('.posting-deduction-pair-id'))
		              .find(el => el.value === existingPairId && el.closest('tr') !== row)
		        : null;
		    const pairedRow = pairedPairIdInput?.closest('tr');

		    if (pairedRow) {
		        const pairedAmountInput = pairedRow.querySelector('.posting-amount, input[data-amount-field]');
		        const amount1N = this.parseSplitAmount(amountInput?.value || '0');
		        const amount2N = this.parseSplitAmount(pairedAmountInput?.value || '0');
		        document.getElementById('split-total').value = this.formatSplitAmount(amount1N + amount2N);

		        const pairedAccountSelect = pairedRow.querySelector('.posting-account');
		        const pairedAccountVal = pairedAccountSelect?.value || '';
		        if (pairedAccountVal) ts2?.setValue(pairedAccountVal, true);
		    } else {
		        document.getElementById('split-total').value = amountInput?.value || '';
		    }

		    const pct = btn.dataset.deductionPct ||
		                accountSelect?.querySelector(`option[value="${accountVal}"]`)?.dataset.deductionPct;
		    if (pct) {
		        document.getElementById('split-percentage').value = pct;
		        this.recalcSplitFromPercentage();
		    }
		});
		/* Split modal: account 2 change — warning suppressed (pairs are auto-managed) */
		delegate(document, 'change', '#split-account-2', () => {
		    const warning = document.getElementById('split-redundant-warning');
		    if (warning) warning.hidden = true;
		});
		/* Split modal: live calculation */
		delegate(document, 'input', '#split-total, #split-percentage', () => {
		    this.recalcSplitFromPercentage();
		});
		delegate(document, 'input', '#split-amount-1', () => {
		    this.recalcSplitFromAmount1();
		});
		/* Split modal: confirm */
		delegate(document, 'click', '#split-confirm', (e) => {
		    e.preventDefault();
		    this.applySplit();
		});
		/* Split modal: cancel */
		delegate(document, 'click', '.split-cancel', () => {
		    document.getElementById('split-modal')?.close();
		});
		/* Cross-entity trigger (Build 2): selecting an account from an entity
		   outside the entry's home group → open the modal (foreign nominal) or
		   block it (foreign balance = a transfer/loan, booked per entity). */
		delegate(document, 'change', '.posting-account', (e, select) => {
		    const opt = select.selectedOptions[0];
		    if (!opt || !opt.value) return;
		    const group = opt.dataset.group;
		    const home  = this.crossEntityHomeGroup(select);
		    if (!home || !group || group === home) return; // same group → normal posting

		    if (['income', 'expense'].includes(opt.dataset.type)) {
		        this.openCrossEntityModal(select);
		    } else {
		        this.blockForeignBalanceAccount(select);
		    }
		});
		/* Cross-entity modal: cancel — on a NEW leg, undo the foreign pick (it can't
		   live in JE₁); when editing an existing leg, leave the gift untouched. */
		delegate(document, 'click', '.ce-cancel', () => {
		    document.getElementById('cross-entity-modal')?.close();
		    if (!this._ceEditMode) {
		        const sel = this._ceTriggerRow?.querySelector('select.posting-account');
		        if (sel) TomSelectHelper.getInstance(sel)?.clear(true);
		    }
		    this._ceTriggerRow = null;
		    this._ceEditMode = false;
		});
		/* Cross-entity modal: confirm */
		delegate(document, 'click', '#ce-confirm', (e) => {
		    e.preventDefault();
		    this.confirmCrossEntity();
		});
		/* "+ add account" chosen in the gift/capital select → open the add-account modal. */
		delegate(document, 'change', '#ce-gift, #ce-capital', (e, select) => {
		    const ts = TomSelectHelper.getInstance(select);
		    if (ts?.getValue() !== '__add_account__') return;
		    ts.clear(true); // drop the sentinel selection
		    this.openAddAccountModal(select.id);
		});
		/* Add-account modal: submit the account form via AJAX; inject on success,
		   show errors on 422 (the form keeps the entered values). */
		delegate(document, 'submit', '#add-account-modal .form_account', async (e, form) => {
		    e.preventDefault();
		    const errBox = document.getElementById('add-account-errors');
		    try {
		        const resp = await fetch(form.action, {
		            method: 'POST',
		            headers: { Accept: 'application/json', 'X-CSRF-Token': csrfToken() },
		            body: new FormData(form)
		        });
		        if (resp.ok) {
		            const targetId = this._addAccountTarget;
		            this.injectCrossEntityAccount(targetId, await resp.json());
		            document.getElementById('add-account-modal')?.close();
		            /* <dialog>.close() hands focus back to the gift/capital select, which
		               re-opens its TomSelect — blur it once focus restoration settles. */
		            setTimeout(() => {
		                const ts = TomSelectHelper.getInstance(document.getElementById(targetId));
		                ts?.close(); ts?.blur(); document.activeElement?.blur?.();
		            }, 0);
		        } else {
		            const data = await resp.json().catch(() => ({}));
		            if (errBox) { errBox.textContent = (data.errors || ['—']).join('; '); errBox.hidden = false; }
		        }
		    } catch (err) {
		        console.error('add-account save failed', err);
		    }
		});
		/* Add-account modal: cancel. */
		delegate(document, 'click', '.add-account-cancel', () => {
		    document.getElementById('add-account-modal')?.close();
		});
		/* A linked amount (the 601 gift or a JE₂ mirror) is locked — clicking it
		   reopens the modal pre-filled, so all three legs edit together. */
		delegate(document, 'click', '.posting-amount', (e, input) => {
		    const row = input.closest('tr');
		    const linkId = row?.classList.contains('ce-mirror-row')
		        ? row.dataset.ceLinkId
		        : row?.querySelector('.posting-cross-entity-link-id')?.value;
		    if (!linkId) return; // a plain posting amount — editable, leave it
		    this.openCrossEntityModalForEdit(linkId);
		});
		/* Cross-entity deletion — ASYMMETRIC (not the split's symmetric 1:1):
		   ticking a JE₂ mirror row marks BOTH of that leg's mirror rows for
		   deletion and SEVERS the 601, which stays in JE₁ as a plain gift. */
		delegate(document, 'change', '.ce-mirror-destroy', (e, checkbox) => {
		    const row = checkbox.closest('tr');
		    const linkId = row?.dataset.ceLinkId;
		    if (!linkId) return;
		    document.querySelectorAll(`.ce-mirror-row[data-ce-link-id="${linkId}"] .ce-mirror-destroy`)
		        .forEach(cb => {
		            if (cb.checked !== checkbox.checked) {
		                cb.checked = checkbox.checked;
		                cb.dispatchEvent(new Event('change', { bubbles: true }));
		            }
		        });
		    /* Sever the gift ONLY if it's staying — not when it's itself being deleted
		       (gift-delete takes JE₂ with it, no sever). */
		    if (checkbox.checked) {
		        const gift = this.ceGiftRow(linkId);
		        if (!gift?.querySelector('.posting-destroy')?.checked) this.severCrossEntityGift(linkId);
		    }
		});
		/* Marking the GIFT for deletion marks its JE₂ mirror rows too, so they hide with
		   it (they always go together — the gift's model cascade deletes JE₂ on save).
		   Both the JE and bank routes delete a posting via this .posting-destroy box. */
		delegate(document, 'change', '.posting-destroy', (e, checkbox) => {
		    const row = checkbox.closest('tr');
		    if (!row || row.classList.contains('ce-mirror-row')) return; // mirror rows handled above
		    const linkId = row.querySelector('.posting-cross-entity-link-id')?.value;
		    if (!linkId) return; // not a gift
		    document.querySelectorAll(`.ce-mirror-row[data-ce-link-id="${linkId}"] .ce-mirror-destroy`).forEach(cb => {
		        if (cb.checked !== checkbox.checked) {
		            cb.checked = checkbox.checked;
		            cb.dispatchEvent(new Event('change', { bubbles: true }));
		        }
		    });
		});
		/* Destroy checkbox: auto-tick and hide the paired posting */
		delegate(document, 'change', '.posting-destroy', (e, checkbox) => {
		    const row = checkbox.closest('tr');
		    const pairId = row?.querySelector('.posting-deduction-pair-id')?.value;
		    if (!pairId) return;
		    const pairedPairIdInput = Array.from(document.querySelectorAll('.posting-deduction-pair-id'))
		        .find(el => el.value === pairId && el.closest('tr') !== row);
		    const pairedCheckbox = pairedPairIdInput?.closest('tr')?.querySelector('.posting-destroy');
		    if (pairedCheckbox && pairedCheckbox.checked !== checkbox.checked) {
		        pairedCheckbox.checked = checkbox.checked;
		        pairedCheckbox.dispatchEvent(new Event('change', { bubbles: true }));
		    }
		});
		/* Reconcile modal: open */
		delegate(document, 'click', '.reconcile-btn', (e, btn) => {
			e.preventDefault();
			e.stopPropagation();
			const modal = document.getElementById('reconcile-modal');
			if (!modal) return;
			modal.dataset.balanceAtUrl = btn.dataset.balanceAtUrl;
			modal.dataset.currency     = btn.dataset.currency;
			modal.dataset.appBalanceCents = '';
			document.getElementById('reconcile-account-name').textContent = btn.dataset.accountName;
			document.getElementById('reconcile-statement').value = '';
			document.getElementById('reconcile-app-balance').textContent = '—';
			const diffEl = document.getElementById('reconcile-difference');
			diffEl.textContent = '—';
			diffEl.className = '';
			// Default date: last day of previous month
			const now = new Date();
			const lastMonth = new Date(now.getFullYear(), now.getMonth(), 0);
			document.getElementById('reconcile-date').value = lastMonth.toISOString().slice(0, 10);
			modal.showModal();
			this.fetchReconcileBalance();
		});
		/* Reconcile modal: close via button */
		delegate(document, 'click', '.reconcile-close', () => {
			document.getElementById('reconcile-modal').close();
		});
		/* Reconcile modal: date change */
		delegate(document, 'change', '#reconcile-date', () => {
			this.fetchReconcileBalance();
		});
		/* Reconcile modal: statement balance change */
		delegate(document, 'input', '#reconcile-statement', () => {
			this.updateReconcileDifference();
		});
		setupReportGroupAccountSelector();
		/* Report currency selector - auto-submit form */
		delegate(document, 'change', '#report-currency-select', (e, select) => {
		  select.closest('form').submit();
		});
		/* Modal edit -> open entry edit form in iframe modal, 
		 * refresh report on save */
		delegate(document, 'click', '.popup-edit', (e, link) => {
		  e.preventDefault();
		  const modal = document.getElementById('edit-modal');
		  const frame = document.getElementById('edit-modal-frame');
		  if (!modal || !frame) return;
		  
		  this.attachModalListeners();

		  const url = new URL(link.href, location.origin);
		  url.searchParams.set('popup', '1');
		  frame.src = url.toString();
		  modal.showModal();
		});
		delegate(document, 'click', '.edit-modal-close', () => this.closeModal());
	},
	/* modal for editing entries from reports */
	initModal(){
		if (new URLSearchParams(location.search).has('popup')) {
		  document.querySelectorAll('form').forEach(form => {
		    if (!form.querySelector('input[name="popup"]')) {
		      const input = Object.assign(document.createElement('input'), {
		        type: 'hidden', name: 'popup', value: '1'
		      });
		      form.appendChild(input);
		    }
		  });
		}
	},
	attachModalListeners(){
		if (this._modalListenersAttached) return;
		this._modalListenersAttached = true;

		const modal = document.getElementById('edit-modal');
		/* backdrop click: click lands on the dialog element itself */
		modal?.addEventListener('click', (e) => {
		  if (e.target === modal) this.closeModal();
		});
		/* cleanup iframe on native Escape close */
		modal?.addEventListener('close', () => {
		  document.getElementById('edit-modal-frame').src = 'about:blank';
		});
		/* Listen for save message from iframe */
		window.addEventListener('message', (event) => {
		  if (event.data !== 'saved') return;
		  this.closeModal();
		  const container = document.getElementById('report-container');
		  if (!container) return;
		  fetch(location.href)
		    .then(r => r.text())
		    .then(html => {
		      const doc = new DOMParser().parseFromString(html, 'text/html');
		      const fresh = doc.getElementById('report-container');
		      if (fresh) container.innerHTML = fresh.innerHTML;
		    });
		});		
	},
	/* --- Cross-entity (Build 2) ---------------------------------------- */
	/* The entry's "home group": explicit on the bank table (fixed bank), else
	   the group of the JE form's balance-sheet posting. */
	crossEntityHomeGroup(fromSelect) {
	    const table = fromSelect.closest('table');
	    if (table?.dataset.homeGroup) return table.dataset.homeGroup;
	    return this.crossEntityBalanceOption()?.dataset.group || null;
	},
	crossEntityHomeEntity(fromSelect) {
	    const table = fromSelect.closest('table');
	    if (table?.dataset.homeEntity) return table.dataset.homeEntity;
	    return this.crossEntityBalanceOption()?.dataset.entity || null;
	},
	crossEntityBankCurrency(fromSelect) {
	    const table = fromSelect.closest('table');
	    if (table?.dataset.bankCurrency) return table.dataset.bankCurrency;
	    return this.crossEntityBalanceOption()?.dataset.currency || null;
	},
	/* The JE form's balance-sheet (bank) posting option, if any. */
	crossEntityBalanceOption() {
	    // NB: TomSelect copies the .posting-account class onto its wrapper <div>,
	    // so qualify with select. to avoid matching a div (no .selectedOptions).
	    return [...document.querySelectorAll('select.posting-account')]
	        .map(s => s.selectedOptions?.[0])
	        .find(o => o && ['asset', 'liability', 'equity'].includes(o.dataset.type)) || null;
	},
	/* A foreign BALANCE account isn't a cross-entity leg — undo it. */
	blockForeignBalanceAccount(select) {
	    TomSelectHelper.getInstance(select)?.clear(true);
	    const warn = document.getElementById('cross-entity-warning');
	    // TODO(next slice): surface this inline rather than alert()
	    alert(warn?.dataset.balanceMsg || 'A cross-entity posting must be an income or expense account. Book a transfer or loan in each business separately.');
	},
	/* Snapshot the modal selects' FULL option data ONCE, before TomSelect init
	   (TomSelect prunes the DOM <option>s to the selected one, so it must be read
	   first). Keyed by select id → [{value,text,entity,group,currency,type}]. */
	ceSnapshotModalOptions() {
	    if (this._ceOptionSnapshot) return;
	    this._ceOptionSnapshot = {};
	    ['ce-gift', 'ce-capital', 'ce-nominal'].forEach(id => {
	        const select = document.getElementById(id);
	        if (!select) return;
	        this._ceOptionSnapshot[id] = [...select.querySelectorAll('option')].map(o => ({
	            value: o.value, text: o.textContent.trim(),
	            entity: o.dataset.entity || '', group: o.dataset.group || '',
	            currency: o.dataset.currency || '', type: o.dataset.type || ''
	        }));
	    });
	},
	ceOptData(id, value) {
	    return this._ceOptionSnapshot?.[id]?.find(o => o.value === value);
	},
	/* Rebuild one modal select's TomSelect option pool from the filtered snapshot;
	   always keep the blank option and the current selection (an edit mustn't lose
	   its existing pick even if it wouldn't pass the filter). */
	ceApplyFilter(id, predicate, keepValue, addAccount) {
	    const ts = TomSelectHelper.getInstance(document.getElementById(id));
	    if (!ts) return;
	    const all = this._ceOptionSnapshot?.[id] || [];
	    ts.clearOptions();
	    all.forEach(o => {
	        if (o.value === '' || predicate(o) || (keepValue && o.value === keepValue)) {
	            ts.addOption({ value: o.value, text: o.text });
	        }
	    });
	    /* Gift/capital get an "+ add account" entry (create one on the fly). */
	    if (addAccount) {
	        const label = document.getElementById('add-account-modal')?.dataset.addLabel || '+ add account';
	        ts.addOption({ value: '__add_account__', text: label });
	    }
	    ts.refreshOptions(false);
	    if (keepValue) ts.setValue(keepValue, true); else ts.clear(true);
	},
	/* Gift → personal accts of the balance account's entity/FAMILY (group); capital
	   → payee entity + bank currency; nominal → payee entity. Gift/capital also offer
	   "+ add account". */
	ceFilterModalSelects(homeGroup, payeeEntity, bankCurrency, keep = {}) {
	    this.ceApplyFilter('ce-gift',    o => o.group === homeGroup, keep.gift, true);
	    this.ceApplyFilter('ce-capital', o => o.entity === payeeEntity && (!bankCurrency || o.currency === bankCurrency), keep.capital, true);
	    this.ceApplyFilter('ce-nominal', o => o.entity === payeeEntity, keep.nominal, false);
	},
	/* "+ add account" was picked in a gift/capital select → fetch the account form
	   (cross-entity mode) into the add-account modal. */
	async openAddAccountModal(selectId) {
	    const ceModal  = document.getElementById('cross-entity-modal');
	    const addModal = document.getElementById('add-account-modal');
	    if (!ceModal || !addModal) return;
	    const isGift   = selectId === 'ce-gift';
	    const entity   = isGift ? ceModal.dataset.homeEntity : ceModal.dataset.payeeEntity;
	    const currency = isGift ? '' : (ceModal.dataset.bankCurrency || '');
	    const prefix   = `${isGift ? '6' : '3'}${entity || ''}`;
	    this._addAccountTarget = selectId;
	    const params = new URLSearchParams({ cross_entity: '1', fixed_type: isGift ? 'personal' : 'equity', fixed_currency: currency, code_prefix: prefix });
	    const errBox = document.getElementById('add-account-errors');
	    if (errBox) errBox.hidden = true;
	    try {
	        const resp = await fetch(`${addModal.dataset.newUrl}?${params}`, { headers: { Accept: 'text/html' } });
	        document.getElementById('add-account-content').innerHTML = await resp.text();
	        await TomSelectHelper.initInContainer(addModal); // the parent select is a TomSelect
	        addModal.showModal();
	        /* Focus the code field with the cursor AFTER the pre-filled 3 digits. */
	        const codeInput = document.getElementById('account_code');
	        if (codeInput) { codeInput.focus(); const len = codeInput.value.length; codeInput.setSelectionRange(len, len); }
	    } catch (err) {
	        console.error('add-account form fetch failed', err);
	    }
	},
	/* Inject a just-created account into its select + the snapshot (so it survives
	   re-filtering), and select it. */
	injectCrossEntityAccount(selectId, acct) {
	    const value = String(acct.id);
	    this._ceOptionSnapshot?.[selectId]?.push({
	        value, text: acct.label,
	        entity: acct.entity || '', group: acct.group || '',
	        currency: acct.currency || '', type: acct.type || ''
	    });
	    const ts = TomSelectHelper.getInstance(document.getElementById(selectId));
	    ts?.addOption({ value, text: acct.label });
	    ts?.setValue(value, false);
	    /* A new GIFT (personal) account also becomes a JE₁ posting — the trigger row's
	       .posting-account select (rendered before the account existed) doesn't know
	       it, so confirmCrossEntity's setValue would blank out. Inject it into every
	       posting-account select. (The capital leg is server-rendered from the DB, so
	       it needs no client injection.) */
	    if (selectId === 'ce-gift') {
	        document.querySelectorAll('select.posting-account').forEach(sel => {
	            TomSelectHelper.getInstance(sel)?.addOption({ value, text: acct.label });
	        });
	    }
	},
	async openCrossEntityModal(triggerSelect) {
	    const modal = document.getElementById('cross-entity-modal');
	    if (!modal) return;
	    const opt = triggerSelect.selectedOptions[0];
	    this._ceTriggerRow = triggerSelect.closest('tr');
	    this._ceEditMode = false;
	    /* An account is chosen — close the trigger's dropdown so it doesn't linger
	       behind (and after) the modal. */
	    const triggerTs = TomSelectHelper.getInstance(triggerSelect);
	    triggerTs?.close();
	    triggerTs?.blur();

	    const homeEntity   = this.crossEntityHomeEntity(triggerSelect);
	    const homeGroup    = this.crossEntityHomeGroup(triggerSelect);
	    const payeeEntity  = opt.dataset.entity;
	    const bankCurrency = this.crossEntityBankCurrency(triggerSelect);
	    modal.dataset.homeEntity   = homeEntity || '';
	    modal.dataset.homeGroup    = homeGroup || '';
	    modal.dataset.payeeEntity  = payeeEntity || '';
	    modal.dataset.bankCurrency = bankCurrency || '';

	    const warn = document.getElementById('cross-entity-warning');
	    if (warn) warn.hidden = true;
	    this._ceSetIntro(modal, homeEntity, payeeEntity, bankCurrency);

	    modal.showModal();
	    this.ceSnapshotModalOptions(); // capture full options before TomSelect prunes them
	    await TomSelectHelper.initInContainer(modal);
	    document.getElementById('ce-amount').value = '';
	    /* Filter each select to the right entity/family/currency; pre-fill the real leg
	       with the account that triggered this, gift/capital start empty. */
	    this.ceFilterModalSelects(homeGroup, payeeEntity, bankCurrency, { nominal: opt.value });
	    /* Real-leg side: default from the account type (income→credit, expense→debit);
	       hide the control in a bank entry (deposit/withdrawal already fixes it). */
	    const inBank = triggerSelect.closest('table')?.id === 'bank-postings-table';
	    const sideRow = modal.querySelector('[data-ce-side-row]');
	    /* inline display, not the `hidden` attr — `.split-row { display:flex }` would
	       otherwise override [hidden]. Bank entries auto-set the side (deposit/
	       withdrawal), and inexperienced admins shouldn't see debit/credit at all. */
	    if (sideRow) sideRow.style.display = inBank ? 'none' : '';
	    const sideSel = document.getElementById('ce-side');
	    if (sideSel) sideSel.value = opt.dataset.type === 'income' ? 'credit' : 'debit';
	},

	/* Entity code → name map (rendered on the modal), for naming the businesses. */
	_ceEntityNames() {
	    if (this._ceNames) return this._ceNames;
	    try { this._ceNames = JSON.parse(document.getElementById('cross-entity-modal')?.dataset.entityNames || '{}'); }
	    catch { this._ceNames = {}; }
	    return this._ceNames;
	},
	/* "01" → "01 Boss Ltd" (falls back to the bare code if the name is unknown). */
	_ceEntityLabel(code) {
	    const name = this._ceEntityNames()[code];
	    return name ? `${code} ${name}` : (code || '');
	},
	/* Fill the modal's intro sentence from the entities/currency in play. */
	_ceSetIntro(modal, home, payee, currency) {
	    const intro = modal.querySelector('[data-ce-intro]');
	    if (!intro || !intro.dataset.template) return;
	    intro.textContent = intro.dataset.template
	        .replaceAll('{home}', this._ceEntityLabel(home))
	        .replaceAll('{payee}', this._ceEntityLabel(payee))
	        .replaceAll('{currency}', currency || '');
	},

	/* The JE₁ posting row that holds the 601 gift for a given link (both
	   client-inserted and server-rendered rows carry the hidden link field). */
	ceGiftRow(linkId) {
	    return Array.from(document.querySelectorAll('.posting-row:not(.ce-mirror-row)'))
	        .find(r => r.querySelector('.posting-cross-entity-link-id')?.value === linkId);
	},

	/* Sever a leg's 601 gift from its (now-deleted) JE₂: the gift STAYS in JE₁ but
	   reverts to a plain personal posting — link cleared, amount editable again, and
	   the account-change re-run so it regains its split button. JE₁ balance is
	   unchanged, so no bank recalc is needed. */
	severCrossEntityGift(linkId) {
	    const gift = this.ceGiftRow(linkId);
	    if (!gift) return;
	    const linkField = gift.querySelector('.posting-cross-entity-link-id');
	    if (linkField) linkField.value = '';
	    const amountInput = gift.querySelector('.posting-amount');
	    if (amountInput) amountInput.readOnly = false;
	    gift.querySelector('select.posting-account')
	        ?.dispatchEvent(new Event('change', { bubbles: true }));
	},

	/* Reopen the modal on an existing leg (gift or mirror amount clicked),
	   pre-filled from the current values; confirm reuses the same link_id/
	   entry_index, so it replaces the JE₂ rows and rewrites the gift in place. */
	async openCrossEntityModalForEdit(linkId) {
	    const modal = document.getElementById('cross-entity-modal');
	    if (!modal) return;
	    const gift = this.ceGiftRow(linkId);
	    if (!gift) return;
	    this._ceTriggerRow = gift;
	    this._ceEditMode   = true;
	    gift.dataset.ceLinkId = linkId; // ensure confirm removes the right JE₂ rows

	    const capRow = document.querySelector(`.ce-mirror-row[data-ce-link-id="${linkId}"][data-ce-role="capital"]`);
	    const nomRow = document.querySelector(`.ce-mirror-row[data-ce-link-id="${linkId}"][data-ce-role="nominal"]`);
	    /* Editing a PERSISTED leg: stash JE₂'s posting ids so confirm re-fetches rows
	       that carry them → the save UPDATES this JE₂ instead of duplicating it. */
	    gift.dataset.ceCapitalPostingId = capRow?.querySelector('input[name$="[id]"]')?.value || '';
	    gift.dataset.ceNominalPostingId = nomRow?.querySelector('input[name$="[id]"]')?.value || '';
	    const giftSel   = gift.querySelector('select.posting-account');
	    const giftId    = giftSel?.value || '';
	    const capitalId = capRow?.querySelector('input[name*="[account_id]"]')?.value || '';
	    const nominalId = nomRow?.querySelector('input[name*="[account_id]"]')?.value || '';
	    const amount    = gift.querySelector('.posting-amount')?.value || '';
	    const giftSide  = gift.querySelector('[name*="[entry_type]"]')?.value || 'debit';
	    const inBank    = gift.closest('table')?.id === 'bank-postings-table';

	    const warn = document.getElementById('cross-entity-warning');
	    if (warn) warn.hidden = true;

	    modal.showModal();
	    this.ceSnapshotModalOptions(); // before TomSelect prunes the options
	    await TomSelectHelper.initInContainer(modal);
	    document.getElementById('ce-amount').value = amount;
	    /* Home group = gift's family, payee = nominal's entity, currency = capital's —
	       read from the option snapshot (the filter prunes the live selects). Then
	       filter + re-select each existing value (kept even if it wouldn't pass). */
	    const homeGroup    = this.ceOptData('ce-gift', giftId)?.group;
	    const payeeEntity  = this.ceOptData('ce-nominal', nominalId)?.entity;
	    const bankCurrency = this.ceOptData('ce-capital', capitalId)?.currency;
	    this.ceFilterModalSelects(homeGroup, payeeEntity, bankCurrency, { gift: giftId, capital: capitalId, nominal: nominalId });
	    this._ceSetIntro(modal, this.ceOptData('ce-gift', giftId)?.entity, payeeEntity, bankCurrency);
	    const sideRow = modal.querySelector('[data-ce-side-row]');
	    if (sideRow) sideRow.style.display = inBank ? 'none' : '';
	    const sideSel = document.getElementById('ce-side');
	    if (sideSel) sideSel.value = giftSide;
	},

	/* Confirm: repurpose the trigger row as JE₁'s 601 gift, then fetch JE₂'s posting
	   rows (real inputs, namespaced cross_entity_entries[…]) from the server and
	   insert them as the .ce-mirror-row band under the gift; recalc; close. */
	async confirmCrossEntity() {
	    const modal     = document.getElementById('cross-entity-modal');
	    const nominalId = TomSelectHelper.getInstance(document.getElementById('ce-nominal'))?.getValue();
	    const giftId    = TomSelectHelper.getInstance(document.getElementById('ce-gift'))?.getValue();
	    const capitalId = TomSelectHelper.getInstance(document.getElementById('ce-capital'))?.getValue();
	    let amount      = document.getElementById('ce-amount').value.trim();
	    const warn      = document.getElementById('cross-entity-warning');

	    if (!nominalId || !giftId || !capitalId || !amount) {
	        if (warn) { warn.textContent = warn.dataset.incompleteMsg || warn.textContent; warn.hidden = false; }
	        return;
	    }
	    /* Normalise to 2 decimals in the display locale (25 → 25.00) so the gift row
	       and the mirror rows match the other posting amounts before the save. */
	    const parsedAmount = this.parseSplitAmount(amount);
	    if (!isNaN(parsedAmount)) amount = this.formatSplitAmount(parsedAmount);

	    const row = this._ceTriggerRow;
	    if (!row) return;
	    const linkId = row.dataset.ceLinkId || crypto.randomUUID();
	    row.dataset.ceLinkId = linkId;
	    /* Numeric entry index (Rails drops uuid-keyed nested hashes); kept on the
	       row so a re-edit reuses it. */
	    let entryIndex = row.dataset.ceEntryIndex;
	    if (!entryIndex) { entryIndex = String(Date.now()); row.dataset.ceEntryIndex = entryIndex; }

	    /* 1. Repurpose the trigger row as JE₁'s 601 gift (keeps its entry_type — the
	          side opposite the bank). */
	    const acctTs = TomSelectHelper.getInstance(row.querySelector('select.posting-account'));
	    acctTs?.setValue(giftId, true);
	    const amountInput = row.querySelector('.posting-amount');
	    /* The gift amount is modal-driven only — lock it (click reopens the modal). */
	    if (amountInput) { amountInput.value = amount; amountInput.readOnly = true; }
	    const linkField = row.querySelector('.posting-cross-entity-link-id');
	    if (linkField) linkField.value = linkId;
	    /* A 601 gift bridge is not splittable — strip the split button it carried
	       from the earlier foreign-nominal selection (the currency-cell "S"/"%"
	       on the JE side or the .split-col "%" on the bank side). */
	    row.querySelector('.split-btn')?.remove();
	    const context = row.closest('table')?.id === 'bank-postings-table' ? 'bank' : 'je';
	    /* The gift (and nominal) side: in a JE the admin picks it in the modal (#ce-side,
	       defaulted from the account type but overridable — the safe call, since a JE
	       need not be a simple bank+gift); in a bank entry it's fixed by deposit/
	       withdrawal (the trigger row's entry_type). The capital takes the opposite
	       (computed server-side from gift_side). */
	    const giftSide = context === 'bank'
	        ? (row.querySelector('[name*="[entry_type]"]')?.value || 'debit')
	        : (document.getElementById('ce-side')?.value || 'debit');
	    /* Force the 601 gift onto that side (overriding any preselection). */
	    const giftTypeField = row.querySelector('[name*="[entry_type]"]');
	    if (giftTypeField) giftTypeField.value = giftSide;

	    /* 2. Fetch JE₂'s rows (real inputs) from the server and insert them. */
	    const params = new URLSearchParams({
	        entry_index: entryIndex, link_id: linkId, gift_side: giftSide, amount,
	        capital_account_id: capitalId, nominal_account_id: nominalId, context,
	    });
	    /* Persisted-leg edit: carry JE₂'s posting ids so the rebuilt rows UPDATE it. */
	    if (row.dataset.ceCapitalPostingId) params.set('capital_posting_id', row.dataset.ceCapitalPostingId);
	    if (row.dataset.ceNominalPostingId) params.set('nominal_posting_id', row.dataset.ceNominalPostingId);
	    try {
	        const resp = await fetch(`${modal.dataset.rowsUrl}?${params}`, { headers: { Accept: 'text/html' } });
	        const html = await resp.text();
	        document.querySelectorAll(`.ce-mirror-row[data-ce-link-id="${linkId}"]`).forEach(r => r.remove());
	        row.insertAdjacentHTML('afterend', html);
	    } catch (err) {
	        console.error('cross-entity rows fetch failed', err);
	    }
	    /* Clear the stashed ids so a later NEW leg on this row doesn't reuse them. */
	    delete row.dataset.ceCapitalPostingId;
	    delete row.dataset.ceNominalPostingId;

	    /* 3. Recalc + close. */
	    this.calculateBankBalance();
	    modal.close();
	    /* <dialog>.close() hands focus back to the trigger select, reopening its
	       TomSelect — blur it once focus restoration settles. */
	    setTimeout(() => { acctTs?.close(); acctTs?.blur(); document.activeElement?.blur?.(); }, 0);
	    this._ceTriggerRow = null;
	    this._ceEditMode = false;
	},

	/* Calculate and display bank balance from counter account postings */
	calculateBankBalance() {
	  const balanceEl = document.querySelector('[data-balance-row]');
	  if (!balanceEl) return;

	  let total = 0;

	  /* Exclude .ce-mirror-row: those posting-amounts belong to JE₂, not the bank line. */
	  document.querySelectorAll('#bank-postings-table .posting-row:not(.ce-mirror-row):not([style*="display: none"])').forEach(row => {
	    const destroyCheckbox = row.querySelector('.posting-destroy');
	    if (destroyCheckbox && destroyCheckbox.checked) return;

	    const amountInput = row.querySelector('.posting-amount');
	    if (!amountInput) return;

	    const cents = parseAmountToCents(amountInput.value);
	    if (cents === null) return;
	    total += cents;
	  });

	  balanceEl.textContent = formatAmountFromCents(total);

	  const warningEl = document.getElementById('direction-warning');
	  if (warningEl) warningEl.hidden = (total >= 0);
	},
	/* Setup reconcile modal: backdrop click to close */
	setupReconcileModal() {
		document.getElementById('reconcile-modal')?.addEventListener('click', (e) => {
			if (e.target === e.currentTarget) e.currentTarget.close();
		});
	},
	setupSplitModal() {
		const modal = document.getElementById('split-modal');
		if (!modal) return;
		modal.addEventListener('click', (e) => {
			if (e.target === modal) modal.close();
		});
		modal.addEventListener('close', () => {
			this._splitSourceRow = null;
			this._splitIsReEdit = false;
		});
	},
	/* split-modal helpers work in whole units (percentage maths); the parse and
	   the display still go through the shared M1 helpers. */
	parseSplitAmount(str) {
		const cents = parseAmountToCents(str);
		return cents === null ? NaN : cents / 100;
	},
	formatSplitAmount(n) {
		return formatAmountFromCents(Math.round(n * 100));
	},
	recalcSplitFromPercentage() {
		const total = this.parseSplitAmount(document.getElementById('split-total').value);
		const pct   = parseFloat(document.getElementById('split-percentage').value);
		if (isNaN(total) || isNaN(pct) || pct <= 0 || pct >= 100) return;
		const amount1 = Math.round(total * pct) / 100;
		const amount2 = Math.round((total - amount1) * 100) / 100;
		document.getElementById('split-amount-1').value = this.formatSplitAmount(amount1);
		document.getElementById('split-amount-2').value = this.formatSplitAmount(amount2);
	},
	recalcSplitFromAmount1() {
		const total   = this.parseSplitAmount(document.getElementById('split-total').value);
		const amount1 = this.parseSplitAmount(document.getElementById('split-amount-1').value);
		if (isNaN(total) || isNaN(amount1) || total === 0) return;
		const amount2 = Math.round((total - amount1) * 100) / 100;
		const pct     = Math.round((amount1 / total) * 1000) / 10;
		document.getElementById('split-amount-2').value = this.formatSplitAmount(amount2);
		document.getElementById('split-percentage').value = pct;
	},
	async applySplit() {
		const sel1     = document.getElementById('split-account-1');
		const sel2     = document.getElementById('split-account-2');
		const amount1N = this.parseSplitAmount(document.getElementById('split-amount-1').value);
		const amount2N = this.parseSplitAmount(document.getElementById('split-amount-2').value);
		if (!sel1.value || !sel2.value || isNaN(amount1N) || isNaN(amount2N)) return;
		const amount1  = this.formatSplitAmount(amount1N);
		const amount2  = this.formatSplitAmount(amount2N);
		const pct      = Math.round(parseFloat(document.getElementById('split-percentage').value));

		const sourceRow = this._splitSourceRow;

		// Use existing pair ID (re-edit) or generate a new one
		const existingPairId = sourceRow?.querySelector('.posting-deduction-pair-id')?.value;
		const pairId = existingPairId || crypto.randomUUID();

		if (sourceRow) {
			const ts = TomSelectHelper.getInstance(sourceRow.querySelector('.posting-account'));
			ts?.setValue(sel1.value, true);
			const amountInput = sourceRow.querySelector('.posting-amount, input[data-amount-field]');
			if (amountInput) amountInput.value = amount1;

			// Freeze pair ID and percentage on the expense (source) posting
			const pairIdInput = sourceRow.querySelector('.posting-deduction-pair-id');
			if (pairIdInput) pairIdInput.value = pairId;
			const pctField = sourceRow.querySelector('.posting-deduction-pct-field');
			if (pctField) pctField.value = pct;

			// Update % button to show the applied percentage
			const splitBtn = sourceRow.querySelector('.split-btn');
			const opt1 = sel1.querySelector(`option[value="${sel1.value}"]`);
			if (splitBtn) {
				splitBtn.dataset.deductionPct = pct;
				splitBtn.textContent = `${pct}%`;
			}
		}

		// In re-edit: find and update the existing paired row instead of injecting a new one
		if (existingPairId) {
			const pairedPairIdInput = Array.from(document.querySelectorAll('.posting-deduction-pair-id'))
				.find(el => el.value === existingPairId && el.closest('tr') !== sourceRow);
			const pairedRow = pairedPairIdInput?.closest('tr');
			if (pairedRow) {
				const ts2 = TomSelectHelper.getInstance(pairedRow.querySelector('.posting-account'));
				ts2?.setValue(sel2.value, true);
				const amountInput2 = pairedRow.querySelector('.posting-amount, input[data-amount-field]');
				if (amountInput2) amountInput2.value = amount2;
			} else {
				await this.injectSplitRow(sourceRow, sel2.value, amount2, pairId);
			}
		} else {
			const descInput = sourceRow?.querySelector('input[name*="[description]"]');
			await this.injectSplitRow(sourceRow, sel2.value, amount2, pairId, descInput?.value || '');
		}

		// Update paired row's percentage to the complement and enable its button
		const pairedRow = Array.from(document.querySelectorAll('.posting-deduction-pair-id'))
			.find(el => el.value === pairId && el.closest('tr') !== sourceRow)
			?.closest('tr');
		if (pairedRow) {
			const pairedPctField = pairedRow.querySelector('.posting-deduction-pct-field');
			if (pairedPctField) pairedPctField.value = 100 - pct;
			const pairedSplitBtn = pairedRow.querySelector('.split-btn');
			if (pairedSplitBtn) {
				pairedSplitBtn.disabled = false;
				pairedSplitBtn.dataset.deductionPct = 100 - pct;
				pairedSplitBtn.textContent = `${100 - pct}%`;
			}
		}

		// Save convenience default back to account
		const opt1 = sel1.querySelector(`option[value="${sel1.value}"]`);
		const saveUrl = opt1?.dataset.saveUrl;
		if (saveUrl && pct >= 1 && pct <= 99) {
			const csrf = csrfToken();
			fetch(saveUrl, {
				method: 'PATCH',
				headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf },
				body: JSON.stringify({ deduction_percentage: pct })
			});
		}

		document.getElementById('split-modal').close();
		if (document.getElementById('bank-postings-table')) this.calculateBankBalance();
	},
	async injectSplitRow(sourceRow, accountId, amount, pairId = null, description = '') {
		const isBank     = !!document.getElementById('bank-postings-table');
		const templateId = isBank ? 'bank-posting-template' : 'posting-template';
		const template   = document.getElementById(templateId);
		if (!template) return;

		const index = new Date().getTime();
		const html  = template.innerHTML.replace(/NEW_INDEX/g, index).replace('posting-row', 'posting-row list-line-odd');
		sourceRow ? sourceRow.insertAdjacentHTML('afterend', html)
		          : document.querySelector('#bank-postings-table tbody, #postings-table tbody')
		                    ?.insertAdjacentHTML('beforeend', html);

		const newRow = sourceRow?.nextElementSibling
		            || document.querySelector('#bank-postings-table tbody, #postings-table tbody')?.lastElementChild;
		if (!newRow) return;

		const amountInput = newRow.querySelector('.posting-amount, input[data-amount-field]');
		if (amountInput) amountInput.value = amount;

		const descInput = newRow.querySelector('input[name*="[description]"]');
		if (descInput && description) descInput.value = description;

		await TomSelectHelper.initInContainer(newRow);
		const ts = TomSelectHelper.getInstance(newRow.querySelector('.posting-account'));

		if (isBank) {
			ts?.on('change', () => this.calculateBankBalance());
		}
		ts?.setValue(accountId);

		const pairIdInput = newRow.querySelector('.posting-deduction-pair-id');
		if (pairIdInput && pairId) pairIdInput.value = pairId;
	},
	groupPairedPostings() {
		const tbodies = document.querySelectorAll('#bank-postings-table tbody, #postings-table tbody');
		tbodies.forEach(tbody => {
		    const seen = new Set();
		    Array.from(tbody.querySelectorAll('tr')).forEach(row => {
		        const pairId = row.querySelector('.posting-deduction-pair-id')?.value;
		        if (!pairId || seen.has(pairId)) return;
		        seen.add(pairId);
		        const partnerRow = Array.from(tbody.querySelectorAll('.posting-deduction-pair-id'))
		            .find(el => el.value === pairId && el.closest('tr') !== row)
		            ?.closest('tr');
		        if (partnerRow && row.nextElementSibling !== partnerRow) {
		            row.insertAdjacentElement('afterend', partnerRow);
		        }
		    });
		});
	},
	/* Setup debounced AJAX filter for accounts index */
	setupAccountsFilter() {
		const filterInput = document.getElementById('accounts-filter-input');
		if (!filterInput) return;

		filterInput.focus();

		/* Keyboard rescue: the filter is autofocused for quick typing, but a keyboard
		   user's very first Tab should reach the skip-link (top of page), not leap
		   forward past the menu. One-shot — typing or any later Tab behaves normally. */
		let firstTab = true;
		filterInput.addEventListener('keydown', (e) => {
			if (!firstTab || e.key !== 'Tab' || e.shiftKey) return;
			e.preventDefault();
			firstTab = false;
			document.getElementById('skip-link')?.focus();
		});
		filterInput.addEventListener('input', () => { firstTab = false; });
		
		let controller = null;
          
		const tbody = document.getElementById('accounts-table-body');
		const paginationContainer = document.querySelector('.pagy');
          
		filterInput.addEventListener('input', (e) => {
            
			// Clear previous timeout
			if (filterTimeout) clearTimeout(filterTimeout);
			if (controller) controller.abort();
            
			// Debounce: wait 300ms after user stops typing
			filterTimeout = setTimeout(() => {
				controller = new AbortController();
				this.filterAccounts(e.target.value.trim(), tbody, paginationContainer, controller.signal);
			}, 300);
		});
	},
	/* Perform AJAX filter request */
	async filterAccounts(filterValue, tbody, paginationContainer) {
		try {
			//const url = new URL(window.location.origin + '/accounts');
			const url = new URL(window.location.href.split('?')[0]);
			if (filterValue) {
				url.searchParams.set('filter', filterValue);
			}
			url.searchParams.set('format', 'json');
            
			const response = await fetch(url, {
				method: 'GET',
				headers: {
					'Accept': 'application/json',
					'X-Requested-With': 'XMLHttpRequest'
				}
			});
            
			if (!response.ok) {
				throw new Error(`HTTP error! status: ${response.status}`);
			}
            
			const data = await response.json();
            
			// Update table body
			if (tbody && data.html) {
				tbody.innerHTML = data.html;
			}
            
			// Hide/show pagination based on filter
			if (paginationContainer) {
				if (filterValue) {
					paginationContainer.style.display = 'none';
				} else {
					paginationContainer.style.display = '';
				}
			}

			// Keep CSV link in sync with current filter
			const csvLink = document.querySelector('a[href*="accounts"][href*="csv"]');
			if (csvLink) {
				const csvUrl = new URL(csvLink.href, location.origin);
				filterValue ? csvUrl.searchParams.set('filter', filterValue) : csvUrl.searchParams.delete('filter');
				csvLink.href = csvUrl.toString();
			}
		} catch (error) {
			console.error('Filter request failed:', error);
		}
	},
	/* Setup debounced AJAX filter for journal entries index */
	setupJournalEntriesFilter() {
		const searchInput = document.getElementById('je-filter-input');
		if (!searchInput) return;

		searchInput.focus();

		const fromInput = document.getElementById('je-filter-from');
		const toInput   = document.getElementById('je-filter-to');
		const tbody     = document.getElementById('je-table-body');
		const pagination = document.querySelector('.pagy');

		const run = () => {
			if (filterTimeout) clearTimeout(filterTimeout);
			filterTimeout = setTimeout(() => {
				this.filterJournalEntries(
					searchInput.value.trim(),
					fromInput?.value || '',
					toInput?.value || '',
					tbody,
					pagination
				);
			}, 300);
		};

		searchInput.addEventListener('input', run);
		fromInput?.addEventListener('change', run);
		toInput?.addEventListener('change', run);
	},
	async filterJournalEntries(search, startDate, endDate, tbody, pagination) {
		try {
			const url = new URL(window.location.href.split('?')[0]);
			if (search)    url.searchParams.set('search', search);
			if (startDate) url.searchParams.set('start_date', startDate);
			if (endDate)   url.searchParams.set('end_date', endDate);
			url.searchParams.set('format', 'json');

			const response = await fetch(url, {
				headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
			});
			if (!response.ok) throw new Error(`HTTP ${response.status}`);

			const data = await response.json();
			if (tbody && data.html) tbody.innerHTML = data.html;

			if (pagination) {
				pagination.style.display = (search || startDate || endDate) ? 'none' : '';
			}

			// Keep CSV link in sync with current filters
			const csvLink = document.querySelector('a[href*="journal_entries"][href*="csv"]');
			if (csvLink) {
				const csvUrl = new URL(csvLink.href, location.origin);
				search    ? csvUrl.searchParams.set('search', search)     : csvUrl.searchParams.delete('search');
				startDate ? csvUrl.searchParams.set('start_date', startDate) : csvUrl.searchParams.delete('start_date');
				endDate   ? csvUrl.searchParams.set('end_date', endDate)  : csvUrl.searchParams.delete('end_date');
				csvLink.href = csvUrl.toString();
			}
		} catch (error) {
			console.error('JE filter failed:', error);
		}
	},
	/* bank transfer form now with currency exchange */
	getTransferCurrencies() {
	  const form = document.getElementById('transfer_entry_form');
	  if (!form?.dataset.transferCurrenciesValue) return {};
	  try {
	    return JSON.parse(form.dataset.transferCurrenciesValue);
	  } catch (e) {
	    return {};
	  }
	},
	updateTransferCurrencies() {
	  const currencies = this.getTransferCurrencies();
	  const fromSelect = document.getElementById('journal_entry_from_account_id');
	  const toSelect = document.getElementById('journal_entry_to_account_id');
  
	  const fromCurrency = currencies[fromSelect?.value] || '';
	  const toCurrency = currencies[toSelect?.value] || '';
  
	  // Update indicators
	  const fromIndicator = document.querySelector('[data-transfer-target="fromCurrency"]');
	  const toIndicator = document.querySelector('[data-transfer-target="toCurrency"]');
	  if (fromIndicator) fromIndicator.textContent = fromCurrency;
	  if (toIndicator) toIndicator.textContent = toCurrency;
  
	  // Show/hide cross-currency fields
	  const isCrossCurrency = fromCurrency && toCurrency && fromCurrency !== toCurrency;
	  const targetWrapper = document.getElementById('target_amount_wrapper');
	  const rateWrapper = document.getElementById('exchange_rate_display');
  
	  if (targetWrapper) targetWrapper.classList.toggle('hidden', !isCrossCurrency);
	  if (rateWrapper) rateWrapper.classList.toggle('hidden', !isCrossCurrency);
  
	  // Update labels
	  const sourceLabel = document.querySelector('label[for="journal_entry_transfer_amount_display"]');
	  if (sourceLabel) sourceLabel.textContent = fromCurrency ? `Amount Sent (${fromCurrency})` : 'Amount Sent';
  
	  const targetLabel = document.querySelector('label[for="journal_entry_target_amount_display"]');
	  if (targetLabel) targetLabel.textContent = toCurrency ? `Amount Received (${toCurrency})` : 'Amount Received';
  
	  this.calculateTransferRate();
	},
	calculateTransferRate() {
	  const rateDisplay = document.querySelector('[data-transfer-target="rateDisplay"]');
	  if (!rateDisplay) return;
  
	  const sourceInput = document.getElementById('journal_entry_transfer_amount_display');
	  const targetInput = document.getElementById('journal_entry_target_amount_display');
  
	  const parseAmount = (value) => (parseAmountToCents(value) || 0) / 100;
  
	  const sourceValue = parseAmount(sourceInput?.value);
	  const targetValue = parseAmount(targetInput?.value);
  
	  rateDisplay.textContent = (sourceValue > 0 && targetValue > 0) 
	    ? (targetValue / sourceValue).toFixed(4) 
	    : '—';
	},
	/* The confirm() text when a transfer's two amounts imply a rate more than
	   50% off the published one, or null when there is nothing to warn about
	   (same currency, an amount missing, or no published rate to compare with).
	   The gap between what they typed and what the published rate says lands
	   in translated reports as extra profit or loss — that figure is quoted. */
	async transferRateWarning(form) {
	  const currencies = this.getTransferCurrencies();
	  const from = currencies[document.getElementById('journal_entry_from_account_id')?.value];
	  const to   = currencies[document.getElementById('journal_entry_to_account_id')?.value];
	  if (!from || !to || from === to) return null;

	  const sourceCents = parseAmountToCents(document.getElementById('journal_entry_transfer_amount_display')?.value);
	  const targetCents = parseAmountToCents(document.getElementById('journal_entry_target_amount_display')?.value);
	  if (!sourceCents || !targetCents || sourceCents <= 0 || targetCents <= 0) return null;

	  const date = document.getElementById('journal_entry_entry_date')?.value || '';
	  let published;
	  try {
	    const resp = await fetch(`/exchange_rates/lookup?from=${from}&to=${to}&date=${date}`,
	                             { headers: { Accept: 'application/json' } });
	    published = resp.ok ? (await resp.json()).rate : null;
	  } catch { published = null; }
	  if (!published || published <= 0) return null;

	  const implied = targetCents / sourceCents;
	  if (Math.abs(implied - published) / published <= 0.5) return null;

	  const tpl = form.dataset.rateWarning;
	  if (!tpl) return null;
	  const overCents = targetCents - Math.round(sourceCents * published);
	  const impactTpl = overCents >= 0 ? form.dataset.rateWarningProfit : form.dataset.rateWarningLoss;
	  const impact = (impactTpl || '').replace('{{amount}}', `${to} ${formatAmountFromCents(Math.abs(overCents))}`);
	  return tpl
	    .replace('{{from}}', from)
	    .replace('{{to}}', to)
	    .replace('{{implied}}', implied.toFixed(4))
	    .replace('{{published}}', Number(published).toFixed(4))
	    .replace('{{impact}}', impact);
	},
	/* calculate exchange rates modal */
	async fetchFxRate() {
	    const from = document.getElementById('fx-from-currency')?.value;
	    const to = document.getElementById('fx-to-currency')?.value;
	    const dateStr = document.getElementById('fx-rate-date')?.value;
	    if (!from || !to || !dateStr || from === to) {
	        document.getElementById('fx-rate').value = from === to ? '1' : '';
	        this.calculateFxResult();
	        return;
	    }
	    // Convert "2025-02" to "2025-02-01" for the backend
	    const date = dateStr + '-01';
	    try {
	        const resp = await fetch(`/exchange_rates/lookup?from=${from}&to=${to}&date=${date}`);
	        if (resp.ok) {
	            const data = await resp.json();
	            const rateEl = document.getElementById('fx-rate');
	            const sourceEl = document.getElementById('fx-rate-source');
	            if (data.rate) {
	                rateEl.value = data.rate;
	                if (sourceEl) sourceEl.textContent = data.source.toUpperCase();
	            } else {
	                rateEl.value = '';
	                if (sourceEl) sourceEl.textContent = 'no rate found';
	            }
	            this.calculateFxResult();
	        }
	    } catch (e) {
	        console.error('FX lookup failed:', e);
	    }
	},
	calculateFxResult() {
	    const amount = (parseAmountToCents(document.getElementById('fx-start-amount')?.value) || 0) / 100;
	    const rate = parseFloat(document.getElementById('fx-rate')?.value) || 0;
	    const result = document.getElementById('fx-result');
	    if (result) result.value = (amount && rate) ? (amount * rate).toFixed(2) : '';
	},
	/* Lock currency field to parent's currency; unlock when parent is cleared */
	lockCurrencyFromParent(parentSelect) {
		const currencySelect = document.getElementById('account_currency');
		if (!currencySelect) return;
		const option = parentSelect.options[parentSelect.selectedIndex];
		const currency = option?.dataset.currency;
		document.getElementById('currency-lock-input')?.remove();
		if (currency) {
			currencySelect.value = currency;
			currencySelect.disabled = true;
			const hidden = Object.assign(document.createElement('input'), {
				type: 'hidden', id: 'currency-lock-input',
				name: currencySelect.name, value: currency
			});
			currencySelect.insertAdjacentElement('afterend', hidden);
		} else {
			currencySelect.disabled = false;
		}
	},
	/* Fetch app balance for the reconcile modal */
	async fetchReconcileBalance() {
		const modal = document.getElementById('reconcile-modal');
		if (!modal) return;
		const baseUrl = modal.dataset.balanceAtUrl;
		const date = document.getElementById('reconcile-date')?.value;
		if (!baseUrl || !date) return;
		const appBalanceEl = document.getElementById('reconcile-app-balance');
		appBalanceEl.textContent = '…';
		try {
			const resp = await fetch(`${baseUrl}?date=${date}`);
			if (!resp.ok) throw new Error();
			const data = await resp.json();
			modal.dataset.appBalanceCents = data.balance_cents;
			appBalanceEl.textContent = this.formatReconcileAmount(data.balance_cents, data.currency);
			this.updateReconcileDifference();
		} catch(e) {
			appBalanceEl.textContent = '—';
		}
	},
	/* Calculate and display the difference */
	updateReconcileDifference() {
		const modal = document.getElementById('reconcile-modal');
		const diffEl = document.getElementById('reconcile-difference');
		if (!modal || !diffEl) return;
		const appCents = parseInt(modal.dataset.appBalanceCents, 10);
		if (isNaN(appCents)) { diffEl.textContent = '—'; return; }
		const statementCents = parseAmountToCents(document.getElementById('reconcile-statement')?.value);
		if (statementCents === null) { diffEl.textContent = '—'; diffEl.className = ''; return; }
		const diff = statementCents - appCents;
		diffEl.textContent = this.formatReconcileAmount(diff, modal.dataset.currency);
		diffEl.className = diff === 0 ? 'reconcile-match' : 'reconcile-mismatch';
	},
	formatReconcileAmount(cents, currency) {
		return `${cents < 0 ? '-' : ''}${currency} ${formatAmountFromCents(Math.abs(cents))}`;
	},
	/* close modal for editing in reports */
	closeModal(){
	  const modal = document.getElementById('edit-modal');
	  if (!modal) return;
	  modal.close();
	}
};

export default Accounts;
