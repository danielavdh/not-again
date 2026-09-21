export const passiveOpt = { passive: true };

export const isTouchDevice = ('ontouchstart' in window || navigator.maxTouchPoints > 0 || navigator.msMaxTouchPoints > 0);

/* Which size band the stylesheet thinks we are in.

   --is-phone and --is-desktop are set in shared/_config.scss, so the breakpoints
   live in ONE place: move them there and JS follows. Never compare
   window.innerWidth to a number — that is a second copy of the breakpoint, and it
   drifts silently.

   Read live rather than cached, so a resize or a rotation is picked up. */
function screenFlag(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim() === '1';
}
export const isPhoneWidth   = () => screenFlag('--is-phone');
export const isDesktopWidth = () => screenFlag('--is-desktop');

function isHidden(el) {
  return window.getComputedStyle(el).display === 'none';
}

/* Check for small screen and toggle language in menu */
export function toggleLanguageBar(){
	delegate(document, 'click', '.lang-toggle', (e) => {
		const phoneMenu = document.querySelector('.touch_menu');
		if (!phoneMenu || isHidden(phoneMenu)) return;
		const selector = document.getElementById('language-selector');
		if (selector.classList.contains('hidden')) {
		  showElementSmoothly(selector);
		} else {
		  hideElementSmoothly(selector);
		}
	});
	delegate(document, 'click', '.lang-close', (e) => {
	  e.preventDefault();
	  hideElementSmoothly(document.getElementById('language-selector'));
	});
}

/* Debounce function to limit the rate at which a function can fire */
export function debounce(func, wait) {
    let timeout;
    return function(...args) {
        const context = this;
        clearTimeout(timeout);
        timeout = setTimeout(() => func.apply(context, args), wait);
    };
}

export function handle_swipes(swipeLeftCallback, swipeRightCallback){
    let touchstartX = 0;
    let touchendX = 0;

    const gestureZone = document.body; // Or a more specific element if needed

    gestureZone.addEventListener('touchstart', function(event) {
        touchstartX = event.changedTouches[0].screenX;
    }, passiveOpt);

    gestureZone.addEventListener('touchend', function(event) {
        touchendX = event.changedTouches[0].screenX;
        handleGesture();
    }, passiveOpt); 

    function handleGesture() {
        const swipeThreshold = 50; // Minimum distance in pixels for a swipe
        if (touchendX < touchstartX - swipeThreshold) {
            // Swiped left
            if (swipeLeftCallback && typeof swipeLeftCallback === 'function') {
                swipeLeftCallback();
            }
        }
        if (touchendX > touchstartX + swipeThreshold) {
            // Swiped right
            if (swipeRightCallback && typeof swipeRightCallback === 'function') {
                swipeRightCallback();
            }
        }
    }
}

export function confirmDestructiveAction() {
  document.addEventListener("click", (event) => {
    // Check if the clicked element (or its parent) has the data-sure attribute
    const button = event.target.closest("[data-sure]");

    if (button) {
      const message = button.dataset.sure;
  
      // Show the confirmation dialog
      if (!confirm(message)) {
        // If user clicks "Cancel", stop the form submission
        event.preventDefault();
        event.stopPropagation();
      }
    }
  });
}

export function showElementSmoothly(element, callback) {
    if (!element) return;

    // 1. CANCEL PENDING HIDE TIMER
    if (element._hideTimer) {
        clearTimeout(element._hideTimer);
        element._hideTimer = null;
    }

    // 2. CANCEL ACTIVE HIDE PROCESS
    // This flag tells any running hide-transition to abort immediately
    element._isHiding = false;

    // 3. RESURRECT IF FADING OUT (The Fix)
    // If it's visible but currently fading out (has zero-opacity), 
    // we must snap it back to full visibility.
    if (element.classList.contains('zero-opacity')) {
        element.classList.remove('zero-opacity');
        // It is now transitioning back to full opacity.
        if (callback) callback();
        return;
    }

    // 4. ALREADY STABLE & VISIBLE
    if (!element.classList.contains('hidden')) {
        if (callback) callback();
        return;
    }

    // 5. FULL SHOW SEQUENCE (From Hidden)
    element.classList.add('zero-opacity');
    element.classList.remove('hidden');
    
    element.offsetWidth; // Force reflow
    
    element.classList.add('fade-transition');
    element.classList.remove('zero-opacity');

    element.addEventListener('transitionend', function handler() {
        element.classList.remove('fade-transition');
        element.removeEventListener('transitionend', handler);
        if (callback && typeof callback === 'function') {
            callback();
        }
    }, { once: true });
}

export function hideElementSmoothly(element, callback, delay = 0) {
    if (!element) return;

    if (element._hideTimer) {
        clearTimeout(element._hideTimer);
        element._hideTimer = null;
    }

    const performHide = () => {
        element._hideTimer = null;
        
        // Mark that we are intentionally hiding
        element._isHiding = true;

        if (element.classList.contains('hidden') || getComputedStyle(element).display === 'none') {
            if (callback) callback();
            return;
        }

        element.classList.add('fade-transition');
        element.offsetWidth;
        element.classList.add('zero-opacity');

        let hasFired = false;
        function complete() {
            if (hasFired) return;
            hasFired = true;

            // CRITICAL CHECK: Did show() cancel us?
            // If show() ran while we were fading, _isHiding will be false.
            // We abort, leaving the element visible.
            if (element._isHiding === false) return;

            element.classList.add('hidden');
            element.classList.remove('fade-transition');
            element.classList.remove('zero-opacity');
            element.removeEventListener('transitionend', complete);
        
            if (callback && typeof callback === 'function') {
                callback();
            }
        }
        
        element.addEventListener('transitionend', complete, { once: true });
        // Fallback safety
        setTimeout(complete, 400);
    };

    if (delay > 0) {
        element._hideTimer = setTimeout(performHide, delay);
    } else {
        performHide();
    }
}

/* Show a translated word (e.g. "Copied") in a hidden status element, then
 * fade it back out on its own — the same show/wait/fade sequence
 * report_groups/show.html.erb's drag-drop autosave already uses for
 * "Saving…"/"Saved"/"Failed", generalised to one call. The word itself is
 * never a JS string — always read from the element's own data attribute,
 * set in ERB via t(), so it is never stuck in English regardless of caller. */
export function showTransientStatus(statusElement, text, duration = 3000) {
    if (!statusElement || !text) return;

    statusElement.textContent = text;
    showElementSmoothly(statusElement);
    setTimeout(() => hideElementSmoothly(statusElement), duration);
}

export function setupFlashMessages() {
	document.addEventListener("click", (e) => {
    // We use .closest() in case the button has an icon inside it
    const closeBtn = e.target.closest(".flash-close");
    
    if (closeBtn) {
      const flashMessage = closeBtn.closest("[data-behavior='removable']");
      
      if (flashMessage) {
		e.preventDefault();
        
        hideElementSmoothly(flashMessage, () => {
          flashMessage.remove(); 
        });
      }
    }
  });
}

export function initModals() {
  delegate(document, 'click', '[data-action="open-modal"]', (e, el) => {
    const modal = document.getElementById(el.dataset.modal);
    if (!modal) return;
    modal.dispatchEvent(new CustomEvent('modal:before-open', { detail: { trigger: el } }));
    modal.showModal();
  });

  delegate(document, 'click', '[data-modal-close]', (e, btn) => {
    const modal = btn.closest('dialog');
    if (modal) modal.close();
  });
}

/**
 * Robust Event Delegation Helper
 * @param {Element} el - The container to listen on (usually document)
 * @param {String} type - Event type ('click', 'change', etc.)
 * @param {String} selector - CSS selector to match the target
 * @param {Function} handler - Callback function (e, target)
 */
export function delegate(el, type, selector, handler) {
  el.addEventListener(type, (e) => {
    const target = e.target.closest(selector);
    if (target && el.contains(target)) {
      handler(e, target);
    }
  });
}

/* The CSRF token for a fetch(), or "" when there is none.
 *
 * ⚠️ THERE IS NONE IN THE TEST ENVIRONMENT. `csrf_meta_tags` renders NOTHING
 * when allow_forgery_protection is off, which is the test default — so the meta
 * tag is present in development and production and absent in every system test.
 * Reading `.content` off the missing element throws, and if that happens inside
 * a timer or a promise it throws SILENTLY: the click appears to work, the
 * request is never made, and the console says nothing. That cost an hour on
 * 2026-08-20 before a system test caught it.
 *
 * One helper because there were FOUR spellings of this across six files —
 * `.content`, `?.content`, `?.content || ''`, and a private method — which is
 * how one of them came to be the unguarded one. */
export function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content || '';
}

export function getNumberFormat() {
  const el = document.getElementById('number-format-config');
  if (!el) return { separator: '.', delimiter: ',' };
  try {
    return JSON.parse(el.dataset.numberFormat);
  } catch {
    return { separator: '.', delimiter: ',' };
  }
}

export function formatWithDelimiter(number, delimiter = ',') {
  return number.toString().replace(/\B(?=(\d{3})+(?!\d))/g, delimiter);
}

/* Free-text money -> integer cents, or null.
 *
 * ⚠️ THE MIRROR OF `CurrencyConfig#parse_to_cents` IN RUBY. The two MUST read a
 * string the same way, or the on-screen running total and the value the server
 * stores drift apart — that is audit finding M1. Locale-INDEPENDENT on purpose:
 * the rightmost of '.' / ',' is the decimal point, the other is thousands
 * grouping; a lone separator before exactly three digits ("1.234" / "1,234") is
 * grouping, since money is not written to three decimals. Change this and the
 * Ruby together; currency_config_test's parity table is the shared spec. */
export function parseAmountToCents(value) {
  if (value == null) return null;
  let str = String(value).trim();
  if (!str) return null;

  const negative = str.startsWith('-');
  if (negative) str = str.slice(1);

  /* apostrophe + every kind of space: grouping or padding, never a decimal point */
  str = str.replace(/[\s']/g, '');
  /* a currency marker still clinging to an end — symbol, ISO code, лв., zł … */
  str = str.replace(/^[^\d]+/, '').replace(/[^\d]+$/, '');
  if (!/^[\d.,]+$/.test(str)) return null;

  const lastDot = str.lastIndexOf('.');
  const lastComma = str.lastIndexOf(',');
  let decimal = null;
  if (lastDot !== -1 && lastComma !== -1) {
    decimal = lastDot > lastComma ? '.' : ',';
  } else if (lastDot !== -1 || lastComma !== -1) {
    const sep = lastDot !== -1 ? '.' : ',';
    const occurrences = str.split(sep).length - 1;
    const trailing = str.length - str.lastIndexOf(sep) - 1;
    decimal = (occurrences === 1 && trailing !== 3) ? sep : null;
  }

  const grouped = /^\d{1,3}([.,]\d{3})*$|^\d*$/;
  let normalized;
  if (decimal) {
    const at = str.lastIndexOf(decimal);
    const intPart = str.slice(0, at);
    if (!grouped.test(intPart)) return null;
    normalized = `${intPart.replace(/\D/g, '')}.${str.slice(at + 1).replace(/\D/g, '')}`;
  } else {
    if (!grouped.test(str)) return null;
    normalized = str.replace(/\D/g, '');
  }
  if (!normalized.replace('.', '')) return null;

  /* Round the magnitude on the decimal STRING, not via *100 — 1.005 * 100 lands
   * at 100.4999… in float and would round the wrong way from BigDecimal. */
  const [intDigits, fracDigits = ''] = normalized.split('.');
  const frac = (fracDigits + '000').slice(0, 3);
  let cents = Number(intDigits) * 100 + Number(frac.slice(0, 2));
  if (Number(frac[2]) >= 5) cents += 1;
  if (!Number.isFinite(cents)) return null;
  return negative ? -cents : cents;
}

/* Integer cents -> the locale's display string (no currency symbol).
 * The mirror of `CurrencyConfig#format_display`. */
export function formatAmountFromCents(cents) {
  if (cents == null || !Number.isFinite(cents)) return '';
  const { separator, delimiter } = getNumberFormat();
  const abs = Math.abs(cents);
  const int = formatWithDelimiter(Math.floor(abs / 100).toString(), delimiter);
  const dec = (abs % 100).toString().padStart(2, '0');
  return `${cents < 0 ? '-' : ''}${int}${separator}${dec}`;
}

/********** debugging ***********/

export function checkType(value) {
  console.log("Value:", value, "Type:", typeof value, "Truthy?", !!value);
  if (value === undefined)  console.log("… undefined");
  if (value === null)       console.log("… null");
  if (value === "")         console.log("… empty string");
  if (value === 0)          console.log("… zero");
  if (Number.isNaN(value))  console.log("… NaN");
  if (Array.isArray(value) && value.length === 0)
    console.log("… empty array");
  if (typeof value === "object" && !Array.isArray(value) && Object.keys(value).length === 0)
    console.log("… empty object");
}

export function debug(){
//	console.log("debug");
}

