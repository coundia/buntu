import { Component, JSX, Show } from 'solid-js';
import type { MiniPlayerController, MiniPlayerItem } from '../../core/player/MiniPlayerController';
import type { PanelExtraAction } from '../design/miniPlayerFocus';

/**
 * Right panel of a catalog screen: the mini player on top, the details of the focused item below,
 * then the actions. The same on every screen; only `details` (what is said about the item) and the
 * optional extra actions change.
 *
 * Nothing may paint behind the preview area while the video plays (the video shows through): the
 * preview sits flush at the top and only the details get a background (see `.mini-panel` in theme.css).
 */
export interface MiniPlayerPanelProps<T extends MiniPlayerItem> {
  ctl: MiniPlayerController<T>;
  /** DOM id prefix of the panel's buttons (`${idPrefix}-screen|play|fav|full`). */
  idPrefix: string;
  focusId: () => string;
  /** Picture shown while nothing plays (channel logo, film poster). */
  posterUrl: (item: T) => string | undefined;
  /** Name of the item (also shown on the badge of what is playing). */
  titleOf: (item: T) => string;
  /** Emoji shown when there is no picture. */
  fallbackIcon: string;
  isFavorite: (item: T) => boolean;
  onToggleFavorite: (item: T) => void;
  /** Heading and facts about the focused item. */
  details: (item: T) => JSX.Element;
  extraActions?: PanelExtraAction[];
  /** Hint under the poster when idle. */
  idleHint?: string;
}

export function MiniPlayerPanel<T extends MiniPlayerItem>(props: MiniPlayerPanelProps<T>): JSX.Element {
  const { ctl } = props;
  const id = (name: string) => `${props.idPrefix}-${name}`;
  const posterItem = () => ctl.playing() ?? ctl.focused();
  const hasWebapis = () => typeof (window as any).webapis !== 'undefined';

  const hint = () => {
    switch (ctl.status()) {
      case 'connecting':
        return 'Connexion…';
      case 'error':
        return '⚠ Indisponible';
      case 'playing':
        return '● Lecture en cours';
      default:
        return props.idleHint ?? '▶ Appuyez sur Lecture';
    }
  };

  return (
    <Show when={ctl.visible() && ctl.focused()}>
      <aside class="buntu-inspector-pane mini-panel" aria-label="Aperçu">
        <div
          id={id('screen')}
          ref={(el) => ctl.setViewport(el)}
          role="button"
          tabindex="-1"
          aria-label="Passer en plein écran"
          class={`buntu-inspector-viewport ${props.focusId() === id('screen') ? 'focused' : ''}`}
          onClick={() => ctl.fullscreenFromScreen()}
        >
          <Show when={ctl.status() !== 'playing' || !hasWebapis()}>
            <div class="buntu-insp-poster">
              <div class="buntu-insp-poster-art">
                <Show
                  when={posterItem() && props.posterUrl(posterItem()!)}
                  fallback={<span class="buntu-insp-poster-fallback">{props.fallbackIcon}</span>}
                >
                  <img src={props.posterUrl(posterItem()!)} alt="" />
                </Show>
              </div>
              <div class={`buntu-insp-poster-hint ${ctl.status() === 'error' ? 'error' : ''}`}>{hint()}</div>
              <Show when={ctl.status() === 'error' && ctl.error()}>
                <div class="buntu-insp-poster-detail">{ctl.error()}</div>
              </Show>
            </div>
          </Show>
          <Show when={ctl.status() === 'playing' && ctl.playing()}>
            <span class="buntu-insp-live">● {props.titleOf(ctl.playing()!)}</span>
          </Show>
        </div>

        <div class="buntu-insp-body">
          {props.details(ctl.focused()!)}

          <div class="buntu-inspector-actions">
            <button
              id={id('play')}
              type="button"
              tabindex="-1"
              class={`buntu-action-primary ${props.focusId() === id('play') ? 'focused' : ''}`}
              onClick={() => ctl.toggle()}
            >
              {ctl.focusedIsPlaying() ? '⏹ Arrêter' : '▶ Lecture'}
            </button>
            <button
              id={id('fav')}
              type="button"
              tabindex="-1"
              class={`buntu-action-secondary ${props.focusId() === id('fav') ? 'focused' : ''}`}
              onClick={() => props.onToggleFavorite(ctl.focused()!)}
            >
              {props.isFavorite(ctl.focused()!) ? '★ Favori' : '☆ Favori'}
            </button>
            <button
              id={id('full')}
              type="button"
              tabindex="-1"
              class={`buntu-action-secondary ${props.focusId() === id('full') ? 'focused' : ''}`}
              onClick={() => ctl.fullscreen()}
            >
              ⛶ Plein écran
            </button>
            {(props.extraActions ?? []).map((extra) => (
              <button
                id={extra.id}
                type="button"
                tabindex="-1"
                class={`buntu-action-secondary ${props.focusId() === extra.id ? 'focused' : ''}`}
                onClick={extra.onSelect}
              >
                {extra.label}
              </button>
            ))}
          </div>
        </div>
      </aside>
    </Show>
  );
}
