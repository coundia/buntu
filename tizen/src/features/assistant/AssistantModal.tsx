/**
 * CND IPTV Tizen - Quick AI Assistant Modal (PRD 40 § 2, § 6.2)
 *
 * Allows voice or text commands with instant local resolution (< 50ms)
 * and fallback to the user's AI provider. Also allows scanning a QR code
 * to type text comfortably from a smartphone.
 */

import { Component, createSignal, For, onCleanup, onMount, Show } from 'solid-js';
import { CndEngine } from '../../core/engine/CndEngine';
import { ItemRecord } from '../../core/storage/Database';
import { FocusableItem, spatialNav } from '../../ui/design/SpatialNav';
import { PairingOffer, PairingService } from '../../core/pairing/PairingService';
import { getAiSettings, PROVIDER_DEFAULTS } from '../../core/ai/AiSettings';

export interface AssistantModalProps {
  onClose: () => void;
  onPlayItem?: (item: ItemRecord) => void;
  onSearchQuery?: (query: string) => void;
}

const HISTORY_KEY = 'cnd_ai_history';
const MAX_HISTORY = 20;

export const AssistantModal: Component<AssistantModalProps> = (props) => {
  const engine = CndEngine.getInstance();
  const [focusId] = spatialNav.getFocusSignal();

  const [inputPhrase, setInputPhrase] = createSignal('');
  const [statusMessage, setStatusMessage] = createSignal('');
  const [isLoading, setIsLoading] = createSignal(false);
  const [history, setHistory] = createSignal<string[]>([]);
  const [qrOffer, setQrOffer] = createSignal<PairingOffer | null>(null);
  const [pairingActive, setPairingActive] = createSignal(false);

  let pairingService: PairingService | null = null;

  const QUICK_COMMANDS = [
    'France 2',
    'Mets le match du PSG',
    'Un film comme Inception',
    'Chaîne suivante',
    'Chaîne précédente',
  ];

  const loadHistory = () => {
    try {
      const raw = localStorage.getItem(HISTORY_KEY);
      if (raw) setHistory(JSON.parse(raw));
    } catch {}
  };

  const saveHistory = (phrase: string) => {
    try {
      const existing = history().filter((h) => h.toLowerCase() !== phrase.toLowerCase());
      const updated = [phrase, ...existing].slice(0, MAX_HISTORY);
      setHistory(updated);
      localStorage.setItem(HISTORY_KEY, JSON.stringify(updated));
    } catch {}
  };

  const updateGrid = () => {
    const grid: FocusableItem[][] = [];

    if (pairingActive()) {
      grid.push([
        {
          id: 'btn-assistant-close-qr',
          onSelect: () => stopPairing(),
        },
      ]);
      spatialNav.setGrid(grid);
      spatialNav.setFocusById('btn-assistant-close-qr');
      return;
    }

    // Top action row
    grid.push([
      { id: 'btn-assistant-phone', onSelect: startPhonePairing },
      { id: 'btn-assistant-close', onSelect: props.onClose },
    ]);

    // Quick command buttons
    const cmdRow: FocusableItem[] = QUICK_COMMANDS.map((cmd, idx) => ({
      id: `btn-quick-cmd-${idx}`,
      onSelect: () => void executeCommand(cmd),
    }));
    grid.push(cmdRow);

    // History rows
    if (history().length > 0) {
      grid.push(
        history().slice(0, 4).map((h, idx) => ({
          id: `btn-hist-cmd-${idx}`,
          onSelect: () => void executeCommand(h),
        }))
      );
    }

    spatialNav.setGrid(grid);
  };

  const startPhonePairing = async () => {
    try {
      setPairingActive(true);
      pairingService = new PairingService({
        onRequest: () => {},
        onTextReceived: (text) => {
          stopPairing();
          void executeCommand(text);
        },
        onClosed: () => {
          stopPairing();
        },
        onError: (err) => {
          setStatusMessage(`Erreur appairage : ${err}`);
        },
      });

      const offer = await pairingService.start();
      setQrOffer(offer);
      updateGrid();
    } catch (e: any) {
      setPairingActive(false);
      setStatusMessage(e?.message || 'Impossible de démarrer l’appairage');
      updateGrid();
    }
  };

  const stopPairing = () => {
    pairingService?.stop();
    pairingService = null;
    setPairingActive(false);
    setQrOffer(null);
    updateGrid();
  };

  const executeCommand = async (phrase: string) => {
    const cleaned = phrase.trim();
    if (!cleaned) return;

    setInputPhrase(cleaned);
    setIsLoading(true);
    setStatusMessage('L’assistant réfléchit…');
    saveHistory(cleaned);

    try {
      const res = await engine.resolveAiCommand(cleaned);
      setIsLoading(false);

      if (res.resolvedItem) {
        setStatusMessage(`Lancement de ${res.resolvedItem.name}…`);
        setTimeout(() => {
          props.onPlayItem?.(res.resolvedItem!);
          props.onClose();
        }, 600);
        return;
      }

      if (res.action?.search?.query) {
        setStatusMessage(`Recherche de : ${res.action.search.query}`);
        setTimeout(() => {
          props.onSearchQuery?.(res.action.search.query);
          props.onClose();
        }, 600);
        return;
      }

      if (res.reply) {
        setStatusMessage(res.reply);
      } else if (res.error) {
        setStatusMessage(`Assistant indisponible : ${res.error}`);
      } else {
        setStatusMessage('Aucune action trouvée');
      }
    } catch (err: any) {
      setIsLoading(false);
      setStatusMessage(`Erreur : ${err?.message || 'Action impossible'}`);
    }
  };

  onMount(() => {
    loadHistory();
    updateGrid();
    spatialNav.setFocusById('btn-quick-cmd-0');
  });

  onCleanup(() => {
    pairingService?.stop();
  });

  const settings = getAiSettings();
  const providerLabel = PROVIDER_DEFAULTS[settings.provider]?.label || 'Désactivé';

  return (
    <div
      style={{
        position: 'fixed',
        top: 0,
        left: 0,
        width: '100vw',
        height: '100vh',
        background: 'rgba(10, 15, 29, 0.92)',
        'backdrop-filter': 'blur(16px)',
        display: 'flex',
        'align-items': 'center',
        'justify-content': 'center',
        'z-index': 10000,
        padding: '40px',
        'box-sizing': 'border-box',
      }}
    >
      <div
        style={{
          background: 'var(--buntu-navy)',
          border: '2px solid var(--buntu-gold)',
          'border-radius': '24px',
          padding: '36px 48px',
          width: '840px',
          'max-width': '95vw',
          display: 'flex',
          'flex-direction': 'column',
          gap: '24px',
          'box-shadow': '0 24px 64px rgba(0, 0, 0, 0.8)',
        }}
      >
        {/* Header */}
        <div style={{ display: 'flex', 'justify-content': 'space-between', 'align-items': 'center' }}>
          <div>
            <h2 style={{ 'font-size': '32px', color: 'var(--buntu-gold)', margin: 0 }}>✨ Assistant CND IPTV</h2>
            <div style={{ color: 'var(--buntu-text-muted)', 'font-size': '16px', 'margin-top': '4px' }}>
              Fournisseur : <span style={{ color: 'var(--buntu-cyan)' }}>{providerLabel}</span>
            </div>
          </div>
          <div style={{ display: 'flex', gap: '12px' }}>
            <button
              id="btn-assistant-phone"
              tabindex="-1"
              class={`tv-btn ${focusId() === 'btn-assistant-phone' ? 'focused' : ''}`}
              style={{ padding: '10px 18px', 'font-size': '16px' }}
              onClick={startPhonePairing}
            >
              📱 Écrire depuis le téléphone
            </button>
            <button
              id="btn-assistant-close"
              tabindex="-1"
              class={`tv-btn ${focusId() === 'btn-assistant-close' ? 'focused' : ''}`}
              style={{ padding: '10px 18px', 'font-size': '16px' }}
              onClick={props.onClose}
            >
              ✕ Fermer
            </button>
          </div>
        </div>

        {/* QR Code Phone Mode */}
        <Show when={pairingActive() && qrOffer()}>
          <div
            style={{
              background: 'var(--buntu-slate)',
              padding: '24px',
              'border-radius': '16px',
              display: 'flex',
              'flex-direction': 'column',
              'align-items': 'center',
              gap: '16px',
            }}
          >
            <h3 style={{ 'font-size': '20px', margin: 0, color: 'var(--buntu-gold)' }}>
              Scannez pour écrire depuis votre smartphone
            </h3>
            <p style={{ color: 'var(--buntu-text-muted)', margin: 0, 'font-size': '16px', 'text-align': 'center' }}>
              La phrase sera envoyée instantanément à la télévision par canal chiffré de bout en bout.
            </p>
            <div
              style={{
                background: '#FFFFFF',
                padding: '12px',
                'border-radius': '12px',
                display: 'inline-block',
              }}
            >
              <canvas
                ref={(el) => {
                  if (!el || !qrOffer()) return;
                  const offer = qrOffer()!;
                  const ctx = el.getContext('2d');
                  if (!ctx) return;
                  const size = offer.qrSize;
                  const scale = 5;
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
            </div>
            <button
              id="btn-assistant-close-qr"
              tabindex="-1"
              class={`tv-btn ${focusId() === 'btn-assistant-close-qr' ? 'focused' : ''}`}
              onClick={stopPairing}
            >
              Annuler la saisie téléphone
            </button>
          </div>
        </Show>

        <Show when={!pairingActive()}>
          {/* Status / Output Display */}
          <div
            style={{
              background: 'var(--buntu-slate)',
              padding: '20px',
              'border-radius': '16px',
              'min-height': '80px',
              display: 'flex',
              'align-items': 'center',
              'font-size': '22px',
              color: isLoading() ? 'var(--buntu-gold)' : statusMessage() ? '#FFFFFF' : 'var(--buntu-text-muted)',
              border: '2px solid var(--buntu-border)',
            }}
          >
            <Show when={isLoading()}>
              <span style={{ 'margin-right': '12px' }}>⏳</span>
            </Show>
            {statusMessage() || 'Choisissez une commande rapide ou écrivez depuis votre téléphone.'}
          </div>

          {/* Quick Commands Row */}
          <div>
            <div style={{ 'font-size': '18px', color: 'var(--buntu-gold)', 'margin-bottom': '12px' }}>
              Commandes rapides :
            </div>
            <div style={{ display: 'flex', gap: '10px', 'flex-wrap': 'wrap' }}>
              <For each={QUICK_COMMANDS}>
                {(cmd, idx) => (
                  <button
                    id={`btn-quick-cmd-${idx()}`}
                    tabindex="-1"
                    class={`tv-btn ${focusId() === `btn-quick-cmd-${idx()}` ? 'focused' : ''}`}
                    style={{ padding: '12px 18px', 'font-size': '16px' }}
                    onClick={() => void executeCommand(cmd)}
                  >
                    {cmd}
                  </button>
                )}
              </For>
            </div>
          </div>

          {/* History */}
          <Show when={history().length > 0}>
            <div>
              <div style={{ 'font-size': '18px', color: 'var(--buntu-cyan)', 'margin-bottom': '12px' }}>
                Dernières demandes :
              </div>
              <div style={{ display: 'flex', gap: '10px', 'flex-wrap': 'wrap' }}>
                <For each={history().slice(0, 4)}>
                  {(h, idx) => (
                    <button
                      id={`btn-hist-cmd-${idx()}`}
                      tabindex="-1"
                      class={`tv-btn ${focusId() === `btn-hist-cmd-${idx()}` ? 'focused' : ''}`}
                      style={{ padding: '10px 16px', 'font-size': '15px', background: '#1E293B' }}
                      onClick={() => void executeCommand(h)}
                    >
                      🕒 {h}
                    </button>
                  )}
                </For>
              </div>
            </div>
          </Show>
        </Show>
      </div>
    </div>
  );
};

