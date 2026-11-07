/**
 * CND IPTV Tizen - Worker RPC Bridge (PRD 38 § 2.2)
 *
 * Dispatches heavy tasks to the Web Worker and returns promises on the main thread.
 */

/** Seconds a request may wait on the worker before the app stops trusting it and works in-process. */
const WORKER_TIMEOUT_MS = 45_000;

type Pending = {
  type: string;
  payload: any;
  resolve: (val: any) => void;
  reject: (err: any) => void;
  timer: ReturnType<typeof setTimeout> | null;
};

export class WorkerBridge {
  private static instance: WorkerBridge;
  private worker: Worker | null = null;
  private requestCounter = 0;
  private pendingRequests = new Map<number, Pending>();
  /** The worker could not start or stopped answering: the domain runs on the main thread instead. */
  private inProcess = false;
  private handlers: Promise<typeof import('./handlers')> | null = null;

  public static getInstance(): WorkerBridge {
    if (!WorkerBridge.instance) {
      WorkerBridge.instance = new WorkerBridge();
    }
    return WorkerBridge.instance;
  }

  /** True when the WebAssembly runs on the main thread (no usable Web Worker on this TV). */
  public get isInProcess(): boolean {
    return this.inProcess;
  }

  public init() {
    if (this.worker || this.inProcess) return;
    if (typeof Worker === 'undefined') {
      this.useMainThread('Web Worker absent');
      return;
    }
    try {
      // A classic worker (the build bundles it as one): Tizen 6 (Chromium 76) cannot start a module worker.
      this.worker = new Worker(new URL('./index.ts', import.meta.url));
      this.worker.onmessage = this.handleMessage;
      this.worker.onerror = (err) => {
        console.error('[WorkerBridge] Worker error:', err);
        this.useMainThread('erreur du worker');
      };
    } catch (e) {
      this.useMainThread(`construction impossible (${(e as Error)?.message ?? e})`);
    }
  }

  /** Switches to the main thread for good and replays what the worker never answered. */
  private useMainThread(reason: string) {
    if (this.inProcess) return;
    console.warn(`[WorkerBridge] Domaine WebAssembly sur le fil principal : ${reason}`);
    this.inProcess = true;
    try {
      this.worker?.terminate();
    } catch {
      /* already gone */
    }
    this.worker = null;
    const waiting = Array.from(this.pendingRequests.entries());
    this.pendingRequests.clear();
    for (const [, p] of waiting) {
      if (p.timer) clearTimeout(p.timer);
      this.runInProcess(p.type, p.payload).then(p.resolve, p.reject);
    }
  }

  private runInProcess(type: string, payload: any): Promise<any> {
    if (!this.handlers) this.handlers = import('./handlers');
    return this.handlers.then((h) => h.handleRequest(type, payload));
  }

  private handleMessage = (event: MessageEvent) => {
    const { id, success, result, error } = event.data;
    const pending = this.pendingRequests.get(id);
    if (!pending) return;

    this.pendingRequests.delete(id);
    if (pending.timer) clearTimeout(pending.timer);
    if (success) {
      pending.resolve(result);
    } else {
      pending.reject(new Error(error));
    }
  };

  public post<T = any>(type: string, payload: any = {}): Promise<T> {
    this.init();
    if (this.inProcess) return this.runInProcess(type, payload) as Promise<T>;
    const id = ++this.requestCounter;

    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => this.useMainThread('le worker ne répond pas'), WORKER_TIMEOUT_MS);
      this.pendingRequests.set(id, { type, payload, resolve, reject, timer });
      this.worker!.postMessage({ id, type, payload });
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

  /** QR code modules as `"<size>:<row-major 0/1>"`. */
  public async qrMatrix(text: string): Promise<string> {
    return this.post<string>('QR_MATRIX', { text });
  }

  public async pairingCreateOffer(
    entropy: Uint8Array, tvName: string, transport: string, host: string, port: number, now: number
  ): Promise<string> {
    return this.post<string>('PAIRING_CREATE_OFFER', { entropy, tvName, transport, host, port, now });
  }

  /** `{ opened }` or `{ rejected }` as JSON. */
  public async pairingOpen(state: string, message: string, now: number): Promise<string> {
    return this.post<string>('PAIRING_OPEN', { state, message, now });
  }

  public async pairingSealReply(
    replyKey: string, session: string, entropy: Uint8Array, result: string, count: number
  ): Promise<string> {
    return this.post<string>('PAIRING_SEAL_REPLY', { replyKey, session, entropy, result, count });
  }
}
