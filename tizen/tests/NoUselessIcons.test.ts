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
