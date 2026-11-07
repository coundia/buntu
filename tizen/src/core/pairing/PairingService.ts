/**
 * Receiving sources from a phone (PRD 39). One responsibility: run a pairing session on the TV.
 *
 *  1. ask the shared Rust protocol (WebAssembly) for an offer: a link for the QR code and a private
 *     state that stays here, in memory;
 *  2. listen on the TV's own channel;
 *  3. open each message through the protocol (it refuses forgeries, replays and a fourth try),
 *     show what it holds, and wait for the user's decision with the remote;
 *  4. tell the phone the outcome.
 */
import { WorkerBridge } from '../../worker/worker-bridge';
import { MsfChannel } from './MsfChannel';
import { SourceRecord } from '../storage/Database';
import { SharePreview, applyShare, existingSources, previewShare } from './ShareImport';

export interface PairingOffer {
  link: string;
  session: string;
  expiresAt: number; // seconds
  qrSize: number;
  qrModules: string;
  host: string;
  port: number;
}

export interface PairingRequest {
  from: string;
  preview: SharePreview;
  accept(): Promise<number>;
  refuse(): Promise<void>;
}

export interface PairingEvents {
  onRequest(request: PairingRequest): void;
  /** The session ended (expired, closed after errors, or served): show a new QR code. */
  onClosed(reason: 'expired' | 'closed' | 'done' | 'channel'): void;
  onError(message: string): void;
}

export interface PairingEnv {
  now(): number; // seconds
  entropy(n: number): Uint8Array;
  tvName(): string;
  tvIp(): string | null;
}

export function defaultEnv(): PairingEnv {
  const w = window as any;
  return {
    now: () => Math.floor(Date.now() / 1000),
    entropy: (n) => {
      const bytes = new Uint8Array(n);
      crypto.getRandomValues(bytes);
      return bytes;
    },
    tvName: () => {
      try {
        return `Samsung ${w.webapis?.productinfo?.getRealModel?.() ?? 'TV'}`;
      } catch {
        return 'Samsung TV';
      }
    },
    tvIp: () => {
      try {
        return w.webapis?.network?.getIp?.() || null;
      } catch {
        return null;
      }
    },
  };
}

const CHANNEL_PORT = 8001;

/** What the service needs from the app, replaceable in tests. */
export interface PairingDeps {
  channel(name: string): Pick<MsfChannel, 'setHandlers' | 'connect' | 'reply' | 'close'>;
  existingSources(): Promise<SourceRecord[]>;
  apply(preview: SharePreview): Promise<number>;
}

export const defaultDeps: PairingDeps = {
  channel: (name) => new MsfChannel(name, [CHANNEL_PORT]),
  existingSources,
  apply: (preview) => applyShare(preview),
};

export class PairingService {
  private channel: Pick<MsfChannel, 'setHandlers' | 'connect' | 'reply' | 'close'> | null = null;
  private state = '';
  private session = '';
  private expiryTimer: ReturnType<typeof setTimeout> | null = null;
  private stopped = true;

  constructor(
    private readonly events: PairingEvents,
    private readonly env: PairingEnv = defaultEnv(),
    private readonly bridge: Pick<WorkerBridge, 'pairingCreateOffer' | 'qrMatrix' | 'pairingOpen' | 'pairingSealReply'> =
      WorkerBridge.getInstance(),
    private readonly deps: PairingDeps = defaultDeps
  ) {}

  /** Starts a session and returns what to display. Call `stop()` when the screen goes away. */
  async start(): Promise<PairingOffer> {
    this.stop();
    this.stopped = false;
    const host = this.env.tvIp();
    if (!host) throw new Error('La TV ne connaît pas son adresse réseau : vérifiez le Wi-Fi ou le câble');

    const now = this.env.now();
    const offer = JSON.parse(
      await this.bridge.pairingCreateOffer(this.env.entropy(40), this.env.tvName(), 'msf', host, CHANNEL_PORT, now)
    );
    this.state = offer.state;
    this.session = offer.session;
    const qr = await this.bridge.qrMatrix(offer.link);
    const [size, modules] = qr.split(':');

    const channel = this.deps.channel(MsfChannel.channelName(offer.session));
    channel.setHandlers(
      (m) => void this.handleMessage(m.data, m.from),
      () => {
        if (!this.stopped) this.finish('channel');
      }
    );
    try {
      await channel.connect(['127.0.0.1', host]);
    } catch {
      throw new Error('Le canal de la TV est indisponible : le mode développeur ou le réseau bloque la réception');
    }
    this.channel = channel;

    const delay = Math.max(0, (offer.expires_at - this.env.now()) * 1000);
    this.expiryTimer = setTimeout(() => this.finish('expired'), delay);

    return {
      link: offer.link,
      session: offer.session,
      expiresAt: offer.expires_at,
      qrSize: Number(size),
      qrModules: modules,
      host,
      port: CHANNEL_PORT,
    };
  }

  private async handleMessage(message: string, from: string) {
    if (this.stopped) return;
    let result: any;
    try {
      result = JSON.parse(await this.bridge.pairingOpen(this.state, message, this.env.now()));
    } catch {
      return; // never let a malformed frame crash the session
    }
    if (result.rejected) {
      this.state = result.rejected.state;
      // The reason is not shown: it would tell an intruder what to adjust.
      if (result.rejected.closed) this.finish('closed');
      return;
    }
    const opened = result.opened;
    this.state = opened.state; // the session served its one message
    let preview: SharePreview;
    try {
      preview = previewShare(opened.share_json, await this.deps.existingSources());
    } catch (e: any) {
      await this.answer(opened.reply_key, from, 'error', 0);
      this.events.onError(e?.message ?? 'Partage illisible');
      this.finish('done');
      return;
    }
    this.events.onRequest({
      from: opened.from,
      preview,
      accept: async () => {
        try {
          const count = await this.deps.apply(preview);
          await this.answer(opened.reply_key, from, 'added', count);
          this.finish('done');
          return count;
        } catch (e: any) {
          await this.answer(opened.reply_key, from, 'error', 0);
          this.events.onError(e?.message ?? 'Ajout impossible');
          this.finish('done');
          return 0;
        }
      },
      refuse: async () => {
        await this.answer(opened.reply_key, from, 'refused', 0);
        this.finish('done');
      },
    });
  }

  private async answer(replyKey: string, to: string, result: string, count: number) {
    try {
      const reply = await this.bridge.pairingSealReply(replyKey, this.session, this.env.entropy(12), result, count);
      this.channel?.reply(to, reply);
    } catch {
      /* the phone will time out; the import itself already happened or was refused */
    }
  }

  private finish(reason: 'expired' | 'closed' | 'done' | 'channel') {
    if (this.stopped) return;
    this.stop();
    this.events.onClosed(reason);
  }

  stop() {
    this.stopped = true;
    if (this.expiryTimer) clearTimeout(this.expiryTimer);
    this.expiryTimer = null;
    this.channel?.close();
    this.channel = null;
    this.state = '';
  }
}
