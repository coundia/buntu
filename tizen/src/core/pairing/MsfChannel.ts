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
        if (msg.event === 'buntu.pair' && typeof msg.data === 'string') {
          this.onMessage({ data: msg.data, from: String(msg.from ?? '') });
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

  /** Answers one client (or everybody when `to` is unknown). */
  reply(to: string, data: string) {
    this.socket?.send(
      JSON.stringify({
        method: 'ms.channel.emit',
        params: { event: 'buntu.pair.reply', to: to || 'broadcast', data },
      })
    );
  }

  close() {
    const ws = this.socket;
    this.socket = null;
    try {
      ws?.close();
    } catch {
      /* already closed */
    }
  }
}
