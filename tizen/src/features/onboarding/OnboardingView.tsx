import { Component, createSignal, onMount } from 'solid-js';
import { spatialNav } from '../../ui/design/SpatialNav';

export interface OnboardingProps {
  onComplete: () => void;
  onAddM3u: (url: string) => void;
}

export const OnboardingView: Component<OnboardingProps> = (props) => {
  const [pairingCode] = createSignal(Math.floor(100000 + Math.random() * 900000).toString());
  const [m3uUrl, setM3uUrl] = createSignal('');
  const [isManualInput, setIsManualInput] = createSignal(false);
  const [focusId] = spatialNav.getFocusSignal();

  onMount(() => {
    updateGrid();
  });

  const updateGrid = () => {
    spatialNav.setGrid([
      [
        {
          id: 'btn-manual',
          onSelect: () => setIsManualInput(true),
        },
        {
          id: 'btn-skip',
          onSelect: () => props.onComplete(),
        },
      ],
    ]);
  };

  return (
    <div class="tv-container" style={{ "justify-content": "center", "align-items": "center" }}>
      <div style={{ "text-align": "center", "max-width": "800px" }}>
        <h1 style={{ "font-size": "48px", "color": "var(--buntu-gold)", "margin-bottom": "16px" }}>
          Bienvenue sur CND IPTV
        </h1>
        <p style={{ "font-size": "24px", "color": "var(--buntu-text-muted)", "margin-bottom": "48px" }}>
          Ajoutez votre abonnement facilement depuis votre smartphone en scannant le QR code.
        </p>

        <div style={{
          display: "flex",
          gap: "48px",
          background: "var(--buntu-slate)",
          padding: "32px",
          "border-radius": "16px",
          "align-items": "center",
          "margin-bottom": "48px",
          border: "1px solid var(--buntu-border)"
        }}>
          {/* Simulated QR Code Canvas */}
          <div style={{
            width: "200px",
            height: "200px",
            background: "#FFFFFF",
            display: "flex",
            "align-items": "center",
            "justify-content": "center",
            color: "#000000",
            "font-weight": "800",
            "border-radius": "8px"
          }}>
            [ QR CODE ]
          </div>

          <div style={{ "text-align": "left", flex: 1 }}>
            <h3 style={{ "font-size": "24px", "margin-bottom": "8px" }}>1. Scannez avec votre téléphone</h3>
            <p style={{ "color": "var(--buntu-text-muted)", "margin-bottom": "16px" }}>
              Ouvrez l'appareil photo ou l'application CND sur iPhone ou Android.
            </p>
            <h3 style={{ "font-size": "24px", "margin-bottom": "8px" }}>2. Ou saisissez le code d'appariement :</h3>
            <div style={{
              "font-size": "36px",
              "font-weight": "800",
              "letter-spacing": "6px",
              color: "var(--buntu-cyan)"
            }}>
              {pairingCode()}
            </div>
          </div>
        </div>

        <div style={{ display: "flex", gap: "24px", "justify-content": "center" }}>
          <button
            class={`tv-btn ${focusId() === 'btn-manual' ? 'focused' : ''}`}
            onClick={() => setIsManualInput(true)}
          >
            Saisie manuelle URL M3U
          </button>
          <button
            class={`tv-btn ${focusId() === 'btn-skip' ? 'focused' : ''}`}
            onClick={() => props.onComplete()}
          >
            Passer / Essai
          </button>
        </div>
      </div>
    </div>
  );
};
