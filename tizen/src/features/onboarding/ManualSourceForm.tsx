import { Component, Show, createEffect, createSignal, onCleanup, onMount, untrack } from 'solid-js';
import { spatialNav } from '../../ui/design/SpatialNav';
import { CndEngine } from '../../core/engine/CndEngine';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { createTvKeyboard, listenFocusedFieldPaste, pasteEventIntoField } from '../../ui/components/TvKeyboard';

export interface ManualSourceFormProps {
  /** An account was added and synchronised. */
  onAdded: () => void;
  onCancel: () => void;
}

type Kind = 'xtream' | 'm3u';

/**
 * Adding an account without a phone: the fields take the TV keyboard (OK on a field opens it).
 * The alternative to the QR code when no phone is at hand or the QR code cannot be shown.
 */
export const ManualSourceForm: Component<ManualSourceFormProps> = (props) => {
  const [kind, setKind] = createSignal<Kind>('xtream');
  const [name, setName] = createSignal('Mon IPTV');
  const [server, setServer] = createSignal('');
  const [username, setUsername] = createSignal('');
  const [password, setPassword] = createSignal('');
  const [url, setUrl] = createSignal('');
  const [busy, setBusy] = createSignal(false);
  const [progressPct, setProgressPct] = createSignal(5);
  const [message, setMessage] = createSignal('');
  const [isError, setIsError] = createSignal(false);
  const [focusId] = spatialNav.getFocusSignal();
  const keyboard = createTvKeyboard();

  const fieldIds = () =>
    kind() === 'xtream'
      ? ['field-name', 'field-server', 'field-username', 'field-password']
      : ['field-name', 'field-url'];

  const fieldSpec: Record<string, [string, () => string, (v: string) => void, boolean]> = {
    'field-name': ['Nom', name, setName, false],
    'field-server': ['Serveur', server, setServer, false],
    'field-username': ['Identifiant', username, setUsername, false],
    'field-password': ['Mot de passe', password, setPassword, true],
    'field-url': ['Adresse de la playlist', url, setUrl, false],
  };

  /** OK on a field: the on-screen keyboard (the Samsung system keyboard is not reliable with a remote). */
  const openFieldKeyboard = (id: string) => {
    const entry = fieldSpec[id];
    if (entry) keyboard.open(entry[0], entry[1](), entry[2], entry[3]);
  };

  const updateGrid = () => {
    spatialNav.setGrid([
      [
        { id: 'kind-xtream', onSelect: () => setKind('xtream') },
        { id: 'kind-m3u', onSelect: () => setKind('m3u') },
      ],
      ...fieldIds().map((id) => [{ id, onSelect: () => openFieldKeyboard(id) }]),
      [
        { id: 'btn-submit', onSelect: () => void submit() },
        { id: 'btn-cancel', onSelect: () => props.onCancel() },
      ],
    ]);
  };

  let backUnsub: (() => void) | null = null;
  let pasteUnsub: (() => void) | null = null;

  onMount(() => {
    updateGrid();
    backUnsub = RemoteKeyHandler.getInstance().addListener((key) => {
      if (key === 'BACK' && !keyboard.isOpen()) {
        props.onCancel();
        return true;
      }
      return false;
    });
    pasteUnsub = listenFocusedFieldPaste(
      () => keyboard.isOpen() || busy(),
      (id) => {
        if (!fieldIds().includes(id) && id !== 'field-name') return undefined;
        const entry = fieldSpec[id];
        return entry ? [entry[1], entry[2]] : undefined;
      }
    );
  });

  onCleanup(() => {
    if (backUnsub) backUnsub();
    if (pasteUnsub) pasteUnsub();
  });

  // The kind changes the fields: rebuild the grid (keeps the focus on the kind buttons).
  // `untrack`: `setGrid` reads the focus; without it every D-pad move re-ran this effect and sent the focus
  // back to the first button, so the fields could never be reached.
  createEffect(() => {
    kind();
    untrack(updateGrid);
  });

  const valid = () => {
    if (kind() === 'm3u') return /^https?:\/\//i.test(url().trim());
    return /^https?:\/\//i.test(server().trim()) && username().trim() !== '' && password() !== '';
  };

  const submit = async () => {
    if (busy()) return;
    if (!valid()) {
      setIsError(true);
      setMessage(
        kind() === 'm3u'
          ? "L'adresse de la playlist doit commencer par http:// ou https://"
          : "Serveur (http://…), identifiant et mot de passe sont nécessaires."
      );
      return;
    }
    setBusy(true);
    setIsError(false);
    setProgressPct(5);
    setMessage('Connexion au serveur IPTV…');
    spatialNav.setGrid([]);
    try {
      const engine = CndEngine.getInstance();
      const label = name().trim() || (kind() === 'm3u' ? 'Ma playlist' : 'Mon IPTV');
      const onProgress = (msg: string, pct?: number) => {
        setMessage(msg);
        if (pct !== undefined) setProgressPct(Math.max(5, Math.min(100, pct)));
      };
      if (kind() === 'xtream') {
        await engine.syncXtreamSource(label, server().trim(), username().trim(), password(), undefined, onProgress);
      } else {
        await engine.syncM3uSource(label, url().trim(), onProgress);
      }
      props.onAdded();
    } catch (e: any) {
      setIsError(true);
      setMessage(e?.message ? `Échec : ${e.message}` : 'Échec de la synchronisation');
      updateGrid();
    } finally {
      setBusy(false);
    }
  };

  const field = (
    id: string, label: string, value: () => string, set: (v: string) => void,
    opts: { type?: string; placeholder?: string } = {}
  ) => (
    <label style={{ display: 'block', 'text-align': 'left', 'margin-bottom': '16px' }}>
      <span style={{ color: 'var(--buntu-text-muted)', 'font-size': '20px' }}>{label}</span>
      <input
        id={id}
        class={`tv-input ${focusId() === id ? 'focused' : ''}`}
        type={opts.type ?? 'text'}
        placeholder={opts.placeholder}
        value={value()}
        autocomplete="off"
        readOnly
        inputMode="none"
        onClick={() => openFieldKeyboard(id)}
        onInput={(e) => set((e.currentTarget as HTMLInputElement).value)}
        onPaste={(e) => pasteEventIntoField(e, value, set)}
      />
    </label>
  );

  return (
    <div style={{ 'max-width': '760px', margin: '0 auto' }}>
      <Show
        when={!busy()}
        fallback={
          <div class="tv-loader-card">
            <div class="tv-spinner" role="status" aria-label="Importation en cours" />
            <h2 style={{ 'font-size': '32px', color: 'var(--buntu-gold)', margin: 0 }}>
              Importation du compte en cours…
            </h2>
            <p style={{ 'font-size': '24px', color: 'var(--buntu-cyan)', margin: 0 }}>
              {message() || 'Synchronisation…'}
            </p>
            <div class="tv-progress-track">
              <div class="tv-progress-bar" style={{ width: `${progressPct()}%` }} />
            </div>
            <p style={{ 'font-size': '18px', color: 'var(--buntu-text-muted)', margin: 0 }}>
              Veuillez patienter ({progressPct()}%)
            </p>
          </div>
        }
      >
      <h2 style={{ 'font-size': '36px', color: 'var(--buntu-gold)', 'margin-bottom': '20px' }}>Ajouter un compte avec la télécommande</h2>

      <div style={{ display: 'flex', gap: '16px', 'margin-bottom': '20px' }} role="radiogroup" aria-label="Type de source">
        <button
          id="kind-xtream"
          role="radio"
          tabindex="-1"
          aria-checked={kind() === 'xtream'}
          aria-label="Type Xtream Codes"
          class={`tv-btn ${focusId() === 'kind-xtream' ? 'focused' : ''}`}
          onClick={() => setKind('xtream')}
        >
          {kind() === 'xtream' ? '● ' : '○ '}Xtream Codes
        </button>
        <button
          id="kind-m3u"
          role="radio"
          tabindex="-1"
          aria-checked={kind() === 'm3u'}
          aria-label="Type Playlist M3U"
          class={`tv-btn ${focusId() === 'kind-m3u' ? 'focused' : ''}`}
          onClick={() => setKind('m3u')}
        >
          {kind() === 'm3u' ? '● ' : '○ '}Playlist M3U
        </button>
      </div>

      {field('field-name', 'Nom', name, setName)}
      <Show
        when={kind() === 'xtream'}
        fallback={field('field-url', 'Adresse de la playlist', url, setUrl, { placeholder: 'http://…/playlist.m3u' })}
      >
        {field('field-server', 'Serveur', server, setServer, { placeholder: 'http://monfournisseur:8080' })}
        {field('field-username', 'Identifiant', username, setUsername)}
        {field('field-password', 'Mot de passe', password, setPassword, { type: 'password' })}
      </Show>

      <Show when={message()}>
        <p style={{ 'font-size': '22px', color: isError() ? 'var(--buntu-danger)' : 'var(--buntu-cyan)', margin: '8px 0 16px' }}>{message()}</p>
      </Show>

      <div style={{ display: 'flex', gap: '24px', 'justify-content': 'center' }}>
        <button
          id="btn-submit"
          tabindex="-1"
          aria-label="Ajouter et synchroniser la source"
          class={`tv-btn ${focusId() === 'btn-submit' ? 'focused' : ''}`}
          onClick={() => void submit()}
        >
          Ajouter
        </button>
        <button
          id="btn-cancel"
          tabindex="-1"
          aria-label="Annuler et retourner à l'écran précédent"
          class={`tv-btn ${focusId() === 'btn-cancel' ? 'focused' : ''}`}
          onClick={() => props.onCancel()}
        >
          Retour
        </button>
      </div>
      </Show>
      {keyboard.view()}
    </div>
  );
};
