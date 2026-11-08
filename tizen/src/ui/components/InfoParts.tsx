import { For, JSX, Show } from 'solid-js';

/**
 * Small building blocks for the details shown in the mini player panel, so every screen
 * presents facts the same way: chips for short facts, labelled sections, a progress bar.
 */

export interface InfoChip {
  text: string;
  /** quality = bold white on color, rating = gold, plain = discreet. */
  tone?: 'quality' | 'uhd' | 'rating' | 'live' | 'plain';
}

/** Short facts side by side: "FHD", "★ 7.4", "2024", "FR", "MKV"… Empty entries are skipped. */
export function InfoChips(props: { chips: (InfoChip | null | undefined | false)[] }): JSX.Element {
  const visible = () => props.chips.filter((c): c is InfoChip => !!c && !!c.text);
  return (
    <Show when={visible().length > 0}>
      <div class="buntu-chips">
        <For each={visible()}>
          {(c) => <span class={`buntu-chip ${c.tone ? 'tone-' + c.tone : ''}`}>{c.text}</span>}
        </For>
      </div>
    </Show>
  );
}

/** A labelled block ("EN CE MOMENT", "À SUIVRE", "SYNOPSIS"). */
export function InfoSection(props: { label: string; children: JSX.Element }): JSX.Element {
  return (
    <div class="buntu-info-section">
      <div class="buntu-info-label">{props.label}</div>
      {props.children}
    </div>
  );
}

/** A thin progress bar, 0..100. */
export function InfoProgress(props: { percent: number }): JSX.Element {
  return (
    <div class="buntu-epg-bar">
      <div class="buntu-epg-fill" style={{ width: `${props.percent}%` }} />
    </div>
  );
}
