import { Component, createSignal, onCleanup, onMount, Show } from 'solid-js';
import { spatialNav } from '../../ui/design/SpatialNav';
import { PairingOffer, PairingRequest, PairingService } from '../../core/pairing/PairingService';
import { PairingQr } from '../pairing/PairingQr';
import { ManualSourceForm } from './ManualSourceForm';

export interface OnboardingProps {
  onComplete: () => void;
  onAddM3u: (url: string) => void;
}

export const OnboardingView: Component<OnboardingProps> = (props) => {
  const [m3uUrl, setM3uUrl] = createSignal('');
  const [isManualInput, setIsManualInput] = createSignal(false);
  const [focusId] = spatialNav.getFocusSignal();

  const [offer, setOffer] = createSignal<PairingOffer | null>(null);
  const [pairingError, setPairingError] = createSignal('');
  const [request, setRequest] = createSignal<PairingRequest | null>(null);
  const [busy, setBusy] = createSignal(false);
  const [importStep, setImportStep] = createSignal('Préparation de l’importation…');
  const [importPercent, setImportPercent] = createSignal(5);
  const [result, setResult] = createSignal('');
  const [isErrorResult, setIsErrorResult] = createSignal(false);
  const [secondsLeft, setSecondsLeft] = createSignal(0);

  let ticker: ReturnType<typeof setInterval> | null = null;

  const service = new PairingService({
    onRequest: (r) => {
      setResult('');
      setIsErrorResult(false);
      setRequest(r);
      updateGrid();
    },
    onClosed: (reason) => {
      if (busy()) return;
      setRequest(null);
      if (reason === 'done') return;
      // Expired, closed after errors, or the channel dropped: a new code, nothing to do for the user.
      void startPairing();
    },
    onError: (message) => {
      setIsErrorResult(true);
      setResult(message);
    },
  });

  const startPairing = async () => {
    setPairingError('');
    try {
      const o = await service.start();
      setOffer(o);
      updateGrid();
      if (ticker) clearInterval(ticker);
      const tick = () => setSecondsLeft(Math.max(0, o.expiresAt - Math.floor(Date.now() / 1000)));
      tick();
      ticker = setInterval(tick, 1000);
    } catch (e: any) {
      setOffer(null);
      setPairingError(e?.message ?? 'Appariement indisponible');
      updateGrid();
    }
  };

  onMount(() => {
    updateGrid();
    void startPairing();
  });

  onCleanup(() => {
    service.stop();
    if (ticker) clearInterval(ticker);
  });

  const accept = async () => {
    const r = request();
    if (!r || busy()) return;
    setBusy(true);
    setResult('');
    setIsErrorResult(false);
    setImportStep('Connexion au fournisseur IPTV…');
    setImportPercent(5);
    spatialNav.setGrid([]);

    const count = await r.accept((stepMsg, pct) => {
      setImportStep(stepMsg);
      if (pct !== undefined) {
        setImportPercent(Math.max(5, Math.min(100, pct)));
      }
    });

    setBusy(false);
    setRequest(null);
    if (count > 0) {
      setIsErrorResult(false);
      setResult(`${count} compte${count > 1 ? 's' : ''} importé${count > 1 ? 's' : ''} avec succès ! Ouverture du Direct TV…`);
      setTimeout(() => props.onComplete(), 1500);
    } else {
      if (!result()) {
        setIsErrorResult(true);
        setResult('Aucun compte ajouté (déjà présent ou mot de passe non inclus).');
      }
      void startPairing();
      updateGrid();
    }
  };

  const refuse = async () => {
    const r = request();
    if (!r || busy()) return;
    await r.refuse();
    setRequest(null);
    setIsErrorResult(false);
    setResult('Envoi refusé');
    void startPairing();
    updateGrid();
  };

  const updateGrid = () => {
    if (busy()) {
      spatialNav.setGrid([]);
      return;
    }
    if (request()) {
      spatialNav.setGrid([[
        { id: 'btn-pair-accept', onSelect: () => void accept() },
        { id: 'btn-pair-refuse', onSelect: () => void refuse() },
      ]]);
      return;
    }
    spatialNav.setGrid([
      [
        ...(pairingError() ? [{ id: 'btn-retry', onSelect: () => void startPairing() }] : []),
        { id: 'btn-manual', onSelect: () => setIsManualInput(true) },
        { id: 'btn-skip', onSelect: () => props.onComplete() },
      ],
    ]);
  };

  const minutes = () => `${Math.floor(secondsLeft() / 60)}:${String(secondsLeft() % 60).padStart(2, '0')}`;

  return (
    <div class="tv-container" style={{ "justify-content": "center", "align-items": "center" }}>
      <Show when={isManualInput()}>
        <ManualSourceForm
          onAdded={() => props.onComplete()}
          onCancel={() => { setIsManualInput(false); updateGrid(); void startPairing(); }}
        />
      </Show>
      <Show when={!isManualInput()}>
      <div style={{ "text-align": "center", "max-width": "900px" }}>
        <h1 style={{ "font-size": "48px", "color": "var(--buntu-gold)", "margin-bottom": "16px" }}>
          Bienvenue sur CND IPTV
        </h1>
        <p style={{ "font-size": "24px", "color": "var(--buntu-text-muted)", "margin-bottom": "40px" }}>
          Ajoutez votre abonnement depuis votre smartphone en scannant le QR code.
        </p>

        <Show when={!busy()} fallback={
          <div class="tv-loader-card" style={{ "margin-bottom": "40px" }}>
            <div class="tv-spinner" role="status" aria-label="Importation en cours" />
            <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)", margin: 0 }}>
              Importation du compte en cours…
            </h2>
            <p style={{ "font-size": "24px", color: "var(--buntu-cyan)", margin: 0 }}>
              {importStep()}
            </p>
            <div class="tv-progress-track">
              <div class="tv-progress-bar" style={{ width: `${importPercent()}%` }} />
            </div>
            <p style={{ "font-size": "18px", color: "var(--buntu-text-muted)", margin: 0 }}>
              Veuillez patienter sans fermer l’application ({importPercent()}%)
            </p>
          </div>
        }>
        <Show when={!request()} fallback={
          <div style={{
            background: "var(--buntu-slate)", padding: "32px", "border-radius": "16px",
            "margin-bottom": "40px", border: "2px solid var(--buntu-gold)", "text-align": "left"
          }}>
            <h2 style={{ "font-size": "32px", "margin-bottom": "8px", color: "var(--buntu-gold)" }}>
              {request()!.from || 'Un téléphone'} veut ajouter {request()!.preview.sources.length} compte{request()!.preview.sources.length > 1 ? 's' : ''}
            </h2>
            <div style={{ display: "flex", "flex-direction": "column", gap: "12px", margin: "20px 0 28px" }}>
              {request()!.preview.sources.map((src) => (
                <div style={{ display: "flex", "justify-content": "space-between", "font-size": "24px" }}>
                  <span>
                    <strong>{src.name}</strong>{' '}
                    <span style={{ color: "var(--buntu-text-muted)" }}>
                      {src.type === 'xtream' ? 'Xtream' : 'M3U'} · {src.host}{src.hasPassword ? ' · avec mot de passe' : ''}
                    </span>
                  </span>
                  <span style={{ color: src.duplicate ? "var(--buntu-text-muted)" : "var(--buntu-cyan)" }}>
                    {src.duplicate ? 'déjà présent' : 'nouveau'}
                  </span>
                </div>
              ))}
            </div>
            <div style={{ display: "flex", gap: "24px", "justify-content": "center" }}>
              <button class={`tv-btn ${focusId() === 'btn-pair-accept' ? 'focused' : ''}`} onClick={() => void accept()}>
                Ajouter sur cette TV
              </button>
              <button class={`tv-btn ${focusId() === 'btn-pair-refuse' ? 'focused' : ''}`} onClick={() => void refuse()}>
                Refuser
              </button>
            </div>
          </div>
        }>
          <div style={{
            display: "flex", gap: "48px", background: "var(--buntu-slate)", padding: "32px",
            "border-radius": "16px", "align-items": "center", "margin-bottom": "40px",
            border: "1px solid var(--buntu-border)"
          }}>
            <div style={{ width: "320px", height: "320px", display: "flex", "align-items": "center", "justify-content": "center" }}>
              <Show when={offer()} fallback={
                <div style={{ color: "var(--buntu-text-muted)", "font-size": "20px", "text-align": "center" }}>
                  <p>{pairingError() || 'Préparation du code…'}</p>
                  <Show when={pairingError()}>
                    <button class={`tv-btn ${focusId() === 'btn-retry' ? 'focused' : ''}`} style={{ "margin-top": "16px" }} onClick={() => void startPairing()}>
                      Réessayer
                    </button>
                  </Show>
                </div>
              }>
                <PairingQr size={offer()!.qrSize} modules={offer()!.qrModules} pixels={320} link={offer()!.link} />
              </Show>
            </div>

            <div style={{ "text-align": "left", flex: 1 }}>
              <h3 style={{ "font-size": "24px", "margin-bottom": "8px" }}>1. Scannez avec votre téléphone</h3>
              <p style={{ "color": "var(--buntu-text-muted)", "margin-bottom": "16px" }}>
                Appareil photo de l'iPhone ou de l'Android : il ouvre l'application Buntu. Téléphone et TV
                doivent être sur le même Wi-Fi.
              </p>
              <h3 style={{ "font-size": "24px", "margin-bottom": "8px" }}>2. Choisissez vos comptes, puis confirmez ici</h3>
              <p style={{ "color": "var(--buntu-text-muted)" }}>
                <Show when={offer()}>Ce code expire dans {minutes()}.</Show>
              </p>
            </div>
          </div>
        </Show>
        </Show>

        <Show when={result()}>
          <p style={{
            "font-size": "24px",
            color: isErrorResult() ? "var(--buntu-danger)" : "var(--buntu-cyan)",
            "margin-bottom": "24px",
            "font-weight": "600",
          }}>{result()}</p>
        </Show>

        <Show when={!request() && !busy()}>
          <div style={{ display: "flex", gap: "24px", "justify-content": "center" }}>
            <button
              class={`tv-btn ${focusId() === 'btn-manual' ? 'focused' : ''}`}
              onClick={() => setIsManualInput(true)}
            >
              Saisir avec la télécommande
            </button>
            <button
              class={`tv-btn ${focusId() === 'btn-skip' ? 'focused' : ''}`}
              onClick={() => props.onComplete()}
            >
              Passer / Essai
            </button>
          </div>
        </Show>
      </div>
      </Show>
    </div>
  );
};
