import { Component, createSignal, onCleanup, onMount, Show, For } from 'solid-js';
import { spatialNav } from '../../ui/design/SpatialNav';
import { announce } from '../../ui/design/a11y';
import { RemoteKey, RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { PairingEvents, PairingOffer, PairingRequest, PairingService } from '../../core/pairing/PairingService';
import { PairingQr } from './PairingQr';

export interface PairingViewProps {
  /** Called when pairing and sync succeed with the number of accounts added. */
  onSuccess: (count: number) => void;
  /** Called when user clicks back or cancels pairing. */
  onBack: () => void;
  /** Custom title for the screen (default: "Ajouter depuis votre smartphone") */
  title?: string;
  /** Custom subtitle for the screen */
  subtitle?: string;
  /** Optional callback to switch to manual remote control input */
  onSwitchToManual?: () => void;
  /** Optional callback to skip adding a source (e.g. during onboarding) */
  onSkip?: () => void;
  /** Optional factory to create a custom PairingService instance (for tests / dependency injection) */
  createService?: (events: PairingEvents) => Pick<PairingService, 'start' | 'stop'>;
}

export const PairingView: Component<PairingViewProps> = (props) => {
  const [focusId] = spatialNav.getFocusSignal();

  const [offer, setOffer] = createSignal<PairingOffer | null>(null);
  const [pairingError, setPairingError] = createSignal('');
  const [request, setRequest] = createSignal<PairingRequest | null>(null);
  const [replaceDuplicates, setReplaceDuplicates] = createSignal(false);
  const [busy, setBusy] = createSignal(false);
  const [importStep, setImportStep] = createSignal('Préparation de l’importation…');
  const [importPercent, setImportPercent] = createSignal(5);
  const [result, setResult] = createSignal('');
  const [isErrorResult, setIsErrorResult] = createSignal(false);
  const [secondsLeft, setSecondsLeft] = createSignal(0);

  let ticker: ReturnType<typeof setInterval> | null = null;
  let keyUnsub: (() => void) | null = null;

  const events: PairingEvents = {
    onRequest: (r) => {
      setResult('');
      setIsErrorResult(false);
      setRequest(r);
      setReplaceDuplicates(false);
      updateGrid();
      // PRD 39 § 2.1: à la réception, focus immédiat sur "Ajouter"
      setTimeout(() => {
        spatialNav.setFocusById('btn-pair-accept');
      }, 50);
      announce(
        `${r.from || 'Un smartphone'} veut ajouter ${r.preview.sources.length} compte${
          r.preview.sources.length > 1 ? 's' : ''
        }. Confirmez avec la télécommande.`
      );
    },
    onClosed: (reason) => {
      if (busy()) return;
      setRequest(null);
      if (reason === 'done') return;
      // Expired, closed after 3 invalid attempts, or channel dropped: renew automatically
      void startPairing();
    },
    onError: (message) => {
      setIsErrorResult(true);
      setResult(message);
      announce(message);
    },
  };

  const service = props.createService ? props.createService(events) : new PairingService(events);

  const startPairing = async () => {
    setPairingError('');
    try {
      const o = await service.start();
      setOffer(o);
      updateGrid();
      if (ticker) clearInterval(ticker);
      const tick = () => {
        const left = Math.max(0, o.expiresAt - Math.floor(Date.now() / 1000));
        setSecondsLeft(left);
        if (left <= 0) {
          if (ticker) clearInterval(ticker);
          void startPairing();
        }
      };
      tick();
      ticker = setInterval(tick, 1000);
    } catch (e: any) {
      setOffer(null);
      setPairingError(e?.message ?? 'Appariement indisponible');
      updateGrid();
    }
  };

  const handleRemoteKey = (key: RemoteKey): boolean => {
    if (key === 'BACK') {
      if (busy()) {
        // Never interrupt in-flight database / stream sync
        return true;
      }
      if (request()) {
        void refuse();
        return true;
      }
      props.onBack();
      return true;
    }
    return false;
  };

  onMount(() => {
    keyUnsub = RemoteKeyHandler.getInstance().addListener(handleRemoteKey);
    updateGrid();
    void startPairing();
  });

  onCleanup(() => {
    if (keyUnsub) keyUnsub();
    if (ticker) clearInterval(ticker);
    service.stop();
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

    const count = await r.accept(
      (stepMsg, pct) => {
        setImportStep(stepMsg);
        if (pct !== undefined) {
          setImportPercent(Math.max(5, Math.min(100, pct)));
        }
      },
      { replaceDuplicates: replaceDuplicates() }
    );

    setBusy(false);
    setRequest(null);
    if (count > 0) {
      setIsErrorResult(false);
      const msg = `${count} compte${count > 1 ? 's' : ''} importé${count > 1 ? 's' : ''} avec succès !`;
      setResult(msg);
      announce(msg);
      setTimeout(() => props.onSuccess(count), 1200);
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
    announce('Importation refusée');
    void startPairing();
    updateGrid();
  };

  const toggleDuplicateMode = () => {
    setReplaceDuplicates(!replaceDuplicates());
  };

  const hasDuplicates = () => {
    const req = request();
    return !!req?.preview?.sources?.some((s) => s.duplicate);
  };

  const updateGrid = () => {
    if (busy()) {
      spatialNav.setGrid([]);
      return;
    }
    if (request()) {
      const rows: any[][] = [];
      let acceptRow = 0;
      if (hasDuplicates()) {
        rows.push([
          {
            id: 'btn-pair-toggle-dup',
            onSelect: toggleDuplicateMode,
          },
        ]);
        acceptRow = 1;
      }
      rows.push([
        { id: 'btn-pair-accept', onSelect: () => void accept() },
        { id: 'btn-pair-refuse', onSelect: () => void refuse() },
      ]);
      spatialNav.setGrid(rows, acceptRow, 0);
      return;
    }

    const mainRow: any[] = [
      { id: 'btn-pairing-back', onSelect: () => props.onBack() },
      ...(offer() ? [{ id: 'btn-pair-renew', onSelect: () => void startPairing() }] : []),
      ...(pairingError() ? [{ id: 'btn-retry', onSelect: () => void startPairing() }] : []),
      ...(props.onSwitchToManual ? [{ id: 'btn-pair-manual', onSelect: () => props.onSwitchToManual!() }] : []),
      ...(props.onSkip ? [{ id: 'btn-pair-skip', onSelect: () => props.onSkip!() }] : []),
    ];
    spatialNav.setGrid([mainRow]);
  };

  const minutes = () => `${Math.floor(secondsLeft() / 60)}:${String(secondsLeft() % 60).padStart(2, '0')}`;

  return (
    <div
      class="tv-container"
      style={{
        display: 'flex',
        'flex-direction': 'column',
        'justify-content': 'center',
        'align-items': 'center',
        width: '100%',
        height: '100%',
        padding: '32px 48px',
        'box-sizing': 'border-box',
      }}
    >
      <div style={{ 'max-width': '980px', width: '100%', 'text-align': 'center' }}>
        {/* Header */}
        <div style={{ display: 'flex', 'align-items': 'center', 'justify-content': 'space-between', 'margin-bottom': '24px' }}>
          <button
            id="btn-pairing-back"
            tabindex="-1"
            aria-label="Retour à l'écran précédent"
            class={`tv-btn ${focusId() === 'btn-pairing-back' ? 'focused' : ''}`}
            onClick={() => props.onBack()}
          >
            ← Retour
          </button>
          <div style={{ flex: 1, 'text-align': 'center' }}>
            <h1 style={{ 'font-size': '40px', color: 'var(--buntu-gold)', margin: '0 0 8px 0' }}>
              {props.title || 'Ajouter depuis votre smartphone'}
            </h1>
            <p style={{ 'font-size': '20px', color: 'var(--buntu-text-muted)', margin: 0 }}>
              {props.subtitle || 'Scannez le QR code avec l’appareil photo ou l’application Buntu pour transférer vos comptes.'}
            </p>
          </div>
          <div style={{ width: '120px' }} />
        </div>

        {/* In-Flight Import Loader */}
        <Show when={!busy()} fallback={
          <div class="tv-loader-card" style={{ 'margin-bottom': '40px' }}>
            <div class="tv-spinner" role="status" aria-label="Importation en cours" />
            <h2 style={{ 'font-size': '32px', color: 'var(--buntu-gold)', margin: 0 }}>
              Importation du compte en cours…
            </h2>
            <p style={{ 'font-size': '24px', color: 'var(--buntu-cyan)', margin: 0 }}>
              {importStep()}
            </p>
            <div class="tv-progress-track">
              <div class="tv-progress-bar" style={{ width: `${importPercent()}%` }} />
            </div>
            <p style={{ 'font-size': '18px', color: 'var(--buntu-text-muted)', margin: 0 }}>
              Veuillez patienter sans fermer l’application ({importPercent()}%)
            </p>
          </div>
        }>

        {/* Incoming Pairing Request Confirmation Card */}
        <Show when={!request()} fallback={
          <div
            style={{
              background: 'var(--buntu-slate)',
              padding: '32px',
              'border-radius': '16px',
              'margin-bottom': '32px',
              border: '2px solid var(--buntu-gold)',
              'text-align': 'left',
            }}
          >
            <div style={{ display: 'flex', 'align-items': 'center', 'justify-content': 'space-between', 'margin-bottom': '16px' }}>
              <h2 style={{ 'font-size': '30px', margin: 0, color: 'var(--buntu-gold)' }}>
                📱 {request()!.from || 'Un smartphone'} veut ajouter {request()!.preview.sources.length} compte
                {request()!.preview.sources.length > 1 ? 's' : ''}
              </h2>
              <span style={{ color: 'var(--buntu-cyan)', 'font-size': '18px', 'font-weight': '600' }}>
                Chiffrement de bout en bout AES-256
              </span>
            </div>

            <p style={{ color: 'var(--buntu-text-muted)', 'font-size': '18px', 'margin-bottom': '20px' }}>
              Vérifiez les comptes reçus ci-dessous avant d’autoriser l’enregistrement sur cette TV :
            </p>

            <div style={{ display: 'flex', 'flex-direction': 'column', gap: '12px', 'margin-bottom': '24px' }}>
              <For each={request()!.preview.sources}>
                {(src) => (
                  <div
                    style={{
                      display: 'flex',
                      'justify-content': 'space-between',
                      'align-items': 'center',
                      background: '#1F2736',
                      border: '1px solid #2A344A',
                      padding: '16px 20px',
                      'border-radius': '8px',
                      'font-size': '22px',
                    }}
                  >
                    <span>
                      <strong style={{ color: '#FFFFFF' }}>{src.name}</strong>{' '}
                      <span style={{ color: 'var(--buntu-text-muted)', 'font-size': '20px' }}>
                        {src.type === 'xtream' ? 'Xtream Codes' : 'M3U'} · {src.host}
                        {src.hasPassword ? ' · avec mot de passe' : ''}
                      </span>
                    </span>
                    <span
                      style={{
                        color: src.duplicate ? 'var(--buntu-gold)' : 'var(--buntu-cyan)',
                        'font-size': '18px',
                        'font-weight': '700',
                      }}
                    >
                      {src.duplicate ? '⚠️ Déjà présent' : '✓ Nouveau'}
                    </span>
                  </div>
                )}
              </For>
            </div>

            <Show when={hasDuplicates()}>
              <div style={{ 'margin-bottom': '24px', display: 'flex', 'align-items': 'center', gap: '16px' }}>
                <button
                  id="btn-pair-toggle-dup"
                  tabindex="-1"
                  aria-label="Basculer le comportement pour les doublons"
                  class={`tv-btn ${focusId() === 'btn-pair-toggle-dup' ? 'focused' : ''}`}
                  onClick={toggleDuplicateMode}
                >
                  {replaceDuplicates() ? '🔄 Doublons : Remplacer l’existant' : '⏭️ Doublons : Ignorer'}
                </button>
                <span style={{ color: 'var(--buntu-text-muted)', 'font-size': '18px' }}>
                  {replaceDuplicates()
                    ? 'Le compte et ses chaînes déjà enregistrés seront mis à jour avec les nouveaux identifiants.'
                    : 'Les comptes déjà présents seront ignorés et conservés tels quels.'}
                </span>
              </div>
            </Show>

            <div style={{ display: 'flex', gap: '24px', 'justify-content': 'center' }}>
              <button
                id="btn-pair-accept"
                tabindex="-1"
                aria-label="Ajouter les comptes reçus sur cette TV"
                class={`tv-btn ${focusId() === 'btn-pair-accept' ? 'focused' : ''}`}
                style={{ 'background-color': focusId() === 'btn-pair-accept' ? 'var(--buntu-gold)' : 'var(--buntu-slate-light)' }}
                onClick={() => void accept()}
              >
                ✓ Ajouter sur cette TV
              </button>
              <button
                id="btn-pair-refuse"
                tabindex="-1"
                aria-label="Refuser l'importation des comptes"
                class={`tv-btn ${focusId() === 'btn-pair-refuse' ? 'focused' : ''}`}
                onClick={() => void refuse()}
              >
                ✕ Refuser
              </button>
            </div>
          </div>
        }>

          {/* Idle Waiting / Scanning QR Code State */}
          <div
            style={{
              display: 'flex',
              gap: '40px',
              background: 'var(--buntu-slate)',
              padding: '32px',
              'border-radius': '16px',
              'align-items': 'center',
              'margin-bottom': '32px',
              border: '1px solid var(--buntu-border)',
              'box-shadow': '0 8px 32px rgba(0,0,0,0.5)',
            }}
          >
            {/* QR Canvas Box */}
            <div
              style={{
                width: '320px',
                height: '320px',
                background: '#FFFFFF',
                'border-radius': '12px',
                padding: '12px',
                display: 'flex',
                'align-items': 'center',
                'justify-content': 'center',
                'flex-shrink': 0,
              }}
            >
              <Show
                when={offer()}
                fallback={
                  <div style={{ color: '#000000', 'font-size': '18px', 'text-align': 'center' }}>
                    <p>{pairingError() || 'Génération du code QR…'}</p>
                    <Show when={pairingError()}>
                      <button
                        id="btn-retry"
                        tabindex="-1"
                        aria-label="Réessayer la génération du code QR d'appariement"
                        class={`tv-btn ${focusId() === 'btn-retry' ? 'focused' : ''}`}
                        style={{ 'margin-top': '12px' }}
                        onClick={() => void startPairing()}
                      >
                        Réessayer
                      </button>
                    </Show>
                  </div>
                }
              >
                <PairingQr size={offer()!.qrSize} modules={offer()!.qrModules} pixels={320} link={offer()!.link} />
              </Show>
            </div>

            {/* Step-by-Step Instructions & TV Info */}
            <div style={{ 'text-align': 'left', flex: 1, display: 'flex', 'flex-direction': 'column', gap: '16px' }}>
              <div>
                <h3 style={{ 'font-size': '24px', 'margin-bottom': '6px', color: 'var(--buntu-gold)' }}>
                  1. Scannez avec votre téléphone
                </h3>
                <p style={{ color: 'var(--buntu-text-muted)', 'font-size': '18px', margin: 0, 'line-height': '1.4' }}>
                  Ouvrez l'appareil photo de votre iPhone ou Android, ou l'application Buntu (Sources &gt; « Envoyer vers une TV »).
                </p>
              </div>

              <div>
                <h3 style={{ 'font-size': '24px', 'margin-bottom': '6px', color: 'var(--buntu-gold)' }}>
                  2. Même réseau Wi-Fi requis
                </h3>
                <p style={{ color: 'var(--buntu-text-muted)', 'font-size': '18px', margin: 0, 'line-height': '1.4' }}>
                  Le smartphone et cette TV doivent être connectés au même réseau Wi-Fi (les réseaux invités isolés sont incompatibles).
                </p>
              </div>

              <div>
                <h3 style={{ 'font-size': '24px', 'margin-bottom': '6px', color: 'var(--buntu-gold)' }}>
                  3. Informations de connexion TV
                </h3>
                <p style={{ color: 'var(--buntu-text)', 'font-size': '18px', margin: 0, 'line-height': '1.4' }}>
                  TV : <strong>{offer()?.tvName || 'Samsung TV'}</strong> · Adresse :{' '}
                  <span style={{ color: 'var(--buntu-cyan)' }}>
                    {offer() ? `${offer()!.host}:${offer()!.port}` : 'Détection…'}
                  </span>
                </p>
                <p style={{ color: 'var(--buntu-text-muted)', 'font-size': '16px', 'margin-top': '4px' }}>
                  Si la TV affiche une demande d'autorisation Samsung, sélectionnez « Autoriser » avec la télécommande.
                </p>
              </div>

              <div style={{ display: 'flex', 'align-items': 'center', 'justify-content': 'space-between', 'margin-top': '4px' }}>
                <span style={{ color: 'var(--buntu-text-muted)', 'font-size': '18px' }}>
                  <Show when={offer()}>
                    Session valide encore <strong style={{ color: 'var(--buntu-gold)' }}>{minutes()}</strong>
                  </Show>
                </span>
                <button
                  id="btn-pair-renew"
                  tabindex="-1"
                  aria-label="Renouveler le code QR immédiatement"
                  class={`tv-btn ${focusId() === 'btn-pair-renew' ? 'focused' : ''}`}
                  onClick={() => void startPairing()}
                >
                  🔄 Renouveler le code
                </button>
              </div>
            </div>
          </div>
        </Show>
        </Show>

        {/* Result & Feedback Banner */}
        <Show when={result()}>
          <p
            style={{
              'font-size': '24px',
              color: isErrorResult() ? 'var(--buntu-danger)' : 'var(--buntu-cyan)',
              'margin-bottom': '24px',
              'font-weight': '600',
            }}
          >
            {result()}
          </p>
        </Show>

        {/* Footer Actions when idle */}
        <Show when={!request() && !busy()}>
          <div style={{ display: 'flex', gap: '24px', 'justify-content': 'center' }}>
            <Show when={props.onSwitchToManual}>
              <button
                id="btn-pair-manual"
                tabindex="-1"
                aria-label="Saisir votre source IPTV manuellement avec la télécommande"
                class={`tv-btn ${focusId() === 'btn-pair-manual' ? 'focused' : ''}`}
                onClick={() => props.onSwitchToManual!()}
              >
                ✍️ Saisir avec la télécommande
              </button>
            </Show>
            <Show when={props.onSkip}>
              <button
                id="btn-pair-skip"
                tabindex="-1"
                aria-label="Passer cette étape et explorer l'application"
                class={`tv-btn ${focusId() === 'btn-pair-skip' ? 'focused' : ''}`}
                onClick={() => props.onSkip!()}
              >
                Passer / Essai
              </button>
            </Show>
          </div>
        </Show>
      </div>
    </div>
  );
};
