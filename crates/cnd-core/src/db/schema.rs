pub const INIT_SQL: &str = r#"
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA mmap_size = 268435456;
PRAGMA cache_size = -32000;
PRAGMA foreign_keys = ON;

-- Sources table
CREATE TABLE IF NOT EXISTS iptv_sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    source_type TEXT NOT NULL, -- 'm3u' | 'xtream'
    url TEXT,
    server TEXT,
    username TEXT,
    password_ref TEXT, -- Reference to Keychain key
    epg_url TEXT,
    exp_date INTEGER,
    max_connections INTEGER,
    active_cons INTEGER,
    account_status TEXT,
    auto_refresh_hours INTEGER DEFAULT 24,
    last_sync_at INTEGER,
    item_count INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

-- Normalized Series catalog (solves the pagination grouping bug)
CREATE TABLE IF NOT EXISTS series_catalog (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER NOT NULL,
    canonical_key TEXT NOT NULL,
    stable_hash TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL,
    group_title TEXT,
    poster_url TEXT,
    backdrop_url TEXT,
    imdb_id TEXT,
    imdb_rating REAL,
    plot TEXT,
    episode_count INTEGER DEFAULT 0,
    season_count INTEGER DEFAULT 0,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY(source_id) REFERENCES iptv_sources(id) ON DELETE CASCADE,
    UNIQUE(source_id, canonical_key)
);
CREATE INDEX IF NOT EXISTS idx_series_stable_hash ON series_catalog(stable_hash);

-- Items table (Channels, Movies, Episodes)
CREATE TABLE IF NOT EXISTS iptv_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER NOT NULL,
    series_id INTEGER,
    stable_hash TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL, -- 'live' | 'movie' | 'episode'
    season_num INTEGER,
    episode_num INTEGER,
    name TEXT NOT NULL,
    name_clean TEXT NOT NULL,
    year INTEGER,
    group_title TEXT,
    tvg_id TEXT,
    tvg_name TEXT,
    logo_url TEXT,
    chno INTEGER,
    country TEXT,
    language TEXT,
    catchup_type TEXT,
    catchup_source TEXT,
    catchup_days INTEGER,
    epg_shift TEXT,
    user_agent TEXT,
    referer TEXT,
    headers_json TEXT,
    host TEXT NOT NULL,
    container_ext TEXT,
    stream_url TEXT NOT NULL,
    imdb_id TEXT,
    imdb_rating REAL,
    plot TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY(source_id) REFERENCES iptv_sources(id) ON DELETE CASCADE,
    FOREIGN KEY(series_id) REFERENCES series_catalog(id) ON DELETE CASCADE
);

-- Covering indexes for ultra-fast pagination and queries
CREATE INDEX IF NOT EXISTS idx_items_kind_group ON iptv_items(kind, group_title, name);
CREATE INDEX IF NOT EXISTS idx_items_kind_host ON iptv_items(kind, host);
CREATE INDEX IF NOT EXISTS idx_items_kind_rating ON iptv_items(kind, imdb_rating DESC);
CREATE INDEX IF NOT EXISTS idx_items_series ON iptv_items(series_id, season_num, episode_num);
CREATE INDEX IF NOT EXISTS idx_items_tvg_id ON iptv_items(tvg_id);

-- FTS5 full text search table
CREATE VIRTUAL TABLE IF NOT EXISTS iptv_items_fts USING fts5(
    name,
    group_title,
    tvg_name,
    content='iptv_items',
    content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
);

-- Triggers for FTS5 synchronization
CREATE TRIGGER IF NOT EXISTS trg_items_ai AFTER INSERT ON iptv_items BEGIN
    INSERT INTO iptv_items_fts(rowid, name, group_title, tvg_name) 
    VALUES (new.id, new.name, new.group_title, new.tvg_name);
END;

CREATE TRIGGER IF NOT EXISTS trg_items_ad AFTER DELETE ON iptv_items BEGIN
    INSERT INTO iptv_items_fts(iptv_items_fts, rowid, name, group_title, tvg_name) 
    VALUES('delete', old.id, old.name, old.group_title, old.tvg_name);
END;

CREATE TRIGGER IF NOT EXISTS trg_items_au AFTER UPDATE ON iptv_items BEGIN
    INSERT INTO iptv_items_fts(iptv_items_fts, rowid, name, group_title, tvg_name) 
    VALUES('delete', old.id, old.name, old.group_title, old.tvg_name);
    INSERT INTO iptv_items_fts(rowid, name, group_title, tvg_name) 
    VALUES (new.id, new.name, new.group_title, new.tvg_name);
END;

-- EPG Programs table
CREATE TABLE IF NOT EXISTS epg_programs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_tvg_id TEXT NOT NULL,
    start_ts INTEGER NOT NULL,
    end_ts INTEGER NOT NULL,
    title TEXT NOT NULL,
    subtitle TEXT,
    description TEXT,
    category TEXT
);
CREATE INDEX IF NOT EXISTS idx_epg_lookup ON epg_programs(channel_tvg_id, start_ts, end_ts);
CREATE UNIQUE INDEX IF NOT EXISTS idx_epg_unique_slot ON epg_programs(channel_tvg_id, start_ts);

-- User Favorites (independent of pagination)
CREATE TABLE IF NOT EXISTS favorites (
    profile_id INTEGER NOT NULL DEFAULT 1,
    stable_hash TEXT NOT NULL,
    item_kind TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(profile_id, stable_hash)
);

-- Items flagged as broken / non-functional by the user or health probes
CREATE TABLE IF NOT EXISTS broken_flags (
    stable_hash TEXT PRIMARY KEY,
    item_kind TEXT NOT NULL,
    flagged_at INTEGER NOT NULL,
    origin TEXT NOT NULL DEFAULT 'user'
);
CREATE INDEX IF NOT EXISTS idx_broken_flags_kind ON broken_flags(item_kind);

-- Stream health tracking from background probes
CREATE TABLE IF NOT EXISTS stream_health (
    stable_hash TEXT PRIMARY KEY,
    status TEXT NOT NULL,
    latency_ms INTEGER,
    checked_at INTEGER NOT NULL,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    last_ok_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_stream_health_checked ON stream_health(checked_at);

-- Deletions awaiting propagation to other devices (iCloud sync, Last-Write-Wins)
CREATE TABLE IF NOT EXISTS sync_tombstones (
    kind TEXT NOT NULL, -- 'favorite' | 'source'
    key TEXT NOT NULL,  -- stable_hash | source uuid
    deleted_at INTEGER NOT NULL,
    PRIMARY KEY (kind, key)
);

-- Watch History & Playback Progress (independent of pagination)
CREATE TABLE IF NOT EXISTS watch_history (
    profile_id INTEGER NOT NULL DEFAULT 1,
    stable_hash TEXT NOT NULL,
    position_ms INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    completed INTEGER DEFAULT 0,
    last_watched_at INTEGER NOT NULL,
    PRIMARY KEY(profile_id, stable_hash)
);

-- Download Manager tables (Multi-segment support)
CREATE TABLE IF NOT EXISTS download_tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT NOT NULL,
    last_real_url TEXT,
    referer TEXT,
    user_agent TEXT,
    headers_json TEXT,
    file_name TEXT NOT NULL,
    save_path TEXT NOT NULL,
    temp_path TEXT NOT NULL,
    total_bytes INTEGER DEFAULT 0,
    downloaded_bytes INTEGER DEFAULT 0,
    accept_ranges INTEGER DEFAULT 0,
    state TEXT DEFAULT 'queued', -- queued, running, paused, completed, error
    speed_bps REAL DEFAULT 0,
    eta_seconds INTEGER DEFAULT 0,
    driver TEXT NOT NULL DEFAULT 'rust',
    platform_resume_data BLOB,
    resume_on_wake INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS download_parts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER NOT NULL,
    part_index INTEGER NOT NULL,
    byte_start INTEGER NOT NULL,
    byte_end INTEGER NOT NULL,
    downloaded_bytes INTEGER DEFAULT 0,
    state TEXT DEFAULT 'idle',
    FOREIGN KEY(task_id) REFERENCES download_tasks(id) ON DELETE CASCADE,
    UNIQUE(task_id, part_index)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_download_parts_task_idx ON download_parts(task_id, part_index);

CREATE TABLE IF NOT EXISTS download_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER NOT NULL,
    timestamp INTEGER NOT NULL,
    level TEXT NOT NULL,
    message TEXT NOT NULL,
    FOREIGN KEY(task_id) REFERENCES download_tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_download_logs_task ON download_logs(task_id, id DESC);

-- Persistent Runtime Settings (PRD-01)
CREATE TABLE IF NOT EXISTS app_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

-- VOD & Series Metadata Cache (PRD-06)
CREATE TABLE IF NOT EXISTS media_metadata_cache (
    lookup_key TEXT PRIMARY KEY,
    imdb_id TEXT,
    title TEXT NOT NULL,
    year TEXT,
    rated TEXT,
    released TEXT,
    runtime TEXT,
    genres TEXT,
    director TEXT,
    actors TEXT,
    plot TEXT,
    language TEXT,
    country TEXT,
    awards TEXT,
    poster_url TEXT,
    imdb_rating REAL,
    imdb_votes TEXT,
    metascore TEXT,
    media_type TEXT,
    fetched_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_metadata_imdb_id ON media_metadata_cache(imdb_id);

-- PVR Recordings (PRD-19)
CREATE TABLE IF NOT EXISTS recordings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id INTEGER NOT NULL,
    channel_tvg_id TEXT,
    channel_name TEXT NOT NULL,
    title TEXT NOT NULL,
    subtitle TEXT,
    stream_url TEXT NOT NULL,
    start_ts INTEGER NOT NULL,
    end_ts INTEGER NOT NULL,
    pre_padding_s INTEGER NOT NULL DEFAULT 120,
    post_padding_s INTEGER NOT NULL DEFAULT 300,
    state TEXT NOT NULL DEFAULT 'scheduled',
    file_path TEXT,
    bytes_written INTEGER NOT NULL DEFAULT 0,
    rule_id INTEGER,
    error TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_recordings_state_start ON recordings(state, start_ts);
CREATE INDEX IF NOT EXISTS idx_recordings_channel ON recordings(channel_tvg_id);

-- Series-Link Rules (PRD-19)
CREATE TABLE IF NOT EXISTS recording_series_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_tvg_id TEXT,
    title_key TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_recording_rules_title ON recording_series_rules(title_key);

-- Profiles (PRD-20)
CREATE TABLE IF NOT EXISTS profiles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    avatar TEXT NOT NULL DEFAULT 'person.crop.circle',
    is_kids INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
);

-- Hidden Groups (Bouquets) (PRD-20)
CREATE TABLE IF NOT EXISTS hidden_groups (
    profile_id INTEGER NOT NULL DEFAULT 1,
    kind TEXT NOT NULL,
    group_key TEXT NOT NULL,
    PRIMARY KEY(profile_id, kind, group_key)
);

-- Hidden Items (PRD-20)
CREATE TABLE IF NOT EXISTS hidden_items (
    profile_id INTEGER NOT NULL DEFAULT 1,
    stable_hash TEXT NOT NULL,
    PRIMARY KEY(profile_id, stable_hash)
);

-- Custom Ordering (PRD-20)
CREATE TABLE IF NOT EXISTS custom_order (
    profile_id INTEGER NOT NULL DEFAULT 1,
    scope TEXT NOT NULL,
    key TEXT NOT NULL,
    position INTEGER NOT NULL,
    PRIMARY KEY(profile_id, scope, key)
);

-- Favorite Folders (PRD-20)
CREATE TABLE IF NOT EXISTS favorite_folders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    profile_id INTEGER NOT NULL DEFAULT 1,
    name TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
);

-- Favorite Folder Items (PRD-20)
CREATE TABLE IF NOT EXISTS favorite_folder_items (
    folder_id INTEGER NOT NULL,
    stable_hash TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(folder_id, stable_hash),
    FOREIGN KEY(folder_id) REFERENCES favorite_folders(id) ON DELETE CASCADE
);

-- Sagas & Universes (PRD-27)
CREATE TABLE IF NOT EXISTS sagas (
    saga_key TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    level TEXT NOT NULL DEFAULT 'saga', -- 'saga' | 'universe'
    source TEXT NOT NULL DEFAULT 'local', -- 'local' | 'tmdb' | 'llm'
    confidence REAL NOT NULL DEFAULT 1.0,
    fetched_at INTEGER NOT NULL,
    missing_titles TEXT -- JSON array of strings
);

CREATE TABLE IF NOT EXISTS saga_members (
    saga_key TEXT NOT NULL,
    work_key TEXT NOT NULL, -- imdb_id or normalized title + year
    release_index INTEGER NOT NULL,
    story_index INTEGER, -- nullable
    PRIMARY KEY (saga_key, work_key),
    FOREIGN KEY (saga_key) REFERENCES sagas(saga_key) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_saga_members_work ON saga_members(work_key);

-- Recommendation Dismissals ("Pas intéressé") (PRD-27)
CREATE TABLE IF NOT EXISTS recommendation_dismissals (
    profile_id INTEGER NOT NULL DEFAULT 1,
    stable_hash TEXT NOT NULL,
    dismissed_at INTEGER NOT NULL,
    PRIMARY KEY(profile_id, stable_hash)
);

-- Per-kind recommendations (PRD-34)
-- "Moins de ce genre": a signed weight on one taste feature, per profile and per kind.
CREATE TABLE IF NOT EXISTS reco_feedback (
    profile_id INTEGER NOT NULL DEFAULT 1,
    kind TEXT NOT NULL, -- 'movie' | 'series' | 'live'
    feature TEXT NOT NULL,
    delta REAL NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(profile_id, kind, feature)
);

-- Answer of the AI re-rank, kept with REAL ids (never the opaque ones sent to the model).
CREATE TABLE IF NOT EXISTS reco_ai_cache (
    profile_id INTEGER NOT NULL DEFAULT 1,
    kind TEXT NOT NULL,
    provider TEXT NOT NULL,
    candidates_hash TEXT NOT NULL,
    picks TEXT NOT NULL, -- JSON
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY(profile_id, kind)
);

-- Calls made to a remote provider for recommendations, per day (daily cap).
CREATE TABLE IF NOT EXISTS reco_ai_usage (
    day TEXT NOT NULL,
    provider TEXT NOT NULL,
    calls INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(day, provider)
);
CREATE INDEX IF NOT EXISTS idx_series_rating ON series_catalog(imdb_rating DESC);
CREATE INDEX IF NOT EXISTS idx_series_updated ON series_catalog(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_history_profile_recent ON watch_history(profile_id, last_watched_at);

-- Local Media Library (PRD-32)
CREATE TABLE IF NOT EXISTS library_folders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    display_name TEXT NOT NULL,
    path TEXT NOT NULL,
    bookmark BLOB,
    include_subfolders INTEGER NOT NULL DEFAULT 1,
    kinds TEXT NOT NULL DEFAULT 'video,audio,image',
    state TEXT NOT NULL DEFAULT 'ok',
    item_count INTEGER NOT NULL DEFAULT 0,
    last_scan_at INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS library_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    folder_id INTEGER NOT NULL,
    rel_path TEXT NOT NULL,
    kind TEXT NOT NULL, -- 'video' | 'audio' | 'image'
    size INTEGER NOT NULL,
    mtime INTEGER NOT NULL,
    fingerprint TEXT NOT NULL,
    title TEXT,
    duration_ms INTEGER,
    width INTEGER,
    height INTEGER,
    codec TEXT,
    artist TEXT,
    album TEXT,
    album_artist TEXT,
    track_no INTEGER,
    disc_no INTEGER,
    genre TEXT,
    year INTEGER,
    taken_at INTEGER,
    thumbnail_path TEXT,
    subtitles_json TEXT,
    metadata_state TEXT NOT NULL DEFAULT 'pending',
    added_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY(folder_id) REFERENCES library_folders(id) ON DELETE CASCADE,
    UNIQUE(folder_id, rel_path)
);
CREATE INDEX IF NOT EXISTS idx_library_items_folder ON library_items(folder_id);
CREATE INDEX IF NOT EXISTS idx_library_items_kind ON library_items(kind);
CREATE INDEX IF NOT EXISTS idx_library_items_fingerprint ON library_items(fingerprint);
CREATE INDEX IF NOT EXISTS idx_library_items_meta_state ON library_items(metadata_state);
CREATE INDEX IF NOT EXISTS idx_library_items_artist ON library_items(artist);
CREATE INDEX IF NOT EXISTS idx_library_items_album ON library_items(album);

CREATE VIRTUAL TABLE IF NOT EXISTS library_items_fts USING fts5(
    title,
    artist,
    album,
    rel_path,
    content='library_items',
    content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS trg_library_items_ai AFTER INSERT ON library_items BEGIN
    INSERT INTO library_items_fts(rowid, title, artist, album, rel_path)
    VALUES (new.id, new.title, new.artist, new.album, new.rel_path);
END;

CREATE TRIGGER IF NOT EXISTS trg_library_items_ad AFTER DELETE ON library_items BEGIN
    INSERT INTO library_items_fts(library_items_fts, rowid, title, artist, album, rel_path)
    VALUES ('delete', old.id, old.title, old.artist, old.album, old.rel_path);
END;

CREATE TRIGGER IF NOT EXISTS trg_library_items_au AFTER UPDATE ON library_items BEGIN
    INSERT INTO library_items_fts(library_items_fts, rowid, title, artist, album, rel_path)
    VALUES ('delete', old.id, old.title, old.artist, old.album, old.rel_path);
    INSERT INTO library_items_fts(rowid, title, artist, album, rel_path)
    VALUES (new.id, new.title, new.artist, new.album, new.rel_path);
END;

CREATE TABLE IF NOT EXISTS library_progress (
    profile_id INTEGER NOT NULL DEFAULT 1,
    fingerprint TEXT NOT NULL,
    position_ms INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    completed INTEGER NOT NULL DEFAULT 0,
    last_played_at INTEGER NOT NULL,
    PRIMARY KEY(profile_id, fingerprint)
);

CREATE TABLE IF NOT EXISTS library_playlists (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS library_playlist_items (
    playlist_id INTEGER NOT NULL,
    item_id INTEGER NOT NULL,
    position INTEGER NOT NULL,
    PRIMARY KEY(playlist_id, item_id),
    FOREIGN KEY(playlist_id) REFERENCES library_playlists(id) ON DELETE CASCADE,
    FOREIGN KEY(item_id) REFERENCES library_items(id) ON DELETE CASCADE
);
"#;

