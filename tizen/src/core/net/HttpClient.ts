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
      const response = await fetch(url, {
        method: 'GET',
        headers,
      });

      if (response.status === 429) {
        this.handleRateLimit(response);
        throw new Error(`Fournisseur saturé (HTTP 429). Pause de ${this.getRateLimitSecondsRemaining()}s...`);
      }

      let data: any;
      if (responseType === 'json') {
        data = await response.json();
      } else if (responseType === 'text') {
        data = await response.text();
      } else {
        data = await response.arrayBuffer();
      }

      const headerMap: Record<string, string> = {};
      response.headers.forEach((value, key) => {
        headerMap[key.toLowerCase()] = value;
      });

      return {
        status: response.status,
        data,
        headers: headerMap,
        finalUrl: response.url || url,
      };
    } finally {
      release();
    }
  }

  private handleRateLimit(response: Response) {
    const retryAfter = response.headers.get('retry-after');
    const delaySecs = retryAfter ? parseInt(retryAfter, 10) || 20 : 20;
    this.rateLimitUntil = Date.now() + Math.min(Math.max(delaySecs, 10), 30) * 1000;
  }
}
