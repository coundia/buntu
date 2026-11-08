/**
 * CND IPTV Tizen - AI Assistant Settings & Consent Store (PRD 40 § 4.1 & § 5)
 */

export type AiProviderType = 'local_only' | 'gemini' | 'openai_compatible' | 'anthropic';

export interface AiSettingsConfig {
  provider: AiProviderType;
  model: string;
  baseUrl: string;
  consents: Record<string, boolean>;
  dailyCap: number;
  sendRecentTitles: boolean;
  timeoutMs: number;
}

const SETTINGS_KEY = 'cnd_ai_settings';

export const PROVIDER_DEFAULTS: Record<AiProviderType, { model: string; baseUrl: string; label: string }> = {
  local_only: {
    model: '',
    baseUrl: '',
    label: 'Désactivé (Recherche locale)',
  },
  gemini: {
    model: 'gemini-3.5-flash-lite',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    label: 'Google Gemini',
  },
  openai_compatible: {
    model: 'gpt-4o-mini',
    baseUrl: 'https://api.openai.com/v1',
    label: 'Compatible OpenAI',
  },
  anthropic: {
    model: 'claude-haiku-5-5',
    baseUrl: 'https://api.anthropic.com',
    label: 'Anthropic Claude',
  },
};

export const DEFAULT_AI_SETTINGS: AiSettingsConfig = {
  provider: 'local_only',
  model: '',
  baseUrl: '',
  consents: {},
  dailyCap: 30,
  sendRecentTitles: false,
  timeoutMs: 8000,
};

export function isLocalNetworkUrl(urlStr: string): boolean {
  if (!urlStr) return false;
  try {
    const url = new URL(urlStr);
    const host = url.hostname.toLowerCase();
    if (
      host === 'localhost' ||
      host === '127.0.0.1' ||
      host === '::1' ||
      host.endsWith('.local') ||
      host.startsWith('127.')
    ) {
      return true;
    }
    const parts = host.split('.').map((p) => parseInt(p, 10));
    if (parts.length === 4 && parts.every((p) => !isNaN(p))) {
      if (parts[0] === 10) return true;
      if (parts[0] === 192 && parts[1] === 168) return true;
      if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return true;
    }
    return false;
  } catch {
    return false;
  }
}

export function getAiSettings(): AiSettingsConfig {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    if (!raw) return { ...DEFAULT_AI_SETTINGS };
    const parsed = JSON.parse(raw);
    return {
      provider: parsed.provider ?? DEFAULT_AI_SETTINGS.provider,
      model: parsed.model ?? '',
      baseUrl: parsed.baseUrl ?? '',
      consents: parsed.consents ?? {},
      dailyCap: typeof parsed.dailyCap === 'number' ? parsed.dailyCap : 30,
      sendRecentTitles: Boolean(parsed.sendRecentTitles),
      timeoutMs: typeof parsed.timeoutMs === 'number' ? parsed.timeoutMs : 8000,
    };
  } catch {
    return { ...DEFAULT_AI_SETTINGS };
  }
}

export function saveAiSettings(partial: Partial<AiSettingsConfig>): AiSettingsConfig {
  const current = getAiSettings();
  const updated: AiSettingsConfig = {
    ...current,
    ...partial,
    consents: {
      ...current.consents,
      ...(partial.consents ?? {}),
    },
  };
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(updated));
  } catch {
    // Ignore localStorage errors
  }
  return updated;
}

export function hasUserConsent(provider: AiProviderType): boolean {
  if (provider === 'local_only') return true;
  const settings = getAiSettings();
  if (provider === 'openai_compatible' && isLocalNetworkUrl(settings.baseUrl)) {
    // Local server on LAN needs no cloud consent
    return true;
  }
  return Boolean(settings.consents[provider]);
}

export function setUserConsent(provider: AiProviderType, granted: boolean): void {
  const settings = getAiSettings();
  settings.consents[provider] = granted;
  saveAiSettings({ consents: settings.consents });
}

export function getEffectiveModel(settings: AiSettingsConfig): string {
  if (settings.model.trim()) return settings.model.trim();
  return PROVIDER_DEFAULTS[settings.provider]?.model ?? '';
}

export function getEffectiveBaseUrl(settings: AiSettingsConfig): string {
  if (settings.baseUrl.trim()) return settings.baseUrl.trim().replace(/\/+$/, '');
  return PROVIDER_DEFAULTS[settings.provider]?.baseUrl ?? '';
}

