import { describe, it, expect, beforeEach, vi } from 'vitest';
import { announce, syncDomFocus } from '../src/ui/design/a11y';
import { supportsFlexGap } from '../src/ui/design/flexGapShim';

describe('Accessibility & FlexGap Helpers', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('announce updates #a11y-announcer after debounce delay', async () => {
    const announcer = document.createElement('div');
    announcer.id = 'a11y-announcer';
    document.body.appendChild(announcer);

    announce('Direct TF1 en cours de lecture');

    expect(announcer.textContent).toBe('');
    await new Promise((r) => setTimeout(r, 100));
    expect(announcer.textContent).toBe('Direct TF1 en cours de lecture');
  });

  it('syncDomFocus shifts DOM focus to element with .focused', () => {
    const btn = document.createElement('button');
    btn.id = 'target-btn';
    btn.className = 'focused';
    document.body.appendChild(btn);

    expect(document.activeElement).not.toBe(btn);
    syncDomFocus();
    expect(document.activeElement).toBe(btn);
  });

  it('syncDomFocus does not automatically focus input elements to prevent keyboard popup', () => {
    const input = document.createElement('input');
    input.id = 'target-input';
    input.className = 'focused';
    document.body.appendChild(input);

    syncDomFocus();
    expect(document.activeElement).not.toBe(input);
  });

  it('supportsFlexGap evaluates without crashing in test environment', () => {
    const result = supportsFlexGap();
    expect(typeof result).toBe('boolean');
  });
});

