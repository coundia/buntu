import { Component, createSignal, onMount } from 'solid-js';
import { HttpClient } from '../../core/net/HttpClient';
import { WorkerBridge } from '../../worker/worker-bridge';
import { spatialNav } from '../../ui/design/SpatialNav';
import { PlatformService } from '../../core/platform/PlatformService';

export interface SettingsViewProps {
  onRequestExit?: () => void;
}

export const SettingsView: Component<SettingsViewProps> = (props) => {
  const net = HttpClient.getInstance();
  const worker = WorkerBridge.getInstance();

  const [singleConn, setSingleConn] = createSignal(net.isSingleConnectionMode());
  const [wasmVer, setWasmVer] = createSignal('Chargement...');
  const [tvModel, setTvModel] = createSignal('Samsung Smart TV (Tizen 3.0+)');
  const [purgeMsg, setPurgeMsg] = createSignal('');
  const [focusId] = spatialNav.getFocusSignal();

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

  onMount(async () => {
    spatialNav.setGrid([
      [{ id: 'btn-single-conn', onSelect: toggleSingleConnection }],
      [{ id: 'btn-purge-cache', onSelect: purgeCache }],
      [{ id: 'btn-exit-app', onSelect: handleExit }],
    ]);

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
    } catch {
      // Mock / browser
    }
  });

  return (
    <div class="tv-container" style={{ "overflow-y": "auto" }}>
      <div class="tv-header">
        <h2 style={{ "font-size": "32px", color: "var(--buntu-gold)" }}>Paramètres & Diagnostics</h2>
      </div>

      <div style={{ display: "flex", "flex-direction": "column", gap: "24px", "max-width": "900px" }}>
        {/* Connection Settings */}
        <div style={{ background: "var(--buntu-slate)", padding: "24px", "border-radius": "12px" }}>
          <h3 style={{ "font-size": "22px", "margin-bottom": "8px" }}>Gestion de connexion fournisseur</h3>
          <p style={{ color: "var(--buntu-text-muted)", "margin-bottom": "16px" }}>
            Pour les abonnements limités à 1 seule connexion simultanée, l'application met en attente
            automatiquement toute requête parallèle pour éviter le bannissement ou l'erreur 429.
          </p>
          <button
            id="btn-single-conn"
            tabindex="-1"
            aria-label={`Mode 1 Connexion Stricte : ${singleConn() ? 'Actif' : 'Désactivé'}. Appuyez pour basculer.`}
            class={`tv-btn ${focusId() === 'btn-single-conn' ? 'focused' : ''}`}
            onClick={toggleSingleConnection}
          >
            Mode 1 Connexion Stricte : {singleConn() ? 'ACTIVÉ (Recommandé)' : 'DÉSACTIVÉ'}
          </button>
        </div>

        {/* Diagnostics Info */}
        <div style={{ background: "var(--buntu-slate)", padding: "24px", "border-radius": "12px" }}>
          <h3 style={{ "font-size": "22px", "margin-bottom": "16px" }}>Informations système</h3>
          <div style={{ display: "grid", "grid-template-columns": "200px 1fr", gap: "12px", "font-size": "18px" }}>
            <span style={{ color: "var(--buntu-text-muted)" }}>Appareil :</span>
            <span style={{ "font-weight": "700" }}>{tvModel()}</span>

            <span style={{ color: "var(--buntu-text-muted)" }}>Cœur Métier :</span>
            <span style={{ color: "var(--buntu-cyan)", "font-weight": "700" }}>{wasmVer()}</span>

            <span style={{ color: "var(--buntu-text-muted)" }}>Moteur Vidéo :</span>
            <span style={{ color: "var(--buntu-gold)", "font-weight": "700" }}>Samsung AVPlay (Décodage matériel)</span>

            <span style={{ color: "var(--buntu-text-muted)" }}>Résolution :</span>
            <span>1920 × 1080 (Mise à l'échelle TV)</span>
          </div>
        </div>

        {/* Maintenance */}
        <div style={{ background: "var(--buntu-slate)", padding: "24px", "border-radius": "12px" }}>
          <h3 style={{ "font-size": "22px", "margin-bottom": "8px" }}>Maintenance du stockage</h3>
          <p style={{ color: "var(--buntu-text-muted)", "margin-bottom": "16px" }}>
            Libère l'espace disque IndexedDB en conservant vos favoris et vos sources.
          </p>
          <button
            id="btn-purge-cache"
            tabindex="-1"
            aria-label="Purger le cache des miniatures et instantanés"
            class={`tv-btn ${focusId() === 'btn-purge-cache' ? 'focused' : ''}`}
            onClick={purgeCache}
          >
            Purger le cache
          </button>
          {purgeMsg() && (
            <div style={{ "margin-top": "12px", color: "var(--buntu-cyan)" }}>{purgeMsg()}</div>
          )}
        </div>

        {/* Application Termination */}
        <div style={{
          background: "var(--buntu-slate)",
          padding: "24px",
          "border-radius": "12px",
          border: "1px solid rgba(239, 68, 68, 0.3)"
        }}>
          <h3 style={{ "font-size": "22px", "margin-bottom": "8px", color: "#F87171" }}>
            Fermer l'application
          </h3>
          <p style={{ color: "var(--buntu-text-muted)", "margin-bottom": "16px" }}>
            Quitte complètement l'application CND IPTV et libère la mémoire et les décodeurs matériels de la télévision.
          </p>
          <button
            id="btn-exit-app"
            tabindex="-1"
            aria-label="Quitter complètement l'application"
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
