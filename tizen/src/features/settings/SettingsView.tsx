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
  getEffectiveBaseUrl,
  getEffectiveModel,
  saveAiSettings,
  setUserConsent,
} from '../../core/ai/AiSettings';
import { AiKeyStore } from '../../core/ai/AiKeyStore';
import { describeKeyShape, normalizeApiKey } from '../../core/ai/keyInput';
import { AiClient } from '../../core/ai/AiClient';
import { PairingOffer, PairingService } from '../../core/pairing/PairingService';
import { HouseholdStore, HouseholdInfo, PairedDevice } from '../../core/sync/HouseholdStore';
import { LocalSyncService } from '../../core/sync/LocalSyncService';

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
  // Typing or pasting a key / model / address on the TV (no phone needed)
  const [keyDraft, setKeyDraft] = createSignal('');
  const [showKey, setShowKey] = createSignal(false);
  const [modelDraft, setModelDraft] = createSignal(initialSettings.model);
  const [baseUrlDraft, setBaseUrlDraft] = createSignal(initialSettings.baseUrl);

  // Household & Multi-device sync (PRD 41)
  const [householdInfo, setHouseholdInfo] = createSignal<HouseholdInfo | null>(null);
  const [pairedDevices, setPairedDevices] = createSignal<PairedDevice[]>([]);
  const [syncConnected, setSyncConnected] = createSignal(false);
  const [syncStatusMsg, setSyncStatusMsg] = createSignal('');
  const [householdQr, setHouseholdQr] = createSignal<{ size: number; modules: string; text: string } | null>(null);

  let pairingService: PairingService | null = null;
  let unsubSync: (() => void) | null = null;

  const PROVIDER_CYCLE: AiProviderType[] = ['local_only', 'gemini', 'openai_compatible', 'anthropic'];

  const cycleProvider = () => {
    const currentIdx = PROVIDER_CYCLE.indexOf(aiProvider());
    const next = PROVIDER_CYCLE[(currentIdx + 1) % PROVIDER_CYCLE.length];
    setAiProvider(next);
    // The model and the server address belong to one provider: start from the new provider's defaults.
    saveAiSettings({ provider: next, model: '', baseUrl: '' });
    setModelDraft('');
    setBaseUrlDraft('');
    setKeyDraft('');
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

  const focusField = (id: string) => (document.getElementById(id) as HTMLInputElement | null)?.focus();
  const fieldHasFocus = (id: string) => document.activeElement === document.getElementById(id);

  /** Saves what was typed or pasted. The key is cleaned first (spaces, quotes, "Bearer"). */
  const saveTypedKey = async () => {
    const key = normalizeApiKey(keyDraft());
    if (!key) {
      setAiTestResult('Collez ou saisissez d’abord la clé dans le champ.');
      return;
    }
    const shape = describeKeyShape(aiProvider(), key);
    try {
      await keyStore.setApiKey(key);
    } catch {
      setAiTestResult('Impossible d’enregistrer la clé sur cette TV.');
      return;
    }
    setKeyDraft('');
    setShowKey(false);
    setAiMaskedKey(await keyStore.getMaskedKey());
    setAiTestResult(
      shape.plausible
        ? 'Clé enregistrée. Appuyez sur « Tester la connexion » pour la vérifier.'
        : `Clé enregistrée. Attention : ${shape.message} Appuyez sur « Tester la connexion » pour vérifier.`
    );
    updateGrid();
  };

  /** Pastes from the clipboard when the TV's browser allows it (often not): otherwise explains. */
  const pasteKey = async () => {
    try {
      const text = await (navigator as any).clipboard?.readText?.();
      if (typeof text === 'string' && text.trim()) {
        setKeyDraft(text);
        setAiTestResult(`Texte collé (${normalizeApiKey(text).length} caractères). Appuyez sur « Enregistrer ».`);
        return;
      }
      setAiTestResult('Le presse-papiers est vide.');
    } catch {
      setAiTestResult('Le presse-papiers n’est pas accessible sur cette TV : saisissez la clé dans le champ avec le clavier de la TV.');
    }
  };

  const saveModel = () => {
    const model = modelDraft().trim();
    saveAiSettings({ model: model === PROVIDER_DEFAULTS[aiProvider()]?.model ? '' : model });
    setAiTestResult(model ? `Modèle : ${model}` : `Modèle par défaut : ${PROVIDER_DEFAULTS[aiProvider()]?.model}`);
  };

  const saveBaseUrl = () => {
    const url = baseUrlDraft().trim();
    if (url && !/^https?:\/\//i.test(url)) {
      setAiTestResult('L’adresse doit commencer par http:// ou https://');
      return;
    }
    saveAiSettings({ baseUrl: url });
    setAiConsent(hasUserConsent(aiProvider()));
    setAiTestResult(url ? `Adresse du serveur : ${url}` : 'Adresse par défaut du fournisseur.');
  };

  const refreshHouseholdState = async () => {
    const store = HouseholdStore.getInstance();
    const info = store.getHouseholdInfo();
    setHouseholdInfo(info);
    setPairedDevices(store.getPairedDevices());
  };

  const createHousehold = async () => {
    try {
      setSyncStatusMsg('Création du foyer en cours…');
      const store = HouseholdStore.getInstance();
      const info = await store.createHousehold('Maison');
      await refreshHouseholdState();
      setSyncStatusMsg(`Foyer « ${info.household_name} » créé.`);
      void LocalSyncService.getInstance().start();
      updateGrid();
    } catch (e: any) {
      setSyncStatusMsg(`Erreur : ${e?.message || e}`);
    }
  };

  const leaveHousehold = async () => {
    LocalSyncService.getInstance().stop();
    await HouseholdStore.getInstance().clearHousehold();
    await refreshHouseholdState();
    setSyncStatusMsg('Vous avez quitté le foyer.');
    updateGrid();
  };

  const triggerSyncNow = async () => {
    setSyncStatusMsg('Synchronisation en cours…');
    await LocalSyncService.getInstance().triggerSync();
    await refreshHouseholdState();
    setSyncStatusMsg(`Synchronisation effectuée à ${new Date().toLocaleTimeString()}.`);
  };

  const showInviteDeviceQr = async () => {
    const store = HouseholdStore.getInstance();
    const info = store.getHouseholdInfo();
    const key = await store.getHouseholdKey();
    if (!info || !key) return;
    const link = `buntu://household-join?id=${encodeURIComponent(info.household_id)}&key=${encodeURIComponent(key)}&name=${encodeURIComponent(info.household_name)}&from=${encodeURIComponent(store.getLocalDeviceName())}`;
    try {
      const matrix = await worker.qrMatrix(link);
      const [sizeStr, modules] = matrix.split(':');
      setHouseholdQr({ size: parseInt(sizeStr, 10), modules, text: link });
      updateGrid();
    } catch (e: any) {
      setSyncStatusMsg(`Impossible de générer le QR code : ${e?.message || e}`);
    }
  };

  const closeHouseholdQr = () => {
    setHouseholdQr(null);
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
        onHouseholdJoinRequest: (req) => {
          void (async () => {
            await req.accept();
            await refreshHouseholdState();
            stopKeyPairing();
            setSyncStatusMsg(`Foyer « ${req.householdName} » rejoint avec succès depuis ${req.from} !`);
            updateGrid();
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
    if (householdQr()) {
      spatialNav.setGrid([[{ id: 'btn-hh-close-qr', onSelect: closeHouseholdQr }]]);
      spatialNav.setFocusById('btn-hh-close-qr');
      return;
    }

    if (pairingActive()) {
      spatialNav.setGrid([[{ id: 'btn-ai-stop-qr', onSelect: stopKeyPairing }]]);
      spatialNav.setFocusById('btn-ai-stop-qr');
      return;
    }

    const grid: FocusableItem[][] = [];

    // AI Section buttons
    grid.push([{ id: 'btn-ai-provider', onSelect: cycleProvider }]);

    if (aiProvider() !== 'local_only') {
      // Type or paste the key right here
      grid.push([
        {
          id: 'ai-key-input',
          // OK opens the TV keyboard; OK again, with the field open, saves what is in it.
          onSelect: () => (fieldHasFocus('ai-key-input') && keyDraft() ? void saveTypedKey() : focusField('ai-key-input')),
        },
      ]);
      grid.push([
        { id: 'btn-ai-show-key', onSelect: () => setShowKey((v) => !v) },
        { id: 'btn-ai-paste-key', onSelect: () => void pasteKey() },
        { id: 'btn-ai-save-key', onSelect: () => void saveTypedKey() },
      ]);

      const keyRow: FocusableItem[] = [{ id: 'btn-ai-receive-key', onSelect: startKeyPairing }];
      if (aiMaskedKey()) {
        keyRow.push({ id: 'btn-ai-del-key', onSelect: deleteKey });
      }
      grid.push(keyRow);

      grid.push([{ id: 'ai-model-input', onSelect: () => (fieldHasFocus('ai-model-input') ? saveModel() : focusField('ai-model-input')) }]);
      if (aiProvider() === 'openai_compatible') {
        grid.push([
          { id: 'ai-baseurl-input', onSelect: () => (fieldHasFocus('ai-baseurl-input') ? saveBaseUrl() : focusField('ai-baseurl-input')) },
        ]);
      }

      grid.push([
        { id: 'btn-ai-consent', onSelect: toggleConsent },
        { id: 'btn-ai-test', onSelect: testConnection },
      ]);
      grid.push([{ id: 'btn-ai-cap', onSelect: cycleDailyCap }]);
    }

    // Household & Multi-Device Sync (PRD-41)
    if (householdInfo()) {
      grid.push([
        { id: 'btn-hh-sync', onSelect: triggerSyncNow },
        { id: 'btn-hh-invite', onSelect: showInviteDeviceQr },
        { id: 'btn-hh-leave', onSelect: leaveHousehold },
      ]);
    } else {
      grid.push([
        { id: 'btn-hh-create', onSelect: createHousehold },
        { id: 'btn-hh-join-qr', onSelect: startKeyPairing },
      ]);
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
    await refreshHouseholdState();
    unsubSync = LocalSyncService.getInstance().onStatusChange((status) => {
      setSyncConnected(status.connected);
      setPairedDevices(HouseholdStore.getInstance().getPairedDevices());
    });
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
    if (unsubSync) unsubSync();
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

              {/* Type or paste the key on the TV */}
              <div style={{ display: 'flex', 'flex-direction': 'column', gap: '10px' }}>
                <label for="ai-key-input" style={{ color: 'var(--buntu-text-muted)', 'font-size': '18px' }}>
                  Coller ou saisir votre clé {PROVIDER_DEFAULTS[aiProvider()]?.label} :
                </label>
                <input
                  id="ai-key-input"
                  type={showKey() ? 'text' : 'password'}
                  tabindex="-1"
                  autocomplete="off"
                  autocapitalize="off"
                  spellcheck={false}
                  placeholder="Collez la clé ici (OK pour ouvrir le clavier)"
                  class={`tv-input ${focusId() === 'ai-key-input' ? 'focused' : ''}`}
                  value={keyDraft()}
                  onInput={(e) => setKeyDraft(e.currentTarget.value)}
                  onPaste={(e) => {
                    // Whatever is pasted is cleaned when saved; keep it as typed until then
                    const text = e.clipboardData?.getData('text');
                    if (text) {
                      e.preventDefault();
                      setKeyDraft(text);
                    }
                  }}
                />
                <Show when={keyDraft()}>
                  <div style={{ 'font-size': '16px', color: describeKeyShape(aiProvider(), normalizeApiKey(keyDraft())).plausible ? 'var(--buntu-cyan)' : 'var(--buntu-gold)' }}>
                    {normalizeApiKey(keyDraft()).length} caractères — {describeKeyShape(aiProvider(), normalizeApiKey(keyDraft())).message}
                  </div>
                </Show>
                <div style={{ display: 'flex', gap: '12px', 'flex-wrap': 'wrap' }}>
                  <button
                    id="btn-ai-show-key"
                    tabindex="-1"
                    class={`tv-btn ${focusId() === 'btn-ai-show-key' ? 'focused' : ''}`}
                    onClick={() => setShowKey((v) => !v)}
                  >
                    {showKey() ? '🙈 Masquer' : '👁 Afficher'}
                  </button>
                  <button
                    id="btn-ai-paste-key"
                    tabindex="-1"
                    class={`tv-btn ${focusId() === 'btn-ai-paste-key' ? 'focused' : ''}`}
                    onClick={() => void pasteKey()}
                  >
                    📋 Coller
                  </button>
                  <button
                    id="btn-ai-save-key"
                    tabindex="-1"
                    class={`tv-btn ${focusId() === 'btn-ai-save-key' ? 'focused' : ''}`}
                    onClick={() => void saveTypedKey()}
                  >
                    💾 Enregistrer la clé
                  </button>
                </div>
              </div>

              {/* Model and server address */}
              <div style={{ display: 'flex', 'flex-direction': 'column', gap: '10px' }}>
                <label for="ai-model-input" style={{ color: 'var(--buntu-text-muted)', 'font-size': '18px' }}>
                  Modèle (vide = {PROVIDER_DEFAULTS[aiProvider()]?.model}) — actuellement : {getEffectiveModel({ ...initialSettings, provider: aiProvider(), model: modelDraft() })}
                </label>
                <input
                  id="ai-model-input"
                  type="text"
                  tabindex="-1"
                  autocomplete="off"
                  autocapitalize="off"
                  spellcheck={false}
                  placeholder={PROVIDER_DEFAULTS[aiProvider()]?.model}
                  class={`tv-input ${focusId() === 'ai-model-input' ? 'focused' : ''}`}
                  value={modelDraft()}
                  onInput={(e) => setModelDraft(e.currentTarget.value)}
                  onChange={saveModel}
                />
                <Show when={aiProvider() === 'openai_compatible'}>
                  <label for="ai-baseurl-input" style={{ color: 'var(--buntu-text-muted)', 'font-size': '18px' }}>
                    Adresse du serveur (OpenAI, Groq, OpenRouter, ou un serveur de la maison comme http://192.168.1.20:11434/v1) —
                    actuellement : {getEffectiveBaseUrl({ ...initialSettings, provider: 'openai_compatible', baseUrl: baseUrlDraft() })}
                  </label>
                  <input
                    id="ai-baseurl-input"
                    type="url"
                    tabindex="-1"
                    autocomplete="off"
                    autocapitalize="off"
                    spellcheck={false}
                    placeholder={PROVIDER_DEFAULTS.openai_compatible.baseUrl}
                    class={`tv-input ${focusId() === 'ai-baseurl-input' ? 'focused' : ''}`}
                    value={baseUrlDraft()}
                    onInput={(e) => setBaseUrlDraft(e.currentTarget.value)}
                    onChange={saveBaseUrl}
                  />
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

        {/* Section Appareils de la maison & Continuité (PRD 41) */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px', border: '1px solid rgba(56, 189, 248, 0.4)' }}>
          <div style={{ display: 'flex', 'align-items': 'center', 'justify-content': 'space-between', 'margin-bottom': '8px' }}>
            <h3 style={{ 'font-size': '22px', color: 'var(--buntu-cyan)', margin: 0 }}>
              📡 Appareils de la maison & Continuité
            </h3>
            <span
              style={{
                padding: '4px 10px',
                'border-radius': '999px',
                'font-size': '14px',
                'font-weight': '600',
                background: syncConnected() ? 'rgba(34, 197, 94, 0.2)' : 'rgba(148, 163, 184, 0.2)',
                color: syncConnected() ? '#4ADE80' : 'var(--buntu-text-muted)',
                border: `1px solid ${syncConnected() ? '#22C55E' : '#64748B'}`,
              }}
            >
              {syncConnected() ? '🟢 Connecté au Wi-Fi local' : '⚪ En attente de connexion'}
            </span>
          </div>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            Synchronisation de vos favoris, reprises de lecture et historique en direct sur le Wi-Fi de la maison.
            Zéro serveur distant, données chiffrées de bout en bout (AES-256-GCM).
          </p>

          <Show
            when={householdInfo()}
            fallback={
              <div style={{ display: 'flex', 'flex-direction': 'column', gap: '12px' }}>
                <p style={{ color: 'var(--buntu-text-muted)', margin: 0 }}>
                  Cette TV ne fait actuellement partie d'aucun foyer Buntu. Créez un foyer ou rejoignez celui de votre téléphone par QR Code.
                </p>
                <div style={{ display: 'flex', gap: '12px', 'flex-wrap': 'wrap' }}>
                  <button
                    id="btn-hh-create"
                    tabindex="-1"
                    class={`tv-btn ${focusId() === 'btn-hh-create' ? 'focused' : ''}`}
                    onClick={() => void createHousehold()}
                  >
                    ✨ Créer un foyer Buntu
                  </button>
                  <button
                    id="btn-hh-join-qr"
                    tabindex="-1"
                    class={`tv-btn ${focusId() === 'btn-hh-join-qr' ? 'focused' : ''}`}
                    onClick={() => void startKeyPairing()}
                  >
                    📲 Rejoindre un foyer (QR Code)
                  </button>
                </div>
              </div>
            }
          >
            <div style={{ display: 'flex', 'flex-direction': 'column', gap: '16px' }}>
              <div style={{ display: 'grid', 'grid-template-columns': '180px 1fr', gap: '8px', 'font-size': '17px' }}>
                <span style={{ color: 'var(--buntu-text-muted)' }}>Nom du foyer :</span>
                <span style={{ 'font-weight': '700', color: 'var(--buntu-gold)' }}>{householdInfo()!.household_name}</span>

                <span style={{ color: 'var(--buntu-text-muted)' }}>Identifiant sécurisé :</span>
                <span style={{ 'font-family': 'monospace', color: 'var(--buntu-text-muted)' }}>
                  {householdInfo()!.household_id.slice(0, 16)}…
                </span>

                <span style={{ color: 'var(--buntu-text-muted)' }}>Appareils jumelés :</span>
                <span>{pairedDevices().length} appareil(s)</span>
              </div>

              {/* Paired devices list */}
              <Show when={pairedDevices().length > 0}>
                <div style={{ display: 'flex', 'flex-direction': 'column', gap: '8px' }}>
                  <div style={{ 'font-weight': '600', color: 'var(--buntu-cyan)', 'font-size': '16px' }}>
                    Appareils actifs sur le réseau :
                  </div>
                  <div style={{ display: 'flex', 'flex-direction': 'column', gap: '6px' }}>
                    {pairedDevices().map((dev) => {
                      const icon = dev.device_type === 'tv' ? '📺' : dev.device_type === 'desktop' ? '💻' : '📱';
                      const isRecent = Date.now() - dev.last_seen < 120_000;
                      return (
                        <div
                          style={{
                            background: '#0F172A',
                            padding: '10px 14px',
                            'border-radius': '6px',
                            display: 'flex',
                            'align-items': 'center',
                            'justify-content': 'space-between',
                            'font-size': '15px',
                          }}
                        >
                          <div style={{ display: 'flex', 'align-items': 'center', gap: '10px' }}>
                            <span>{icon}</span>
                            <span style={{ 'font-weight': '600' }}>{dev.device_name}</span>
                          </div>
                          <span style={{ color: isRecent ? '#4ADE80' : 'var(--buntu-text-muted)' }}>
                            {isRecent ? '🟢 En ligne' : 'Vu récemment'}
                          </span>
                        </div>
                      );
                    })}
                  </div>
                </div>
              </Show>

              {/* QR Modal for inviting devices */}
              <Show when={householdQr()}>
                <div
                  style={{
                    background: '#0F172A',
                    padding: '20px',
                    'border-radius': '12px',
                    border: '2px solid var(--buntu-cyan)',
                    display: 'flex',
                    'flex-direction': 'column',
                    'align-items': 'center',
                    gap: '12px',
                  }}
                >
                  <div style={{ 'font-size': '18px', color: 'var(--buntu-cyan)' }}>
                    Scannez pour ajouter cet appareil au foyer « {householdInfo()?.household_name} »
                  </div>
                  <canvas
                    ref={(el) => {
                      if (!el || !householdQr()) return;
                      const q = householdQr()!;
                      const ctx = el.getContext('2d');
                      if (!ctx) return;
                      const size = q.size;
                      const scale = 4;
                      el.width = size * scale;
                      el.height = size * scale;
                      ctx.fillStyle = '#FFFFFF';
                      ctx.fillRect(0, 0, el.width, el.height);
                      ctx.fillStyle = '#000000';
                      for (let r = 0; r < size; r++) {
                        for (let c = 0; c < size; c++) {
                          if (q.modules[r * size + c] === '1') {
                            ctx.fillRect(c * scale, r * scale, scale, scale);
                          }
                        }
                      }
                    }}
                  />
                  <p style={{ color: 'var(--buntu-text-muted)', 'font-size': '15px', 'text-align': 'center', margin: 0 }}>
                    Ouvrez Buntu sur votre iPhone, iPad, Mac ou Android et scannez ce code dans Réglages &gt; Continuité.
                  </p>
                  <button
                    id="btn-hh-close-qr"
                    tabindex="-1"
                    class={`tv-btn ${focusId() === 'btn-hh-close-qr' ? 'focused' : ''}`}
                    onClick={closeHouseholdQr}
                  >
                    Fermer le QR Code
                  </button>
                </div>
              </Show>

              {/* Household action buttons */}
              <div style={{ display: 'flex', gap: '12px', 'flex-wrap': 'wrap' }}>
                <button
                  id="btn-hh-sync"
                  tabindex="-1"
                  class={`tv-btn ${focusId() === 'btn-hh-sync' ? 'focused' : ''}`}
                  onClick={() => void triggerSyncNow()}
                >
                  🔄 Synchroniser maintenant
                </button>
                <button
                  id="btn-hh-invite"
                  tabindex="-1"
                  class={`tv-btn ${focusId() === 'btn-hh-invite' ? 'focused' : ''}`}
                  onClick={() => void showInviteDeviceQr()}
                >
                  📱 Inviter un appareil (QR)
                </button>
                <button
                  id="btn-hh-leave"
                  tabindex="-1"
                  class={`tv-btn tv-btn-danger ${focusId() === 'btn-hh-leave' ? 'focused' : ''}`}
                  onClick={() => void leaveHousehold()}
                >
                  🚪 Quitter le foyer
                </button>
              </div>

              <Show when={syncStatusMsg()}>
                <div style={{ color: 'var(--buntu-cyan)', 'font-size': '16px' }}>
                  {syncStatusMsg()}
                </div>
              </Show>
            </div>
          </Show>
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
