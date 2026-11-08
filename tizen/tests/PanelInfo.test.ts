import { describe, it, expect, vi } from 'vitest';
import { createRoot } from 'solid-js';
import { summarizeStream, codecLabel, channelsLabel, qualityFromHeight } from '../src/core/player/streamInfo';
import { formatDuration, formatRuntime, formatClock, percentOf } from '../src/core/utils/timeFormat';
import { createMiniPlayer } from '../src/core/player/MiniPlayerController';

describe('stream summary', () => {
  // What the TV reported for a real channel (AVPlay getCurrentStreamInfo)
  const real = [
    { type: 'AUDIO', index: 1, extra_info: '{"language":"","channels":"2","sample_rate":"48000","bit_rate":"69000","fourCC":"audio/mpeg"}' },
    { type: 'VIDEO', index: 0, extra_info: '{"fourCC":"video/x-h264","Width":"1920","Height":"1080","Bit_rate":"0"}' },
  ];

  it('reads size, quality and codecs', () => {
    const s = summarizeStream(real)!;
    expect(s.width).toBe(1920);
    expect(s.height).toBe(1080);
    expect(s.quality).toBe('FHD');
    expect(s.videoCodec).toBe('H.264');
    expect(s.audioChannels).toBe('2.0');
  });

  it('returns null while the stream has told nothing', () => {
    expect(summarizeStream(null)).toBeNull();
    expect(summarizeStream([])).toBeNull();
    expect(summarizeStream([{ type: 'TEXT', extra_info: '{}' }])).toBeNull();
  });

  it('survives a malformed extra_info', () => {
    const s = summarizeStream([{ type: 'VIDEO', extra_info: 'not json' }]);
    expect(s).not.toBeNull();
    expect(s!.height).toBe(0);
    expect(s!.quality).toBe('');
  });

  it('names codecs, channel layouts and qualities', () => {
    expect(codecLabel('video/x-h265')).toBe('H.265');
    expect(codecLabel('video/hevc')).toBe('H.265');
    expect(codecLabel('audio/mp4a-latm')).toBe('AAC');
    expect(codecLabel('audio/eac3')).toBe('E-AC3');
    expect(codecLabel('audio/ac3')).toBe('AC3');
    expect(codecLabel('')).toBe('');
    expect(channelsLabel('6')).toBe('5.1');
    expect(channelsLabel(8)).toBe('7.1');
    expect(channelsLabel(1)).toBe('1.0');
    expect(channelsLabel(undefined)).toBe('');
    expect(qualityFromHeight(2160)).toBe('4K');
    expect(qualityFromHeight(1080)).toBe('FHD');
    expect(qualityFromHeight(720)).toBe('HD');
    expect(qualityFromHeight(576)).toBe('SD');
    expect(qualityFromHeight(0)).toBe('');
  });
});

describe('time formatting', () => {
  it('formats a position', () => {
    expect(formatDuration(725000)).toBe('12:05');
    expect(formatDuration(5025000)).toBe('1:23:45');
    expect(formatDuration(-5)).toBe('0:00');
  });
  it('formats a runtime', () => {
    expect(formatRuntime(5520000)).toBe('1 h 32');
    expect(formatRuntime(2700000)).toBe('45 min');
    expect(formatRuntime(0)).toBe('');
  });
  it('formats a clock time', () => {
    const ts = new Date(2026, 10, 8, 21, 5).getTime() / 1000;
    expect(formatClock(ts)).toBe('21:05');
  });
  it('computes a progress percentage', () => {
    expect(percentOf(50, 200)).toBe(25);
    expect(percentOf(500, 200)).toBe(100);
    expect(percentOf(10, 0)).toBe(0);
  });
});

describe('mini player facts while playing', () => {
  it('reads the stream facts and the position, and clears them when stopped', async () => {
    const engine = { play: vi.fn(async () => {}), stopPlayback: vi.fn(), recordRecent: vi.fn() };
    let position = 30000;
    const summary = summarizeStream([{ type: 'VIDEO', extra_info: '{"fourCC":"video/x-h264","Width":"1280","Height":"720"}' }]);
    const player = {
      setDisplayArea: vi.fn(),
      getStreamSummary: () => summary,
      getCurrentTime: () => position,
      getDuration: () => 600000,
    };
    const ctl = createRoot(() => createMiniPlayer({ engine, player, onFullscreen: vi.fn(), startTimeoutMs: 100 }));
    const item = { id: 1 };
    ctl.focus(item);
    await ctl.playItem(item);
    expect(ctl.streamInfo()?.quality).toBe('HD');
    expect(ctl.positionMs()).toBe(30000);
    expect(ctl.durationMs()).toBe(600000);

    position = 45000;
    await vi.waitFor(() => expect(ctl.positionMs()).toBe(45000), { timeout: 2500 }); // refreshed every second

    ctl.stop();
    expect(ctl.streamInfo()).toBeNull();
    expect(ctl.positionMs()).toBe(0);
    expect(ctl.durationMs()).toBe(0);
  });
});
