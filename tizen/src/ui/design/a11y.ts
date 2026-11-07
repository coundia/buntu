/**
 * Accessibility helpers for the TV (PRD 38 § 5): announcements for screen readers / Samsung Voice Guide,
 * and moving the real DOM focus with the remote so the focused element is read aloud.
 */

let clearTimer: ReturnType<typeof setTimeout> | null = null;

/** Reads a short status aloud (polite: after what is being read). */
export function announce(message: string) {
  if (typeof document === 'undefined' || !message) return;
  const region = document.getElementById('a11y-announcer');
  if (!region) return;
  // Emptying first makes the same message read again when it repeats.
  region.textContent = '';
  if (clearTimer) clearTimeout(clearTimer);
  setTimeout(() => {
    region.textContent = message;
  }, 60);
  clearTimer = setTimeout(() => {
    region.textContent = '';
  }, 6000);
}

/**
 * Gives the DOM focus to the element the remote highlights (`.focused`), so assistive technologies follow
 * it. Text fields are skipped: focusing one opens the TV keyboard, which only OK must do.
 */
export function syncDomFocus() {
  if (typeof document === 'undefined') return;
  const el = document.querySelector('.focused') as HTMLElement | null;
  if (!el) return;
  if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return;
  if (document.activeElement === el) return;
  if (!el.hasAttribute('tabindex') && !/^(BUTTON|A|SELECT)$/.test(el.tagName)) {
    el.setAttribute('tabindex', '-1');
  }
  try {
    (el as any).focus({ preventScroll: true });
  } catch {
    el.focus();
  }
}

