import { beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import {
  applyAccessibilityPrefs,
  getAccessibilityPrefs,
  nextTextSizePreset,
  setAccessibilityPrefs,
  textSizeLabel,
} from '../src/ui/design/accessibilityPrefs';

describe('Tizen TV accessibility preferences', () => {
  beforeEach(() => {
    const store: Record<string, string> = {};
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => store[k] ?? null,
      setItem: (k: string, v: string) => { store[k] = v; },
      removeItem: (k: string) => { delete store[k]; },
      clear: () => { for (const k of Object.keys(store)) delete store[k]; },
    });
    document.documentElement.removeAttribute('data-high-contrast');
    document.documentElement.removeAttribute('data-text-size');
  });

  it('defaults to standard text size and normal contrast, and handles corrupted storage', () => {
    expect(getAccessibilityPrefs()).toEqual({ highContrast: false, textSize: 'standard' });
    localStorage.setItem('buntu.ui.accessibility', '{bad json');
    expect(getAccessibilityPrefs()).toEqual({ highContrast: false, textSize: 'standard' });
  });

  it('persists and applies high contrast and text size attributes on the root element', () => {
    const saved = setAccessibilityPrefs({ highContrast: true, textSize: 'large' });
    expect(saved).toEqual({ highContrast: true, textSize: 'large' });
    expect(getAccessibilityPrefs()).toEqual({ highContrast: true, textSize: 'large' });
    expect(document.documentElement.getAttribute('data-high-contrast')).toBe('true');
    expect(document.documentElement.getAttribute('data-text-size')).toBe('large');

    const updated = setAccessibilityPrefs({ highContrast: false });
    expect(updated).toEqual({ highContrast: false, textSize: 'large' });
    expect(document.documentElement.hasAttribute('data-high-contrast')).toBe(false);
    expect(document.documentElement.getAttribute('data-text-size')).toBe('large');
  });

  it('cycles text size presets and returns localized French labels', () => {
    expect(nextTextSizePreset('standard')).toBe('large');
    expect(nextTextSizePreset('large')).toBe('xlarge');
    expect(nextTextSizePreset('xlarge')).toBe('standard');

    expect(textSizeLabel('standard')).toBe('Standard (100 %)');
    expect(textSizeLabel('large')).toBe('Grand (115 %)');
    expect(textSizeLabel('xlarge')).toBe('Très grand (130 %)');
  });

  it('applyAccessibilityPrefs handles a custom root element safely', () => {
    const root = document.createElement('html');
    applyAccessibilityPrefs({ highContrast: true, textSize: 'xlarge' }, root);
    expect(root.getAttribute('data-high-contrast')).toBe('true');
    expect(root.getAttribute('data-text-size')).toBe('xlarge');
  });

  it('wires controls in SettingsView and styles in theme.css', () => {
    const settings = readFileSync(resolve(import.meta.dirname, '../src/features/settings/SettingsView.tsx'), 'utf8');
    expect(settings).toContain('id="btn-high-contrast"');
    expect(settings).toContain('id="btn-text-size"');
    expect(settings).toContain("{ id: 'btn-high-contrast', onSelect: toggleHighContrast }");
    expect(settings).toContain("{ id: 'btn-text-size', onSelect: cycleTextSize }");

    const css = readFileSync(resolve(import.meta.dirname, '../src/ui/design/theme.css'), 'utf8');
    expect(css).toContain('html[data-high-contrast="true"]');
    expect(css).toContain('html[data-text-size="large"]');
    expect(css).toContain('html[data-text-size="xlarge"]');
  });
});
