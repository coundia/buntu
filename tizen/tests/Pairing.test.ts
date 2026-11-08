import { describe, it, expect, beforeAll } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import init, {
  wasm_pairing_create_offer, wasm_pairing_open, wasm_pairing_open_reply, wasm_pairing_parse_link,
  wasm_pairing_seal, wasm_pairing_seal_reply, wasm_qr_matrix,
} from '../src/wasm/pkg/cnd_domain_wasm.js';
import { PairingService, PairingEnv, PairingRequest } from '../src/core/pairing/PairingService';
import { parseShareDocument, previewShare, findDuplicate, applyShare } from '../src/core/pairing/ShareImport';
import { SourceRecord } from '../src/core/storage/Database';

const WASM = resolve(__dirname, '../src/wasm/pkg/cnd_domain_wasm_bg.wasm');
const VECTORS = resolve(__dirname, '../../crates/cnd-domain/src/pairing/vectors.json');
const built = existsSync(WASM);

const SHARE = JSON.stringify({
  format: 'cnd-source-share', version: 1,
  sources: [
    { name: 'Premium', type: 'xtream', server: 'http://srv.example:8080', username: 'alice', password: 'secret' },
    { name: 'Liste', type: 'm3u', url: 'http://lists.example/a.m3u' },
  ],
});

const bytes = (from: number, n: number) => Uint8Array.from({ length: n }, (_, i) => (from + i) & 255);

// The WebAssembly is built by `task tizen:build`; without it these tests cannot run.
describe.skipIf(!built)('pairing protocol in WebAssembly (shared with Swift and Kotlin)', () => {
  beforeAll(async () => {
    await init({ module_or_path: readFileSync(WASM) });
  });

  it('reproduces the shared vectors byte for byte', () => {
    const v = JSON.parse(readFileSync(VECTORS, 'utf8'));
    const offer = JSON.parse(wasm_pairing_create_offer(
      Uint8Array.from(v.offer.entropy), v.offer.tv_name, v.offer.transport, v.offer.host, v.offer.port, v.now));
    expect(offer.link).toBe(v.offer.link);
    expect(offer.session).toBe(v.offer.session);
    expect(offer.state).toBe(v.offer.state);
    const sealed = JSON.parse(wasm_pairing_seal(offer.link, Uint8Array.from(v.seal.entropy), v.seal.share_json, v.seal.phone_name, v.now + 5));
    expect(sealed.message).toBe(v.seal.message);
    expect(sealed.reply_key).toBe(v.seal.reply_key);
    const reply = wasm_pairing_seal_reply(sealed.reply_key, offer.session, Uint8Array.from(v.reply.entropy), v.reply.result, v.reply.count);
    expect(reply).toBe(v.reply.reply);
  });

  it('draws a QR code that fits a phone camera', () => {
    const offer = JSON.parse(wasm_pairing_create_offer(bytes(0, 40), 'Salon TV', 'msf', '192.168.1.9', 8001, 1_800_000_000));
    const [size, modules] = wasm_qr_matrix(offer.link).split(':');
    expect(Number(size) * Number(size)).toBe(modules.length);
    expect(Number(size)).toBeLessThanOrEqual(61); // version <= 11: readable from 3 m
    expect(/^[01]+$/.test(modules)).toBe(true);
  });

  it('a phone and the service agree end to end, with the confirmation in between', async () => {
    const now = 1_800_000_000;
    const env: PairingEnv = { now: () => now, entropy: (n) => bytes(7, n), tvName: () => 'Salon TV', tvIp: () => '192.168.1.9' };
    const bridge = {
      pairingCreateOffer: async (e: Uint8Array, n: string, t: string, h: string, p: number, at: number) => wasm_pairing_create_offer(e, n, t, h, p, at),
      qrMatrix: async (t: string) => wasm_qr_matrix(t),
      pairingOpen: async (st: string, m: string, at: number) => wasm_pairing_open(st, m, at),
      pairingSealReply: async (k: string, s: string, e: Uint8Array, r: string, c: number) => wasm_pairing_seal_reply(k, s, e, r, c),
    };
    let deliver: (data: string, from: string) => void = () => {};
    const replies: string[] = [];
    const applied: string[] = [];
    const service = new PairingService(
      { onRequest: (r) => requests.push(r), onClosed: (reason) => closed.push(reason), onError: () => {} },
      env, bridge,
      {
        channel: () => ({
          setHandlers: (m: any) => { deliver = (d, f) => m({ data: d, from: f }); },
          connect: async () => {}, reply: (_to: string, data: string) => replies.push(data), close: () => {},
        }),
        existingSources: async () => [],
        apply: async (preview) => { applied.push(...preview.sources.map((s) => s.name)); return preview.sources.length; },
      }
    );
    const requests: PairingRequest[] = [];
    const closed: string[] = [];
    const offer = await service.start();

    // The phone scans the link and sends its sources.
    const phone = JSON.parse(wasm_pairing_seal(offer.link, bytes(100, 44), SHARE, 'iPhone de Papa', now + 1));
    deliver(phone.message, 'client-1');
    await new Promise((r) => setTimeout(r, 20));

    expect(requests).toHaveLength(1);
    expect(requests[0].from).toBe('iPhone de Papa');
    expect(requests[0].preview.sources.map((s) => `${s.name}|${s.host}|${s.hasPassword}`)).toEqual([
      'Premium|srv.example:8080|true', 'Liste|lists.example|false',
    ]);
    expect(applied, 'nothing is added before the user agrees').toEqual([]);

    expect(await requests[0].accept()).toBe(2);
    expect(applied).toEqual(['Premium', 'Liste']);
    const body = JSON.parse(wasm_pairing_open_reply(phone.reply_key, offer.session, replies[0]));
    expect(body).toEqual({ result: 'added', count: 2 });
    expect(closed).toEqual(['done']);
  });

  it('refuses a replayed message: the session served its one message', async () => {
    const now = 1_800_000_000;
    const env: PairingEnv = { now: () => now, entropy: (n) => bytes(9, n), tvName: () => 'TV', tvIp: () => '10.0.0.2' };
    const bridge = {
      pairingCreateOffer: async (e: Uint8Array, n: string, t: string, h: string, p: number, at: number) => wasm_pairing_create_offer(e, n, t, h, p, at),
      qrMatrix: async (t: string) => wasm_qr_matrix(t),
      pairingOpen: async (st: string, m: string, at: number) => wasm_pairing_open(st, m, at),
      pairingSealReply: async (k: string, s: string, e: Uint8Array, r: string, c: number) => wasm_pairing_seal_reply(k, s, e, r, c),
    };
    let deliver: (d: string, f: string) => void = () => {};
    const requests: PairingRequest[] = [];
    const closed: string[] = [];
    const service = new PairingService(
      { onRequest: (r) => requests.push(r), onClosed: (c) => closed.push(c), onError: () => {} }, env, bridge,
      {
        channel: () => ({ setHandlers: (m: any) => { deliver = (d, f) => m({ data: d, from: f }); }, connect: async () => {}, reply: () => {}, close: () => {} }),
        existingSources: async () => [], apply: async () => 1,
      }
    );
    const offer = await service.start();
    const phone = JSON.parse(wasm_pairing_seal(offer.link, bytes(100, 44), SHARE, 'p', now + 1));
    deliver(phone.message, 'a');
    await new Promise((r) => setTimeout(r, 20));
    await requests[0].refuse();
    deliver(phone.message, 'a');
    await new Promise((r) => setTimeout(r, 20));
    expect(requests).toHaveLength(1);
  });

  it('parse_link reads what the offer wrote', () => {
    const offer = JSON.parse(wasm_pairing_create_offer(bytes(0, 40), 'Salon TV', 'msf', '192.168.1.9', 8001, 1_800_000_000));
    const link = JSON.parse(wasm_pairing_parse_link(offer.link, 1_800_000_001));
    expect(link).toMatchObject({ tv_name: 'Salon TV', transport: 'msf', host: '192.168.1.9', port: 8001 });
  });

  it('accepts a share document when phone clock is behind TV clock and streams import progress', async () => {
    const tvNow = 1_794_058_828; // e.g. TV clock set months ahead of phone
    const phoneNow = 1_775_000_000;
    const skewedShare = JSON.stringify({
      format: 'cnd-source-share',
      version: 1,
      created_at: phoneNow,
      expires_at: phoneNow + 3600,
      sources: [
        { name: 'Mon Abonnement', type: 'xtream', server: 'http://srv.example:8080', username: 'bob', password: 'pw' },
      ],
    });
    const env: PairingEnv = { now: () => tvNow, entropy: (n) => bytes(17, n), tvName: () => 'Samsung TV', tvIp: () => '192.168.1.9' };
    const bridge = {
      pairingCreateOffer: async (e: Uint8Array, n: string, t: string, h: string, p: number, at: number) => wasm_pairing_create_offer(e, n, t, h, p, at),
      qrMatrix: async (t: string) => wasm_qr_matrix(t),
      pairingOpen: async (st: string, m: string, at: number) => wasm_pairing_open(st, m, at),
      pairingSealReply: async (k: string, s: string, e: Uint8Array, r: string, c: number) => wasm_pairing_seal_reply(k, s, e, r, c),
    };
    let deliver: (d: string, f: string) => void = () => {};
    const requests: PairingRequest[] = [];
    const progressSteps: string[] = [];
    const service = new PairingService(
      { onRequest: (r) => requests.push(r), onClosed: () => {}, onError: () => {} },
      env,
      bridge,
      {
        channel: () => ({
          setHandlers: (m: any) => { deliver = (d, f) => m({ data: d, from: f }); },
          connect: async () => {},
          reply: () => {},
          close: () => {},
        }),
        existingSources: async () => [],
        apply: async (_preview, onProgress) => {
          onProgress?.('Vérification du compte Xtream…', 10);
          onProgress?.('Téléchargement des chaînes…', 60);
          return 1;
        },
      }
    );
    const offer = await service.start();
    const phone = JSON.parse(wasm_pairing_seal(offer.link, bytes(55, 44), skewedShare, 'Samsung SM-S908N', phoneNow));
    deliver(phone.message, 'phone-client-id');
    await new Promise((r) => setTimeout(r, 20));

    expect(requests).toHaveLength(1);
    expect(requests[0].from).toBe('Samsung SM-S908N');
    const added = await requests[0].accept((msg, pct) => progressSteps.push(`${pct}:${msg}`));
    expect(added).toBe(1);
    expect(progressSteps).toEqual(['10:Vérification du compte Xtream…', '60:Téléchargement des chaînes…']);
  });
});

describe('share document import (preview before anything is added)', () => {
  const existing: SourceRecord[] = [
    { id: 1, uuid: 'u', name: 'Déjà', source_type: 'xtream', server: 'http://SRV.example:8080/', username: 'alice', item_count: 1 } as SourceRecord,
  ];

  it('shows host and "with password", never the password or the full address', () => {
    const p = previewShare(SHARE, []);
    const shown = JSON.stringify(p.sources);
    expect(shown).not.toContain('secret');
    expect(shown).not.toContain('a.m3u');
    expect(p.sources[0]).toEqual({ name: 'Premium', type: 'xtream', host: 'srv.example:8080', hasPassword: true, duplicate: false });
  });

  it('marks a source already present (same server and user, case and slash tolerant)', () => {
    expect(previewShare(SHARE, existing).sources[0].duplicate).toBe(true);
    expect(previewShare(SHARE, existing).sources[1].duplicate).toBe(false);
  });

  it('refuses a document that is not a share, is expired, or holds nothing usable', () => {
    expect(() => parseShareDocument('not json')).toThrow();
    expect(() => parseShareDocument('{"format":"other"}')).toThrow();
    expect(() => parseShareDocument(JSON.stringify({ format: 'cnd-source-share', version: 1, expires_at: 1, sources: [] }))).toThrow(/expiré/);
    expect(() => parseShareDocument(JSON.stringify({ format: 'cnd-source-share', version: 1, sources: [{ type: 'xtream', server: 'ftp://x', username: 'a' }] }))).toThrow(/Aucun compte/);
  });

  it('cleans names and keeps at most 20 sources', () => {
    const many = Array.from({ length: 30 }, (_, i) => ({ name: `S\u0007${i}`, type: 'm3u', url: `http://h/${i}.m3u` }));
    const out = parseShareDocument(JSON.stringify({ format: 'cnd-source-share', version: 1, sources: many }));
    expect(out).toHaveLength(20);
    expect(out[0].name).toBe('S0');
  });

  it('finds existing duplicate sources accurately for both Xtream and M3U', () => {
    const existingList: SourceRecord[] = [
      { id: 10, uuid: 'u1', name: 'Existing Xtream', source_type: 'xtream', server: 'http://srv.example:8080/', username: 'alice', item_count: 5 } as SourceRecord,
      { id: 20, uuid: 'u2', name: 'Existing M3U', source_type: 'm3u', url: 'http://lists.example/a.m3u/', item_count: 12 } as SourceRecord,
    ];
    const matchXtream = findDuplicate(
      { name: 'New Xtream', type: 'xtream', server: 'http://SRV.example:8080', username: 'alice' },
      existingList
    );
    expect(matchXtream?.id).toBe(10);

    const matchM3u = findDuplicate(
      { name: 'New M3U', type: 'm3u', url: 'http://lists.example/a.m3u' },
      existingList
    );
    expect(matchM3u?.id).toBe(20);

    const nonMatch = findDuplicate(
      { name: 'Other', type: 'm3u', url: 'http://lists.example/other.m3u' },
      existingList
    );
    expect(nonMatch).toBeUndefined();
  });

  it('applyShare supports replaceDuplicates option', async () => {
    const existingList: SourceRecord[] = [
      { id: 1, uuid: 'u', name: 'Déjà', source_type: 'xtream', server: 'http://srv.example:8080', username: 'alice', item_count: 1 } as SourceRecord,
    ];
    const preview = previewShare(SHARE, existingList);

    const deletedIds: number[] = [];
    const syncedNames: string[] = [];
    const mockEngine: any = {
      deleteSource: async (id: number) => { deletedIds.push(id); },
      syncXtreamSource: async (name: string) => { syncedNames.push(name); return 10; },
      syncM3uSource: async (name: string) => { syncedNames.push(name); return 5; },
    };

    // When replaceDuplicates is false: duplicate is skipped
    const addedDefault = await applyShare(preview, mockEngine, undefined, { replaceDuplicates: false, existingSources: existingList });
    expect(addedDefault).toBe(1); // Only 'Liste'
    expect(syncedNames).toEqual(['Liste']);
    expect(deletedIds).toEqual([]);

    // Reset
    syncedNames.length = 0;
    deletedIds.length = 0;

    // When replaceDuplicates is true: duplicate is replaced
    const addedReplaced = await applyShare(preview, mockEngine, undefined, { replaceDuplicates: true, existingSources: existingList });
    expect(addedReplaced).toBe(2); // Both 'Premium' and 'Liste'
    expect(deletedIds).toEqual([1]);
    expect(syncedNames).toEqual(['Premium', 'Liste']);
  });
});
