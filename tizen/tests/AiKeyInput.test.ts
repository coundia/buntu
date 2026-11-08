import { describe, it, expect } from 'vitest';
import { describeKeyShape, normalizeApiKey } from '../src/core/ai/keyInput';

describe('normalizeApiKey', () => {
  it('removes spaces, line breaks and zero-width characters added by pasting', () => {
    expect(normalizeApiKey('  AIzaSyAAAA BBBB\nCCCC\r\n ')).toBe('AIzaSyAAAABBBBCCCC');
    expect(normalizeApiKey('AIza​xyz')).toBe('AIzaxyz');
  });

  it('removes quotes around the key', () => {
    expect(normalizeApiKey('"AIzaSyAAAA"')).toBe('AIzaSyAAAA');
    expect(normalizeApiKey("'sk-abc123'")).toBe('sk-abc123');
    expect(normalizeApiKey('“sk-ant-xyz”')).toBe('sk-ant-xyz');
  });

  it('keeps only the key from a pasted header line', () => {
    expect(normalizeApiKey('Authorization: Bearer sk-abc123456789')).toBe('sk-abc123456789');
    expect(normalizeApiKey('Bearer sk-abc123456789')).toBe('sk-abc123456789');
    expect(normalizeApiKey('x-goog-api-key: AIzaSyAAAA')).toBe('AIzaSyAAAA');
    expect(normalizeApiKey('x-api-key: sk-ant-xyz')).toBe('sk-ant-xyz');
  });

  it('handles an empty value', () => {
    expect(normalizeApiKey('')).toBe('');
    expect(normalizeApiKey('   \n ')).toBe('');
  });
});

describe('describeKeyShape', () => {
  it('accepts the usual look of each provider', () => {
    expect(describeKeyShape('gemini', 'AIzaSyD-1234567890abcdefghijklmnopqrstu').plausible).toBe(true);
    expect(describeKeyShape('anthropic', 'sk-ant-api03-abcdefghijklmnop').plausible).toBe(true);
    expect(describeKeyShape('openai_compatible', 'sk-proj-abcdefghijklmnop').plausible).toBe(true);
  });

  it('warns about a wrong provider or a truncated key, without refusing', () => {
    expect(describeKeyShape('gemini', 'sk-abcdefghijklmnopqrstuv').plausible).toBe(false);
    expect(describeKeyShape('anthropic', 'AIzaSyD-1234567890abcdefghij').message).toContain('sk-ant-');
    expect(describeKeyShape('openai_compatible', 'AIzaSyD-1234567890abcdefghij').message).toContain('Gemini');
    expect(describeKeyShape('gemini', 'AIza12').message).toContain('trop courte');
    expect(describeKeyShape('gemini', '').plausible).toBe(false);
  });
});
