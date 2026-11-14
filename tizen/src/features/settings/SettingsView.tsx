import { Component, createSignal, onCleanup, onMount, Show } from 'solid-js';
import { HttpClient } from '../../core/net/HttpClient';
import { WorkerBridge } from '../../worker/worker-bridge';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { PlatformService } from '../../core/platform/PlatformService';
import { APP_VERSION_LABEL } from '../../core/appInfo';
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
import { createTvKeyboard } from '../../ui/components/TvKeyboard';
import { UiSounds } from '../../core/audio/UiSounds';
import { getUpNextPrefs, nextCountdownChoice, setUpNextPrefs } from '../../core/player/upNext';
import {
  getSubtitlePrefs,
  nextSubtitleColor,
  nextSubtitleSize,
  setSubtitlePrefs,
  subtitleColorLabel,
  subtitleSizeLabel,
} from '../../core/player/subtitlePrefs';
import {
  getAccessibilityPrefs,
  nextTextSizePreset,
  setAccessibilityPrefs,
  textSizeLabel,
} from '../../ui/design/accessibilityPrefs';
import { PairingOffer, PairingService } from '../../core/pairing/PairingService';
import { PairingQr } from '../pairing/PairingQr';
import { HouseholdStore, HouseholdInfo, PairedDevice } from '../../core/sync/HouseholdStore';
import { LocalSyncService, SyncLogEntry } from '../../core/sync/LocalSyncService';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';
import { appLanguage, setAppLanguage, t } from '../../core/i18n';

export interface SettingsViewProps {
  onRequestExit?: () => void;
  onProfiles?: () => void;
  /** Household devices, or a compact settings chooser. */
  section?: 'all' | 'household';
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
  const householdOnly = () => props.section === 'household';
  const [panel, setPanel] = createSignal<'connection' | 'ai' | 'system' | 'about' | null>(null);
  const [deviceDetails, setDeviceDetails] = createSignal(false);
  const openPanel = (next: 'connection' | 'ai' | 'system' | 'about' | null) => {
    const previous = panel();
    setPanel(next);
    updateGrid();
    if (next === null && previous) spatialNav.setFocusById(`settings-${previous}`);
  };
  const toggleDeviceDetails = () => {
    setDeviceDetails((value) => !value);
    updateGrid();
    spatialNav.setFocusById('btn-hh-details');
  };

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
  const keyboard = createTvKeyboard();

  // Household & Multi-device sync (PRD 41)
  const [householdInfo, setHouseholdInfo] = createSignal<HouseholdInfo | null>(null);
  const [pairedDevices, setPairedDevices] = createSignal<PairedDevice[]>([]);
  const [syncConnected, setSyncConnected] = createSignal(false);
  const [syncStatusMsg, setSyncStatusMsg] = createSignal('');
  const [transferBusy, setTransferBusy] = createSignal(false);
  const [syncLogs, setSyncLogs] = createSignal<SyncLogEntry[]>([]);
  const [householdQr, setHouseholdQr] = createSignal<{ size: number; modules: string; text: string } | null>(null);

  let pairingService: PairingService | null = null;
  let unsubSync: (() => void) | null = null;
  let unsubLogs: (() => void) | null = null;
  let unsubKeys: (() => void) | null = null;

  const PROVIDER_CYCLE: AiProviderType[] = ['local_only', 'gemini', 'openai_compatible', 'anthropic'];

  const cycleProvider = () => {
    const currentIdx = PROVIDER_CYCLE.indexOf(aiProvider());
    const next = PROVIDER_CYCLE[(currentIdx + 1) % PROVIDER_CYCLE.length];
    setAiProvider(next);
    setAiMaskedKey(null);
    void keyStore.getMaskedKey(next).then((key) => {
      if (aiProvider() === next) { setAiMaskedKey(key); updateGrid(); }
    });
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

  /** OK on a field: the on-screen keyboard (the Samsung system keyboard is not reliable with a remote). What is typed is saved at once. */
  const editKey = () => keyboard.open('Clé API ' + (PROVIDER_DEFAULTS[aiProvider()]?.label ?? ''), '', (v) => { setKeyDraft(v); void saveTypedKey(); }, true);
  const editModel = () => keyboard.open('Modèle', modelDraft(), (v) => { setModelDraft(v); saveModel(); });
  const editBaseUrl = () => keyboard.open('Adresse du serveur', baseUrlDraft(), (v) => { setBaseUrlDraft(v); saveBaseUrl(); });

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

  const leaveHousehold = async () => {
    LocalSyncService.getInstance().stop();
    await HouseholdStore.getInstance().clearHousehold();
    await refreshHouseholdState();
    setSyncStatusMsg('Vous avez quitté le foyer.');
    updateGrid();
  };

  const transferHouseholdData = async (direction: 'receive' | 'send') => {
    if (transferBusy()) return;
    if (!syncConnected()) {
      setSyncStatusMsg('La TV n’est pas connectée au foyer. Ouvrez Buntu sur vos appareils et vérifiez le Wi-Fi.');
      return;
    }
    setTransferBusy(true);
    setSyncStatusMsg(direction === 'receive' ? 'Demande de réception en cours…' : 'Envoi des données en cours…');
    try {
      const sync = LocalSyncService.getInstance();
      if (direction === 'receive') await sync.requestFullSync();
      else await sync.sendHouseholdDataDelta();
      await refreshHouseholdState();
      setSyncStatusMsg(direction === 'receive'
        ? 'Données demandées aux appareils du foyer.'
        : 'Comptes et favoris envoyés aux appareils du foyer.');
    } catch {
      setSyncStatusMsg(direction === 'receive' ? 'La demande de réception a échoué. Réessayez.' : 'L’envoi a échoué. Réessayez.');
    } finally {
      setTransferBusy(false);
    }
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
          setSyncStatusMsg(`Erreur appairage : ${err}`);
        },
      });

      const offer = await pairingService.start();
      setQrOffer(offer);
      updateGrid();
    } catch (e: any) {
      setPairingActive(false);
      setAiTestResult(e?.message || 'Impossible de démarrer l’appairage');
      setSyncStatusMsg(e?.message || 'Impossible de démarrer l’appairage');
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

  const [soundsOn, setSoundsOn] = createSignal(UiSounds.getInstance().isEnabled());
  const toggleSounds = () => {
    const sounds = UiSounds.getInstance();
    sounds.setEnabled(!sounds.isEnabled());
    setSoundsOn(sounds.isEnabled());
    sounds.play('select');
  };

  const [upNext, setUpNext] = createSignal(getUpNextPrefs());
  const toggleUpNextAuto = () => setUpNext(setUpNextPrefs({ auto: !upNext().auto }));
  const cycleUpNextSeconds = () => setUpNext(setUpNextPrefs({ seconds: nextCountdownChoice(upNext().seconds) }));

  const [a11yPrefs, setA11yPrefs] = createSignal(getAccessibilityPrefs());
  const toggleHighContrast = () => setA11yPrefs(setAccessibilityPrefs({ highContrast: !a11yPrefs().highContrast }));
  const cycleTextSize = () => setA11yPrefs(setAccessibilityPrefs({ textSize: nextTextSizePreset(a11yPrefs().textSize) }));

  const [subPrefs, setSubPrefs] = createSignal(getSubtitlePrefs());
  const cycleSubSize = () => setSubPrefs(setSubtitlePrefs({ size: nextSubtitleSize(subPrefs().size) }));
  const cycleSubColor = () => setSubPrefs(setSubtitlePrefs({ color: nextSubtitleColor(subPrefs().color) }));
  const toggleSubOpaque = () => setSubPrefs(setSubtitlePrefs({ opaqueBox: !subPrefs().opaqueBox }));

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

    if (!householdOnly() && panel() === null) {
      grid.push([{ id: 'settings-connection', onSelect: () => openPanel('connection') }]);
      grid.push([{ id: 'settings-ai', onSelect: () => openPanel('ai') }]);
      grid.push([{ id: 'settings-system', onSelect: () => openPanel('system') }]);
      grid.push([{ id: 'settings-about', onSelect: () => openPanel('about') }]);
      if (props.onProfiles) grid.push([{ id: 'settings-profiles', onSelect: props.onProfiles }]);
      spatialNav.setGrid(grid);
      return;
    }
    if (!householdOnly()) grid.push([{ id: 'settings-back', onSelect: () => openPanel(null) }]);

    // AI Section buttons
    if (!householdOnly() && panel() === 'ai') grid.push([{ id: 'btn-ai-provider', onSelect: cycleProvider }]);

    if (!householdOnly() && panel() === 'ai' && aiProvider() !== 'local_only') {
      // OK opens the on-screen keyboard; what is typed is saved at once.
      grid.push([{ id: 'ai-key-input', onSelect: editKey }]);
      const keyRow: FocusableItem[] = [
        { id: 'btn-ai-paste-key', onSelect: () => void pasteKey() },
        { id: 'btn-ai-save-key', onSelect: () => void saveTypedKey() },
      ];
      if (aiMaskedKey()) keyRow.push({ id: 'btn-ai-del-key', onSelect: deleteKey });
      grid.push(keyRow);

      grid.push([{ id: 'ai-model-input', onSelect: editModel }]);
      if (aiProvider() === 'openai_compatible') {
        grid.push([{ id: 'ai-baseurl-input', onSelect: editBaseUrl }]);
      }

      grid.push([
        { id: 'btn-ai-consent', onSelect: toggleConsent },
        { id: 'btn-ai-test', onSelect: testConnection },
      ]);
      grid.push([{ id: 'btn-ai-cap', onSelect: cycleDailyCap }]);
    }

    // Household & Multi-Device Sync (PRD-41)
    if (householdOnly() && householdInfo()) {
      grid.push([
        { id: 'btn-hh-receive', onSelect: () => void transferHouseholdData('receive') },
        { id: 'btn-hh-send', onSelect: () => void transferHouseholdData('send') },
        { id: 'btn-hh-invite', onSelect: showInviteDeviceQr },
        { id: 'btn-hh-details', onSelect: toggleDeviceDetails },
      ]);
      if (deviceDetails()) grid.push([{ id: 'btn-hh-leave', onSelect: leaveHousehold }]);
    } else if (householdOnly()) {
      grid.push([
        { id: 'btn-hh-join-qr', onSelect: startKeyPairing },
      ]);
    }

    // Diagnostics & maintenance
    if (!householdOnly() && panel() === 'connection') {
      grid.push([{ id: 'btn-single-conn', onSelect: toggleSingleConnection }]);
    }
    if (!householdOnly() && panel() === 'system') {
      grid.push([
        { id: 'btn-lang-fr', onSelect: () => setAppLanguage('fr') },
        { id: 'btn-lang-en', onSelect: () => setAppLanguage('en') },
      ]);
      grid.push([
        { id: 'btn-high-contrast', onSelect: toggleHighContrast },
        { id: 'btn-text-size', onSelect: cycleTextSize },
      ]);
      grid.push([
        { id: 'btn-sub-size', onSelect: cycleSubSize },
        { id: 'btn-sub-color', onSelect: cycleSubColor },
        { id: 'btn-sub-bg', onSelect: toggleSubOpaque },
      ]);
      grid.push([{ id: 'btn-ui-sounds', onSelect: toggleSounds }]);
      grid.push([
        { id: 'btn-upnext-auto', onSelect: toggleUpNextAuto },
        { id: 'btn-upnext-seconds', onSelect: cycleUpNextSeconds },
      ]);
      grid.push([{ id: 'btn-purge-cache', onSelect: purgeCache }]);
      grid.push([{ id: 'btn-exit-app', onSelect: handleExit }]);
    }

    spatialNav.setGrid(grid);
  };

  onMount(async () => {
    unsubKeys = RemoteKeyHandler.getInstance().addListener((key) => {
      if (key !== 'BACK') return false;
      if (householdQr()) { closeHouseholdQr(); return true; }
      if (pairingActive()) { stopKeyPairing(); return true; }
      if (!householdOnly() && panel()) { openPanel(null); return true; }
      if (householdOnly() && deviceDetails()) { toggleDeviceDetails(); return true; }
      return false;
    });
    updateGrid();
    const masked = await keyStore.getMaskedKey();
    setAiMaskedKey(masked);
    await refreshHouseholdState();
    unsubSync = LocalSyncService.getInstance().onStatusChange((status) => {
      setSyncConnected(status.connected);
      setPairedDevices(HouseholdStore.getInstance().getPairedDevices());
    });
    unsubLogs = LocalSyncService.getInstance().onLogChange((logs) => {
      setSyncLogs(logs);
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
    if (unsubKeys) unsubKeys();
    pairingService?.stop();
    if (unsubSync) unsubSync();
    if (unsubLogs) unsubLogs();
  });

  /** QR of the pairing service (AI key or household join): shown in the AI section or on the devices screen. */
  const renderPairingQr = () => (
    <>
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
                    {householdOnly()
                      ? 'Scannez avec un appareil du foyer pour y ajouter cette TV'
                      : "Scannez pour envoyer votre clé d'IA de manière chiffrée"}
                  </div>
                  <PairingQr size={qrOffer()!.qrSize} modules={qrOffer()!.qrModules} pixels={320} link={qrOffer()!.link} />
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
    </>
  );

  return (
    <div class="buntu-simple-page"
      style={{
        width: '100%',
        height: '100%',
        padding: '40px 64px',
        'box-sizing': 'border-box',
        'overflow-y': 'auto',
        display: 'flex',
        'flex-direction': 'column',
      }}
    >
      <div class="tv-header">
        <h2 style={{ 'font-size': '32px', color: 'var(--buntu-gold)' }}>
          {householdOnly() ? t('settings.devicesTitle') : t('settings.title')}
        </h2>
        <p class="buntu-return-hint">{panel() ? t('settings.returnToSettings') : t('settings.returnToHome')}</p>
      </div>

      <div class="buntu-settings-stack" style={{ display: 'flex', 'flex-direction': 'column', 'max-width': '1100px', 'padding-bottom': '40px' }}>
        <Show when={!householdOnly() && panel() === null}>
          <p class="buntu-simple-intro">{t('settings.intro')}</p>
          <div class="buntu-settings-choices">
            <button id="settings-connection" tabindex="-1" class={`buntu-settings-choice ${focusId() === 'settings-connection' ? 'focused' : ''}`} onClick={() => openPanel('connection')}>
              <strong>{t('settings.cardConnectionTitle')}</strong><span>{t('settings.cardConnectionDesc')}</span>
            </button>
            <button id="settings-ai" tabindex="-1" class={`buntu-settings-choice ${focusId() === 'settings-ai' ? 'focused' : ''}`} onClick={() => openPanel('ai')}>
              <strong>{t('settings.cardAiTitle')}</strong><span>{t('settings.cardAiDesc')}</span>
            </button>
            <button id="settings-system" tabindex="-1" class={`buntu-settings-choice ${focusId() === 'settings-system' ? 'focused' : ''}`} onClick={() => openPanel('system')}>
              <strong>{t('settings.cardSystemTitle')}</strong><span>{t('settings.cardSystemDesc')}</span>
            </button>
            <button id="settings-about" tabindex="-1" class={`buntu-settings-choice ${focusId() === 'settings-about' ? 'focused' : ''}`} onClick={() => openPanel('about')}>
              <strong>{t('settings.cardAboutTitle')}</strong><span>{t('settings.cardAboutDesc')}</span>
            </button>
            <Show when={props.onProfiles}>
              <button id="settings-profiles" tabindex="-1" class={`buntu-settings-choice ${focusId() === 'settings-profiles' ? 'focused' : ''}`} onClick={() => props.onProfiles?.()}>
                <strong>{t('settings.cardProfilesTitle')}</strong><span>{t('settings.cardProfilesDesc')}</span>
              </button>
            </Show>
          </div>
        </Show>
        <Show when={!householdOnly() && panel() !== null}>
          <button id="settings-back" tabindex="-1" class={`tv-btn ${focusId() === 'settings-back' ? 'focused' : ''}`} onClick={() => openPanel(null)}>{t('settings.backToSettings')}</button>
        </Show>
        {/* Section Assistant IA (PRD 40) */}
        <Show when={!householdOnly() && panel() === 'ai'}>
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px', border: '2px solid var(--buntu-border)' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px', color: 'var(--buntu-gold)' }}>
            {t('settings.aiTitle')}
          </h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            {t('settings.aiDesc')}
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
                {t('settings.aiProvider', { label: PROVIDER_DEFAULTS[aiProvider()]?.label || '' })}
              </button>
            </div>

            <Show when={aiProvider() !== 'local_only'}>
              {/* API Key management */}
              <div style={{ display: 'flex', 'align-items': 'center', gap: '12px', 'flex-wrap': 'wrap' }}>
                <span style={{ color: 'var(--buntu-text-muted)', 'font-size': '18px' }}>
                  {t('settings.aiApiKey')} <strong style={{ color: '#FFFFFF' }}>{aiMaskedKey() || t('settings.aiNoKey')}</strong>
                </span>
                <span class="buntu-ai-sync-note">
                  {householdInfo()
                    ? t('settings.aiSyncHousehold')
                    : t('settings.aiSyncStandalone')}
                </span>
              </div>

              {/* Type or paste the key on the TV */}
              <div style={{ display: 'flex', 'flex-direction': 'column', gap: '10px' }}>
                <label for="ai-key-input" style={{ color: 'var(--buntu-text-muted)', 'font-size': '18px' }}>
                  {t('settings.aiKeyLabel', { label: PROVIDER_DEFAULTS[aiProvider()]?.label || '' })}
                </label>
                <input
                  id="ai-key-input"
                  type="password"
                  tabindex="-1"
                  readOnly
                  inputMode="none"
                  autocomplete="off"
                  placeholder={aiMaskedKey() ? t('settings.aiKeyPlaceholderSaved') : t('settings.aiKeyPlaceholderEmpty')}
                  class={`tv-input ${focusId() === 'ai-key-input' ? 'focused' : ''}`}
                  value={keyDraft()}
                  onClick={editKey}
                />
                <Show when={keyDraft()}>
                  <div style={{ 'font-size': '16px', color: describeKeyShape(aiProvider(), normalizeApiKey(keyDraft())).plausible ? 'var(--buntu-cyan)' : 'var(--buntu-gold)' }}>
                    {normalizeApiKey(keyDraft()).length} caractères — {describeKeyShape(aiProvider(), normalizeApiKey(keyDraft())).message}
                  </div>
                </Show>
                <div style={{ display: 'flex', gap: '12px', 'flex-wrap': 'wrap' }}>
                  <button
                    id="btn-ai-paste-key"
                    tabindex="-1"
                    class={`tv-btn ${focusId() === 'btn-ai-paste-key' ? 'focused' : ''}`}
                    onClick={() => void pasteKey()}
                  >
                    {t('settings.aiPaste')}
                  </button>
                  <button
                    id="btn-ai-save-key"
                    tabindex="-1"
                    class={`tv-btn ${focusId() === 'btn-ai-save-key' ? 'focused' : ''}`}
                    onClick={() => void saveTypedKey()}
                  >
                    {t('settings.aiSaveKey')}
                  </button>
                  <Show when={aiMaskedKey()}>
                    <button
                      id="btn-ai-del-key"
                      tabindex="-1"
                      class={`tv-btn tv-btn-danger ${focusId() === 'btn-ai-del-key' ? 'focused' : ''}`}
                      onClick={deleteKey}
                    >
                      {t('settings.aiDeleteKey')}
                    </button>
                  </Show>
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
                  readOnly
                  inputMode="none"
                  placeholder={PROVIDER_DEFAULTS[aiProvider()]?.model}
                  class={`tv-input ${focusId() === 'ai-model-input' ? 'focused' : ''}`}
                  value={modelDraft()}
                  onClick={editModel}
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
                    readOnly
                    inputMode="none"
                    placeholder={PROVIDER_DEFAULTS.openai_compatible.baseUrl}
                    class={`tv-input ${focusId() === 'ai-baseurl-input' ? 'focused' : ''}`}
                    value={baseUrlDraft()}
                    onClick={editBaseUrl}
                    onInput={(e) => setBaseUrlDraft(e.currentTarget.value)}
                    onChange={saveBaseUrl}
                  />
                </Show>
              </div>

              {renderPairingQr()}

              {/* Consent & Test Buttons */}
              <div style={{ display: 'flex', gap: '12px', 'align-items': 'center' }}>
                <button
                  id="btn-ai-consent"
                  tabindex="-1"
                  class={`tv-btn ${focusId() === 'btn-ai-consent' ? 'focused' : ''}`}
                  onClick={toggleConsent}
                >
                  {t('settings.aiConsent', { state: aiConsent() ? t('settings.aiConsentGranted') : t('settings.aiConsentRequired') })}
                </button>
                <button
                  id="btn-ai-test"
                  tabindex="-1"
                  class={`tv-btn ${focusId() === 'btn-ai-test' ? 'focused' : ''}`}
                  onClick={testConnection}
                >
                  {isTesting() ? t('settings.aiTesting') : t('settings.aiTest')}
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
                  {t('settings.aiDailyCap', { cap: aiDailyCap() })}
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

        {keyboard.view()}
        </Show>

        <Show when={householdOnly()}>
        {/* Appareils */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px', border: '2px solid var(--buntu-border)' }}>
          <div style={{ display: 'flex', 'align-items': 'center', 'justify-content': 'space-between', 'margin-bottom': '8px' }}>
            <h3 style={{ 'font-size': '22px', color: 'var(--buntu-cyan)', margin: 0 }}>
              {t('settings.hhTitle')}
            </h3>
            <span
              style={{
                padding: '4px 10px',
                'border-radius': '999px',
                'font-size': '14px',
                'font-weight': '600',
                background: syncConnected() ? '#163826' : '#242D3E',
                color: syncConnected() ? '#4ADE80' : 'var(--buntu-text-muted)',
                border: `1px solid ${syncConnected() ? '#22C55E' : '#344058'}`,
              }}
            >
              {syncConnected() ? t('settings.hhConnected') : t('settings.hhOffline')}
            </span>
          </div>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            {t('settings.hhDesc')}
          </p>

          <Show
            when={householdInfo()}
            fallback={
              <div style={{ display: 'flex', 'flex-direction': 'column', gap: '12px' }}>
                <p style={{ color: 'var(--buntu-text-muted)', margin: 0 }}>
                  {t('settings.hhNone')}
                </p>
                <div style={{ display: 'flex', gap: '12px', 'flex-wrap': 'wrap' }}>

                  <button
                    id="btn-hh-join-qr"
                    tabindex="-1"
                    class={`tv-btn ${focusId() === 'btn-hh-join-qr' ? 'focused' : ''}`}
                    onClick={() => void startKeyPairing()}
                  >
                    {t('settings.hhJoinQr')}
                  </button>
                </div>
              </div>
            }
          >
            <div style={{ display: 'flex', 'flex-direction': 'column', gap: '16px' }}>
              <div style={{ display: 'grid', 'grid-template-columns': '180px 1fr', gap: '8px', 'font-size': '17px' }}>
                <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.hhName')}</span>
                <span style={{ 'font-weight': '700', color: 'var(--buntu-gold)' }}>{householdInfo()!.household_name}</span>

                <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.hhDevices')}</span>
                <span>{t('settings.hhDevicesCount', { count: pairedDevices().length })}</span>
              </div>

              {/* Paired devices list */}
              <Show when={pairedDevices().length > 0}>
                <div style={{ display: 'flex', 'flex-direction': 'column', gap: '8px' }}>
                  <div style={{ 'font-weight': '600', color: 'var(--buntu-cyan)', 'font-size': '16px' }}>
                    {t('settings.hhActiveDevices')}
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
                            {isRecent ? t('settings.hhOnline') : t('settings.hhRecent')}
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
                  <PairingQr size={householdQr()!.size} modules={householdQr()!.modules} pixels={320} />
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
                  id="btn-hh-receive"
                  tabindex="-1"
                  disabled={transferBusy()}
                  class={`tv-btn ${focusId() === 'btn-hh-receive' ? 'focused' : ''}`}
                  onClick={() => void transferHouseholdData('receive')}
                >
                  {t('settings.hhReceive')}
                </button>
                <button
                  id="btn-hh-send"
                  tabindex="-1"
                  disabled={transferBusy()}
                  class={`tv-btn ${focusId() === 'btn-hh-send' ? 'focused' : ''}`}
                  onClick={() => void transferHouseholdData('send')}
                >
                  {t('settings.hhSend')}
                </button>
                <button
                  id="btn-hh-invite"
                  tabindex="-1"
                  class={`tv-btn ${focusId() === 'btn-hh-invite' ? 'focused' : ''}`}
                  onClick={() => void showInviteDeviceQr()}
                >
                  {t('settings.hhInvite')}
                </button>
                <button id="btn-hh-details" tabindex="-1" class={`tv-btn ${focusId() === 'btn-hh-details' ? 'focused' : ''}`} aria-expanded={deviceDetails()} onClick={toggleDeviceDetails}>
                  {deviceDetails() ? t('settings.hhLess') : t('settings.hhMore')}
                </button>
                <Show when={deviceDetails()}>
                <button
                  id="btn-hh-leave"
                  tabindex="-1"
                  class={`tv-btn tv-btn-danger ${focusId() === 'btn-hh-leave' ? 'focused' : ''}`}
                  onClick={() => void leaveHousehold()}
                >
                  {t('settings.hhLeave')}
                </button>
                </Show>
              </div>

              <Show when={syncStatusMsg()}>
                <div style={{ color: 'var(--buntu-cyan)', 'font-size': '16px' }}>
                  {syncStatusMsg()}
                </div>
              </Show>

              {/* Journal d'activité / synchronisation du foyer */}
              <Show when={deviceDetails() && syncLogs().length > 0}>
                <div style={{ display: 'flex', 'flex-direction': 'column', gap: '8px', 'margin-top': '8px' }}>
                  <div style={{ 'font-weight': '600', color: 'var(--buntu-gold)', 'font-size': '15px' }}>
                    Journal d'activité du foyer :
                  </div>
                  <div
                    style={{
                      background: '#070D18',
                      border: '1px solid #1E293B',
                      'border-radius': '8px',
                      padding: '10px 12px',
                      'max-height': '180px',
                      'overflow-y': 'auto',
                      display: 'flex',
                      'flex-direction': 'column',
                      gap: '4px',
                      'font-family': 'monospace',
                      'font-size': '13px',
                    }}
                  >
                    {syncLogs().map((log) => (
                      <div style={{ display: 'flex', gap: '8px', color: log.warning ? '#F59E0B' : '#94A3B8' }}>
                        <span style={{ color: '#64748B', 'flex-shrink': 0 }}>[{log.time}]</span>
                        <span>{log.text}</span>
                      </div>
                    ))}
                  </div>
                </div>
              </Show>
            </div>
          </Show>
          {/* « Rejoindre (QR) » on the devices screen: the QR lives here, not in the hidden AI section. */}
          <Show when={householdOnly()}>
            <div style={{ 'margin-top': '16px' }}>{renderPairingQr()}</div>
          </Show>
        </div>

        </Show>
        <Show when={!householdOnly() && panel() === 'connection'}>
        {/* Connection Settings */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px' }}>{t('settings.connTitle')}</h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            {t('settings.connDesc')}
          </p>
          <button
            id="btn-single-conn"
            tabindex="-1"
            class={`tv-btn ${focusId() === 'btn-single-conn' ? 'focused' : ''}`}
            onClick={toggleSingleConnection}
          >
            {t('settings.singleConn', { state: singleConn() ? t('settings.singleConnOn') : t('settings.singleConnOff') })}
          </button>
        </div>

        </Show>
        <Show when={!householdOnly() && panel() === 'system'}>
        {/* Language selector */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px', border: '1px solid var(--buntu-border)' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px' }}>{t('settings.langTitle')}</h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            {t('settings.langDesc')}
          </p>
          <div style={{ display: 'flex', 'flex-wrap': 'wrap', gap: '12px' }}>
            <button
              id="btn-lang-fr"
              tabindex="-1"
              aria-pressed={appLanguage() === 'fr'}
              class={`tv-btn ${focusId() === 'btn-lang-fr' ? 'focused' : ''}`}
              onClick={() => setAppLanguage('fr')}
            >
              {appLanguage() === 'fr' ? `✓ ${t('settings.langFr')}` : t('settings.langFr')}
            </button>
            <button
              id="btn-lang-en"
              tabindex="-1"
              aria-pressed={appLanguage() === 'en'}
              class={`tv-btn ${focusId() === 'btn-lang-en' ? 'focused' : ''}`}
              onClick={() => setAppLanguage('en')}
            >
              {appLanguage() === 'en' ? `✓ ${t('settings.langEn')}` : t('settings.langEn')}
            </button>
          </div>
        </div>

        {/* Diagnostics Info */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '16px' }}>{t('settings.sysTitle')}</h3>
          <div style={{ display: 'grid', 'grid-template-columns': '200px 1fr', gap: '12px', 'font-size': '18px' }}>
            <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.sysDevice')}</span>
            <span style={{ 'font-weight': '700' }}>{tvModel()}</span>

            <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.sysCore')}</span>
            <span style={{ color: 'var(--buntu-cyan)', 'font-weight': '700' }}>{wasmVer()}</span>

            <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.sysVideo')}</span>
            <span style={{ color: 'var(--buntu-gold)', 'font-weight': '700' }}>{t('settings.sysVideoVal')}</span>

            <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.sysRes')}</span>
            <span>{t('settings.sysResVal')}</span>

            <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.sysCreator')}</span>
            <span>Papa COUNDIA (papacoundia@gmail.com · {t('settings.aboutCountryVal')})</span>
          </div>
        </div>

        {/* Accessibilité visuelle */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px', border: '1px solid var(--buntu-border)' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px' }}>{t('settings.a11yTitle')}</h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            {t('settings.a11yDesc')}
          </p>
          <div style={{ display: 'flex', 'flex-wrap': 'wrap', gap: '12px' }}>
            <button
              id="btn-high-contrast"
              tabindex="-1"
              aria-pressed={a11yPrefs().highContrast}
              class={`tv-btn ${focusId() === 'btn-high-contrast' ? 'focused' : ''}`}
              onClick={toggleHighContrast}
            >
              {t('settings.a11yHighContrast', { state: a11yPrefs().highContrast ? `✓ ${t('common.enabled')}` : `✗ ${t('common.disabled')}` })}
            </button>
            <button
              id="btn-text-size"
              tabindex="-1"
              class={`tv-btn ${focusId() === 'btn-text-size' ? 'focused' : ''}`}
              onClick={cycleTextSize}
            >
              {t('settings.a11yTextSize', { size: textSizeLabel(a11yPrefs().textSize) })}
            </button>
          </div>
        </div>

        {/* Sous-titres */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px', border: '1px solid var(--buntu-border)' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px' }}>{t('settings.subTitle')}</h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            {t('settings.subDesc')}
          </p>
          <div style={{ display: 'flex', 'flex-wrap': 'wrap', gap: '12px' }}>
            <button
              id="btn-sub-size"
              tabindex="-1"
              class={`tv-btn ${focusId() === 'btn-sub-size' ? 'focused' : ''}`}
              onClick={cycleSubSize}
            >
              {t('settings.subSize', { size: subtitleSizeLabel(subPrefs().size) })}
            </button>
            <button
              id="btn-sub-color"
              tabindex="-1"
              class={`tv-btn ${focusId() === 'btn-sub-color' ? 'focused' : ''}`}
              onClick={cycleSubColor}
            >
              {t('settings.subColor', { color: subtitleColorLabel(subPrefs().color) })}
            </button>
            <button
              id="btn-sub-bg"
              tabindex="-1"
              aria-pressed={subPrefs().opaqueBox}
              class={`tv-btn ${focusId() === 'btn-sub-bg' ? 'focused' : ''}`}
              onClick={toggleSubOpaque}
            >
              {t('settings.subBg', { state: subPrefs().opaqueBox ? `✓ ${t('common.enabled')}` : `✗ ${t('common.disabled')}` })}
            </button>
          </div>
        </div>

        {/* Navigation sounds */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px' }}>{t('settings.soundsTitle')}</h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            {UiSounds.getInstance().isAvailable()
              ? t('settings.soundsDescAvail')
              : t('settings.soundsDescUnavail')}
          </p>
          <button
            id="btn-ui-sounds"
            tabindex="-1"
            aria-pressed={soundsOn()}
            class={`tv-btn ${focusId() === 'btn-ui-sounds' ? 'focused' : ''}`}
            onClick={toggleSounds}
          >
            {t('settings.soundsBtn', { state: soundsOn() ? `✓ ${t('common.enabledPlural')}` : `✗ ${t('common.disabledPlural')}` })}
          </button>
        </div>

        {/* Next film */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px' }}>{t('settings.upnextTitle')}</h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            {t('settings.upnextDesc')}
          </p>
          <button
            id="btn-upnext-auto"
            tabindex="-1"
            aria-pressed={upNext().auto}
            class={`tv-btn ${focusId() === 'btn-upnext-auto' ? 'focused' : ''}`}
            onClick={toggleUpNextAuto}
          >
            {t('settings.upnextAuto', { state: upNext().auto ? `✓ ${t('common.enabledFem')}` : `✗ ${t('common.disabledFem')}` })}
          </button>
          <button
            id="btn-upnext-seconds"
            tabindex="-1"
            class={`tv-btn ${focusId() === 'btn-upnext-seconds' ? 'focused' : ''}`}
            onClick={cycleUpNextSeconds}
          >
            {t('settings.upnextCountdown', { seconds: upNext().seconds })}
          </button>
        </div>

        {/* Maintenance */}
        <div style={{ background: 'var(--buntu-slate)', padding: '24px', 'border-radius': '12px' }}>
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px' }}>{t('settings.storageTitle')}</h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            {t('settings.storageDesc')}
          </p>
          <button
            id="btn-purge-cache"
            tabindex="-1"
            class={`tv-btn ${focusId() === 'btn-purge-cache' ? 'focused' : ''}`}
            onClick={purgeCache}
          >
            {t('settings.purgeCache')}
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
            border: '2px solid var(--buntu-danger-border)',
          }}
        >
          <h3 style={{ 'font-size': '22px', 'margin-bottom': '8px', color: '#F87171' }}>
            {t('settings.exitTitle')}
          </h3>
          <p style={{ color: 'var(--buntu-text-muted)', 'margin-bottom': '16px' }}>
            {t('settings.exitDesc')}
          </p>
          <button
            id="btn-exit-app"
            tabindex="-1"
            class={`tv-btn tv-btn-danger ${focusId() === 'btn-exit-app' ? 'focused' : ''}`}
            onClick={handleExit}
          >
            {t('settings.exitBtn')}
          </button>
        </div>
        </Show>

        <Show when={!householdOnly() && panel() === 'about'}>
        {/* À propos de Buntu */}
        <div
          id="about-page"
          style={{
            background: 'var(--buntu-slate)',
            padding: '28px',
            'border-radius': '12px',
            border: '2px solid var(--buntu-border)',
          }}
        >
          <div style={{ 'margin-bottom': '20px' }}>
            <div style={{ 'font-size': '15px', 'text-transform': 'uppercase', 'letter-spacing': '0.06em', color: 'var(--buntu-text-muted)', 'margin-bottom': '6px' }}>
              {t('settings.aboutLabel')}
            </div>
            <h3 style={{ 'font-size': '28px', margin: '0 0 8px 0', color: 'var(--buntu-gold)' }}>
              Buntu
            </h3>
            <p style={{ margin: 0, 'font-size': '18px', color: 'var(--buntu-text-muted)' }}>
              {t('settings.aboutTagline')}
            </p>
          </div>

          <div
            style={{
              display: 'grid',
              'grid-template-columns': '200px 1fr',
              'grid-gap': '12px',
              gap: '12px',
              'font-size': '18px',
              'margin-bottom': '20px',
            }}
          >
            <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.aboutCreator')}</span>
            <span style={{ 'font-weight': '700' }}>Papa COUNDIA</span>

            <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.aboutEmail')}</span>
            <span style={{ color: 'var(--buntu-cyan)' }}>papacoundia@gmail.com</span>

            <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.aboutCountry')}</span>
            <span>{t('settings.aboutCountryVal')}</span>

            <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.aboutVersion')}</span>
            <span>{APP_VERSION_LABEL}</span>

            <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.aboutCore')}</span>
            <span style={{ color: 'var(--buntu-cyan)', 'font-weight': '700' }}>{wasmVer()}</span>

            <span style={{ color: 'var(--buntu-text-muted)' }}>{t('settings.aboutLicense')}</span>
            <span>MIT / Apache-2.0</span>
          </div>

          <div
            style={{
              background: '#0F172A',
              padding: '16px',
              'border-radius': '8px',
              border: '1px solid var(--buntu-border)',
              color: 'var(--buntu-text-muted)',
              'font-size': '16px',
              'line-height': '1.5',
            }}
          >
            {t('settings.aboutDisclaimer')}
          </div>
        </div>
        </Show>
      </div>
    </div>
  );
};
