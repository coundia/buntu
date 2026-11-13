import { Component, For, JSX, Show, createSignal, onCleanup, onMount } from 'solid-js';
import { spatialNav } from '../design/SpatialNav';
import { announce } from '../design/a11y';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { KeyDef, applyKey, displayValue, keyboardRows } from './tvKeyboardLogic';

export interface TvKeyboardProps {
  title: string;
  value: string;
  /** A password: shown as dots until « Afficher ». */
  secret?: boolean;
  onDone: (value: string) => void;
  onCancel: () => void;
}

/**
 * On-screen keyboard driven by the D-pad: OK presses the key, the number keys of the remote type digits,
 * BACK cancels. It takes the remote focus as a modal and gives it back when it closes.
 */
export const TvKeyboard: Component<TvKeyboardProps> = (props) => {
  const rows = keyboardRows();
  const [text, setText] = createSignal(props.value);
  const [shift, setShift] = createSignal(false);
  const [revealed, setRevealed] = createSignal(false);
  const [focusId] = spatialNav.getFocusSignal();
  let unsubscribe: (() => void) | undefined;

  const press = (key: KeyDef) => {
    if (key.kind === 'shift') { setShift(!shift()); return; }
    if (key.kind === 'reveal') { setRevealed(!revealed()); return; }
    if (key.kind === 'ok') { props.onDone(text()); return; }
    if (key.kind === 'cancel') { props.onCancel(); return; }
    setText(applyKey(text(), key, shift()));
  };

  onMount(() => {
    spatialNav.openModal(rows.map((row) => row.map((key) => ({ id: key.id, onSelect: () => press(key) }))), 0, 0);
    unsubscribe = RemoteKeyHandler.getInstance().addListener((key) => {
      if (key === 'BACK') { props.onCancel(); return true; }
      if (key.startsWith('NUM_')) { setText(applyKey(text(), { id: 'num', kind: 'char', label: '', text: key.slice(4) }, false)); return true; }
      return false;
    });
    announce(`Saisie : ${props.title}. Choisissez les touches, puis Valider.`);
  });
  onCleanup(() => {
    unsubscribe?.();
    spatialNav.closeModal();
  });

  const label = (key: KeyDef) => {
    if (key.kind === 'char' && shift()) return key.label.toUpperCase();
    if (key.kind === 'reveal') return revealed() ? 'Masquer' : 'Afficher';
    if (key.kind === 'shift') return shift() ? 'MAJ ●' : 'Maj';
    return key.label;
  };

  return (
    <div class="tv-modal-overlay" role="dialog" aria-modal="true" aria-label={`Clavier : ${props.title}`}>
      <div class="buntu-kb">
        <h2 class="buntu-kb-title">{props.title}</h2>
        <div class="buntu-kb-text" aria-live="polite">
          {displayValue(text(), !!props.secret, revealed()) || ' '}
          <span class="buntu-kb-caret">|</span>
        </div>
        <For each={rows}>
          {(row) => (
            <div class="buntu-kb-row">
              <For each={row}>
                {(key) => (
                  <button
                    id={key.id}
                    tabindex="-1"
                    class={`buntu-kb-key ${key.wide ? 'wide' : ''} ${key.kind === 'ok' ? 'primary' : ''} ${focusId() === key.id ? 'focused' : ''}`}
                    onClick={() => press(key)}
                  >
                    {label(key)}
                  </button>
                )}
              </For>
            </div>
          )}
        </For>
        <p class="buntu-kb-hint">OK : appuyer sur la touche · Chiffres de la télécommande : saisie directe · Retour : annuler</p>
      </div>
    </div>
  );
};

interface KeyboardRequest {
  title: string;
  value: string;
  secret: boolean;
  set: (value: string) => void;
}

/** One keyboard per form: `open(...)` on OK of a field, `view()` rendered once in the form. */
export function createTvKeyboard() {
  const [request, setRequest] = createSignal<KeyboardRequest | null>(null);
  return {
    isOpen: () => request() !== null,
    open: (title: string, value: string, set: (value: string) => void, secret = false) =>
      setRequest({ title, value, set, secret }),
    view: (): JSX.Element => (
      <Show when={request()}>
        {(r) => (
          <TvKeyboard
            title={r().title}
            value={r().value}
            secret={r().secret}
            onDone={(v) => { r().set(v); setRequest(null); }}
            onCancel={() => setRequest(null)}
          />
        )}
      </Show>
    ),
  };
}
