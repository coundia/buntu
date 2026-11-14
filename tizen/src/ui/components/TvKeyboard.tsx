import { Component, For, JSX, Show, createSignal, onCleanup, onMount } from 'solid-js';
import { spatialNav } from '../design/SpatialNav';
import { announce } from '../design/a11y';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { KeyDef, applyKey, applyPastedText, displayValue, keyboardRows } from './tvKeyboardLogic';

/** Extracts plain text from a DOM ClipboardEvent across modern and legacy Chromium versions. */
export function extractClipboardText(event: Event): string {
  const clip = (event as ClipboardEvent).clipboardData || (window as any).clipboardData;
  if (!clip || typeof clip.getData !== 'function') return '';
  return clip.getData('text/plain') || clip.getData('text') || '';
}

/** Handles a paste event targeting a field signal pair, returning true if text was pasted. */
export function pasteEventIntoField(
  event: Event,
  current: () => string,
  set: (value: string) => void
): boolean {
  const pasted = extractClipboardText(event);
  if (!pasted.trim()) return false;
  event.preventDefault();
  event.stopPropagation();
  const next = applyPastedText(current(), pasted);
  if (next !== current()) set(next);
  return true;
}

/** Listens for window-level paste events and applies them to the spatially focused field when unblocked. */
export function listenFocusedFieldPaste(
  isBlocked: () => boolean,
  resolveField: (focusId: string) => [() => string, (value: string) => void] | undefined
): () => void {
  const onPaste = (event: Event) => {
    if (event.defaultPrevented || isBlocked()) return;
    const focusId = spatialNav.getCurrentFocusId();
    if (!focusId) return;
    const field = resolveField(focusId);
    if (field) pasteEventIntoField(event, field[0], field[1]);
  };
  window.addEventListener('paste', onPaste);
  return () => window.removeEventListener('paste', onPaste);
}

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
  const [pasteFeedback, setPasteFeedback] = createSignal('');
  const [focusId] = spatialNav.getFocusSignal();
  let unsubscribe: (() => void) | undefined;

  const applyIncomingPaste = (raw: string): boolean => {
    if (!raw.trim()) return false;
    setText((prev) => applyPastedText(prev, raw));
    setPasteFeedback('Texte collé.');
    announce('Texte collé.');
    return true;
  };

  const pasteFromClipboard = async () => {
    try {
      const readText = (navigator as any).clipboard && (navigator as any).clipboard.readText;
      if (typeof readText !== 'function') {
        setPasteFeedback('Presse-papiers inaccessible ici : collez directement avec Ctrl+V ou SmartThings.');
        return;
      }
      const raw = await (navigator as any).clipboard.readText();
      if (typeof raw === 'string' && applyIncomingPaste(raw)) return;
      setPasteFeedback('Le presse-papiers est vide.');
      announce('Le presse-papiers est vide.');
    } catch {
      setPasteFeedback('Le presse-papiers n’est pas accessible sur cette TV : collez avec Ctrl+V/SmartThings ou saisissez ici.');
    }
  };

  const press = (key: KeyDef) => {
    if (key.kind === 'paste') { void pasteFromClipboard(); return; }
    setPasteFeedback('');
    if (key.kind === 'shift') { setShift(!shift()); return; }
    if (key.kind === 'reveal') { setRevealed(!revealed()); return; }
    if (key.kind === 'ok') { props.onDone(text()); return; }
    if (key.kind === 'cancel') { props.onCancel(); return; }
    setText(applyKey(text(), key, shift()));
  };

  const onWindowPaste = (event: Event) => {
    const pasted = extractClipboardText(event);
    if (!pasted.trim()) return;
    event.preventDefault();
    event.stopPropagation();
    applyIncomingPaste(pasted);
  };

  onMount(() => {
    spatialNav.openModal(rows.map((row) => row.map((key) => ({ id: key.id, onSelect: () => press(key) }))), 0, 0);
    window.addEventListener('paste', onWindowPaste);
    unsubscribe = RemoteKeyHandler.getInstance().addListener((key) => {
      if (key === 'BACK') { props.onCancel(); return true; }
      if (key.startsWith('NUM_')) { setText(applyKey(text(), { id: 'num', kind: 'char', label: '', text: key.slice(4) }, false)); return true; }
      return false;
    });
    announce(`Saisie : ${props.title}. Choisissez les touches, puis Valider.`);
  });
  onCleanup(() => {
    window.removeEventListener('paste', onWindowPaste);
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
        <Show when={pasteFeedback()}>
          <p class="buntu-kb-hint" role="status" aria-live="polite" style={{ color: 'var(--buntu-cyan)' }}>{pasteFeedback()}</p>
        </Show>
        <p class="buntu-kb-hint">OK : appuyer sur la touche · Chiffres de la télécommande : saisie directe · Coller / Ctrl+V · Retour : annuler</p>
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
