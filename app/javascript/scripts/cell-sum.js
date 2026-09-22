// app/javascript/scripts/cell-sum.js
import { delegate, parseAmountToCents, formatAmountFromCents, formatCentsWithCurrency, showElementSmoothly, hideElementSmoothly, showTransientStatus } from "scripts/utils";

/* Like a spreadsheet: a click selects an amount, ⌘/Ctrl-click toggles one
   more, Shift-click adds the range from the last one. In an entry form a plain
   click still means "edit this amount" — the amount being edited becomes the
   first of the selection once a modifier-click follows.

   Summable: a table cell under a <th data-sum="EUR">, or a posting amount in
   an entry form. A selection never crosses a column or a currency, so the sum
   is always one number in one currency. */
const CellSum = {
  cells: [],
  anchor: null,

  init() {
    this.output = document.getElementById('cell-sum');
    if (!this.output) return;
    this.markSummable();
    this.attachListeners();
  },

  /* data-summable is the stylesheet's hook (cursor) — CSS cannot reach from a
     column's <th> down to its cells */
  markSummable() {
    document.querySelectorAll('th[data-sum]').forEach(th => {
      this.columnCells(th).forEach(td => {
        if (this.valueOf(td) !== null) td.setAttribute('data-summable', '');
      });
    });
  },

  attachListeners() {
    /* mousedown, not click: cancelling it keeps the focus and the text
       selection where they were, so a modifier-click never enters the field. */
    document.addEventListener('mousedown', (e) => {
      if (e.target.closest('#cell-sum')) return;
      const cell = this.summableCell(e.target);
      const modifier = e.metaKey || e.ctrlKey || e.shiftKey;
      if (!cell || !modifier) {
        this.clear();
        if (cell && cell.tagName !== 'INPUT') {
          this.toggle(cell);
          this.render();
        }
        return;
      }
      e.preventDefault();
      this.adoptEditedAmount(cell);
      if (e.shiftKey && this.anchor && this.sameGroup(this.anchor, cell)) {
        this.selectRange(this.anchor, cell);
      } else {
        this.toggle(cell);
      }
      this.render();
    });
    /* an edited amount changes the sum it is part of */
    delegate(document, 'input', '.posting-amount', (e, input) => {
      if (this.cells.includes(input)) this.render();
    });
    delegate(document, 'click', '[data-action="copy-cell-sum"]', () => {
      navigator.clipboard.writeText(formatAmountFromCents(this.total()));
      const status = this.output.querySelector('[data-copied]');
      showTransientStatus(status, status?.dataset.copied);
    });
  },

  /* The amount the cursor is in, when a modifier-click lands on another
     amount of the same form: it stops being edited and starts the selection. */
  adoptEditedAmount(cell) {
    if (this.cells.length || cell.tagName !== 'INPUT') return;
    const active = document.activeElement;
    if (active === cell || !active?.matches('.posting-amount')) return;
    if (this.summableCell(active) !== active || !this.sameGroup(active, cell)) return;
    active.blur();
    this.toggle(active);
  },

  /* true when there was a selection to clear — index.js lets Escape clear it
     before Escape navigates away */
  clear() {
    if (!this.cells.length) return false;
    this.cells.forEach(c => c.removeAttribute('aria-selected'));
    this.cells = [];
    this.anchor = null;
    this.render();
    return true;
  },

  /* an empty or unreadable amount is not summable */
  summableCell(target) {
    const input = target.closest('.posting-amount');
    if (input) {
      if (input.closest('.ce-mirror-row') || this.formCurrencies(input.form).length > 1) return null;
      return this.valueOf(input) === null ? null : input;
    }
    const td = target.closest('td');
    return td && this.header(td) && this.valueOf(td) !== null ? td : null;
  },

  /* the <th data-sum> above a cell, by column position — colspans counted,
     so a full-width header row above cannot shift it */
  header(td) {
    const head = td.closest('table')?.tHead?.rows[0];
    if (!head) return null;
    const column = this.columnOf(td);
    return Array.from(head.cells).find(th => this.columnOf(th) === column && th.hasAttribute('data-sum')) || null;
  },

  columnOf(cell) {
    let column = 0;
    for (let c = cell.previousElementSibling; c; c = c.previousElementSibling) column += c.colSpan || 1;
    return column;
  },

  /* An entry's currency is its balance accounts' — the bank form carries it
     in a hidden field per row, the journal-entry form on each account option.
     Two means a cross-currency entry, whose amounts must not be added. */
  formCurrencies(form) {
    if (!form) return [];
    const fromRows    = Array.from(form.querySelectorAll('.posting-row:not(.ce-mirror-row) .posting-currency'), i => i.value);
    const fromAccount = Array.from(form.querySelectorAll('.posting-row:not(.ce-mirror-row) select.posting-account'),
                                   s => s.selectedOptions[0]?.dataset.currency);
    return [...new Set([...fromRows, ...fromAccount].filter(Boolean))];
  },

  currencyOf(cell) {
    return cell.tagName === 'INPUT' ? (this.formCurrencies(cell.form)[0] || '') : this.header(cell).dataset.sum;
  },

  /* Same column of the same table, or posting amounts of the same form. */
  group(cell) {
    return cell.tagName === 'INPUT' ? cell.form : this.header(cell);
  },

  sameGroup(a, b) {
    return this.group(a) === this.group(b);
  },

  /* every summable cell of a group, in document order */
  members(cell) {
    if (cell.tagName === 'INPUT') {
      return Array.from(cell.form.querySelectorAll('.posting-row:not(.ce-mirror-row) .posting-amount'));
    }
    return this.columnCells(this.header(cell));
  },

  columnCells(th) {
    const column = this.columnOf(th);
    return Array.from(th.closest('table').querySelectorAll('tbody td'))
      .filter(td => this.columnOf(td) === column);
  },

  toggle(cell) {
    if (this.cells.length && !this.sameGroup(this.cells[0], cell)) this.clear();
    if (this.cells.includes(cell)) {
      this.cells = this.cells.filter(c => c !== cell);
      cell.removeAttribute('aria-selected');
    } else {
      this.cells.push(cell);
      cell.setAttribute('aria-selected', 'true');
    }
    this.anchor = cell;
  },

  selectRange(from, to) {
    const members = this.members(from);
    const [start, end] = [members.indexOf(from), members.indexOf(to)].sort((a, b) => a - b);
    members.slice(start, end + 1).forEach(cell => {
      if (this.cells.includes(cell) || this.valueOf(cell) === null) return;
      this.cells.push(cell);
      cell.setAttribute('aria-selected', 'true');
    });
  },

  valueOf(cell) {
    return parseAmountToCents(cell.tagName === 'INPUT' ? cell.value : cell.textContent);
  },

  total() {
    return this.cells.reduce((sum, cell) => sum + (this.valueOf(cell) || 0), 0);
  },

  render() {
    this.cells = this.cells.filter(c => c.isConnected);
    if (this.cells.length < 2) {
      hideElementSmoothly(this.output);
      return;
    }
    this.output.querySelector('[data-sum-count]').textContent = this.cells.length;
    this.output.querySelector('[data-sum-total]').textContent =
      formatCentsWithCurrency(this.total(), this.currencyOf(this.cells[0]));
    showElementSmoothly(this.output);
  }
};

export default CellSum;
