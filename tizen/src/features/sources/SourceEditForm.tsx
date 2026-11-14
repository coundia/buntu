import { Component, createSignal, onMount, onCleanup, Show } from 'solid-js';
import { SourceRecord } from '../../core/storage/Database';
import { CndEngine } from '../../core/engine/CndEngine';
import { spatialNav } from '../../ui/design/SpatialNav';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { createTvKeyboard, listenFocusedFieldPaste, pasteEventIntoField } from '../../ui/components/TvKeyboard';

export const SourceEditForm: Component<{ source: SourceRecord; onSaved: () => void; onCancel: () => void }> = (props) => {
  const [host, setHost] = createSignal(props.source.server || '');
  const [user, setUser] = createSignal(props.source.username || '');
  const [password, setPassword] = createSignal(props.source.password || '');
  const [url, setUrl] = createSignal(props.source.url || '');
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal('');
  const [focus] = spatialNav.getFocusSignal();
  const keyboard = createTvKeyboard();
  let unsubscribe: (() => void) | undefined;
  let pasteUnsub: (() => void) | undefined;
  const cancel = () => { if (!busy()) props.onCancel(); };
  const submit = async () => {
    if (busy()) return;
    setBusy(true);
    setError('');
    try {
      await CndEngine.getInstance().updateLocalSource(props.source.id, {
        source_type: props.source.source_type, server: host(), username: user(), password: password(), url: url(),
      });
      props.onSaved();
    } catch {
      setError('Enregistrement impossible. Vérifiez l’adresse HTTP(S), l’utilisateur et le mot de passe, puis réessayez.');
    } finally { setBusy(false); }
  };
  const fields: Record<string, [string, () => string, (v: string) => void, boolean]> = {
    'edit-host': ['Adresse du serveur', host, setHost, false],
    'edit-user': ['Utilisateur', user, setUser, false],
    'edit-password': ['Mot de passe', password, setPassword, true],
    'edit-url': ['Adresse de la playlist', url, setUrl, false],
  };
  /** OK on a field: the on-screen keyboard (the Samsung system keyboard is not reliable with a remote). */
  const openKeyboard = (id: string) => {
    if (busy()) return;
    const f = fields[id];
    if (f) keyboard.open(f[0], f[1](), f[2], f[3]);
  };
  onMount(() => {
    const ids = props.source.source_type === 'xtream' ? ['edit-host', 'edit-user', 'edit-password'] : ['edit-url'];
    spatialNav.setGrid([
      ...ids.map((id) => [{ id, onSelect: () => openKeyboard(id) }]),
      [{ id: 'edit-save', onSelect: () => void submit() }, { id: 'edit-cancel', onSelect: cancel }],
    ]);
    unsubscribe = RemoteKeyHandler.getInstance().addListener((key) => {
      if (key !== 'BACK' || keyboard.isOpen()) return false;
      cancel(); return true;
    });
    pasteUnsub = listenFocusedFieldPaste(
      () => keyboard.isOpen() || busy(),
      (id) => {
        if (!ids.includes(id)) return undefined;
        const entry = fields[id];
        return entry ? [entry[1], entry[2]] : undefined;
      }
    );
  });
  onCleanup(() => { unsubscribe?.(); pasteUnsub?.(); setPassword(''); });
  const field = (id: string, label: string, value: () => string, setter: (s: string) => void, type = 'text') =>
    <label style={{ display: 'block', 'margin-bottom': '16px' }}>{label}
      <input id={id} type={type} autocomplete="off" value={value()} disabled={busy()} readOnly inputMode="none" onClick={() => openKeyboard(id)} class={`tv-input ${focus() === id ? 'focused' : ''}`} onInput={(e) => setter(e.currentTarget.value)} onPaste={(e) => { if (!busy()) pasteEventIntoField(e, value, setter); }} />
    </label>;
  return <div style={{ 'max-width': '760px', margin: '0 auto', padding: '24px' }}>
    <h2>Modifier « {props.source.name} » sur cette TV</h2>
    <p>Ces coordonnées restent locales. Elles ne seront pas envoyées au foyer ni remplacées par les données reçues.</p>
    <Show when={props.source.source_type === 'xtream'} fallback={field('edit-url', 'Adresse de la playlist', url, setUrl)}>
      {field('edit-host', 'HOST (http:// ou https://)', host, setHost)}
      {field('edit-user', 'Utilisateur', user, setUser)}
      {field('edit-password', 'Mot de passe', password, setPassword, 'password')}
    </Show>
    <Show when={error()}><p role="alert">{error()}</p></Show>
    <button id="edit-save" class={`tv-btn ${focus() === 'edit-save' ? 'focused' : ''}`} disabled={busy()} onClick={() => void submit()}>{busy() ? 'Enregistrement…' : props.source.source_type === 'm3u' ? 'Enregistrer et recharger la playlist' : 'Enregistrer sur cette TV'}</button>
    <button id="edit-cancel" class={`tv-btn ${focus() === 'edit-cancel' ? 'focused' : ''}`} disabled={busy()} onClick={cancel}>Annuler</button>
    {keyboard.view()}
  </div>;
};
