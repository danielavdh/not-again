// app/javascript/scripts/receipts.js
import { delegate, showElementSmoothly, hideElementSmoothly, csrfToken } from "scripts/utils";

const Receipts = {
  init() {
	  const config = document.getElementById('receipts-config');
	  if (!config) return;
	  this.paths = {
	    receipts: config.dataset.receiptsPath,
	    forPosting: config.dataset.forPostingPath,
	    unlinked: config.dataset.unlinkedPath,
	    link: config.dataset.linkPath
	  };
	  const pickerModal  = document.getElementById('receipt-picker-modal');
	  const previewModal = document.getElementById('receipt-preview-modal');
	  const uploadModal  = document.getElementById('receipt-upload-modal');
	  this.i18n = {
	    loading:      pickerModal?.dataset.textLoading     || 'Loading...',
	    empty:        pickerModal?.dataset.textEmpty        || 'No unlinked receipts available',
	    errorLoad:    pickerModal?.dataset.textErrorLoad    || 'Failed to load receipts',
	    errorLink:    pickerModal?.dataset.textErrorLink    || 'Failed to link receipt',
	    linked:       pickerModal?.dataset.textLinked       || 'Linked',
    viewReceipts: pickerModal?.dataset.textViewReceipts || 'Receipts',
    linkExisting: pickerModal?.dataset.textLinkExisting || 'Link receipt',
	    errorUnlink:  previewModal?.dataset.textErrorUnlink || 'Failed to unlink receipt',
	    errorUpload:  uploadModal?.dataset.textErrorUpload  || 'Upload failed'
	  };
      this.pickedReceiptsData = {};
      this.pickerTargetIndex = null;
      this.attachListeners();
  },

  attachListeners() {
    // Bulk download (§8): the header checkbox ticks/unticks every receipt
    // row on THIS page only — there is no cross-page "select all matching",
    // deliberately, to match the bank-statement pattern this was modelled on.
    delegate(document, 'change', '[data-action="select-all-receipts"]', (e, checkbox) => {
	  document.querySelectorAll('[data-role="receipt-checkbox"]').forEach((box) => {
	    box.checked = checkbox.checked;
	  });
	});

    // Preview receipt on thumbnail click or view button
	delegate(document, 'click', '[data-action="preview-receipt"]', (e, el) => {
	  e.preventDefault();
	  const receiptId = el.dataset.receiptId;
	  const postingId = el.closest('[data-posting-id]')?.dataset.postingId;
	  if (receiptId) this.showPreview(receiptId, { postingId });
	});
	
	delegate(document, 'click', '[data-action="upload-receipt-for-posting"]', (e, btn) => {
	  e.preventDefault();
	  const postingId = btn.dataset.postingId;
	  const modal = document.getElementById('receipt-upload-modal');
	  if (!modal) return;

	  modal.dataset.mode = 'persisted';
	  modal.dataset.postingIndex = '';
	  modal.dataset.standalone = '';

	  const form = modal.querySelector('.form_receipt');
	  if (form) form.reset();
	  form?.querySelector('.receipt-file-preview')?.classList.add('hidden');

	  const postingField = form?.querySelector('.receipt-form-posting-id');
	  if (postingField) postingField.value = postingId;

	  // Auto-select the entity from THIS posting row's account.
	  this.setReceiptEntityFromRow(btn.closest('tr'), form);

	  modal.showModal();
	});
	// --- Open upload modal for new (unsaved) postings too ---
	delegate(document, 'click', '[data-action="capture-receipt-for-new-posting"]', (e, btn) => {
	  e.preventDefault();
	  const modal = document.getElementById('receipt-upload-modal');
	  if (!modal) return;

	  modal.dataset.mode = 'new';
	  modal.dataset.postingIndex = btn.dataset.postingIndex;
	  modal.dataset.standalone = '';

	  const form = modal.querySelector('.form_receipt');
	  const postingField = form?.querySelector('.receipt-form-posting-id');
	  if (postingField) postingField.value = '';

	  if (form) form.reset();
	  form?.querySelector('.receipt-file-preview')?.classList.add('hidden');

	  // Auto-select the entity from THIS (new) posting row's account.
	  this.setReceiptEntityFromRow(btn.closest('tr'), form);

	  modal.showModal();
	});

	// View receipts already linked to a posting
	delegate(document, 'click', '[data-action="view-posting-receipts"]', (e, btn) => {
	  e.preventDefault();
	  const postingId = btn.dataset.postingId;
	  this.showPostingReceiptsViewer(postingId);
	});

    // Link existing receipt to posting
    delegate(document, 'click', '[data-action="link-existing-receipt"]', (e, btn) => {
      e.preventDefault();
      this.pickerTargetIndex = null;
      const postingId = btn.dataset.postingId;
      this.showReceiptPicker(postingId);
    });
	// Link existing receipt to NEW (unsaved) posting
	delegate(document, 'click', '[data-action="link-existing-receipt-for-new-posting"]', (e, btn) => {
	  e.preventDefault();
	  this.pickerTargetIndex = btn.dataset.postingIndex;
	  this.showReceiptPicker(null);
	});
	// View receipts already picked for a new (unsaved) posting
	delegate(document, 'click', '[data-action="view-linked-receipts-for-new-posting"]', (e, btn) => {
	  e.preventDefault();
	  this.showPickedReceiptsViewer(btn.dataset.postingIndex);
	});

	// Unlink receipt from posting (edit form widget)
	delegate(document, 'click', '[data-action="unlink-receipt"]', (e, btn) => {
	  e.preventDefault();
	  const receiptId = btn.dataset.receiptId;
	  const postingId = btn.dataset.postingId;
	  if (receiptId) this.unlinkReceipt(receiptId, postingId);
	});
	
	// Pick a receipt from the picker modal
	delegate(document, 'click', '[data-action="pick-receipt"]', (e, el) => {
	  e.preventDefault();
	  const receiptId = el.dataset.receiptId;
	  const postingId = el.dataset.postingId;

	  if (this.pickerTargetIndex != null) {
	    // New posting: accumulate receipt IDs in the hidden field
	    const idx = this.pickerTargetIndex;
	    const idField = document.querySelector(`[data-receipt-id="${idx}"]`);
	    if (idField) {
	      const current = idField.value ? idField.value.split(',') : [];
	      if (!current.includes(receiptId)) {
	        current.push(receiptId);
	        idField.value = current.join(',');
	      }
	    }
	    // Cache receipt data for the view button
	    if (!this.pickedReceiptsData[idx]) this.pickedReceiptsData[idx] = [];
	    if (!this.pickedReceiptsData[idx].some(r => r.id === receiptId)) {
	      this.pickedReceiptsData[idx].push({
	        id: receiptId,
	        thumbnailSrc: el.querySelector('.receipt-picker-thumb')?.src || '',
	        filename: el.querySelector('.receipt-picker-info strong')?.textContent || '',
	        description: el.querySelector('.receipt-picker-info span')?.textContent || ''
	      });
	    }
	    if (!document.querySelector(`[data-action="view-linked-receipts-for-new-posting"][data-posting-index="${idx}"]`)) {
	      const widget = document.querySelector(`.receipt-posting-widget [data-action="link-existing-receipt-for-new-posting"][data-posting-index="${idx}"]`)?.closest('.receipt-posting-widget');
	      if (widget) {
	        const viewBtn = this.viewButton();
	        if (!viewBtn) return;
	        viewBtn.dataset.action = 'view-linked-receipts-for-new-posting';
	        viewBtn.dataset.postingIndex = idx;
	        widget.insertBefore(viewBtn, widget.firstChild);
	      }
	    }
	    el.classList.add('is-picked');
	  } else if (receiptId && postingId) {
	    // Persisted posting: AJAX link
	    this.linkReceipt(receiptId, postingId);
	  }
	});
    // File input preview (both regular form and quick upload)
    delegate(document, 'change', '[data-receipt-file], [data-receipt-camera]', (e, input) => {
      this.handleFilePreview(input);
    });

	/* modal - open & close via hook, initModals called in index.js */
	document.getElementById('receipt-upload-modal')?.addEventListener('modal:before-open', (e) => {
	  const el = e.detail.trigger;
	  const modal = e.currentTarget;

	  if (el.dataset.standalone === 'true') {
	    modal.dataset.standalone = 'true';
	    modal.dataset.mode = '';
	    modal.dataset.postingIndex = '';
	  }

	  const form = modal.querySelector('.form_receipt');
	  if (form) form.reset();
	  form?.querySelector('.receipt-file-preview')?.classList.add('hidden');
	});

	// Close dialog on backdrop click
	delegate(document, 'click', 'dialog[data-close-on-backdrop]', (e, dialog) => {
	  if (e.target === dialog) dialog.close();
	});

	// unlink receipt from preview modal in edit bank/journal entries
	delegate(document, 'click', '#receipt-unlink-btn', (e, btn) => {
	  e.preventDefault();
	  const receiptId = btn.dataset.receiptId;
	  const postingId = btn.dataset.postingId;
	  if (receiptId && postingId) {
	    this.unlinkReceipt(receiptId, postingId);
	  }
	});
	
	// Intercept form submit inside dialog — AJAX instead of full page submit
	delegate(document, 'submit', 'dialog .form_receipt', (e, form) => {
	  e.preventDefault();
	  const modal = form.closest('dialog');

	  if (modal?.dataset.mode === 'new') {
	    // New (unsaved) posting: copy fields to nested attributes
	    const idx = modal.dataset.postingIndex;
	    const titleField = document.querySelector(`[data-receipt-title="${idx}"]`);
	    const dateField = document.querySelector(`[data-receipt-date="${idx}"]`);
	    const descField = document.querySelector(`[data-receipt-description="${idx}"]`);
	    const scanField = document.querySelector(`[data-receipt-scan="${idx}"]`);
	    const filenameSpan = document.querySelector(`[data-receipt-filename="${idx}"]`);

	    if (titleField) titleField.value = form.querySelector('[name*="[title]"]').value;
	    if (dateField) dateField.value = form.querySelector('[name*="[receipt_date]"]').value;
	    if (descField) descField.value = form.querySelector('[name*="[description]"]').value;

	    const fileInput = form.querySelector('[name*="[scan]"]');
	    const file = fileInput?.files[0];
	    if (scanField && file) {
	      const dt = new DataTransfer();
	      dt.items.add(file);
	      scanField.files = dt.files;
	    }
	    if (filenameSpan) filenameSpan.textContent = '';

	    const uploadBtn = document.querySelector(`[data-action="capture-receipt-for-new-posting"][data-posting-index="${idx}"]`);
	    if (uploadBtn) {
	      uploadBtn.classList.add('has-receipt');
	      const widget = uploadBtn.closest('.receipt-posting-widget');
	      if (widget && !widget.querySelector('[data-action="preview-local-receipt"]')) {
	        const viewBtn = Receipts.viewButton();
	        if (!viewBtn) return;
	        viewBtn.dataset.action = 'preview-local-receipt';
	        viewBtn.dataset.postingIndex = idx;
	        widget.insertBefore(viewBtn, uploadBtn);
	      }
	    }

	    modal.close();
	  } else {
	    Receipts.handleQuickUpload(form, modal);
	  }
	});
	// Preview receipt attached to an unsaved (new) posting from local file
	delegate(document, 'click', '[data-action="preview-local-receipt"]', (e, btn) => {
	  e.preventDefault();
	  const idx = btn.dataset.postingIndex;
	  const scanInput = document.querySelector(`[data-receipt-scan="${idx}"]`);
	  const file = scanInput?.files[0];
	  if (file) this.showLocalFilePreview(file);
	});
	// Retake / re-choose file
	delegate(document, 'click', '[data-action="retake-photo"]', (e, btn) => {
	  const form = btn.closest('form');
	  const preview = form.querySelector('.receipt-file-preview');
	  const inputs = form.querySelectorAll('.receipt-file-input');
	  inputs.forEach(input => { input.value = ''; });
	  if (preview) hideElementSmoothly(preview);
	});
	// Paste receipt from clipboard
	delegate(document, 'paste', '.form_receipt', (e, form) => {
	  const items = e.clipboardData?.items;
	  if (!items) return;

	  for (const item of items) {
	    if (item.type.match(/^image\//) || item.type === 'application/pdf') {
	      e.preventDefault();
	      const file = item.getAsFile();
	      if (!file) return;

	      const input = form.querySelector('.receipt-file-input');
	      if (input) {
	        const dt = new DataTransfer();
	        dt.items.add(file);
	        input.files = dt.files;
	        input.dispatchEvent(new Event('change', { bubbles: true }));
	      }
	      return;
	    }
	  }
	});
  },

  // Show full preview modal for a receipt
  async showPreview(receiptId, opts = {}) {
    const modal = document.getElementById('receipt-preview-modal');
    if (!modal) return;

    try {
      const response = await fetch(`${this.paths.receipts}/${receiptId}.json`);
      const data = await response.json();

      const img = document.getElementById('receipt-preview-img');
      const title = document.getElementById('receipt-preview-title');
      const desc = document.getElementById('receipt-preview-description');
      const downloadLink = document.getElementById('receipt-download-link');
      const unlinkBtn = document.getElementById('receipt-unlink-btn');

      if (img) {
        img.src = data.preview_url || data.thumbnail_url || '';
        img.alt = data.title;
      }
      if (title) title.textContent = data.filename || data.title;
      if (desc) desc.textContent = data.description || '';

      // Context-aware actions: edit form shows unlink, otherwise download
      if (opts.postingId) {
        if (downloadLink) downloadLink.classList.add('hidden');
        if (unlinkBtn) {
          unlinkBtn.classList.remove('hidden');
          unlinkBtn.dataset.receiptId = receiptId;
          unlinkBtn.dataset.postingId = opts.postingId;
        }
      } else {
        if (downloadLink) {
          downloadLink.classList.remove('hidden');
          downloadLink.href = data.original_url || '#';
          downloadLink.download = data.filename || 'receipt';
        }
        if (unlinkBtn) unlinkBtn.classList.add('hidden');
      }

      modal.showModal();
    } catch (err) {
      console.error('Failed to load receipt preview:', err);
    }
  },
  
  // A fresh "view receipts" button, cloned from the <template> in
  // _picker_modal.html.erb. The caller sets its data-action.
  viewButton() {
    const template = document.getElementById('view-receipts-button-template');
    return template ? template.content.firstElementChild.cloneNode(true) : null;
  },

  // Loading / empty / error placeholder in a list. Text, not markup — the one
  // thing this file is allowed to put on the page by itself.
  setStatus(list, kind, text) {
    const p = document.createElement('p');
    p.className = kind;
    p.textContent = text;
    list.replaceChildren(p);
  },

  // Show receipts already linked to a posting (view mode — click to preview)
  async showPostingReceiptsViewer(postingId) {
    const modal = document.getElementById('receipt-picker-modal');
    const list  = document.getElementById('receipt-picker-list');
    if (!modal || !list) return;

    const heading = modal.querySelector('h3');
    if (heading) heading.textContent = this.i18n.viewReceipts;
    this.setStatus(list, "loading", this.i18n.loading);
    modal.showModal();

    try {
      const url = this.paths.forPosting.replace(':posting_id', postingId);
      const response = await fetch(url, { headers: { Accept: 'text/html' } });
      list.innerHTML = await response.text();
    } catch (err) {
      this.setStatus(list, "error", this.i18n.errorLoad);
      console.error('Failed to load posting receipts:', err);
    }
  },

  /* Auto-select the receipt modal's entity from the account chosen in the posting
     row it was opened from (the account's entity code → the matching entity option).
     Normal rows read the account select; cross-entity mirror rows carry data-ce-entity.
     Single-entity forms use a fixed hidden field, so there is nothing to pick. */
  setReceiptEntityFromRow(row, form) {
    if (!row || !form) return;
    const code = row.querySelector('select.posting-account')?.selectedOptions?.[0]?.dataset.entity
              || row.dataset.ceEntity;
    if (!code) return;
    const field = form.querySelector('[name*="[entity_id]"]');
    if (field?.tagName !== 'SELECT') return; // single-entity: fixed hidden field
    const opt = field.querySelector(`option[data-code="${code}"]`);
    if (opt) field.value = opt.value;
  },

  // Show receipts picked for a new (unsaved) posting — data from in-memory cache
  showPickedReceiptsViewer(idx) {
    const modal = document.getElementById('receipt-picker-modal');
    const list  = document.getElementById('receipt-picker-list');
    if (!modal || !list) return;

    const heading = modal.querySelector('h3');
    if (heading) heading.textContent = this.i18n.viewReceipts;

    // The one list with no server-side record to render: these receipts were
    // picked for a posting that has not been saved yet, so they live in memory.
    // Built with DOM nodes rather than a template string — the values were read
    // out of the page with textContent, and putting them back through innerHTML
    // would parse them as markup again.
    const receipts = this.pickedReceiptsData[idx] || [];
    list.replaceChildren();

    if (receipts.length === 0) {
      const empty = document.createElement('p');
      empty.className = 'empty';
      empty.textContent = this.i18n.empty;
      list.append(empty);
    } else {
      receipts.forEach(r => {
        const item = document.createElement('div');
        item.className = 'receipt-picker-item';
        item.dataset.action = 'preview-receipt';
        item.dataset.receiptId = r.id;

        const thumb = document.createElement('img');
        thumb.className = 'receipt-picker-thumb';
        thumb.src = r.thumbnailSrc;
        thumb.alt = r.filename;

        const info = document.createElement('div');
        info.className = 'receipt-picker-info';
        const name = document.createElement('strong');
        name.textContent = r.filename;
        const desc = document.createElement('span');
        desc.textContent = r.description;
        info.append(name, desc);

        item.append(thumb, info);
        list.append(item);
      });
    }
    modal.showModal();
  },

  // Show receipt picker modal with unlinked receipts
  async showReceiptPicker(postingId) {
    const modal = document.getElementById('receipt-picker-modal');
    const list = document.getElementById('receipt-picker-list');
    if (!modal || !list) return;

    const heading = modal.querySelector('h3');
    if (heading) heading.textContent = this.i18n.linkExisting;
    this.setStatus(list, "loading", this.i18n.loading);
    modal.showModal();

    try {
      const url = `${this.paths.unlinked}?posting_id=${encodeURIComponent(postingId)}`;
      const response = await fetch(url, { headers: { Accept: 'text/html' } });
      list.innerHTML = await response.text();
    } catch (err) {
      this.setStatus(list, "error", this.i18n.errorLoad);
      console.error('Failed to load unlinked receipts:', err);
    }
  },

  // Link a receipt to a posting via AJAX
  async linkReceipt(receiptId, postingId) {
    try {
      const token = csrfToken();
      const response = await fetch(this.paths.link.replace(':id', receiptId), {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': token,
          'Accept': 'application/json'
        },
        body: JSON.stringify({ posting_id: postingId })
      });

      if (response.ok) {
        const data = await response.json();
                const pickerItem = document.querySelector(`#receipt-picker-list [data-receipt-id="${receiptId}"]`);
        if (pickerItem) pickerItem.classList.add('is-picked');
        // Update the receipt widget for this posting
        this.refreshPostingReceipts(postingId);
      } else {
        const err = await response.json();
        alert(err.error || this.i18n.errorLink);
      }
    } catch (err) {
      console.error('Failed to link receipt:', err);
    }
  },

  async unlinkReceipt(receiptId, postingId) {
    try {
      const token = csrfToken();
      const response = await fetch(`${this.paths.receipts}/${receiptId}/unlink`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': token,
          'Accept': 'application/json'
        }
      });

      if (response.ok) {
		document.getElementById('receipt-preview-modal')?.close();
        document.querySelector(`#receipt-picker-list [data-receipt-id="${receiptId}"]`)?.classList.add('is-picked');
        this.refreshPostingReceipts(postingId);
      } else {
        const err = await response.json();
        alert(err.error || this.i18n.errorUnlink);
      }
    } catch (err) {
      console.error('Failed to unlink receipt:', err);
    }
  },
  

  // Handle quick upload form via AJAX
  async handleQuickUpload(form, modal) {
    const formData = new FormData(form);
    const token = csrfToken();

    try {
      const response = await fetch(form.action, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': token,
          'Accept': 'application/json'
        },
        body: formData
      });

      if (response.ok) {
        const data = await response.json();
        modal?.close();
        form.reset();
        form.querySelector('.receipt-file-preview')?.classList.add('hidden');

        if (modal?.dataset.standalone === 'true') {
          window.location.reload();
        } else {
          const postingId = data.posting_id;
          if (postingId) this.refreshPostingReceipts(String(postingId));
        }
      } else {
        const err = await response.json();
        alert(err.errors?.join(', ') || this.i18n.errorUpload);
      }
    } catch (err) {
      console.error('Upload failed:', err);
    }
  },
  
  // Refresh receipt state for a posting after link/unlink/upload
  async refreshPostingReceipts(postingId) {
    try {
      const response = await fetch(this.paths.forPosting.replace(':posting_id', postingId));
      const receipts = await response.json();

      const widget = document.querySelector(`.receipt-posting-widget[data-posting-id="${postingId}"]`);
      if (!widget) return;

      const viewBtn = widget.querySelector('[data-action="view-posting-receipts"]');
      if (receipts.length > 0 && !viewBtn) {
        const btn = this.viewButton();
        if (!btn) return;
        btn.dataset.action = 'view-posting-receipts';
        btn.dataset.postingId = postingId;
        widget.insertBefore(btn, widget.firstChild);
      } else if (receipts.length === 0 && viewBtn) {
        viewBtn.remove();
      }
    } catch (err) {
      console.error('Failed to refresh posting receipts:', err);
    }
  },

  // Preview a local File object in the receipt preview modal (unsaved postings)
  showLocalFilePreview(file) {
    const modal = document.getElementById('receipt-preview-modal');
    if (!modal) return;
    const img = document.getElementById('receipt-preview-img');
    const title = document.getElementById('receipt-preview-title');
    const downloadLink = document.getElementById('receipt-download-link');
    const unlinkBtn = document.getElementById('receipt-unlink-btn');

    if (title) title.textContent = file.name;
    if (downloadLink) downloadLink.classList.add('hidden');
    if (unlinkBtn) unlinkBtn.classList.add('hidden');

    if (img) {
      img.alt = file.name;
      if (file.type.startsWith('image/')) {
        const reader = new FileReader();
        reader.onload = (ev) => { img.src = ev.target.result; modal.showModal(); };
        reader.readAsDataURL(file);
        return;
      } else {
        img.src = '/fallback/receipt_thumbnail.svg';
      }
    }
    modal.showModal();
  },

  // Handle file input preview
  handleFilePreview(input) {

      const file = input.files[0];
      if (!file) return;

      const form = input.closest('form');
      const preview = form?.querySelector('.receipt-file-preview');
      const thumb = form?.querySelector('.receipt-file-preview img');
      const nameSpan = form?.querySelector('.receipt-file-preview span');
      const original = form?.querySelector('[data-original-preview]');

      if (!preview) return;

      if (original) hideElementSmoothly(original);

      nameSpan.textContent = file.name;

      if (file.type.startsWith('image/')) {
        const reader = new FileReader();
        reader.onload = (e) => {
          thumb.src = e.target.result;
          showElementSmoothly(preview);
        };
        reader.readAsDataURL(file);
      } else {
        thumb.src = '/fallback/receipt_thumbnail.svg';
        showElementSmoothly(preview);
      }
  },	

};

export default Receipts;
