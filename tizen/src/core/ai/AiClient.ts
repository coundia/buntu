/**
 * CND IPTV Tizen - AI Client (PRD 40 § 3.3, § 4 & § 5)
 *
 * Coordinates:
 * - Local resolution (< 50ms)
 * - Wasm request preparation & response validation via WorkerBridge
 * - Network communication using native fetch with XMLHttpRequest fallback for older TVs
 * - 8s timeout, graceful cancellation via AbortController/abort()
 * - Automatic retry on 429 rate limit (Retry-After <= 2s) and schema rejection (Light mode fallback)
 * - Guardrails: Zero API keys in logs/network URLs, zero remote calls in Kids mode or without consent
 */

import { WorkerBridge } from '../../worker/worker-bridge';
import { AiCandidate } from './candidates';
import { AiKeyStore } from './AiKeyStore';
import {
  AiProviderType,
  getAiSettings,
  getEffectiveBaseUrl,
  getEffectiveModel,
  hasUserConsent,
  isLocalNetworkUrl,
} from './AiSettings';
import { isDailyCapReached, recordCall } from './AiUsage';

export interface AiTaskResult {
  ok: boolean;
  action?: any;
  reply?: string;
  understanding?: any;
  recommendations?: any;
  error?: string;
  needsConsent?: boolean;
  needsKey?: boolean;
  quotaReached?: boolean;
  isLocalFallback?: boolean;
}

export interface AiTestResult {
  ok: boolean;
  latencyMs: number;
  message: string;
  model: string;
}

export class AiClient {
  private static instance: AiClient;

  public static getInstance(): AiClient {
    if (!AiClient.instance) {
      AiClient.instance = new AiClient();
    }
    return AiClient.instance;
  }

  /**
   * Safe URL logging: strips query parameters and credentials so keys never appear in logs.
   */
  private cleanUrlForLog(urlStr: string): string {
    try {
      const u = new URL(urlStr);
      return `${u.protocol}//${u.host}${u.pathname}`;
    } catch {
      return urlStr.split('?')[0];
    }
  }

  /**
   * Native HTTP request with fetch, falling back to XMLHttpRequest for Chromium < 66.
   */
  public async httpRequest(
    url: string,
    method: string,
    headers: Array<[string, string]>,
    body: any,
    timeoutMs = 8000,
    signal?: AbortSignal
  ): Promise<{ status: number; body: string; retryAfter?: number }> {
    const started = Date.now();
    const cleanUrl = this.cleanUrlForLog(url);

    // 1. Try modern fetch with AbortController
    if (typeof fetch !== 'undefined' && typeof AbortController !== 'undefined') {
      const controller = new AbortController();
      let timedOut = false;
      const timer = setTimeout(() => {
        timedOut = true;
        controller.abort();
      }, timeoutMs);

      if (signal) {
        signal.addEventListener('abort', () => controller.abort());
      }

      try {
        const headerObj: Record<string, string> = {
          'Content-Type': 'application/json',
        };
        for (const [k, v] of headers) {
          headerObj[k] = v;
        }

        const res = await fetch(url, {
          method,
          headers: headerObj,
          body: typeof body === 'string' ? body : JSON.stringify(body),
          signal: controller.signal,
        });

        clearTimeout(timer);
        const text = await res.text();
        const retryAfterHdr = res.headers.get('retry-after');
        const retryAfter = retryAfterHdr ? parseInt(retryAfterHdr, 10) : undefined;
        const duration = Date.now() - started;

        console.log(`[AI] ${method} ${cleanUrl} -> ${res.status} (${duration}ms)`);
        return { status: res.status, body: text, retryAfter: isNaN(retryAfter as number) ? undefined : retryAfter };
      } catch (err: any) {
        clearTimeout(timer);
        if (timedOut) {
          throw new Error('Délai d’attente dépassé (8s)');
        }
        if (err?.name === 'AbortError') {
          throw new Error('Appel annulé');
        }
        // Fallback to XHR below if network error occurred on older Tizen engine
      }
    }

    // 2. XMLHttpRequest fallback
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open(method, url, true);
      xhr.timeout = timeoutMs;
      xhr.setRequestHeader('Content-Type', 'application/json');

      for (const [k, v] of headers) {
        xhr.setRequestHeader(k, v);
      }

      if (signal) {
        signal.addEventListener('abort', () => xhr.abort());
      }

      xhr.ontimeout = () => {
        reject(new Error('Délai d’attente dépassé (8s)'));
      };

      xhr.onabort = () => {
        reject(new Error('Appel annulé'));
      };

      xhr.onerror = () => {
        reject(new Error('Erreur réseau ou fournisseur indisponible'));
      };

      xhr.onload = () => {
        const duration = Date.now() - started;
        console.log(`[AI] ${method} ${cleanUrl} -> ${xhr.status} (${duration}ms)`);
        const retryHeader = xhr.getResponseHeader('Retry-After');
        const retryAfter = retryHeader ? parseInt(retryHeader, 10) : undefined;
        resolve({
          status: xhr.status,
          body: xhr.responseText || '',
          retryAfter: isNaN(retryAfter as number) ? undefined : retryAfter,
        });
      };

      xhr.send(typeof body === 'string' ? body : JSON.stringify(body));
    });
  }

  /**
   * Resolves a command locally without touching the network (< 50ms).
   */
  public async resolveLocal(
    command: string,
    candidates: AiCandidate[],
    context: { playing_stable_hash?: string; group_title?: string; locale?: string } = {}
  ): Promise<{ action: any; candidates: AiCandidate[]; note?: string }> {
    const bridge = WorkerBridge.getInstance();
    return bridge.post('AI_RESOLVE_LOCAL', {
      command,
      candidates,
      context: {
        locale: context.locale || 'fr-FR',
        ...context,
      },
    });
  }

  /**
   * Runs an AI task (command, understand_search, recommend) with guardrails and fallbacks.
   */
  public async executeTask(
    task: 'command' | 'understand_search' | 'recommend',
    payload: any,
    options: { isKidsProfile?: boolean; signal?: AbortSignal } = {}
  ): Promise<AiTaskResult> {
    // 1. Guardrail: 0 remote calls in Kids mode
    if (options.isKidsProfile) {
      return { ok: false, error: 'Mode Enfants : recherche locale uniquement', isLocalFallback: true };
    }

    const settings = getAiSettings();

    // 2. Guardrail: Local-only mode
    if (settings.provider === 'local_only') {
      return { ok: false, error: 'Fournisseur désactivé', isLocalFallback: true };
    }

    // 3. Guardrail: Consent check
    if (!hasUserConsent(settings.provider)) {
      return { ok: false, needsConsent: true, error: 'Consentement requis pour utiliser l’assistant IA' };
    }

    const keyStore = AiKeyStore.getInstance();
    const apiKey = await keyStore.getApiKey();
    const isLocal = isLocalNetworkUrl(settings.baseUrl);

    // 4. Guardrail: API key check (except for local LAN servers)
    if (!isLocal && (settings.provider === 'gemini' || settings.provider === 'anthropic')) {
      if (!apiKey) {
        return { ok: false, needsKey: true, error: 'Clé API manquante' };
      }
    }

    // 5. Guardrail: Daily quota check for recommendations
    const effectiveModel = getEffectiveModel(settings);
    const providerKey = `${settings.provider}:${effectiveModel}`;
    if (task === 'recommend' && isDailyCapReached(providerKey, settings.dailyCap, isLocal)) {
      return { ok: false, quotaReached: true, error: 'Plafond quotidien d’appels atteint' };
    }

    const bridge = WorkerBridge.getInstance();
    const config = {
      kind: settings.provider,
      model: effectiveModel,
      base_url: getEffectiveBaseUrl(settings),
      api_key: apiKey || undefined,
      timeout_ms: settings.timeoutMs,
    };

    // 6. Build request in Rust/Wasm
    let mode: 'strict' | 'light' = 'strict';
    let buildResult: any;

    try {
      buildResult = await bridge.post('AI_BUILD_REQUEST', {
        config,
        task,
        payload: {
          ...payload,
          mode,
          locale: payload.locale || 'fr-FR',
        },
      });
    } catch (err: any) {
      return { ok: false, error: err?.message || 'Erreur lors de la préparation de la requête' };
    }

    // 7. Send HTTP request with retry on 429 and schema rejection
    try {
      let httpRes = await this.httpRequest(
        buildResult.url,
        buildResult.method || 'POST',
        buildResult.headers || [],
        buildResult.body,
        settings.timeoutMs,
        options.signal
      );

      // Handle 429 rate limit with short Retry-After <= 2s
      if (httpRes.status === 429 && typeof httpRes.retryAfter === 'number' && httpRes.retryAfter <= 2) {
        await new Promise((r) => setTimeout(r, httpRes.retryAfter! * 1000));
        httpRes = await this.httpRequest(
          buildResult.url,
          buildResult.method || 'POST',
          buildResult.headers || [],
          buildResult.body,
          settings.timeoutMs,
          options.signal
        );
      }

      // Read response via Wasm
      let readRes = await bridge.post('AI_READ_RESPONSE', {
        kind: settings.provider,
        status: httpRes.status,
        body: httpRes.body,
      });

      // Handle schema rejection: retry once in Light mode
      if (!readRes.ok && readRes.is_schema_rejection && mode === 'strict') {
        mode = 'light';
        buildResult = await bridge.post('AI_BUILD_REQUEST', {
          config,
          task,
          payload: {
            ...payload,
            mode,
            locale: payload.locale || 'fr-FR',
          },
        });
        httpRes = await this.httpRequest(
          buildResult.url,
          buildResult.method || 'POST',
          buildResult.headers || [],
          buildResult.body,
          settings.timeoutMs,
          options.signal
        );
        readRes = await bridge.post('AI_READ_RESPONSE', {
          kind: settings.provider,
          status: httpRes.status,
          body: httpRes.body,
        });
      }

      if (!readRes.ok) {
        return { ok: false, error: readRes.error || 'Erreur fournisseur', isLocalFallback: true };
      }

      // Record successful call in usage tracker
      if (!isLocal) {
        recordCall(providerKey);
      }

      // 8. Validate model response in Rust/Wasm
      const validRes = await bridge.post('AI_VALIDATE', {
        task,
        text: readRes.text,
        candidates: payload.candidates || [],
        profile: options.isKidsProfile ? { is_kids: true } : {},
      });

      if (!validRes.ok) {
        return { ok: false, error: validRes.error || 'Réponse invalide du modèle', isLocalFallback: true };
      }

      return {
        ok: true,
        action: validRes.action,
        reply: validRes.reply,
        understanding: validRes.understanding,
        recommendations: validRes.recommendations,
      };
    } catch (err: any) {
      return { ok: false, error: err?.message || 'Erreur de connexion', isLocalFallback: true };
    }
  }

  /**
   * Tests provider connectivity and latency from the TV.
   */
  public async testConnection(provider?: AiProviderType, customKey?: string): Promise<AiTestResult> {
    const settings = getAiSettings();
    const effectiveProvider = provider || settings.provider;

    if (effectiveProvider === 'local_only') {
      return { ok: true, latencyMs: 0, message: 'Mode local actif (sans réseau)', model: 'local' };
    }

    const key = customKey ?? (await AiKeyStore.getInstance().getApiKey());
    const isLocal = isLocalNetworkUrl(settings.baseUrl);
    if (!isLocal && (effectiveProvider === 'gemini' || effectiveProvider === 'anthropic')) {
      if (!key) {
        return { ok: false, latencyMs: 0, message: 'Clé API absente', model: '' };
      }
    }

    const effectiveModel = getEffectiveModel(settings);
    const bridge = WorkerBridge.getInstance();
    const config = {
      kind: effectiveProvider,
      model: effectiveModel,
      base_url: getEffectiveBaseUrl(settings),
      api_key: key || undefined,
      timeout_ms: settings.timeoutMs,
    };

    const start = Date.now();
    try {
      const buildResult = await bridge.post('AI_BUILD_REQUEST', {
        config,
        task: 'command',
        payload: {
          locale: 'fr-FR',
          command: 'bonjour',
          candidates: [],
        },
      });

      const httpRes = await this.httpRequest(
        buildResult.url,
        buildResult.method || 'POST',
        buildResult.headers || [],
        buildResult.body,
        settings.timeoutMs
      );

      const latencyMs = Date.now() - start;
      const readRes = await bridge.post('AI_READ_RESPONSE', {
        kind: effectiveProvider,
        status: httpRes.status,
        body: httpRes.body,
      });

      if (readRes.ok) {
        return {
          ok: true,
          latencyMs,
          message: `Connexion réussie (${latencyMs} ms)`,
          model: effectiveModel,
        };
      } else {
        return {
          ok: false,
          latencyMs,
          message: readRes.error || `Erreur HTTP ${httpRes.status}`,
          model: effectiveModel,
        };
      }
    } catch (err: any) {
      const latencyMs = Date.now() - start;
      return {
        ok: false,
        latencyMs,
        message: err?.message || 'Erreur réseau ou fournisseur indisponible',
        model: effectiveModel,
      };
    }
  }
}

