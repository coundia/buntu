/**
 * CND IPTV Tizen - Single Connection Network Client (PRD 38 § 4.2)
 *
 * Implements:
 * 1. Sequential 1-connection queue for providers with single-connection limits.
 * 2. Final URL resolution via Range: bytes=0-0 to keep AVPlay in the same server session.
 * 3. 429 Too Many Requests backoff (10s to 30s pause without burst retries).
 */

export interface HttpResponse<T = any> {
  status: number;
  data: T;
  headers: Record<string, string>;
  finalUrl: string;
}

export class HttpClient {
  private static instance: HttpClient;
  private singleConnectionMode = true;
  private activeConnections = 0;
  private connectionQueue: (() => void)[] = [];
  private rateLimitUntil = 0;
  private resolvedUrlCache = new Map<string, { finalUrl: string; timestamp: number }>();
  private readonly URL_CACHE_TTL_MS = 30 * 60 * 1000; // 30 minutes

  public static getInstance(): HttpClient {
    if (!HttpClient.instance) {
      HttpClient.instance = new HttpClient();
    }
    return HttpClient.instance;
  }

  public setSingleConnectionMode(enabled: boolean) {
    this.singleConnectionMode = enabled;
  }

  public isSingleConnectionMode(): boolean {
    return this.singleConnectionMode;
  }

  public isRateLimited(): boolean {
    return Date.now() < this.rateLimitUntil;
  }

  public getRateLimitSecondsRemaining(): number {
    const diff = this.rateLimitUntil - Date.now();
    return diff > 0 ? Math.ceil(diff / 1000) : 0;
  }

  private async acquireConnectionSlot(): Promise<() => void> {
    if (!this.singleConnectionMode) {
      return () => {};
    }

    if (this.activeConnections === 0) {
      this.activeConnections++;
      return () => this.releaseConnectionSlot();
    }

    return new Promise<() => void>((resolve) => {
      this.connectionQueue.push(() => {
        this.activeConnections++;
        resolve(() => this.releaseConnectionSlot());
      });
    });
  }

  private releaseConnectionSlot() {
    this.activeConnections = Math.max(0, this.activeConnections - 1);
    const next = this.connectionQueue.shift();
    if (next) {
      next();
    }
  }

  /**
   * Resolves the final streaming URL after redirects using Range: bytes=0-0.
   * Caches the resolved URL so subsequent seeks stay in the exact same session.
   */
  public async resolveFinalUrl(rawUrl: string, headers: Record<string, string> = {}): Promise<string> {
    // Check cache
    const cached = this.resolvedUrlCache.get(rawUrl);
    if (cached && Date.now() - cached.timestamp < this.URL_CACHE_TTL_MS) {
      return cached.finalUrl;
    }

    const release = await this.acquireConnectionSlot();
    try {
      const response = await fetch(rawUrl, {
        method: 'GET',
        headers: {
          ...headers,
          Range: 'bytes=0-0',
        },
      });

      if (response.status === 429) {
        this.handleRateLimit(response);
      }

      const finalUrl = response.url || rawUrl;
      this.resolvedUrlCache.set(rawUrl, { finalUrl, timestamp: Date.now() });
      return finalUrl;
    } catch {
      return rawUrl;
    } finally {
      release();
    }
  }

  /**
   * Sends an HTTP request with single-connection synchronization.
   */
  public async get<T = any>(
    url: string,
    headers: Record<string, string> = {},
    responseType: 'json' | 'text' | 'arraybuffer' = 'json'
  ): Promise<HttpResponse<T>> {
    if (this.isRateLimited()) {
      throw new Error(`Fournisseur saturé (HTTP 429). Pause de ${this.getRateLimitSecondsRemaining()}s...`);
    }

    const release = await this.acquireConnectionSlot();
    try {
      let status = 0;
      let data: any;
      let finalUrl = url;
      const headerMap: Record<string, string> = {};

      try {
        const response = await fetch(url, {
          method: 'GET',
          headers,
        });
        status = response.status;
        finalUrl = response.url || url;
        response.headers.forEach((value, key) => {
          headerMap[key.toLowerCase()] = value;
        });

        if (status === 429) {
          this.handleRateLimit(response);
          throw new Error(`Fournisseur saturé (HTTP 429). Pause de ${this.getRateLimitSecondsRemaining()}s...`);
        }
        if (status === 401 || status === 403) {
          throw new Error(`Identifiants IPTV refusés par le serveur (HTTP ${status}).`);
        }
        if (status >= 400) {
          throw new Error(`Erreur du serveur IPTV (HTTP ${status}).`);
        }

        if (responseType === 'json') {
          const rawText = await response.text();
          data = JSON.parse(rawText);
        } else if (responseType === 'text') {
          data = await response.text();
        } else {
          data = await response.arrayBuffer();
        }
      } catch (fetchErr: any) {
        // Re-throw explicit HTTP status errors (401/403/429/5xx) or JSON parse errors immediately
        if (status >= 400 || fetchErr instanceof SyntaxError) {
          throw fetchErr;
        }
        // Fallback to XMLHttpRequest for Tizen file:// origin when providers send malformed CORS headers
        const xhrRes = await this.xhrGet<T>(url, headers, responseType);
        status = xhrRes.status;
        data = xhrRes.data;
        finalUrl = xhrRes.finalUrl;
      }

      return {
        status,
        data,
        headers: headerMap,
        finalUrl,
      };
    } finally {
      release();
    }
  }

  private xhrGet<T>(
    url: string,
    headers: Record<string, string>,
    responseType: 'json' | 'text' | 'arraybuffer'
  ): Promise<HttpResponse<T>> {
    return new Promise((resolve, reject) => {
      if (typeof XMLHttpRequest === 'undefined') {
        reject(new Error(' Serveur IPTV injoignable.'));
        return;
      }
      const xhr = new XMLHttpRequest();
      xhr.open('GET', url, true);
      xhr.timeout = 60_000;
      if (responseType === 'arraybuffer') {
        xhr.responseType = 'arraybuffer';
      }
      Object.entries(headers).forEach(([k, v]) => {
        try {
          xhr.setRequestHeader(k, v);
        } catch {
          /* ignore restricted headers */
        }
      });
      xhr.onload = () => {
        if (xhr.status === 429) {
          this.rateLimitUntil = Date.now() + 20_000;
          reject(new Error('Fournisseur saturé (HTTP 429). Pause de 20s...'));
          return;
        }
        if (xhr.status === 401 || xhr.status === 403) {
          reject(new Error(`Identifiants IPTV refusés par le serveur (HTTP ${xhr.status}).`));
          return;
        }
        if (xhr.status >= 400) {
          reject(new Error(`Erreur du serveur IPTV (HTTP ${xhr.status}).`));
          return;
        }
        try {
          let parsed: any;
          if (responseType === 'json') {
            parsed = JSON.parse(xhr.responseText);
          } else if (responseType === 'text') {
            parsed = xhr.responseText;
          } else {
            parsed = xhr.response;
          }
          resolve({
            status: xhr.status || 200,
            data: parsed,
            headers: {},
            finalUrl: xhr.responseURL || url,
          });
        } catch (err) {
          reject(err);
        }
      };
      xhr.onerror = () => reject(new Error('Serveur IPTV injoignable : vérifiez la connexion réseau de la TV.'));
      xhr.ontimeout = () => reject(new Error('Délai dépassé lors du téléchargement auprès du fournisseur IPTV.'));
      xhr.send();
    });
  }

  private handleRateLimit(response: Response) {
    const retryAfter = response.headers.get('retry-after');
    const delaySecs = retryAfter ? parseInt(retryAfter, 10) || 20 : 20;
    this.rateLimitUntil = Date.now() + Math.min(Math.max(delaySecs, 10), 30) * 1000;
  }
}

