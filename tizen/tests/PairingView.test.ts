import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render } from 'solid-js/web';
import { PairingView } from '../src/features/pairing/PairingView';
import { spatialNav } from '../src/ui/design/SpatialNav';
import { RemoteKeyHandler } from '../src/core/input/RemoteKeyHandler';
import { PairingEvents, PairingOffer, PairingRequest } from '../src/core/pairing/PairingService';

describe('PairingView Component (PRD 39)', () => {
  let container: HTMLDivElement;
  let dispose: () => void = () => {};

  beforeEach(() => {
    container = document.createElement('div');
    document.body.appendChild(container);
    RemoteKeyHandler.getInstance().init();
    spatialNav.init();
  });

  afterEach(() => {
    dispose();
    container.remove();
    RemoteKeyHandler.getInstance().destroy();
  });

  it('renders TV name, host and port and starts pairing session', async () => {
    const offer: PairingOffer = {
      link: 'buntu://pair?v=1&s=testsession',
      session: 'testsession',
      expiresAt: Math.floor(Date.now() / 1000) + 300,
      qrSize: 25,
      qrModules: '0'.repeat(625),
      host: '192.168.1.42',
      port: 8001,
      tvName: 'Samsung QN90A',
    };

    const mockService = {
      start: vi.fn(async () => offer),
      stop: vi.fn(),
    };

    const onBack = vi.fn();
    const onSuccess = vi.fn();

    dispose = render(
      () =>
        PairingView({
          title: 'Ajouter depuis votre smartphone',
          subtitle: 'Scannez le QR code',
          onBack,
          onSuccess,
          createService: () => mockService,
        }),
      container
    );

    await new Promise((r) => setTimeout(r, 50));

    expect(mockService.start).toHaveBeenCalledTimes(1);
    expect(container.textContent).toContain('Samsung QN90A');
    expect(container.textContent).toContain('192.168.1.42:8001');
    expect(container.textContent).toContain('1. Scannez avec votre téléphone');
    expect(container.querySelector('canvas')).not.toBeNull();
  });

  it('upon incoming request: immediately moves focus to "btn-pair-accept" and shows accounts and duplicate toggle', async () => {
    const offer: PairingOffer = {
      link: 'buntu://pair?v=1&s=test2',
      session: 'test2',
      expiresAt: Math.floor(Date.now() / 1000) + 300,
      qrSize: 25,
      qrModules: '0'.repeat(625),
      host: '192.168.1.15',
      port: 8001,
      tvName: 'Samsung AU8000',
    };

    let events: PairingEvents | null = null;
    const mockService = {
      start: vi.fn(async () => offer),
      stop: vi.fn(),
    };

    const onBack = vi.fn();
    const onSuccess = vi.fn();

    dispose = render(
      () =>
        PairingView({
          onBack,
          onSuccess,
          createService: (e) => {
            events = e;
            return mockService;
          },
        }),
      container
    );

    await new Promise((r) => setTimeout(r, 50));

    let accepted = false;
    let acceptOptions: any = null;
    const requestMock: PairingRequest = {
      from: 'iPhone de Jean',
      preview: {
        sources: [
          { name: 'Canal+', type: 'xtream', host: 'srv.iptv.com:8080', hasPassword: true, duplicate: true },
          { name: 'M3U Sport', type: 'm3u', host: 'm3u.iptv.com', hasPassword: false, duplicate: false },
        ],
        pending: [] as any,
      },
      accept: async (_onProg, opts) => {
        accepted = true;
        acceptOptions = opts;
        return 2;
      },
      refuse: async () => {},
    };

    // Trigger pairing request
    expect(events).not.toBeNull();
    events!.onRequest(requestMock);
    await new Promise((r) => setTimeout(r, 80));

    // Focus must be on btn-pair-accept per PRD 39 § 2.1
    expect(spatialNav.getCurrentFocusId()).toBe('btn-pair-accept');
    expect(container.textContent).toContain('iPhone de Jean veut ajouter 2 comptes');
    expect(container.textContent).toContain('Canal+');
    expect(container.textContent).toContain('srv.iptv.com:8080');
    expect(container.textContent).toContain('⚠️ Déjà présent');
    expect(container.textContent).toContain('M3U Sport');

    // Duplicate toggle button exists because one source is duplicate
    const toggleBtn = container.querySelector('#btn-pair-toggle-dup') as HTMLButtonElement;
    expect(toggleBtn).not.toBeNull();
    expect(toggleBtn.textContent).toContain('Ignorer');

    // Toggle duplicate replacement mode
    toggleBtn.click();
    await new Promise((r) => setTimeout(r, 30));
    expect(toggleBtn.textContent).toContain('Remplacer');

    // Click accept
    const acceptBtn = container.querySelector('#btn-pair-accept') as HTMLButtonElement;
    acceptBtn.click();

    await new Promise((r) => setTimeout(r, 50));
    expect(accepted).toBe(true);
    expect(acceptOptions).toEqual({ replaceDuplicates: true });
  });

  it('remote BACK key cancels confirmation when request is open, or calls onBack when idle', async () => {
    const offer: PairingOffer = {
      link: 'buntu://pair?v=1&s=test3',
      session: 'test3',
      expiresAt: Math.floor(Date.now() / 1000) + 300,
      qrSize: 25,
      qrModules: '0'.repeat(625),
      host: '192.168.1.15',
      port: 8001,
      tvName: 'Samsung AU8000',
    };

    let events: PairingEvents | null = null;
    const mockService = {
      start: vi.fn(async () => offer),
      stop: vi.fn(),
    };

    const onBack = vi.fn();
    const onSuccess = vi.fn();

    dispose = render(
      () =>
        PairingView({
          onBack,
          onSuccess,
          createService: (e) => {
            events = e;
            return mockService;
          },
        }),
      container
    );

    await new Promise((r) => setTimeout(r, 50));

    let refused = false;
    const requestMock: PairingRequest = {
      from: 'Android TV User',
      preview: { sources: [], pending: [] },
      accept: async () => 1,
      refuse: async () => {
        refused = true;
      },
    };

    expect(events).not.toBeNull();
    events!.onRequest(requestMock);
    await new Promise((r) => setTimeout(r, 50));

    // Press BACK with remote control
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 10009, key: 'XF86Back' }));
    await new Promise((r) => setTimeout(r, 50));

    // When request was open, BACK refuses the request without exiting the screen
    expect(refused).toBe(true);
    expect(onBack).not.toHaveBeenCalled();

    // Now idle: pressing BACK calls onBack()
    window.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 10009, key: 'XF86Back' }));
    await new Promise((r) => setTimeout(r, 50));

    expect(onBack).toHaveBeenCalledTimes(1);
  });
});
