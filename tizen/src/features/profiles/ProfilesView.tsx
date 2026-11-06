import { Component, createSignal } from 'solid-js';
import { CndEngine, ProfileState } from '../../core/engine/CndEngine';

export interface ProfilesViewProps {
  onProfileChanged: () => void;
}

export const ProfilesView: Component<ProfilesViewProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [activeProfile, setActiveProfile] = createSignal<ProfileState>(engine.getActiveProfile());
  const [pinInput, setPinInput] = createSignal('');
  const [unlockedMsg, setUnlockedMsg] = createSignal('');

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

  return (
    <div class="tv-container" style={{ "justify-content": "center", "align-items": "center" }}>
      <div style={{ "text-align": "center", "max-width": "700px" }}>
        <h1 style={{ "font-size": "44px", color: "var(--buntu-gold)", "margin-bottom": "36px" }}>
          Qui regarde la télévision ?
        </h1>

        <div style={{ display: "flex", gap: "32px", "justify-content": "center", "margin-bottom": "48px" }}>
          {profiles.map((p) => (
            <div
              class={`tv-card ${activeProfile().id === p.id ? 'focused' : ''}`}
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
              type="password"
              maxlength="4"
              value={pinInput()}
              onInput={(e) => setPinInput(e.currentTarget.value)}
              placeholder="PIN (défaut 0000)"
              style={{
                padding: "12px 16px",
                "font-size": "20px",
                "border-radius": "8px",
                border: "2px solid var(--buntu-border)",
                background: "var(--buntu-midnight)",
                color: "#FFFFFF",
                width: "200px",
                "text-align": "center"
              }}
            />
            <button class="tv-btn" onClick={verifyPin}>Déverrouiller</button>
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
