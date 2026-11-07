/**
 * The TV's own Samsung channel (PRD 39 § 3): a WebSocket on the TV that relays messages between
 * every client connected to the same channel name. The TV app listens on it (it cannot open a
 * port), the phone connects from the network. Nothing sent here is trusted: the pairing protocol
 * encrypts and authenticates each message.
 */
export type ChannelMessage = { data: string; from: string };

export class MsfChannel {
  private socket: WebSocket | null = null;
  private onMessage: (m: ChannelMessage) => void = () => {};
  private onClosed: () => void = () => {};

  constructor(private readonly name: string, private readonly ports = [8001]) {}

  static channelName(session: string): string {
    return `buntu.pair.${session}`;
  }

  setHandlers(onMessage: (m: ChannelMessage) => void, onClosed: () => void) {
    this.onMessage = onMessage;
    this.onClosed = onClosed;
  }

  /** The app is on the TV itself: its loopback reaches the TV's channel service. */
  async connect(hosts: string[] = ['127.0.0.1']): Promise<void> {
    let lastError: unknown = null;
    for (const host of hosts) {
      for (const port of this.ports) {
        try {
          await this.open(`ws://${host}:${port}/api/v2/channels/${this.name}`);
          return;
        } catch (e) {
          lastError = e;
        }
      }
    }
    throw lastError ?? new Error('Canal de la TV indisponible');
  }

  private open(url: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      let settled = false;
      const timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          ws.close();
          reject(new Error('Délai dépassé'));
        }
      }, 4000);
      ws.onmessage = (ev) => {
        let msg: any;
        try {
          msg = JSON.parse(String(ev.data));
        } catch {
          return;
        }
        if (msg.event === 'ms.channel.connect' && !settled) {
          settled = true;
          clearTimeout(timer);
          this.socket = ws;
          resolve();
          return;
        }
        if (msg.event === 'buntu.pair' && msg.data != null) {
          const payload = typeof msg.data === 'string' ? msg.data : JSON.stringify(msg.data);
          this.onMessage({ data: payload, from: String(msg.from ?? '') });
        }
      };
      ws.onerror = () => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          reject(new Error('Connexion refusée'));
        }
      };
      ws.onclose = () => {
        clearTimeout(timer);
        if (!settled) {
          settled = true;
          reject(new Error('Connexion fermée'));
        } else if (this.socket === ws) {
          this.socket = null;
          this.onClosed();
        }
      };
    });
  }

  /**
   * Sends the encrypted reply on the channel.
   * Note: On Samsung Tizen MSF 2.0 (`ws://<tv>:8001/api/v2/channels/...`), passing a client UUID string in `to`
   * silently drops the frame on Tizen 6+; `'broadcast'` delivers reliably while AES-256-GCM (`replyKey`) ensures
   * only the paired phone can decrypt the reply.
   */
  reply(_to: string, data: string) {
    this.socket?.send(
      JSON.stringify({
        method: 'ms.channel.emit',
        params: { event: 'buntu.pair.reply', to: 'broadcast', data },
      })
    );
  }

  close() {
    const ws = this.socket;
    this.socket = null;
    if (!ws) return;
    // Allow any queued outgoing reply frame to flush to the local Samsung MSF daemon before closing TCP.
    setTimeout(() => {
      try {
        ws.close();
      } catch {
        /* already closed */
      }
    }, 120);
  }
}
