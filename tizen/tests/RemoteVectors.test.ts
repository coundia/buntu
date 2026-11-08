import { describe, it, expect } from 'vitest';
import * as fs from 'fs';
import * as path from 'path';

describe('Remote Playback Vectors Parity (PRD-42)', () => {
  const vectorsPath = path.resolve(__dirname, '../../crates/cnd-domain/src/remote/vectors.json');
  const raw = fs.readFileSync(vectorsPath, 'utf-8');
  const vectors = JSON.parse(raw);

  it('validates canonical wire message shapes', () => {
    const messages = vectors.messages;
    expect(messages).toBeDefined();

    for (const [key, msgDef] of Object.entries<any>(messages)) {
      const parsed = JSON.parse(msgDef.json);
      expect(parsed.type).toBe(msgDef.expected_type);

      if (msgDef.expected_position_ms !== undefined) {
        expect(parsed.position_ms).toBe(msgDef.expected_position_ms);
      }
      if (msgDef.expected_target !== undefined) {
        expect(parsed.target_device_id).toBe(msgDef.expected_target);
      }
      if (msgDef.expected_reason !== undefined) {
        expect(parsed.reason).toBe(msgDef.expected_reason);
      }
    }
  });

  it('validates single stream rule checks (PRD-42 § 3.4)', () => {
    for (const item of vectors.single_stream_checks) {
      const current = item.current_source_key ? item.current_source_key.trim().toLowerCase() : null;
      const release = item.release_source_key.trim().toLowerCase();
      const mustStop = current !== null && current === release;

      expect(mustStop).toBe(item.must_stop);
    }
  });

  it('validates Xtream fallback URL reconstruction (PRD-42 § 6.2)', () => {
    for (const item of vectors.xtream_url_reconstruction) {
      const server = item.server.replace(/\/$/, '');
      const ext = item.container_ext || 'mp4';
      let url = '';

      if (item.kind === 'live') {
        url = `${server}/live/${item.username}/${item.password}/${item.provider_ref}.ts`;
      } else if (item.kind === 'movie') {
        url = `${server}/movie/${item.username}/${item.password}/${item.provider_ref}.${ext}`;
      } else if (item.kind === 'episode') {
        url = `${server}/series/${item.username}/${item.password}/${item.provider_ref}.${ext}`;
      }

      expect(url).toBe(item.expected_url);
    }
  });
});

