import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { render } from 'solid-js/web';
import { TvSearchBar } from '../src/ui/components/TvSearchBar';

const source = (p: string) => readFileSync(resolve(__dirname, '..', p), 'utf8');

describe('Icons the remote used to stop on', () => {
  it('the category « home » icon, the search ✕ and the toolbar icon buttons are gone from Live, Films and Séries', () => {
    for (const p of ['src/features/live/LiveView.tsx', 'src/features/movies/MoviesView.tsx', 'src/features/series/SeriesView.tsx']) {
      const text = source(p);
      expect(text, p).not.toMatch(/cat-home/);
      expect(text, p).not.toMatch(/search-clear/);
      expect(text, p).not.toMatch(/toggle-cats|mode-grid|mode-list|toggle-inspector|buntu-seg-group/);
    }
  });

  it('the guide search bar has no clear icon and no focus stop for it', () => {
    expect(source('src/features/guide/GuideView.tsx')).not.toContain('-clear');
    const box = document.createElement('div');
    document.body.appendChild(box);
    const dispose = render(() => TvSearchBar({ id: 'q', value: 'abc', onInput: () => {} }), box);
    expect(box.querySelector('#q-clear')).toBeNull();
    expect(box.textContent).not.toContain('✕');
    dispose();
    box.remove();
  });
});

describe('Category list readability', () => {
  it('is wider than before and lets a long name use two lines instead of being cut', () => {
    const css = source('src/ui/design/theme.css');
    expect(css).toContain('.buntu-cat-pane { width: clamp(260px, 25vw, 620px); }');
    expect(css).not.toContain('.buntu-cat-pane { width: clamp(220px, 19vw, 480px); }');
    expect(css).toMatch(/\.buntu-cat-row-title \{[^}]*-webkit-line-clamp: 2;/);
  });
});

describe('Mini player buttons', () => {
  it('are laid out on one compact line', () => {
    const css = source('src/ui/design/theme.css');
    expect(css).toMatch(/\.mini-panel \.buntu-inspector-actions \{[^}]*flex-direction: row;[^}]*flex-wrap: nowrap;/);
    expect(css).toMatch(/\.mini-panel \.buntu-action-secondary \{[^}]*white-space: nowrap;/);
  });
});

describe('Buntu logo home button in Live, Films and Séries', () => {
  it('exposes the clickable and focusable Buntu logo button to return home in Live, Films and Séries', () => {
    const views = [
      { path: 'src/features/live/LiveView.tsx', id: 'live-brand-home' },
      { path: 'src/features/movies/MoviesView.tsx', id: 'mv-brand-home' },
      { path: 'src/features/series/SeriesView.tsx', id: 's-brand-home' },
    ];

    for (const view of views) {
      const text = readFileSync(resolve(import.meta.dirname, '..', view.path), 'utf8');
      expect(text, view.path).toContain('onHome?: () => void');
      expect(text, view.path).toContain(`{ id: '${view.id}', onSelect: goHome }`);
      expect(text, view.path).toContain(`id="${view.id}"`);
      expect(text, view.path).toContain('./icon.png');
      expect(text, view.path).not.toContain('buntu-toolbar-brand-name');
      expect(text, view.path).not.toContain('>Buntu<');
      expect(text, view.path).toContain('onClick={goHome}');
    }

    const live = readFileSync(resolve(import.meta.dirname, '..', 'src/features/live/LiveView.tsx'), 'utf8');
    expect(live).toContain("emptyGrid: FocusableItem[][] = [[{ id: 'live-brand-home', onSelect: goHome }]]");

    const app = readFileSync(resolve(import.meta.dirname, '..', 'src/app/App.tsx'), 'utf8');
    expect(app).toContain("<LiveView");
    expect(app).toContain("<MoviesView");
    expect(app).toContain("<SeriesView");
    expect(app.match(/onHome=\{\(\) => navigateTo\('home', \{ reset: true \}\)\}/g)?.length).toBeGreaterThanOrEqual(3);

    const css = readFileSync(resolve(import.meta.dirname, '../src/ui/design/theme.css'), 'utf8');
    expect(css).toContain('.buntu-toolbar-brand {');
    expect(css).toContain('.buntu-toolbar-brand.focused');
    expect(css).toContain('.buntu-toolbar-brand:focus');
  });
});

describe('Solid Buntu design (anti-AI)', () => {
  it('bans gradients and backdrop blurs across theme.css', () => {
    const css = readFileSync(resolve(import.meta.dirname, '../src/ui/design/theme.css'), 'utf8');
    expect(css).not.toMatch(/backdrop-filter|linear-gradient|radial-gradient/);
  });

  it('uses opaque solid backgrounds on primary button classes', () => {
    const css = readFileSync(resolve(import.meta.dirname, '../src/ui/design/theme.css'), 'utf8');
    const selectors = [
      '.tv-btn',
      '.buntu-action-primary',
      '.buntu-action-secondary',
      '.buntu-toolbar-brand',
      '.buntu-tool-btn',
    ];
    for (const selector of selectors) {
      const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const match = css.match(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`));
      expect(match, `Missing rule for ${selector}`).not.toBeNull();
      const body = match![1];
      expect(body, `${selector} should declare a background`).toMatch(/background(?:-color)?\s*:/);
      expect(body, `${selector} must stay solid without rgba`).not.toContain('rgba(');
      expect(body, `${selector} must not be transparent`).not.toMatch(/background(?:-color)?\s*:\s*transparent/);
    }
  });
});
