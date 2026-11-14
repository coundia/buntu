/**
 * Non-régression : le QR « Ajouter cette TV à votre foyer » de Réglages → Appareils n'était plus
 * lisible par le scanner de l'Android. Il était dessiné à la main : 4 px par module, sans marge
 * blanche (quiet zone), sur le fond sombre de la carte. Un scanner a besoin de 4 modules blancs
 * autour du code ; sans eux, il ne trouve pas les coins.
 * Le QR doit passer par `PairingQr`, comme sur les écrans Sources et accueil.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render } from 'solid-js/web';
import { SettingsView } from '../src/features/settings/SettingsView';
import { HouseholdStore } from '../src/core/sync/HouseholdStore';
import { LocalSyncService } from '../src/core/sync/LocalSyncService';
import { AiKeyStore } from '../src/core/ai/AiKeyStore';
import { PairingOffer, PairingService } from '../src/core/pairing/PairingService';
import { WorkerBridge } from '../src/worker/worker-bridge';
import { QR_QUIET_ZONE, layoutQr } from '../src/features/pairing/PairingQr';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };

// A real pairing link is about 150 characters: a QR of version 9 to 10 (53 to 57 modules).
const QR_SIZE = 57;
const offer: PairingOffer = {
  link: 'buntu://pair?v=1&s=TESTSESSION&n=Samsung+TV&t=msf&h=192.168.1.20&p=8001&k=AAAA&e=9999999999',
  session: 'TESTSESSION',
  expiresAt: 9999999999,
  qrSize: QR_SIZE,
  qrModules: '10'.repeat((QR_SIZE * QR_SIZE) / 2 + 1).slice(0, QR_SIZE * QR_SIZE),
  host: '192.168.1.20',
  port: 8001,
  tvName: 'Samsung TV',
};

describe('QR layout a phone scanner can read', () => {
  it('leaves a 4-module white border and a sharp integer scale', () => {
    const l = layoutQr(QR_SIZE, 320);
    expect(QR_QUIET_ZONE).toBeGreaterThanOrEqual(4);
    expect(l.quiet).toBe(QR_QUIET_ZONE);
    expect(l.total).toBe(QR_SIZE + 2 * QR_QUIET_ZONE);
    expect(Number.isInteger(l.scale)).toBe(true);
    expect(l.side).toBe(l.total * l.scale);
    expect(l.scale).toBeGreaterThanOrEqual(4);
  });

  it('never goes below one pixel per module, even for a very large code', () => {
    expect(layoutQr(177, 100).scale).toBe(1);
  });
});

describe('Réglages → Appareils : QR pour ajouter cette TV au foyer', () => {
  let dispose = () => {};

  beforeEach(() => {
    vi.spyOn(AiKeyStore.getInstance(), 'getMaskedKey').mockResolvedValue(null);
    vi.spyOn(WorkerBridge.getInstance(), 'getVersion').mockResolvedValue('test');
    vi.spyOn(HouseholdStore.getInstance(), 'getHouseholdInfo').mockReturnValue(null);
    vi.spyOn(HouseholdStore.getInstance(), 'getPairedDevices').mockReturnValue([]);
    vi.spyOn(LocalSyncService.getInstance(), 'onStatusChange').mockImplementation((listener) => {
      listener({ connected: false, pairedDeviceCount: 0 });
      return () => {};
    });
    vi.spyOn(PairingService.prototype, 'start').mockResolvedValue(offer);
    vi.spyOn(PairingService.prototype, 'stop').mockImplementation(() => {});
  });

  afterEach(() => {
    dispose();
    document.body.innerHTML = '';
    vi.restoreAllMocks();
  });

  it('draws the code with its quiet zone and keeps the link a camera would read', async () => {
    dispose = render(() => SettingsView({ section: 'household' }), document.body);
    await settle();
    (document.getElementById('btn-hh-join-qr') as HTMLButtonElement).click();
    await settle();

    const canvases = Array.from(document.querySelectorAll('canvas'));
    expect(canvases).toHaveLength(1);
    const canvas = canvases[0];
    const l = layoutQr(QR_SIZE, 320);
    expect(canvas.width).toBe(l.side);
    expect(canvas.width).toBeGreaterThan(QR_SIZE * 4); // the old drawing: 4 px per module, no border
    expect(canvas.style.width).toBe('320px');
    expect(canvas.getAttribute('data-pairing-link')).toBe(offer.link);
  });
});
