import { Component, createSignal, onMount } from 'solid-js';
import { CndEngine, ProfileState } from '../../core/engine/CndEngine';
import { spatialNav } from '../../ui/design/SpatialNav';

export interface ProfilesViewProps {
  onProfileChanged: () => void;
}

export const ProfilesView: Component<ProfilesViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [activeProfile, setActiveProfile] = createSignal<ProfileState>(engine.getActiveProfile());
  const [pinInput, setPinInput] = createSignal('');
  const [unlockedMsg, setUnlockedMsg] = createSignal('');
  const [focusId] = spatialNav.getFocusSignal();

  const profiles: ProfileState[] = [
    { id: 1, name: 'Principal (Adultes)', isKids: false, avatar: '👤' },
    { id: 2, name: 'Enfants (Sécurisé)', isKids: true, avatar: '👶' },
  ];

  const selectProfile = (p: ProfileState) => {
    engine.setProfile(p);
    setActiveProfile(p);
    props.onProfileChanged();
  };

  const verifyPin = () => {
    if (engine.unlockAdult(pinInput())) {
      setUnlockedMsg('Catégories adultes déverrouillées avec succès.');
    } else {
      setUnlockedMsg('Code PIN incorrect.');
    }
    setPinInput('');
  };

  onMount(() => {
    spatialNav.setGrid([
      profiles.map((p) => ({
        id: `profile-${p.id}`,
        onSelect: () => selectProfile(p),
      })),
      [
        {
          id: 'field-pin',
          onSelect: () => {
            const el = document.getElementById('field-pin') as HTMLInputElement | null;
            el?.focus();
            el?.click();
          },
        },
        {
          id: 'btn-unlock-pin',
          onSelect: verifyPin,
        },
      ],
    ]);
  });

  return (
    <div class="tv-container" style={{ "justify-content": "center", "align-items": "center" }}>
      <div style={{ "text-align": "center", "max-width": "700px" }}>
        <h1 style={{ "font-size": "44px", color: "var(--buntu-gold)", "margin-bottom": "36px" }}>
          Qui regarde la télévision ?
        </h1>

        <div style={{ display: "flex", gap: "32px", "justify-content": "center", "margin-bottom": "48px" }} role="list" aria-label="Liste des profils">
          {profiles.map((p) => (
            <div
              id={`profile-${p.id}`}
              role="button"
              tabindex="-1"
              aria-label={`Profil ${p.name}`}
              class={`tv-card ${focusId() === `profile-${p.id}` || activeProfile().id === p.id ? 'focused' : ''}`}
              style={{
                width: "240px",
                padding: "32px 16px",
                cursor: "pointer",
                display: "flex",
                "flex-direction": "column",
                "align-items": "center",
                gap: "16px",
              }}
              onClick={() => selectProfile(p)}
            >
              <div style={{ "font-size": "64px" }}>{p.avatar}</div>
              <div style={{ "font-size": "22px", "font-weight": "700" }}>{p.name}</div>
            </div>
          ))}
        </div>

        {/* Parental PIN Control */}
        <div style={{
          background: "var(--buntu-slate)",
          padding: "24px 32px",
          "border-radius": "12px",
          border: "1px solid var(--buntu-border)"
        }}>
          <h3 style={{ "font-size": "20px", "margin-bottom": "8px" }}>Contrôle parental (Code PIN)</h3>
          <p style={{ "font-size": "14px", color: "var(--buntu-text-muted)", "margin-bottom": "16px" }}>
            Saisissez le code PIN pour afficher les catégories adultes masquées.
          </p>
          <div style={{ display: "flex", gap: "16px", "justify-content": "center" }}>
            <input
              id="field-pin"
              class={`tv-input ${focusId() === 'field-pin' ? 'focused' : ''}`}
              type="password"
              maxlength="4"
              value={pinInput()}
              onInput={(e) => setPinInput(e.currentTarget.value)}
              placeholder="PIN (défaut 0000)"
              aria-label="Code PIN parental à 4 chiffres"
              style={{
                width: "200px",
                "text-align": "center"
              }}
            />
            <button
              id="btn-unlock-pin"
              tabindex="-1"
              aria-label="Déverrouiller avec le code PIN saisi"
              class={`tv-btn ${focusId() === 'btn-unlock-pin' ? 'focused' : ''}`}
              onClick={verifyPin}
            >
              Déverrouiller
            </button>
          </div>
          {unlockedMsg() && (
            <div style={{ "margin-top": "12px", color: "var(--buntu-cyan)", "font-weight": "600" }}>
              {unlockedMsg()}
            </div>
          )}
        </div>
      </div>
    </div>
  );
};
