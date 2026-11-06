import { Component, createSignal, onMount } from 'solid-js';
import { HttpClient } from '../../core/net/HttpClient';
import { WorkerBridge } from '../../worker/worker-bridge';

export const SettingsView: Component = () => {
  const net = HttpClient.getInstance();
  const worker = WorkerBridge.getInstance();

  const [singleConn, setSingleConn] = createSignal(net.isSingleConnectionMode());
  const [wasmVer, setWasmVer] = createSignal('Chargement...');
  const [tvModel, setTvModel] = createSignal('Samsung Smart TV (Tizen 3.0+)');
  const [purgeMsg, setPurgeMsg] = createSignal('');

  onMount(async () => {
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

  const toggleSingleConnection = () => {
    const next = !singleConn();
    net.setSingleConnectionMode(next);
    setSingleConn(next);
  };

  const purgeCache = () => {
    localStorage.clear();
    setPurgeMsg('Cache des miniatures et instantanés purgé.');
  };

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
          <button class="tv-btn" onClick={toggleSingleConnection}>
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
          <button class="tv-btn" onClick={purgeCache}>
            Purger le cache
          </button>
          {purgeMsg() && (
            <div style={{ "margin-top": "12px", color: "var(--buntu-cyan)" }}>{purgeMsg()}</div>
          )}
        </div>
      </div>
    </div>
  );
};

