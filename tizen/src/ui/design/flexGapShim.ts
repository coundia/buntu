/**
 * `gap` on flex containers only works from Chromium 84. Samsung TVs up to Tizen 6 (Chromium 76) ignore it,
 * so buttons, cards and labels end up stuck together. When the engine lacks it, this shim turns each flex
 * container's `gap` into margins between its children (rows: left, columns: top, wrapping rows: both).
 */

const PROCESSED = 'data-fgap';

export function supportsFlexGap(): boolean {
  if (typeof document === 'undefined' || !document.body) return true;
  const flex = document.createElement('div');
  flex.style.display = 'flex';
  flex.style.flexDirection = 'column';
  flex.style.rowGap = '1px';
  flex.style.position = 'absolute';
  flex.style.visibility = 'hidden';
  flex.appendChild(document.createElement('div'));
  flex.appendChild(document.createElement('div'));
  document.body.appendChild(flex);
  const ok = flex.scrollHeight === 1;
  document.body.removeChild(flex);
  return ok;
}

function apply(el: HTMLElement) {
  const gap = el.style.getPropertyValue('gap') || el.style.getPropertyValue('grid-gap');
  if (!gap) {
    if (el.hasAttribute(PROCESSED)) {
      el.removeAttribute(PROCESSED);
    }
    return;
  }
  const cs = window.getComputedStyle(el);
  if (cs.display !== 'flex' && cs.display !== 'inline-flex') return;
  const parts = gap.trim().split(/\s+/);
  const rowGap = parts[0];
  const colGap = parts[1] || parts[0];
  const column = cs.flexDirection.indexOf('column') === 0;
  const wrap = cs.flexWrap !== 'nowrap';
  el.setAttribute(PROCESSED, wrap ? 'wrap' : column ? 'col' : 'row');
  el.style.setProperty('--fgap-row', rowGap);
  el.style.setProperty('--fgap-col', colGap);
}

function scan(root: ParentNode) {
  if ((root as HTMLElement).style) apply(root as HTMLElement);
  const nodes = root.querySelectorAll ? root.querySelectorAll<HTMLElement>('[style*="gap"]') : [];
  for (let i = 0; i < nodes.length; i++) apply(nodes[i]);
}

export function installFlexGapShim() {
  if (typeof window === 'undefined' || typeof MutationObserver === 'undefined') return;
  if (supportsFlexGap()) return;
  document.documentElement.classList.add('no-flex-gap');
  scan(document.body);
  let pending = false;
  const queue = new Set<ParentNode>();
  const observer = new MutationObserver((mutations) => {
    for (const m of mutations) {
      if (m.type === 'attributes') queue.add(m.target as HTMLElement);
      m.addedNodes.forEach((n) => {
        if (n.nodeType === 1) queue.add(n as HTMLElement);
      });
    }
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      queue.forEach((n) => scan(n));
      queue.clear();
    });
  });
  observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['style'] });
}

