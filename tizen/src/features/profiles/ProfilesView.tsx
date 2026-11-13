import { Component, createSignal, onMount, onCleanup, Show, For } from 'solid-js';
import { CndEngine, ProfileState } from '../../core/engine/CndEngine';
import { spatialNav } from '../../ui/design/SpatialNav';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';

export interface ProfilesViewProps {
  onProfileChanged: () => void;
}

export const ProfilesView: Component<ProfilesViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [activeProfile, setActiveProfile] = createSignal<ProfileState>(engine.getActiveProfile());
  const [showPin, setShowPin] = createSignal(false);
  const [pinInput, setPinInput] = createSignal('');
  const [unlockedMsg, setUnlockedMsg] = createSignal('');
  const [focusId] = spatialNav.getFocusSignal();
  const profiles: ProfileState[] = [
    { id: 1, name: 'Principal', isKids: false, avatar: '👤' },
    { id: 2, name: 'Enfants', isKids: true, avatar: '👶' },
  ];
  const selectProfile = (profile: ProfileState) => {
    engine.setProfile(profile);
    setActiveProfile(profile);
    props.onProfileChanged();
  };
  const verifyPin = () => {
    setUnlockedMsg(engine.unlockAdult(pinInput()) ? 'Catégories adultes déverrouillées.' : 'Code PIN incorrect.');
    setPinInput('');
  };
  const updateGrid = () => {
    spatialNav.setGrid([
      profiles.map((profile) => ({ id: `profile-${profile.id}`, onSelect: () => selectProfile(profile) })),
      [{ id: 'profile-parental', onSelect: togglePin }],
      ...(showPin() ? [[
        { id: 'field-pin', onSelect: () => (document.getElementById('field-pin') as HTMLInputElement | null)?.focus() },
        { id: 'btn-unlock-pin', onSelect: verifyPin },
      ]] : []),
    ], 0, Math.max(0, profiles.findIndex((profile) => profile.id === activeProfile().id)));
  };
  const togglePin = () => {
    setShowPin((value) => !value);
    setPinInput('');
    setUnlockedMsg('');
    updateGrid();
    spatialNav.setFocusById(showPin() ? 'field-pin' : 'profile-parental');
  };
  onMount(() => {
    spatialNav.setHeader([]);
    updateGrid();
    const unsubscribe = RemoteKeyHandler.getInstance().addListener((key) => {
      if (key === 'BACK' && showPin()) { togglePin(); return true; }
      return false;
    });
    onCleanup(unsubscribe);
  });

  return (
    <section class="buntu-profiles-page" aria-labelledby="profiles-title">
      <h1 id="profiles-title">Qui regarde ?</h1>
      <p class="buntu-return-hint">Choisissez un profil · Retour : réglages</p>
      <div class="buntu-profile-choices" aria-label="Profils">
        <For each={profiles}>{(profile) => (
          <button id={`profile-${profile.id}`} type="button" tabindex="-1"
            aria-label={`Profil ${profile.name}`} aria-pressed={activeProfile().id === profile.id}
            class={`buntu-profile-card ${focusId() === `profile-${profile.id}` ? 'focused' : ''}`}
            onClick={() => selectProfile(profile)}>
            <span class="buntu-profile-avatar" aria-hidden="true">{profile.avatar}</span>
            <strong>{profile.name}</strong>
            <span>{activeProfile().id === profile.id ? 'Profil actuel' : profile.isKids ? 'Pour les plus jeunes' : 'Pour vous'}</span>
          </button>
        )}</For>
      </div>
      <button id="profile-parental" type="button" tabindex="-1" aria-expanded={showPin()}
        class={`tv-btn ${focusId() === 'profile-parental' ? 'focused' : ''}`} onClick={togglePin}>
        {showPin() ? 'Fermer le contrôle parental' : 'Contrôle parental'}
      </button>
      <Show when={showPin()}>
        <div class="buntu-profile-pin">
          <label for="field-pin">Code PIN parental</label>
          <div class="buntu-simple-actions">
            <input id="field-pin" class={`tv-input ${focusId() === 'field-pin' ? 'focused' : ''}`}
              type="password" inputmode="numeric" maxlength="4" value={pinInput()}
              onInput={(event) => setPinInput(event.currentTarget.value)} placeholder="4 chiffres" />
            <button id="btn-unlock-pin" type="button" tabindex="-1"
              class={`tv-btn ${focusId() === 'btn-unlock-pin' ? 'focused' : ''}`} onClick={verifyPin}>Déverrouiller</button>
          </div>
          <Show when={unlockedMsg()}><p role="status">{unlockedMsg()}</p></Show>
        </div>
      </Show>
    </section>
  );
};
