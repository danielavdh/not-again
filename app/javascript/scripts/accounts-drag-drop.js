import { showElementSmoothly, hideElementSmoothly, delegate, csrfToken } from "scripts/utils";

export function setupReportGroupAccountSelector() {
  const sortableList = document.querySelector('.sortable-list');
  if (!sortableList) return;

  const reportGroupId = sortableList.dataset.reportGroupId;
  let draggedItem = null;

  // Drag and drop for reordering
  delegate(document, 'dragstart', '.sortable-list li', (e, li) => {
    draggedItem = li;
    li.classList.add('dragging');
    e.dataTransfer.effectAllowed = 'move';
  });

  delegate(document, 'dragend', '.sortable-list li', (e, li) => {
    li.classList.remove('dragging');
    draggedItem = null;
    // Order is part of the data here, so a drop is an edit like any other.
    scheduleSave();
  });

  delegate(document, 'dragover', '.sortable-list', (e, list) => {
    e.preventDefault();
    const afterElement = getDragAfterElement(list, e.clientY);
    if (afterElement == null) {
      list.appendChild(draggedItem);
    } else {
      list.insertBefore(draggedItem, afterElement);
    }
  });

  // Add account button
  delegate(document, 'click', '.add-account:not([disabled])', (e, btn) => {
    const accountId = btn.dataset.accountId;
    const accountCode = btn.dataset.accountCode;
    const accountName = btn.dataset.accountName;

    // Markup comes from the <template> in _custom_assignment.html.erb; only the
    // values are set here, as text. Account names are user input.
    const template = document.getElementById('selected-account-template');
    if (!template) return;

    const li = template.content.firstElementChild.cloneNode(true);
    li.dataset.accountId = accountId;
    li.querySelector('.account-code').textContent = accountCode;
    li.querySelector('.account-name').textContent = accountName;
    li.querySelector('.remove-account').dataset.accountId = accountId;
    sortableList.appendChild(li);

    // Mark as selected in available list
    btn.disabled = true;
    btn.textContent = '✓';
    btn.closest('li').classList.add('already-selected');

    updateSelectedCount();
    scheduleSave();
  });

  // Remove account button
  delegate(document, 'click', '.remove-account', (e, btn) => {
    const accountId = btn.dataset.accountId;
    btn.closest('li').remove();

    // Unmark in available list
    const availableBtn = document.querySelector(`.add-account[data-account-id="${accountId}"]`);
    if (availableBtn) {
      availableBtn.disabled = false;
      availableBtn.textContent = '+';
      availableBtn.closest('li').classList.remove('already-selected');
    }

    updateSelectedCount();
    scheduleSave();
  });

  // Filter available accounts
  delegate(document, 'input', '.filter-input', (e, input) => {
    const filter = input.value.toLowerCase();
    document.querySelectorAll('.available-accounts li[data-account-id]').forEach(li => {
      const code = li.dataset.code || '';
      const name = li.dataset.name || '';
      const matches = code.includes(filter) || name.includes(filter);
      li.style.display = matches ? '' : 'none';
    });
  });

  // Autosave.
  //
  // ⚠️ The whole ordered list goes every time, which is what the endpoint has
  // always expected — it deletes and re-inserts in one transaction. So a save is
  // idempotent and the ORDER travels with it, which a per-account endpoint could
  // not express. That is why this screen keeps one call rather than copying the
  // tax screen's one-PATCH-per-account.
  //
  // Debounced, so clicking ten accounts in a row is one request, not ten.
  let saveTimer = null;

  function scheduleSave() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(persist, 400);
  }

  async function persist() {
    const status = document.querySelector('.save-status');
    if (!status) return;

    const accounts = Array.from(sortableList.querySelectorAll('li')).map((li, idx) => ({
      id: parseInt(li.dataset.accountId),
      position: idx
    }));

    // The words live in data attributes, set in ERB. A string here would stay
    // English in every language.
    status.textContent = status.dataset.saving;
    showElementSmoothly(status);

    try {
      const response = await fetch(status.dataset.url, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-CSRF-Token': csrfToken()
        },
        body: JSON.stringify({ accounts })
      });
      const data = await response.json();
      status.textContent = data.success ? status.dataset.saved : status.dataset.failed;
    } catch (err) {
      status.textContent = status.dataset.failed;
    }

    setTimeout(() => hideElementSmoothly(status), 3000);
  }

  function getDragAfterElement(container, y) {
    const draggableElements = [...container.querySelectorAll('li:not(.dragging)')];
    return draggableElements.reduce((closest, child) => {
      const box = child.getBoundingClientRect();
      const offset = y - box.top - box.height / 2;
      if (offset < 0 && offset > closest.offset) {
        return { offset: offset, element: child };
      } else {
        return closest;
      }
    }, { offset: Number.NEGATIVE_INFINITY }).element;
  }

  function updateSelectedCount() {
    const count = sortableList.querySelectorAll('li').length;
    document.querySelector('.selected-accounts .count').textContent = `(${count})`;
  }
}