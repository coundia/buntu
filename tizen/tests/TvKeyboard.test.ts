import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render } from 'solid-js/web';
import { applyKey, displayValue, keyboardRows, KeyDef } from '../src/ui/components/tvKeyboardLogic';
import { ManualSourceForm } from '../src/features/onboarding/ManualSourceForm';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';

const all = () => keyboardRows().flat();
const key = (id: string): KeyDef => all().find((k) => k.id === id)!;
const byLabel = (label: string): KeyDef => all().find((k) => k.label === label)!;

describe('TV keyboard logic', () => {
  it('has unique key ids and every character an IPTV address needs', () => {
    const ids = all().map((k) => k.id);
    expect(new Set(ids).size).toBe(ids.length);
    const labels = all().map((k) => k.label).join('');
    for (const c of '0123456789abcdefghijklmnopqrstuvwxyz.-_/:@?=&%') expect(labels).toContain(c);
  });

  it('types, uppercases with shift, erases and clears', () => {
    let v = '';
    v = applyKey(v, byLabel('a'), false);
    v = applyKey(v, byLabel('b'), true);
    expect(v).toBe('aB');
    v = applyKey(v, key('kb-space'), false);
    expect(v).toBe('aB ');
    v = applyKey(v, key('kb-back'), false);
    v = applyKey(v, key('kb-back'), false);
    expect(v).toBe('a');
    expect(applyKey('abc', key('kb-clear'), false)).toBe('');
    expect(applyKey('', key('kb-back'), false)).toBe('');
  });

  it('inserts address shortcuts in one press', () => {
    let v = applyKey('', byLabel('https://'), false);
    v = applyKey(v, byLabel('a'), false);
    v = applyKey(v, byLabel('.com'), false);
    v = applyKey(v, byLabel(':8080'), false);
    expect(v).toBe('https://a.com:8080');
  });

  it('keeps the text on keys that do not edit it, and caps the length', () => {
    expect(applyKey('x', key('kb-ok'), false)).toBe('x');
    expect(applyKey('x', key('kb-shift'), false)).toBe('x');
    expect(applyKey('a'.repeat(5000), byLabel('b'), false).length).toBe(2048);
  });

  it('hides a password until it is revealed', () => {
    expect(displayValue('secret', true, false)).toBe('••••••');
    expect(displayValue('secret', true, true)).toBe('secret');
    expect(displayValue('visible', false, false)).toBe('visible');
  });
});

describe('Manual source form with the remote only', () => {
  let container: HTMLDivElement;
  let dispose: () => void = () => {};
  const tick = () => new Promise((r) => setTimeout(r, 30));
  const pressRemote = (keyCode: number) => window.dispatchEvent(new KeyboardEvent('keydown', { keyCode }));

  beforeEach(() => {
    container = document.createElement('div');
    document.body.appendChild(container);
    RemoteKeyHandler.getInstance().init();
    (spatialNav as any).isInitialized = false;
    spatialNav.init();
    spatialNav.setHeader([]);
  });
  afterEach(() => {
    dispose();
    container.remove();
    RemoteKeyHandler.getInstance().destroy();
    vi.restoreAllMocks();
  });

  const field = (id: string) => container.querySelector(`#${id}`) as HTMLInputElement;
  const pick = async (id: string) => {
    spatialNav.setFocusById(id);
    pressRemote(13); // OK
    await tick();
  };
  const press = (id: string) => (document.getElementById(id) as HTMLButtonElement).click();

  it('OK on a field opens the keyboard, typing then Valider fills the field', async () => {
    const onCancel = vi.fn();
    dispose = render(() => ManualSourceForm({ onAdded: vi.fn(), onCancel }), container);
    await tick();
    await pick('field-server');
    expect(document.querySelector('.buntu-kb')).not.toBeNull();
    expect(spatialNav.isModalOpen()).toBe(true);

    press(byLabel('https://').id);
    press(byLabel('a').id);
    press(byLabel('.com').id);
    press('kb-ok');
    await tick();

    expect(field('field-server').value).toBe('https://a.com');
    expect(document.querySelector('.buntu-kb')).toBeNull();
    expect(spatialNav.isModalOpen()).toBe(false);
    expect(onCancel).not.toHaveBeenCalled();
  });

  it('the number keys of the remote type digits', async () => {
    dispose = render(() => ManualSourceForm({ onAdded: vi.fn(), onCancel: vi.fn() }), container);
    await tick();
    await pick('field-username');
    pressRemote(49);
    pressRemote(50);
    await tick();
    press('kb-ok');
    await tick();
    expect(field('field-username').value).toBe('12');
  });

  it('BACK closes the keyboard without changing the field and without leaving the form', async () => {
    const onCancel = vi.fn();
    dispose = render(() => ManualSourceForm({ onAdded: vi.fn(), onCancel }), container);
    await tick();
    await pick('field-name');
    press(byLabel('z').id);
    pressRemote(10009); // BACK
    await tick();
    expect(document.querySelector('.buntu-kb')).toBeNull();
    expect(field('field-name').value).toBe('Mon IPTV');
    expect(onCancel).not.toHaveBeenCalled();
    pressRemote(10009); // BACK again: now the form closes
    expect(onCancel).toHaveBeenCalledTimes(1);
  });

  it('moving down with the D-pad reaches the fields and keeps the focus there', async () => {
    dispose = render(() => ManualSourceForm({ onAdded: vi.fn(), onCancel: vi.fn() }), container);
    await tick();
    expect(spatialNav.getCurrentFocusId()).toBe('kind-xtream');
    pressRemote(40);
    expect(spatialNav.getCurrentFocusId()).toBe('field-name');
    pressRemote(40);
    expect(spatialNav.getCurrentFocusId()).toBe('field-server');
    pressRemote(40);
    expect(spatialNav.getCurrentFocusId()).toBe('field-username');
  });

  it('a password field stays masked in the form', async () => {
    dispose = render(() => ManualSourceForm({ onAdded: vi.fn(), onCancel: vi.fn() }), container);
    await tick();
    expect(field('field-password').type).toBe('password');
    expect(field('field-password').readOnly).toBe(true);
  });
});
