import { describe, it, expect, beforeEach } from 'vitest';
import {
  getAiSettings,
  saveAiSettings,
  hasUserConsent,
  setUserConsent,
  isLocalNetworkUrl,
  getEffectiveModel,
  getEffectiveBaseUrl,
} from '../src/core/ai/AiSettings';
import {
  getCallsToday,
  recordCall,
  isDailyCapReached,
  resetUsage,
} from '../src/core/ai/AiUsage';

describe('AiSettings & AiUsage', () => {
  const store = new Map<string, string>();
  const mockLocalStorage = {
    getItem: (key: string) => store.get(key) || null,
    setItem: (key: string, val: string) => store.set(key, val),
    removeItem: (key: string) => store.delete(key),
    clear: () => store.clear(),
  };

  beforeEach(() => {
    store.clear();
    (globalThis as any).localStorage = mockLocalStorage;
  });

  it('provides sensible defaults when empty', () => {
    const s = getAiSettings();
    expect(s.provider).toBe('local_only');
    expect(s.dailyCap).toBe(30);
    expect(s.timeoutMs).toBe(8000);
    expect(s.sendRecentTitles).toBe(false);
  });

  it('saves and updates settings', () => {
    saveAiSettings({ provider: 'gemini', dailyCap: 50 });
    const s = getAiSettings();
    expect(s.provider).toBe('gemini');
    expect(s.dailyCap).toBe(50);
    expect(getEffectiveModel(s)).toBe('gemini-3.5-flash-lite');
    expect(getEffectiveBaseUrl(s)).toBe('https://generativelanguage.googleapis.com/v1beta');
  });

  it('manages consent per provider', () => {
    expect(hasUserConsent('gemini')).toBe(false);
    setUserConsent('gemini', true);
    expect(hasUserConsent('gemini')).toBe(true);

    // local_only always has consent
    expect(hasUserConsent('local_only')).toBe(true);
  });

  it('recognizes LAN/local network addresses (Ollama, LM Studio)', () => {
    expect(isLocalNetworkUrl('http://192.168.1.50:11434/v1')).toBe(true);
    expect(isLocalNetworkUrl('http://10.0.0.12:1234/v1')).toBe(true);
    expect(isLocalNetworkUrl('http://127.0.0.1:11434/v1')).toBe(true);
    expect(isLocalNetworkUrl('http://localhost:8080/v1')).toBe(true);
    expect(isLocalNetworkUrl('http://server.local:11434/v1')).toBe(true);

    expect(isLocalNetworkUrl('https://api.openai.com/v1')).toBe(false);
    expect(isLocalNetworkUrl('https://generativelanguage.googleapis.com/v1beta')).toBe(false);
  });

  it('tracks daily usage and quota caps', () => {
    resetUsage();
    const providerKey = 'gemini:gemini-3.5-flash-lite';
    expect(getCallsToday(providerKey)).toBe(0);
    expect(isDailyCapReached(providerKey, 3, false)).toBe(false);

    recordCall(providerKey);
    recordCall(providerKey);
    expect(getCallsToday(providerKey)).toBe(2);
    expect(isDailyCapReached(providerKey, 2, false)).toBe(true);

    // Local providers are exempt from caps
    expect(isDailyCapReached(providerKey, 2, true)).toBe(false);
  });
});
