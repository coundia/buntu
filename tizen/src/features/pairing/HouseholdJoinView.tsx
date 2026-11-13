import { Component, createSignal, onMount, onCleanup, Show } from 'solid-js';
import { PairingEvents, PairingOffer, HouseholdJoinRequest, PairingService } from '../../core/pairing/PairingService';
import { PairingQr } from './PairingQr';
import { spatialNav } from '../../ui/design/SpatialNav';
import { RemoteKeyHandler } from '../../core/input/RemoteKeyHandler';

export interface HouseholdJoinViewProps {
  onBack: () => void;
  onJoined: () => void;
  title?: string;
  backLabel?: string;
  onManualInput?: () => void;
  createService?: (events: PairingEvents) => Pick<PairingService, 'start' | 'stop'>;
}

/** The phone sends its existing household through the encrypted, short-lived TV pairing session. */
export const HouseholdJoinView: Component<HouseholdJoinViewProps> = (props) => {
  const [offer, setOffer] = createSignal<PairingOffer | null>(null);
  const [incoming, setIncoming] = createSignal<HouseholdJoinRequest | null>(null);
  const [error, setError] = createSignal('');
  const [busy, setBusy] = createSignal(false);
  const [focusId] = spatialNav.getFocusSignal();
  let active = true;
  let starting = false;
  let unsubscribe: (() => void) | undefined;

  const grid = () => spatialNav.setGrid([[
    { id: 'household-qr-back', onSelect: props.onBack },
    { id: 'household-qr-renew', onSelect: () => void renew() },
    ...(props.onManualInput ? [{ id: 'household-qr-manual', onSelect: props.onManualInput }] : []),
  ]]);
  const answer = async (accepted: boolean) => {
    const request = incoming();
    if (!request || busy()) return;
    setBusy(true);
    setError('');
    try {
      if (accepted) await request.accept();
      else await request.refuse();
      if (!active) return;
      setIncoming(null);
      spatialNav.closeModal();
      if (accepted && !error()) props.onJoined();
      else {
        const failure = error();
        await renew();
        if (failure) setError(failure);
      }
    } catch {
      setError('La TV n’a pas pu rejoindre le foyer. Réessayez.');
    } finally {
      if (active) setBusy(false);
    }
  };
  const events: PairingEvents = {
    onRequest: (request) => { void request.refuse(); },
    onHouseholdJoinRequest: (request) => {
      setIncoming(request);
      spatialNav.openModal([[
        { id: 'household-qr-accept', onSelect: () => void answer(true) },
        { id: 'household-qr-refuse', onSelect: () => void answer(false) },
      ]], 0, 1);
    },
    onClosed: () => {
      if (!active || busy()) return;
      if (incoming()) { setIncoming(null); spatialNav.closeModal(); }
      void renew();
    },
    onError: () => { if (active) setError('La connexion au téléphone a échoué. Réessayez.'); },
  };
  const service = props.createService ? props.createService(events) : new PairingService(events);
  const renew = async () => {
    if (starting || !active) return;
    starting = true;
    setOffer(null);
    setError('');
    try {
      const next = await service.start();
      if (active) { setOffer(next); grid(); }
      else service.stop();
    } catch {
      if (active) { setError('QR indisponible. Vérifiez le réseau puis réessayez.'); grid(); }
    } finally {
      starting = false;
    }
  };
  onMount(() => {
    grid();
    unsubscribe = RemoteKeyHandler.getInstance().addListener((key) => {
      if (key !== 'BACK') return false;
      if (!busy()) {
        if (incoming()) void answer(false);
        else props.onBack();
      }
      return true;
    });
    void renew();
  });
  onCleanup(() => {
    active = false;
    unsubscribe?.();
    if (incoming()) spatialNav.closeModal();
    service.stop();
  });

  return <div class="tv-container" style={{ padding: '32px 48px', 'text-align': 'center' }}>
    <h2>{props.title || 'Ajouter cette TV à votre foyer'}</h2>
    <p>Dans Buntu sur votre téléphone : Appareils → Scanner un QR et envoyer mes données (Android), ou Ajouter une TV Samsung (iPhone). Scannez ce QR puis confirmez sur la TV.</p>
    <Show when={incoming()} fallback={<>
      <Show when={offer()} fallback={<p>{error() ? '' : 'Préparation du QR…'}</p>}>
        <PairingQr size={offer()!.qrSize} modules={offer()!.qrModules} pixels={320} />
        <p>Le téléphone transmet son foyer à cette TV. Aucun foyer n’est créé sur la TV.</p>
      </Show>
      <button id="household-qr-back" class={`tv-btn ${focusId() === 'household-qr-back' ? 'focused' : ''}`} onClick={props.onBack}>{props.backLabel || 'Retour aux sources'}</button>
      <button id="household-qr-renew" class={`tv-btn ${focusId() === 'household-qr-renew' ? 'focused' : ''}`} onClick={() => void renew()}>Renouveler le QR</button>
      <Show when={props.onManualInput}>
        <button id="household-qr-manual" class={`tv-btn ${focusId() === 'household-qr-manual' ? 'focused' : ''}`} onClick={() => props.onManualInput?.()}>Saisir une source avec la télécommande</button>
      </Show>
    </>}>
      <h3>{incoming()?.from} vous invite dans le foyer « {incoming()?.householdName} »</h3>
      <p>Rejoindre ce foyer avec cette TV ?</p>
      <button id="household-qr-accept" disabled={busy()} class={`tv-btn ${focusId() === 'household-qr-accept' ? 'focused' : ''}`} onClick={() => void answer(true)}>{busy() ? 'Connexion…' : 'Ajouter la TV au foyer'}</button>
      <button id="household-qr-refuse" disabled={busy()} class={`tv-btn ${focusId() === 'household-qr-refuse' ? 'focused' : ''}`} onClick={() => void answer(false)}>Refuser</button>
    </Show>
    <Show when={error()}><p role="alert">{error()}</p></Show>
  </div>;
};
