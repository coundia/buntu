import { Component, createSignal, For, onCleanup, onMount, Show } from 'solid-js';
import { spatialNav } from '../../ui/design/SpatialNav';
import { CndEngine } from '../../core/engine/CndEngine';
import { Database, type ItemRecord } from '../../core/storage/Database';
import { describeSourceExpiry, type SourceExpiryInfo } from '../sources/sourceExpiry';
import { describeResume } from './resumeInfo';
import { t, type TranslationKey } from '../../core/i18n';

export type HomeSection = 'live' | 'movies' | 'series';
type HomeDestination = HomeSection | 'sources' | 'devices' | 'settings';

interface HomeViewProps {
  initialSection: HomeSection;
  onOpen: (route: HomeDestination) => void;
  onExit: () => void;
  /** OK on the « Reprendre » card: the last thing watched. */
  onResume?: (item: ItemRecord) => void;
}

const sections: {
  route: HomeSection;
  titleKey: TranslationKey;
  subtitleKey: TranslationKey;
  icon: string;
  detailKey: TranslationKey;
}[] = [
  { route: 'live', titleKey: 'home.liveTitle', subtitleKey: 'home.liveSubtitle', icon: 'live', detailKey: 'home.liveDetail' },
  { route: 'movies', titleKey: 'home.moviesTitle', subtitleKey: 'home.moviesSubtitle', icon: 'movies', detailKey: 'home.moviesDetail' },
  { route: 'series', titleKey: 'home.seriesTitle', subtitleKey: 'home.seriesSubtitle', icon: 'series', detailKey: 'home.seriesDetail' },
];

/** A lightweight entrance: no catalogue, thumbnails, counters or player on this screen. */
export const HomeView: Component<HomeViewProps> = (props) => {
  const [focusId] = spatialNav.getFocusSignal();
  const localTime = () => {
    const now = new Date();
    return `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
  };
  const [time, setTime] = createSignal(localTime());
  const [resume, setResume] = createSignal<ItemRecord | null>(null);
  const [sourceExpiries, setSourceExpiries] = createSignal<{ id: number; name: string; info: SourceExpiryInfo }[]>([]);
  const shortcuts: { route: HomeDestination; titleKey: TranslationKey }[] = [
    { route: 'sources', titleKey: 'home.sources' },
    { route: 'devices', titleKey: 'home.devices' },
    { route: 'settings', titleKey: 'home.settings' },
  ];

  onMount(() => {
    const updateTime = () => setTime(localTime());
    const clock = setInterval(updateTime, 1000);
    document.addEventListener('visibilitychange', updateTime);
    onCleanup(() => {
      clearInterval(clock);
      document.removeEventListener('visibilitychange', updateTime);
    });
    spatialNav.setHeader([]);
    const buildGrid = (withResume: boolean) => {
      const rows = [
        sections.map((section) => ({ id: `home-${section.route}`, onSelect: () => props.onOpen(section.route) })),
        [
          ...shortcuts.map((shortcut) => ({ id: `home-${shortcut.route}`, onSelect: () => props.onOpen(shortcut.route) })),
          { id: 'home-exit', onSelect: props.onExit },
        ],
      ];
      if (withResume) {
        rows.unshift([{ id: 'home-resume', onSelect: () => { const item = resume(); if (item) props.onResume?.(item); } }]);
        spatialNav.setGrid(rows, 0, 0);
      } else {
        spatialNav.setGrid(rows, 0, Math.max(0, sections.findIndex((section) => section.route === props.initialSection)));
      }
    };
    buildGrid(false);
    // Two or three local reads: the home stays instant, the card appears when there is something to resume.
    void (async () => {
      try {
        const last = props.onResume ? await CndEngine.getInstance().getLastWatched() : null;
        if (last) {
          setResume(last);
          buildGrid(true);
        }
      } catch {
        /* nothing to offer */
      }
      try {
        const list = await Database.getInstance().getSources();
        const expiries = list.map((src) => {
          const info = describeSourceExpiry(src);
          return {
            id: src.id,
            name: src.name || t('home.sourceFallback'),
            info: info ?? {
              exp: 0,
              daysLeft: 0,
              dateStr: '',
              status: 'ok' as const,
              label: t('home.noExpiry'), // Sans date d’expiration
            },
          };
        });
        setSourceExpiries(expiries);
      } catch {
        /* ignore source expiry lookup failure */
      }
    })();
  });

  return (
    <section class="buntu-home" aria-labelledby="home-title">
      <header class="buntu-home-brand">
        <img src="./icon.png" alt="" />
        <span>Buntu</span>
        <span class="buntu-home-brand-caption">{t('home.brandCaption')}</span>
        <time class="buntu-home-clock" aria-label={t('home.localTimeAria', { time: time() })}>{time()}</time>
      </header>
      <div class="buntu-home-heading">
        <p>{t('home.welcome')}</p>
        <h1 id="home-title">{t('home.question')}</h1>
      </div>
      <Show when={sourceExpiries().length > 0}>
        <div class="buntu-home-expirations" aria-label={t('home.expirationsAria')}>
          <For each={sourceExpiries()}>{(entry) => (
            <span class={`buntu-home-expiry-pill ${entry.info.status === 'expired' ? 'is-expired' : entry.info.status === 'soon' ? 'is-soon' : ''}`}>
              <strong>{entry.name}</strong> · {entry.info.label}
            </span>
          )}</For>
        </div>
      </Show>
      <Show when={resume()}>
        {(item) => {
          const info = () => describeResume(item());
          return (
            <button
              id="home-resume"
              type="button"
              tabindex="-1"
              aria-label={`${info().kind} : ${info().title}. ${info().action}`}
              class={`buntu-home-resume ${focusId() === 'home-resume' ? 'focused' : ''}`}
              onClick={() => props.onResume?.(item())}
            >
              <span class="buntu-home-resume-play" aria-hidden="true">▶</span>
              <span class="buntu-home-resume-text">
                <span class="buntu-home-resume-label">{t('home.resumeLabel', { kind: info().kind })}</span>
                <span class="buntu-home-resume-title">{info().title}</span>
                <span class="buntu-home-resume-action">{info().action}</span>
              </span>
              <Show when={info().percent !== undefined}>
                <span class="buntu-home-resume-bar" aria-hidden="true">
                  <span class="buntu-home-resume-fill" style={{ width: `${info().percent}%` }} />
                </span>
              </Show>
            </button>
          );
        }}
      </Show>
      <div class="buntu-home-sections">
        <For each={sections}>{(section) => (
          <button
            id={`home-${section.route}`}
            type="button"
            tabindex="-1"
            class={`buntu-home-card buntu-home-card-${section.route} ${focusId() === `home-${section.route}` ? 'focused' : ''}`}
            onClick={() => props.onOpen(section.route)}
          >
            <span class={`buntu-home-symbol buntu-home-symbol-${section.icon}`} aria-hidden="true">
              {section.route === 'live' ? '◉' : section.route === 'movies' ? '▶' : '▤'}
            </span>
            <span class="buntu-home-card-subtitle">{t(section.subtitleKey)}</span>
            <span class="buntu-home-card-title">{t(section.titleKey)}</span>
            <span class="buntu-home-card-detail">{t(section.detailKey)}</span>
            <span class="buntu-home-card-open" aria-hidden="true">{t('home.explore')}</span>
          </button>
        )}</For>
      </div>
      <footer class="buntu-home-footer">
        <div class="buntu-home-shortcuts">
          <For each={shortcuts}>{(shortcut) => (
            <button type="button" tabindex="-1" id={`home-${shortcut.route}`}
              class={`buntu-home-shortcut ${focusId() === `home-${shortcut.route}` ? 'focused' : ''}`}
              onClick={() => props.onOpen(shortcut.route)}>{t(shortcut.titleKey)}</button>
          )}</For>
          <button type="button" tabindex="-1" id="home-exit"
            class={`buntu-home-shortcut ${focusId() === 'home-exit' ? 'focused' : ''}`}
            onClick={props.onExit}>{t('home.exit')}</button>
        </div>
        <p>{t('home.footerChoose')} <span>{t('home.footerOpen')}</span></p>
      </footer>
    </section>
  );
};
