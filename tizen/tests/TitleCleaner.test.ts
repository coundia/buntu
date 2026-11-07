import { describe, it, expect } from 'vitest';
import { cleanMediaTitle } from '../src/core/utils/titleCleaner';

describe('Universal Media Title Normalizer', () => {
  it('cleans movie titles with provider prefix and noise', () => {
    const res1 = cleanMediaTitle('EAR - Athlete A');
    expect(res1.clean).toBe('Athlete A');

    const res2 = cleanMediaTitle('EAR - Murder to Mercy: The Cyntoia Brown Story');
    expect(res2.clean).toBe('Murder to Mercy: The Cyntoia Brown Story');

    const res3 = cleanMediaTitle('EAR - Mucho Mucho Amor');
    expect(res3.clean).toBe('Mucho Mucho Amor');
  });

  it('cleans series titles with language, year, country, and resolution', () => {
    const res1 = cleanMediaTitle('EN - Tires (2024) (US) [1080p]');
    expect(res1.clean).toBe('Tires');
    expect(res1.year).toBe(2024);

    const res2 = cleanMediaTitle('EN - The Perfect Couple (2024) [1080p]');
    expect(res2.clean).toBe('The Perfect Couple');
    expect(res2.year).toBe(2024);

    const res3 = cleanMediaTitle('EN - Tomorrow And I (2024) [1080p]');
    expect(res3.clean).toBe('Tomorrow And I');
    expect(res3.year).toBe(2024);
  });

  it('cleans live TV channels with country prefixes', () => {
    const ch1 = cleanMediaTitle('AF: Tele Congo');
    expect(ch1.clean).toBe('Tele Congo');

    const ch2 = cleanMediaTitle('AF: Hadi TV4');
    expect(ch2.clean).toBe('Hadi TV4');

    const ch3 = cleanMediaTitle('AF: Lagos TV');
    expect(ch3.clean).toBe('Lagos TV');

    const ch4 = cleanMediaTitle('AF: SuperSport 11');
    expect(ch4.clean).toBe('SuperSport 11');

    const ch5 = cleanMediaTitle('AF:Humanitarian TV (CM)');
    expect(ch5.clean).toBe('Humanitarian TV');

    const ch6 = cleanMediaTitle('AF: Laayoune TV (MA)');
    expect(ch6.clean).toBe('Laayoune TV');
  });

  it('cleans guide EPG sports titles and prefix tags', () => {
    const g1 = cleanMediaTitle('FR - MATCH 2 / UEFA CHAMPIONS LEAGUE');
    expect(g1.clean).toBe('MATCH 2 / UEFA CHAMPIONS LEAGUE');

    const g2 = cleanMediaTitle('EN - MATCH 1');
    expect(g2.clean).toBe('MATCH 1');
  });

  it('gracefully handles empty or edge case strings', () => {
    expect(cleanMediaTitle('').clean).toBe('');
    expect(cleanMediaTitle('   ').clean).toBe('');
    expect(cleanMediaTitle('Gladiator').clean).toBe('Gladiator');
    expect(cleanMediaTitle('Inception (2010)').clean).toBe('Inception');
    expect(cleanMediaTitle('Inception (2010)').year).toBe(2010);
  });
});

