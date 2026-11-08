import { Component, createSignal, onCleanup, onMount, Show } from 'solid-js';
import { HttpClient } from '../../core/net/HttpClient';
import { WorkerBridge } from '../../worker/worker-bridge';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { PlatformService } from '../../core/platform/PlatformService';
import {
  AiProviderType,
  getAiSettings,
  hasUserConsent,
  PROVIDER_DEFAULTS,
  saveAiSettings,
  setUserConsent,
} from '../../core/ai/AiSettings';
import { AiKeyStore } from '../../core/ai/AiKeyStore';
import { AiClient } from '../../core/ai/AiClient';
import { PairingOffer, PairingService } from '../../core/pairing/PairingService';

export interface SettingsViewProps {
  onRequestExit?: () => void;
}

export const SettingsView: Component<SettingsViewProps> = (props) => {
  const net = HttpClient.getInstance();
  const worker = WorkerBridge.getInstance();
  const keyStore = AiKeyStore.getInstance();
  const aiClient = AiClient.getInstance();

  const [singleConn, setSingleConn] = createSignal(net.isSingleConnectionMode());
  const [wasmVer, setWasmVer] = createSignal('Chargement...');
  const [tvModel, setTvModel] = createSignal('Samsung Smart TV (Tizen 3.0+)');
  const [purgeMsg, setPurgeMsg] = createSignal('');
  const [focusId] = spatialNav.getFocusSignal();

  // AI Assistant state
  const initialSettings = getAiSettings();
  const [aiProvider, setAiProvider] = createSignal<AiProviderType>(initialSettings.provider);
  const [aiMaskedKey, setAiMaskedKey] = createSignal<string | null>(null);
  const [aiConsent, setAiConsent] = createSignal(hasUserConsent(initialSettings.provider));
  const [aiDailyCap, setAiDailyCap] = createSignal(initialSettings.dailyCap);
  const [aiTestResult, setAiTestResult] = createSignal<string>('');
  const [isTesting, setIsTesting] = createSignal(false);
  const [qrOffer, setQrOffer] = createSignal<PairingOffer | null>(null);
  const [pairingActive, setPairingActive] = createSignal(false);

  let pairingService: PairingService | null = null;

  const PROVIDER_CYCLE: AiProviderType[] = ['local_only', 'gemini', 'openai_compatible', 'anthropic'];

  const cycleProvider = () => {
    const currentIdx = PROVIDER_CYCLE.indexOf(aiProvider());
    const next = PROVIDER_CYCLE[(currentIdx + 1) % PROVIDER_CYCLE.length];
    setAiProvider(next);
    saveAiSettings({ provider: next });
    setAiConsent(hasUserConsent(next));
    setAiTestResult('');
    updateGrid();
  };

  const toggleConsent = () => {
    const next = !aiConsent();
    setAiConsent(next);
    setUserConsent(aiProvider(), next);
  };

  const cycleDailyCap = () => {
    const caps = [10, 30, 50, 100];
    const currentIdx = caps.indexOf(aiDailyCap());
    const next = caps[(currentIdx + 1) % caps.length];
    setAiDailyCap(next);
    saveAiSettings({ dailyCap: next });
  };

  const testConnection = async () => {
    setIsTesting(true);
    setAiTestResult('Test de connexion en cours…');
    try {
      const res = await aiClient.testConnection(aiProvider());
      setIsTesting(false);
      setAiTestResult(res.message);
    } catch (err: any) {
      setIsTesting(false);
      setAiTestResult(`Échec : ${err?.message || 'Erreur réseau'}`);
    }
  };

  const deleteKey = async () => {
    await keyStore.deleteApiKey();
    setAiMaskedKey(null);
    setAiTestResult('Clé supprimée.');
    updateGrid();
  };

  const startKeyPairing = async () => {
    try {
      setPairingActive(true);
      pairingService = new PairingService({
        onRequest: () => {},
        onAiConfigRequest: (req) => {
          void (async () => {
            await req.accept();
            const masked = await keyStore.getMaskedKey();
            setAiMaskedKey(masked);
            const settings = getAiSettings();
            setAiProvider(settings.provider);
            setAiConsent(true);
            setUserConsent(settings.provider, true);
            stopKeyPairing();
            setAiTestResult(`Clé ${req.provider} enregistrée depuis ${req.from} !`);
          })();
        },
        onClosed: () => {
          stopKeyPairing();
        },
        onError: (err) => {
          setAiTestResult(`Erreur appairage : ${err}`);
        },
      });

      const offer = await pairingService.start();
      setQrOffer(offer);
      updateGrid();
    } catch (e: any) {
      setPairingActive(false);
      setAiTestResult(e?.message || 'Impossible de démarrer l’appairage');
      updateGrid();
    }
  };

  const stopKeyPairing = () => {
    pairingService?.stop();
    pairingService = null;
    setPairingActive(false);
    setQrOffer(null);
    updateGrid();
  };

  const toggleSingleConnection = () => {
    const next = !singleConn();
    net.setSingleConnectionMode(next);
    setSingleConn(next);
  };

  const purgeCache = () => {
    localStorage.clear();
    setPurgeMsg('Cache des miniatures et instantanés purgé.');
  };

  const handleExit = () => {
    if (props.onRequestExit) {
      props.onRequestExit();
    } else {
      PlatformService.exitApp();
    }
  };

  const updateGrid = () => {
    if (pairingActive()) {
      spatialNav.setGrid([[{ id: 'btn-ai-stop-qr', onSelect: stopKeyPairing }]]);
      spatialNav.setFocusById('btn-ai-stop-qr');
      return;
    }

    const grid: FocusableItem[][] = [];

    // AI Section buttons
    grid.push([{ id: 'btn-ai-provider', onSelect: cycleProvider }]);

    if (aiProvider() !== 'local_only') {
      const keyRow: FocusableItem[] = [{ id: 'btn-ai-receive-key', onSelect: startKeyPairing }];
      if (aiMaskedKey()) {
        keyRow.push({ id: 'btn-ai-del-key', onSelect: deleteKey });
      }
      grid.push(keyRow);

      grid.push([
        { id: 'btn-ai-consent', onSelect: toggleConsent },
        { id: 'btn-ai-test', onSelect: testConnection },
      ]);
      grid.push([{ id: 'btn-ai-cap', onSelect: cycleDailyCap }]);
    }

    // Diagnostics & maintenance
    grid.push([{ id: 'btn-single-conn', onSelect: toggleSingleConnection }]);
    grid.push([{ id: 'btn-purge-cache', onSelect: purgeCache }]);
    grid.push([{ id: 'btn-exit-app', onSelect: handleExit }]);

    spatialNav.setGrid(grid);
  };

  onMount(async () => {
    const masked = await keyStore.getMaskedKey();
    setAiMaskedKey(masked);
    updateGrid();

    try {
      const v = await worker.getVersion();
      setWasmVer(v);
    } catch {
      setWasmVer('cnd-domain-wasm 0.1.0');
    }

    try {
      const productInfo = (window as any).webapis?.productinfo;
      if (productInfo) {
        setTvModel(`${productInfo.getModel()} (Tizen ${productInfo.getVersion()})`);
      }
    } catch {}
  });

  onCleanup(() => {
    pairingService?.stop();
  });

  return (
    <div
      style={{
        width: '100%',
        height: '100%',
        padding: '24px 40px',
        'box-sizing': 'border-box',
        'overflow-y': 'auto',
        display: 'flex',
        'flex-direction': 'column',
      }}
    >
      <div class="tv-header">
        <h2 style={{ 'font-size': '32px', color: 'var(--buntu-gold)' }}>Paramètres & Diagnostics</h2>
      </div>

      <div style={{ display: 'flex', 'flex-direction': 'column', gap: '24px', 'max-width': '900px', 'padding-bottom': '40px' }}>
        {/* Section Assistant IA (PRD 40) */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px', border: '1px solid rgba(212, 160, 23, 0.4)' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px', color: 'var(--buntu-gold)' }}>
            ✨ Assistant IA (Recherche, Commandes & Recommandations)
          </h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            Contrôlez l'application à la voix ou par phrase descriptive (« Mets le match du PSG », « Un film comme Inception »).
            Vos données de flux IPTV, identifiants et serveurs ne sont <strong>jamais</strong> transmis au fournisseur.
          </p>

          <div style={{ display: 'flex', 'flex-direction': 'column', gap: '16px' }}>
            {/* Provider Selector */}
            <div>
              <button
                id="btn-ai-provider"
                tabindex="-1"
                class={`tv-btn ${focusId() === 'btn-ai-provider' ? 'focused' : ''}`}
                onClick={cycleProvider}
              >
                Fournisseur : {PROVIDER_DEFAULTS[aiProvider()]?.label} ↻
              </button>
            </div>

            <Show when={aiProvider() !== 'local_only'}>
              {/* API Key management */}
              <div style={{ display: 'flex', 'align-items': 'center', gap: '12px', 'flex-wrap': 'wrap' }}>
                <span style={{ color: 'var(--buntu-text-muted)', 'font-size': '18px' }}>
                  Clé API : <strong style={{ color: '#FFFFFF' }}>{aiMaskedKey() || 'Aucune clé enregistrée'}</strong>
                </span>
                <button
                  id="btn-ai-receive-key"
                  tabindex="-1"
                  class={`tv-btn ${focusId() === 'btn-ai-receive-key' ? 'focused' : ''}`}
                  onClick={startKeyPairing}
                >
                  📱 Envoyer depuis le téléphone (QR code)
                </button>
                <Show when={aiMaskedKey()}>
                  <button
                    id="btn-ai-del-key"
                    tabindex="-1"
                    class={`tv-btn tv-btn-danger ${focusId() === 'btn-ai-del-key' ? 'focused' : ''}`}
                    onClick={deleteKey}
                  >
                    Supprimer la clé
                  </button>
                </Show>
              </div>

              {/* QR Modal when pairing key */}
              <Show when={pairingActive() && qrOffer()}>
                <div
                  style={{
                    background: '#0F172A',
                    padding: '20px',
                    'border-radius': '12px',
                    border: '2px solid var(--buntu-gold)',
                    display: 'flex',
                    'flex-direction': 'column',
                    'align-items': 'center',
                    gap: '12px',
                  }}
                >
                  <div style={{ 'font-size': '18px', color: 'var(--buntu-gold)' }}>
                    Scannez pour envoyer votre clé d'IA de manière chiffrée
                  </div>
                  <canvas
                    ref={(el) => {
                      if (!el || !qrOffer()) return;
                      const offer = qrOffer()!;
                      const ctx = el.getContext('2d');
                      if (!ctx) return;
                      const size = offer.qrSize;
                      const scale = 4;
                      el.width = size * scale;
                      el.height = size * scale;
                      ctx.fillStyle = '#FFFFFF';
                      ctx.fillRect(0, 0, el.width, el.height);
                      ctx.fillStyle = '#000000';
                      for (let r = 0; r < size; r++) {
                        for (let c = 0; c < size; c++) {
                          if (offer.qrModules[r * size + c] === '1') {
                            ctx.fillRect(c * scale, r * scale, scale, scale);
                          }
                        }
                      }
                    }}
                  />
                  <button
                    id="btn-ai-stop-qr"
                    tabindex="-1"
                    class={`tv-btn ${focusId() === 'btn-ai-stop-qr' ? 'focused' : ''}`}
                    onClick={stopKeyPairing}
                  >
                    Fermer le QR Code
                  </button>
                </div>
              </Show>

              {/* Consent & Test Buttons */}
              <div style={{ display: 'flex', gap: '12px', 'align-items': 'center' }}>
                <button
                  id="btn-ai-consent"
                  tabindex="-1"
                  class={`tv-btn ${focusId() === 'btn-ai-consent' ? 'focused' : ''}`}
                  onClick={toggleConsent}
                >
                  Consentement : {aiConsent() ? '✓ Accordé' : '✗ Requis (Non accordé)'}
                </button>
                <button
                  id="btn-ai-test"
                  tabindex="-1"
                  class={`tv-btn ${focusId() === 'btn-ai-test' ? 'focused' : ''}`}
                  onClick={testConnection}
                >
                  {isTesting() ? 'Test en cours…' : 'Tester la connexion'}
                </button>
              </div>

              {/* Daily Cap */}
              <div>
                <button
                  id="btn-ai-cap"
                  tabindex="-1"
                  class={`tv-btn ${focusId() === 'btn-ai-cap' ? 'focused' : ''}`}
                  onClick={cycleDailyCap}
                >
                  Plafond quotidien recommandations : {aiDailyCap()} appels/jour ↻
                </button>
              </div>

              {/* Test output message */}
              <Show when={aiTestResult()}>
                <div style={{ color: aiTestResult().includes('réussie') ? 'var(--buntu-cyan)' : 'var(--buntu-gold)', 'font-size': '16px' }}>
                  {aiTestResult()}
                </div>
              </Show>

              {/* Privacy summary */}
              <div style={{ background: '#1E293B', padding: '16px', 'border-radius': '8px', 'font-size': '15px' }}>
                <div style={{ 'font-weight': '700', 'margin-bottom': '6px', color: 'var(--buntu-cyan)' }}>
                  🔒 Règles de confidentialité (PRD 40 § 5) :
                </div>
                <div style={{ color: 'var(--buntu-text-muted)' }}>
                  • <strong>Envoyé :</strong> phrase saisie, langue, au plus 40 candidats sans aucune URL ni hôte.<br />
                  • <strong>Jamais envoyé :</strong> liens de flux, mots de passe Xtream, catalogue complet.<br />
                  • <strong>Mode Enfants :</strong> 0 appel distant garanti.
                </div>
              </div>
            </Show>
          </div>
        </div>

        {/* Connection Settings */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px' }}>Gestion de connexion fournisseur</h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            Pour les abonnements limités à 1 seule connexion simultanée, l'application met en attente
            automatiquement toute requête parallèle pour éviter le bannissement ou l'erreur 429.
          </p>
          <button
            id="btn-single-conn"
            tabindex="-1"
            class={`tv-btn ${focusId() === 'btn-single-conn' ? 'focused' : ''}`}
            onClick={toggleSingleConnection}
          >
            Mode 1 Connexion Stricte : {singleConn() ? 'ACTIVÉ (Recommandé)' : 'DÉSACTIVÉ'}
          </button>
        </div>

        {/* Diagnostics Info */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '16px' }}>Informations système</h3>
          <div style={{ display: 'grid', 'grid-template-columns': '200px 1fr', gap: '12px', 'font-size': '18px' }}>
            <span style={{ color: 'var(--buntu-text-muted)' }}>Appareil :</span>
            <span style={{ 'font-weight': '700' }}>{tvModel()}</span>

            <span style={{ color: 'var(--buntu-text-muted)' }}>Cœur Métier :</span>
            <span style={{ color: 'var(--buntu-cyan)', 'font-weight': '700' }}>{wasmVer()}</span>

            <span style={{ color: 'var(--buntu-text-muted)' }}>Moteur Vidéo :</span>
            <span style={{ color: 'var(--buntu-gold)', 'font-weight': '700' }}>Samsung AVPlay (Décodage matériel)</span>

            <span style={{ color: 'var(--buntu-text-muted)' }}>Résolution :</span>
            <span>1920 × 1080 (Mise à l'échelle TV)</span>
          </div>
        </div>

        {/* Maintenance */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px' }}>Maintenance du stockage</h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            Libère l'espace disque IndexedDB en conservant vos favoris et vos sources.
          </p>
          <button
            id="btn-purge-cache"
            tabindex="-1"
            class={`tv-btn ${focusId() === 'btn-purge-cache' ? 'focused' : ''}`}
            onClick={purgeCache}
          >
            Purger le cache
          </button>
          {purgeMsg() && (
            <div style={{ 'margin-top': '12px', color: 'var(--buntu-cyan)' }}>{purgeMsg()}</div>
          )}
        </div>

        {/* Application Termination */}
        <div
          style={{
            background: 'var(--buntu-slate)',
            padding: '24px',
            'border-radius': '12px',
            border: '1px solid rgba(239, 68, 68, 0.3)',
          }}
        >
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px', color: '#F87171' }}>
            Fermer l'application
          </h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            Quitte complètement l'application CND IPTV et libère la mémoire et les décodeurs matériels de la télévision.
          </p>
          <button
            id="btn-exit-app"
            tabindex="-1"
            class={`tv-btn tv-btn-danger ${focusId() === 'btn-exit-app' ? 'focused' : ''}`}
            onClick={handleExit}
          >
            ⏻ Fermer CND IPTV
          </button>
        </div>
      </div>
    </div>
  );
};
