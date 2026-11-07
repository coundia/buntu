import { Component, Show, createEffect, createSignal, onCleanup, onMount } from 'solid-js';
import { spatialNav } from '../../ui/design/SpatialNav';
import { CndEngine } from '../../core/engine/CndEngine';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';

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
  const [message, setMessage] = createSignal('');
  const [focusId] = spatialNav.getFocusSignal();

  const fieldIds = () =>
    kind() === 'xtream'
      ? ['field-name', 'field-server', 'field-username', 'field-password']
      : ['field-name', 'field-url'];

  const openFieldKeyboard = (id: string) => {
    const el = document.getElementById(id) as HTMLInputElement | null;
    if (el) {
      el.focus();
      el.click();
    }
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

  onMount(() => {
    updateGrid();
    backUnsub = RemoteKeyHandler.getInstance().addListener((key) => {
      if (key === 'BACK') {
        props.onCancel();
        return true;
      }
      return false;
    });
  });

  onCleanup(() => {
    if (backUnsub) backUnsub();
  });

  // The kind changes the fields: rebuild the grid (keeps the focus on the kind buttons).
  createEffect(() => {
    kind();
    updateGrid();
  });

  // Blur any active input when moving focus away with D-Pad; pressing OK (ENTER) opens the TV keyboard.
  createEffect(() => {
    const id = focusId();
    if (document.activeElement instanceof HTMLInputElement && document.activeElement.id !== id) {
      document.activeElement.blur();
    }
  });

  const valid = () => {
    if (kind() === 'm3u') return /^https?:\/\//i.test(url().trim());
    return /^https?:\/\//i.test(server().trim()) && username().trim() !== '' && password() !== '';
  };

  const submit = async () => {
    if (busy()) return;
    if (!valid()) {
      setMessage(
        kind() === 'm3u'
          ? "L'adresse de la playlist doit commencer par http:// ou https://"
          : "Serveur (http://…), identifiant et mot de passe sont nécessaires."
      );
      return;
    }
    setBusy(true);
    setMessage('');
    try {
      const engine = CndEngine.getInstance();
      const label = name().trim() || (kind() === 'm3u' ? 'Ma playlist' : 'Mon IPTV');
      if (kind() === 'xtream') {
        await engine.syncXtreamSource(label, server().trim(), username().trim(), password(), undefined, setMessage);
      } else {
        await engine.syncM3uSource(label, url().trim(), setMessage);
      }
      props.onAdded();
    } catch (e: any) {
      setMessage(e?.message ? `Échec : ${e.message}` : 'Échec de la synchronisation');
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
        onInput={(e) => set((e.currentTarget as HTMLInputElement).value)}
      />
    </label>
  );

  return (
    <div style={{ 'max-width': '760px', margin: '0 auto' }}>
      <h2 style={{ 'font-size': '36px', color: 'var(--buntu-gold)', 'margin-bottom': '20px' }}>Ajouter un compte avec la télécommande</h2>

      <div style={{ display: 'flex', gap: '16px', 'margin-bottom': '20px' }}>
        <button class={`tv-btn ${focusId() === 'kind-xtream' ? 'focused' : ''}`} onClick={() => setKind('xtream')}>
          {kind() === 'xtream' ? '● ' : '○ '}Xtream Codes
        </button>
        <button class={`tv-btn ${focusId() === 'kind-m3u' ? 'focused' : ''}`} onClick={() => setKind('m3u')}>
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
        <p style={{ 'font-size': '22px', color: 'var(--buntu-cyan)', margin: '8px 0 16px' }}>{message()}</p>
      </Show>

      <div style={{ display: 'flex', gap: '24px', 'justify-content': 'center' }}>
        <button class={`tv-btn ${focusId() === 'btn-submit' ? 'focused' : ''}`} onClick={() => void submit()}>
          {busy() ? 'Synchronisation…' : 'Ajouter'}
        </button>
        <button class={`tv-btn ${focusId() === 'btn-cancel' ? 'focused' : ''}`} onClick={() => props.onCancel()}>
          Retour
        </button>
      </div>
    </div>
  );
};
