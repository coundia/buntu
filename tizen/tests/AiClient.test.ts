import { describe, it, expect, beforeEach, beforeAll, vi } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { AiClient } from '../src/core/ai/AiClient';
import { AiKeyStore } from '../src/core/ai/AiKeyStore';
import { saveAiSettings, setUserConsent } from '../src/core/ai/AiSettings';
import { recordCall } from '../src/core/ai/AiUsage';
import { setWasmSource } from '../src/worker/handlers';

const WASM = resolve(__dirname, '../src/wasm/pkg/cnd_domain_wasm_bg.wasm');

describe('AiClient Guardrails and Execution', () => {
  const store = new Map<string, string>();
  const mockLocalStorage = {
    getItem: (key: string) => store.get(key) || null,
    setItem: (key: string, val: string) => store.set(key, val),
    removeItem: (key: string) => store.delete(key),
    clear: () => store.clear(),
  };

  beforeAll(() => {
    if (existsSync(WASM)) {
      setWasmSource(readFileSync(WASM));
    }
  });

  beforeEach(() => {
    store.clear();
    (globalThis as any).localStorage = mockLocalStorage;
    // Reset key store mock
    (AiKeyStore as any).instance = {
      getApiKey: vi.fn().mockResolvedValue(null),
      hasApiKey: vi.fn().mockResolvedValue(false),
      setApiKey: vi.fn().mockResolvedValue(undefined),
      deleteApiKey: vi.fn().mockResolvedValue(undefined),
      getMaskedKey: vi.fn().mockResolvedValue(null),
    };
  });

  it('strictly blocks remote AI calls when Kids profile is active', async () => {
    const client = AiClient.getInstance();
    saveAiSettings({ provider: 'gemini' });
    setUserConsent('gemini', true);

    const result = await client.executeTask(
      'command',
      { command: 'mets un dessin animé' },
      { isKidsProfile: true }
    );

    expect(result.ok).toBe(false);
    expect(result.isLocalFallback).toBe(true);
    expect(result.error).toContain('Mode Enfants');
  });

  it('rejects remote calls when provider is set to local_only', async () => {
    const client = AiClient.getInstance();
    saveAiSettings({ provider: 'local_only' });

    const result = await client.executeTask(
      'command',
      { command: 'mets TF1' },
      { isKidsProfile: false }
    );

    expect(result.ok).toBe(false);
    expect(result.isLocalFallback).toBe(true);
    expect(result.error).toContain('Fournisseur désactivé');
  });

  it('requires explicit consent before sending any external requests', async () => {
    const client = AiClient.getInstance();
    saveAiSettings({ provider: 'gemini' });
    setUserConsent('gemini', false);

    const result = await client.executeTask(
      'command',
      { command: 'mets France 2' },
      { isKidsProfile: false }
    );

    expect(result.ok).toBe(false);
    expect(result.needsConsent).toBe(true);
    expect(result.error).toContain('Consentement requis');
  });

  it('requires an API key for remote providers when none is configured', async () => {
    const client = AiClient.getInstance();
    saveAiSettings({ provider: 'gemini' });
    setUserConsent('gemini', true);
    // KeyStore returns null (no key)

    const result = await client.executeTask(
      'command',
      { command: 'mets France 2' },
      { isKidsProfile: false }
    );

    expect(result.ok).toBe(false);
    expect(result.needsKey).toBe(true);
    expect(result.error).toContain('Clé API manquante');
  });

  it('enforces the daily quota cap on recommendation calls', async () => {
    const client = AiClient.getInstance();
    saveAiSettings({ provider: 'gemini', dailyCap: 3 });
    setUserConsent('gemini', true);

    const keyStore = AiKeyStore.getInstance();
    (keyStore.getApiKey as any).mockResolvedValue('sk-test-fake-key');

    // Simulate 3 calls today recorded via recordCall
    recordCall('gemini:gemini-3.5-flash-lite');
    recordCall('gemini:gemini-3.5-flash-lite');
    recordCall('gemini:gemini-3.5-flash-lite');

    const result = await client.executeTask(
      'recommend',
      { prompt: 'recommande moi un film' },
      { isKidsProfile: false }
    );

    expect(result.ok).toBe(false);
    expect(result.quotaReached).toBe(true);
    expect(result.error).toContain('Plafond quotidien');
  });

  it('resolves commands locally with zero latency without triggering network', async () => {
    const client = AiClient.getInstance();
    const candidates = [
      { id: 1, name: 'TF1 HD', is_favorite: false },
      { id: 2, name: 'France 2 FHD', is_favorite: true },
    ];

    const outcome = await client.resolveLocal('mets france 2', candidates);
    expect(outcome.action).toBeDefined();
    expect(outcome.action.action).toBe('play_channel');
    expect(outcome.action.item_id).toBe(2);
  });
});
