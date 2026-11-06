/**
 * CND IPTV Tizen - Worker RPC Bridge (PRD 38 § 2.2)
 *
 * Dispatches heavy tasks to the Web Worker and returns promises on the main thread.
 */

export class WorkerBridge {
  private static instance: WorkerBridge;
  private worker: Worker | null = null;
  private requestCounter = 0;
  private pendingRequests = new Map<number, { resolve: (val: any) => void; reject: (err: any) => void }>();

  public static getInstance(): WorkerBridge {
    if (!WorkerBridge.instance) {
      WorkerBridge.instance = new WorkerBridge();
    }
    return WorkerBridge.instance;
  }

  public init() {
    if (this.worker) return;

    try {
      this.worker = new Worker(new URL('./index.ts', import.meta.url), { type: 'module' });
      this.worker.onmessage = this.handleMessage;
      this.worker.onerror = (err) => {
        console.error('[WorkerBridge] Worker error:', err);
      };
    } catch (e) {
      console.warn('[WorkerBridge] Failed to construct Web Worker, fallback mode active:', e);
    }
  }

  private handleMessage = (event: MessageEvent) => {
    const { id, success, result, error } = event.data;
    const pending = this.pendingRequests.get(id);
    if (!pending) return;

    this.pendingRequests.delete(id);
    if (success) {
      pending.resolve(result);
    } else {
      pending.reject(new Error(error));
    }
  };

  public post<T = any>(type: string, payload: any = {}): Promise<T> {
    this.init();
    const id = ++this.requestCounter;

    return new Promise<T>((resolve, reject) => {
      this.pendingRequests.set(id, { resolve, reject });
      if (this.worker) {
        this.worker.postMessage({ id, type, payload });
      } else {
        reject(new Error('Web Worker not supported in this environment'));
      }
    });
  }

  public async getVersion(): Promise<string> {
    return this.post<string>('GET_VERSION');
  }

  public async isAdultCategory(group: string): Promise<boolean> {
    return this.post<boolean>('IS_ADULT_CATEGORY', { group });
  }

  public async normalizeGroup(group: string): Promise<string> {
    return this.post<string>('NORMALIZE_GROUP', { group });
  }

  public async normalizeTitle(raw: string, group?: string): Promise<any> {
    return this.post('NORMALIZE_TITLE', { raw, group });
  }

  public async parseM3uChunk(content: string, sourceUuid: string): Promise<{ header: any; items: any[] }> {
    return this.post('PARSE_M3U_CHUNK', { content, sourceUuid });
  }

  public async parseXmltvChunk(xmlContent: string, cutoffTs: number): Promise<any[]> {
    return this.post('PARSE_XMLTV_CHUNK', { xmlContent, cutoffTs });
  }

  public async parseSearchQuery(query: string, nowEpoch: number, utcOffsetMinutes: number): Promise<any> {
    return this.post('PARSE_SEARCH_QUERY', { query, nowEpoch, utcOffsetMinutes });
  }

  public async rankSearch(query: any, candidates: any[]): Promise<any[]> {
    return this.post('RANK_SEARCH', { query, candidates });
  }

  public async scoreRecommendations(taste: any, items: any[]): Promise<any[]> {
    return this.post('SCORE_RECOMMENDATIONS', { taste, items });
  }

  public async parseSagaTitle(title: string, year?: number): Promise<any> {
    return this.post('PARSE_SAGA_TITLE', { title, year });
  }
}

