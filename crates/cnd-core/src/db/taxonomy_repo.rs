//! Storage and queries of the normalised categories (PRD-33 § 5): classification of stored items,
//! theme borrowing through the `tvg-id`, facets by country / theme, and the user's corrections.
//! No classification rule lives here: they are in `crate::taxonomy`.

use crate::db::catalog_repo::FacetCount;
use crate::db::{chrono_now_ts, DatabaseManager, DbError};
use crate::taxonomy::{
    classify_with_override, ClassifyInput, Theme, ThemeSource, TaxonomyOverride, TAXONOMY_VERSION,
};
use rusqlite::{params, Connection};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};

const TAXONOMY_VERSION_KEY: &str = "taxonomy_version";
const PAGE_SIZE: i64 = 5_000;

/// Country and theme restrictions added to a catalogue query (PRD-33 § 5.4). All `None` = no filter.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct TaxonomyFilter {
    /// ISO code, `INT`, or an empty string for "country unknown".
    pub country: Option<String>,
    pub theme: Option<String>,
    /// Only with `theme`. Ignored for series, which keep their main theme only.
    pub subtheme: Option<String>,
}

impl TaxonomyFilter {
    pub fn is_empty(&self) -> bool {
        self.country.is_none() && self.theme.is_none()
    }

    /// SQL conditions (each starting with `AND`) for items (`series == false`, alias with `id`,
    /// `tx_country`) or series (`tx_country`, `tx_theme`). Values are validated and inlined: a value
    /// that is not a known code makes the condition false instead of reaching the SQL text.
    pub(crate) fn sql(&self, alias: &str, series: bool) -> String {
        let mut out = String::new();
        if let Some(country) = &self.country {
            let country = country.trim().to_ascii_uppercase();
            if country.is_empty() {
                out.push_str(&format!(" AND {alias}.tx_country IS NULL"));
            } else if country == "INT" || (country.len() == 2 && country.chars().all(|c| c.is_ascii_uppercase())) {
                out.push_str(&format!(" AND {alias}.tx_country = '{country}'"));
            } else {
                out.push_str(" AND 1 = 0");
            }
        }
        if let Some(theme) = &self.theme {
            match Theme::parse(theme.trim()) {
                None => out.push_str(" AND 1 = 0"),
                Some(theme) if series => out.push_str(&format!(" AND {alias}.tx_theme = '{}'", theme.as_str())),
                Some(theme) => {
                    let sub = match self.subtheme.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                        None => String::new(),
                        Some(s) if s.chars().all(|c| c.is_ascii_lowercase()) => format!(" AND t.subtheme = '{s}'"),
                        Some(_) => " AND 1 = 0".to_string(),
                    };
                    out.push_str(&format!(
                        " AND EXISTS (SELECT 1 FROM item_themes t WHERE t.item_id = {alias}.id AND t.theme = '{}'{sub})",
                        theme.as_str()
                    ));
                }
            }
        }
        out
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CategoryAxis {
    Country,
    Theme,
    Provider,
}

/// One entry of the category column: a country, a theme or a provider category.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CategoryFacet {
    /// `FR` / `INT` / `` (unknown country), a theme id, or the raw provider label.
    pub key: String,
    pub count: u32,
    /// Sub-themes of a theme (axis `Theme`, live and movies only).
    pub subkeys: Vec<FacetCount>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TaxonomyStatus {
    pub version: u32,
    pub stored_version: u32,
    pub live_total: u32,
    pub live_without_country: u32,
    pub live_without_theme: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ClassifyReport {
    pub items: u64,
    pub series: u64,
    pub borrowed: u64,
}

/// The columns the classifier reads from a stored item.
struct StoredItem {
    id: i64,
    stable_hash: String,
    kind: String,
    group_title: Option<String>,
    tvg_id: Option<String>,
    name: String,
    country: Option<String>,
}

enum Scope {
    All,
    Source(i64),
    SeriesEpisodes(i64),
    Hash(String),
}

impl Scope {
    fn params(&self) -> (Option<i64>, Option<i64>, Option<&str>) {
        match self {
            Scope::All => (None, None, None),
            Scope::Source(id) => (Some(*id), None, None),
            Scope::SeriesEpisodes(id) => (None, Some(*id), None),
            Scope::Hash(h) => (None, None, Some(h)),
        }
    }
}

/// `tx_theme` of a series row: the main theme only (series have no `item_themes` rows).
fn series_theme_sql(alias: &str) -> String {
    format!("{alias}.tx_theme")
}

/// Same visibility rules as `get_groups` / `query_catalog` (hidden bouquets, adult, kids profile),
/// for a table aliased `alias` and a catalogue kind written as a trusted literal.
fn visibility_sql(alias: &str, kind_literal: &str) -> String {
    format!(
        " AND NOT EXISTS (SELECT 1 FROM hidden_groups h WHERE h.profile_id = (SELECT id FROM temp.active_profile) AND h.kind = {kind_literal} AND h.group_key = LOWER(TRIM({alias}.group_title))) \
         AND (((SELECT show_adult FROM temp.catalog_flags) = 1 AND (SELECT kids_only FROM temp.catalog_flags) = 0) OR NOT is_adult_group({alias}.group_title)) \
         AND ((SELECT kids_only FROM temp.catalog_flags) = 0 OR EXISTS (SELECT 1 FROM kids_allowed_groups k WHERE k.profile_id = (SELECT id FROM temp.active_profile) AND k.kind = {kind_literal} AND k.group_key = LOWER(TRIM({alias}.group_title))))"
    )
}

fn load_overrides(conn: &Connection) -> Result<HashMap<String, TaxonomyOverride>, DbError> {
    let mut stmt = conn.prepare("SELECT stable_hash, country, themes FROM taxonomy_overrides")?;
    let rows = stmt.query_map([], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, Option<String>>(2)?))
    })?;
    let mut out = HashMap::new();
    for row in rows {
        let (hash, country, themes) = row?;
        let themes = themes.map(|t| t.split(',').filter_map(|s| Theme::parse(s.trim())).collect::<Vec<_>>());
        out.insert(hash, TaxonomyOverride { country, themes });
    }
    Ok(out)
}

fn stored_version(conn: &Connection) -> u32 {
    conn.query_row("SELECT value FROM app_settings WHERE key = ?1", params![TAXONOMY_VERSION_KEY], |r| {
        r.get::<_, String>(0)
    })
    .ok()
    .and_then(|v| v.parse().ok())
    .unwrap_or(0)
}

/// Key under which two channels are the same channel: `DHA.tr@SD` and `DHA.tr` match.
fn tvg_key(tvg_id: &str) -> Option<String> {
    let key = tvg_id.split('@').next()?.trim().to_lowercase();
    (!key.is_empty()).then_some(key)
}

impl DatabaseManager {
    /// Classifies the stored items of `scope` page by page (one transaction per page, so the
    /// connection is shared with the rest of the app between pages).
    fn classify_items(
        &self,
        scope: &Scope,
        progress: &dyn Fn(u64, u64),
        cancel: &AtomicBool,
    ) -> Result<u64, DbError> {
        let (source, series, hash) = scope.params();
        let total: i64 = self.with_conn(|conn| {
            Ok(conn.query_row(
                "SELECT COUNT(*) FROM iptv_items
                 WHERE (?1 IS NULL OR source_id = ?1) AND (?2 IS NULL OR series_id = ?2) AND (?3 IS NULL OR stable_hash = ?3)",
                params![source, series, hash],
                |r| r.get(0),
            )?)
        })?;
        let overrides = self.with_conn(load_overrides)?;
        let (mut last_id, mut done) = (0i64, 0u64);
        loop {
            if cancel.load(Ordering::Relaxed) {
                break;
            }
            let page = self.with_conn_mut(|conn| {
                let tx = conn.transaction()?;
                let rows: Vec<StoredItem> = {
                    let mut stmt = tx.prepare_cached(
                        "SELECT id, stable_hash, kind, group_title, tvg_id, name, country FROM iptv_items
                         WHERE id > ?4 AND (?1 IS NULL OR source_id = ?1) AND (?2 IS NULL OR series_id = ?2) AND (?3 IS NULL OR stable_hash = ?3)
                         ORDER BY id LIMIT ?5",
                    )?;
                    let mapped = stmt.query_map(params![source, series, hash, last_id, PAGE_SIZE], |r| {
                        Ok(StoredItem {
                            id: r.get(0)?,
                            stable_hash: r.get(1)?,
                            kind: r.get(2)?,
                            group_title: r.get(3)?,
                            tvg_id: r.get(4)?,
                            name: r.get(5)?,
                            country: r.get(6)?,
                        })
                    })?;
                    mapped.collect::<Result<_, _>>()?
                };
                {
                    let mut delete = tx.prepare_cached("DELETE FROM item_themes WHERE item_id = ?1")?;
                    let mut update = tx.prepare_cached(
                        "UPDATE iptv_items SET tx_country = ?2, tx_country_src = ?3, tx_theme = ?4 WHERE id = ?1",
                    )?;
                    let mut insert = tx.prepare_cached(
                        "INSERT INTO item_themes (item_id, theme, subtheme, src) VALUES (?1, ?2, ?3, ?4)",
                    )?;
                    for item in &rows {
                        let id = &item.id;
                        let c = classify_with_override(
                            &ClassifyInput {
                                kind: &item.kind,
                                group_title: item.group_title.as_deref(),
                                tvg_id: item.tvg_id.as_deref(),
                                name: &item.name,
                                country_attr: item.country.as_deref().filter(|c| !c.trim().is_empty()),
                            },
                            overrides.get(&item.stable_hash),
                        );
                        update.execute(params![
                            id,
                            c.country.as_ref().map(|m| m.code.as_str()),
                            c.country.as_ref().map(|m| m.source.as_str()),
                            c.primary_theme().as_str()
                        ])?;
                        delete.execute(params![id])?;
                        for tag in &c.themes {
                            insert.execute(params![id, tag.theme.as_str(), tag.subtheme, tag.source.as_str()])?;
                        }
                    }
                }
                tx.commit()?;
                Ok(rows.last().map(|r| (r.id, rows.len() as u64)))
            })?;
            let Some((max_id, n)) = page else { break };
            last_id = max_id;
            done += n;
            progress(done, total.max(0) as u64);
            if (n as i64) < PAGE_SIZE {
                break;
            }
        }
        Ok(done)
    }

    /// Series rows carry a country and a main theme only.
    fn classify_series(&self, scope: &Scope) -> Result<u64, DbError> {
        let (source, _, hash) = scope.params();
        if matches!(scope, Scope::SeriesEpisodes(_)) {
            return Ok(0);
        }
        let overrides = self.with_conn(load_overrides)?;
        self.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            let rows: Vec<(i64, String, Option<String>, String)> = {
                let mut stmt = tx.prepare_cached(
                    "SELECT id, stable_hash, group_title, title FROM series_catalog
                     WHERE (?1 IS NULL OR source_id = ?1) AND (?2 IS NULL OR stable_hash = ?2)",
                )?;
                let mapped = stmt.query_map(params![source, hash], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
                mapped.collect::<Result<_, _>>()?
            };
            {
                let mut update = tx.prepare_cached("UPDATE series_catalog SET tx_country = ?2, tx_theme = ?3 WHERE id = ?1")?;
                for (id, stable_hash, group, title) in &rows {
                    let c = classify_with_override(
                        &ClassifyInput { kind: "series", group_title: group.as_deref(), tvg_id: None, name: title, country_attr: None },
                        overrides.get(stable_hash),
                    );
                    update.execute(params![id, c.country.as_ref().map(|m| m.code.as_str()), c.primary_theme().as_str()])?;
                }
            }
            tx.commit()?;
            Ok(rows.len() as u64)
        })
    }

    /// A channel with no theme of its own (`other`) takes the theme of another stored channel with
    /// the same `tvg-id` (PRD-33 lot 33.2): `Italy` playlists carry no theme, the same channel in a
    /// themed playlist does. Items the user corrected are left alone.
    pub fn borrow_themes_by_tvg_id(&self) -> Result<u64, DbError> {
        self.with_conn_mut(|conn| {
            let mut donors: HashMap<String, HashMap<String, u32>> = HashMap::new();
            {
                let mut stmt = conn.prepare(
                    "SELECT tvg_id, tx_theme FROM iptv_items
                     WHERE kind = 'live' AND tvg_id IS NOT NULL AND tvg_id != ''
                       AND tx_theme IS NOT NULL AND tx_theme NOT IN ('other', 'general', 'adult')",
                )?;
                let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
                for row in rows {
                    let (tvg_id, theme) = row?;
                    if let Some(key) = tvg_key(&tvg_id) {
                        *donors.entry(key).or_default().entry(theme).or_default() += 1;
                    }
                }
            }
            if donors.is_empty() {
                return Ok(0);
            }
            let receivers: Vec<(i64, String)> = {
                let mut stmt = conn.prepare(
                    "SELECT id, tvg_id FROM iptv_items
                     WHERE kind = 'live' AND tx_theme = 'other' AND tvg_id IS NOT NULL AND tvg_id != ''
                       AND stable_hash NOT IN (SELECT stable_hash FROM taxonomy_overrides)",
                )?;
                let mapped = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
                mapped.collect::<Result<_, _>>()?
            };
            let tx = conn.transaction()?;
            let mut borrowed = 0u64;
            {
                let mut update = tx.prepare_cached("UPDATE iptv_items SET tx_theme = ?2 WHERE id = ?1")?;
                let mut delete = tx.prepare_cached("DELETE FROM item_themes WHERE item_id = ?1")?;
                let mut insert = tx.prepare_cached(
                    "INSERT INTO item_themes (item_id, theme, subtheme, src) VALUES (?1, ?2, NULL, ?3)",
                )?;
                for (id, tvg_id) in receivers {
                    let Some(counts) = tvg_key(&tvg_id).and_then(|k| donors.get(&k)) else { continue };
                    // Most frequent theme; ties broken by name so the result never depends on map order.
                    let Some((theme, _)) = counts.iter().max_by(|a, b| a.1.cmp(b.1).then_with(|| b.0.cmp(a.0))) else { continue };
                    update.execute(params![id, theme])?;
                    delete.execute(params![id])?;
                    insert.execute(params![id, theme, ThemeSource::TvgId.as_str()])?;
                    borrowed += 1;
                }
            }
            tx.commit()?;
            Ok(borrowed)
        })
    }

    fn classify_scope(&self, scope: Scope, progress: &dyn Fn(u64, u64), cancel: &AtomicBool) -> Result<ClassifyReport, DbError> {
        let items = self.classify_items(&scope, progress, cancel)?;
        let series = self.classify_series(&scope)?;
        let borrowed = if matches!(scope, Scope::Hash(_) | Scope::SeriesEpisodes(_)) { 0 } else { self.borrow_themes_by_tvg_id()? };
        Ok(ClassifyReport { items, series, borrowed })
    }

    /// Called at the end of an M3U or Xtream refresh of `source_id`.
    pub fn classify_source(&self, source_id: i64) -> Result<ClassifyReport, DbError> {
        self.with_conn(|conn| {
            // Items replaced by a refresh leave their theme rows behind when foreign keys are off.
            conn.execute("DELETE FROM item_themes WHERE item_id NOT IN (SELECT id FROM iptv_items)", [])?;
            Ok(())
        })?;
        self.classify_scope(Scope::Source(source_id), &|_, _| {}, &AtomicBool::new(false))
    }

    /// Episodes added to the catalogue after the first Xtream refresh.
    pub fn classify_series_episodes(&self, series_id: i64) -> Result<u64, DbError> {
        Ok(self.classify_scope(Scope::SeriesEpisodes(series_id), &|_, _| {}, &AtomicBool::new(false))?.items)
    }

    /// Reclassifies the whole catalogue from the stored columns, without refreshing any source.
    pub fn reclassify_all(&self, progress: &dyn Fn(u64, u64), cancel: &AtomicBool) -> Result<ClassifyReport, DbError> {
        self.with_conn(|conn| {
            conn.execute("DELETE FROM item_themes WHERE item_id NOT IN (SELECT id FROM iptv_items)", [])?;
            Ok(())
        })?;
        let report = self.classify_scope(Scope::All, progress, cancel)?;
        if !cancel.load(Ordering::Relaxed) {
            self.set_stored_taxonomy_version(TAXONOMY_VERSION)?;
        }
        Ok(report)
    }

    /// Reclassifies when the stored rules are older than the code (first launch after the update
    /// included). Returns whether it ran.
    pub fn ensure_taxonomy_current(&self, progress: &dyn Fn(u64, u64), cancel: &AtomicBool) -> Result<bool, DbError> {
        if self.stored_taxonomy_version()? >= TAXONOMY_VERSION {
            return Ok(false);
        }
        // A new, empty catalogue has nothing to reclassify: record the version and stay silent.
        if !self.catalog_has_items() {
            self.set_stored_taxonomy_version(TAXONOMY_VERSION)?;
            return Ok(false);
        }
        self.reclassify_all(progress, cancel)?;
        Ok(true)
    }

    pub fn catalog_has_items(&self) -> bool {
        self.with_conn(|conn| {
            Ok(conn.query_row("SELECT EXISTS(SELECT 1 FROM iptv_items) OR EXISTS(SELECT 1 FROM series_catalog)", [], |r| r.get(0))?)
        })
        .unwrap_or(true)
    }

    pub fn stored_taxonomy_version(&self) -> Result<u32, DbError> {
        self.with_conn(|conn| Ok(stored_version(conn)))
    }

    fn set_stored_taxonomy_version(&self, version: u32) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute(
                "INSERT INTO app_settings (key, value, updated_at) VALUES (?1, ?2, ?3)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
                params![TAXONOMY_VERSION_KEY, version.to_string(), chrono_now_ts()],
            )?;
            Ok(())
        })
    }

    pub fn taxonomy_status(&self) -> Result<TaxonomyStatus, DbError> {
        self.with_conn(|conn| {
            let (total, no_country, no_theme): (u32, u32, u32) = conn.query_row(
                "SELECT COUNT(*), COALESCE(SUM(tx_country IS NULL), 0), COALESCE(SUM(tx_theme IS NULL OR tx_theme = 'other'), 0)
                 FROM iptv_items WHERE kind = 'live'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?;
            Ok(TaxonomyStatus {
                version: TAXONOMY_VERSION,
                stored_version: stored_version(conn),
                live_total: total,
                live_without_country: no_country,
                live_without_theme: no_theme,
            })
        })
    }

    /// Stores (or replaces) a correction and applies it to the item at once. `themes` are theme ids;
    /// unknown ids are refused so the closed list stays closed.
    pub fn set_taxonomy_override(
        &self,
        stable_hash: &str,
        country: Option<&str>,
        themes: Option<&[String]>,
    ) -> Result<(), DbError> {
        let country = country.map(|c| c.trim().to_ascii_uppercase()).filter(|c| !c.is_empty());
        if let Some(c) = &country {
            if !(c == "INT" || (c.len() == 2 && c.chars().all(|ch| ch.is_ascii_uppercase()))) {
                return Err(DbError::Query(format!("Unknown country code '{c}'")));
            }
        }
        let themes = match themes {
            None => None,
            Some(list) => {
                let mut ids = Vec::new();
                for t in list {
                    let theme = Theme::parse(t.trim()).ok_or_else(|| DbError::Query(format!("Unknown theme '{t}'")))?;
                    ids.push(theme.as_str());
                }
                (!ids.is_empty()).then(|| ids.join(","))
            }
        };
        if country.is_none() && themes.is_none() {
            return self.clear_taxonomy_override(stable_hash);
        }
        self.with_conn(|conn| {
            conn.execute(
                "INSERT INTO taxonomy_overrides (stable_hash, country, themes, updated_at) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(stable_hash) DO UPDATE SET country = excluded.country, themes = excluded.themes, updated_at = excluded.updated_at",
                params![stable_hash, country, themes, chrono_now_ts()],
            )?;
            Ok(())
        })?;
        self.reclassify_hash(stable_hash)
    }

    pub fn clear_taxonomy_override(&self, stable_hash: &str) -> Result<(), DbError> {
        self.with_conn(|conn| {
            conn.execute("DELETE FROM taxonomy_overrides WHERE stable_hash = ?1", params![stable_hash])?;
            Ok(())
        })?;
        self.reclassify_hash(stable_hash)
    }

    fn reclassify_hash(&self, stable_hash: &str) -> Result<(), DbError> {
        self.classify_scope(Scope::Hash(stable_hash.to_string()), &|_, _| {}, &AtomicBool::new(false))?;
        // Without the donor pass an uncorrected channel would lose a borrowed theme here.
        self.borrow_themes_by_tvg_id()?;
        Ok(())
    }

    /// Entries of the category column for `axis`, with the filters of the other axis applied
    /// (PRD-33 § 5.4). `kind` is `live`, `movie` or `series`. Same visibility rules as `get_groups`.
    pub fn get_category_facets(
        &self,
        kind: &str,
        axis: CategoryAxis,
        source_id: Option<i64>,
        filter: &TaxonomyFilter,
    ) -> Result<Vec<CategoryFacet>, DbError> {
        if !matches!(kind, "live" | "movie" | "series") {
            return Err(DbError::Query(format!("Unknown catalogue kind '{kind}'")));
        }
        let series = kind == "series";
        let (table, alias) = if series { ("series_catalog", "sc") } else { ("iptv_items", "i") };
        let kind_filter = if series { String::new() } else { format!("{alias}.kind = '{kind}' AND ") };
        let visibility = visibility_sql(alias, &format!("'{kind}'"));
        match axis {
            CategoryAxis::Provider => Ok(self
                .get_groups(kind, source_id, false)?
                .into_iter()
                .map(|g| CategoryFacet { key: g.value, count: g.count, subkeys: Vec::new() })
                .collect()),
            CategoryAxis::Country => {
                // The country list is narrowed by the chosen theme only.
                let narrowed = TaxonomyFilter { country: None, theme: filter.theme.clone(), subtheme: filter.subtheme.clone() };
                let extra = narrowed.sql(alias, series);
                let sql = format!(
                    "SELECT COALESCE({alias}.tx_country, ''), COUNT(*) FROM {table} {alias}
                     WHERE {kind_filter}(?1 IS NULL OR {alias}.source_id = ?1){extra}{visibility}
                     GROUP BY 1 ORDER BY 2 DESC, 1"
                );
                self.with_conn(|conn| {
                    let mut stmt = conn.prepare(&sql)?;
                    let rows = stmt.query_map(params![source_id], |r| {
                        Ok(CategoryFacet { key: r.get(0)?, count: r.get(1)?, subkeys: Vec::new() })
                    })?;
                    Ok(rows.collect::<Result<Vec<_>, _>>()?)
                })
            }
            CategoryAxis::Theme => {
                // The theme list is narrowed by the chosen country only.
                let narrowed = TaxonomyFilter { country: filter.country.clone(), theme: None, subtheme: None };
                let extra = narrowed.sql(alias, series);
                self.with_conn(|conn| {
                    if series {
                        let theme = series_theme_sql(alias);
                        let sql = format!(
                            "SELECT COALESCE({theme}, 'other'), COUNT(*) FROM {table} {alias}
                             WHERE (?1 IS NULL OR {alias}.source_id = ?1){extra}{visibility}
                             GROUP BY 1 ORDER BY 2 DESC, 1"
                        );
                        let mut stmt = conn.prepare(&sql)?;
                        let rows = stmt.query_map(params![source_id], |r| {
                            Ok(CategoryFacet { key: r.get(0)?, count: r.get(1)?, subkeys: Vec::new() })
                        })?;
                        return Ok(rows.collect::<Result<Vec<_>, _>>()?);
                    }
                    let sql = format!(
                        "SELECT t.theme, t.subtheme, COUNT(*) FROM iptv_items {alias}
                         JOIN item_themes t ON t.item_id = {alias}.id
                         WHERE {kind_filter}(?1 IS NULL OR {alias}.source_id = ?1){extra}{visibility}
                         GROUP BY t.theme, t.subtheme"
                    );
                    let mut stmt = conn.prepare(&sql)?;
                    let rows = stmt.query_map(params![source_id], |r| {
                        Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, u32>(2)?))
                    })?;
                    // An item has at most one sub-theme per theme (primary key `(item_id, theme)`), so
                    // the rows of one theme add up to its total.
                    let mut totals: HashMap<String, u32> = HashMap::new();
                    let mut subs: HashMap<String, Vec<FacetCount>> = HashMap::new();
                    for row in rows {
                        let (theme, sub, count) = row?;
                        *totals.entry(theme.clone()).or_default() += count;
                        if let Some(sub) = sub {
                            subs.entry(theme).or_default().push(FacetCount { value: sub, count });
                        }
                    }
                    let mut out: Vec<CategoryFacet> = totals
                        .into_iter()
                        .map(|(key, count)| {
                            let mut subkeys = subs.remove(&key).unwrap_or_default();
                            subkeys.sort_by(|a, b| b.count.cmp(&a.count).then_with(|| a.value.cmp(&b.value)));
                            CategoryFacet { key, count, subkeys }
                        })
                        .collect();
                    out.sort_by(|a, b| b.count.cmp(&a.count).then_with(|| a.key.cmp(&b.key)));
                    Ok(out)
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::catalog_repo::{CatalogFilter, SortField};

    struct Row<'a> {
        hash: &'a str,
        kind: &'a str,
        name: &'a str,
        group: &'a str,
        tvg_id: &'a str,
        country: &'a str,
    }

    fn live<'a>(hash: &'a str, name: &'a str, group: &'a str, tvg_id: &'a str) -> Row<'a> {
        Row { hash, kind: "live", name, group, tvg_id, country: "" }
    }

    fn db_with(rows: &[Row<'_>]) -> (DatabaseManager, i64) {
        let db = DatabaseManager::open_in_memory().expect("in-memory db");
        let source = db.add_source("S", "m3u", Some("http://x/list.m3u"), None, None, None).expect("source");
        insert(&db, source, rows);
        (db, source)
    }

    fn insert(db: &DatabaseManager, source: i64, rows: &[Row<'_>]) {
        db.with_conn(|conn| {
            for r in rows {
                conn.execute(
                    "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, group_title, tvg_id, country, host, stream_url, created_at, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?4, ?5, NULLIF(?6, ''), NULLIF(?7, ''), 'x', 'http://x/1.ts', 0, 0)",
                    params![source, r.hash, r.kind, r.name, r.group, r.tvg_id, r.country],
                )?;
            }
            Ok(())
        })
        .expect("items");
    }

    fn facets(db: &DatabaseManager, axis: CategoryAxis, filter: &TaxonomyFilter) -> Vec<(String, u32)> {
        db.get_category_facets("live", axis, None, filter).expect("facets").into_iter().map(|f| (f.key, f.count)).collect()
    }

    fn catalog_filter(kind: &str) -> CatalogFilter {
        CatalogFilter {
            kind: kind.into(),
            source_id: None,
            query: String::new(),
            group_title: None,
            host: None,
            favorites_only: false,
            include_broken: true,
            include_hidden: false,
            sort_by: SortField::Name,
            sort_asc: true,
            limit: 100,
            offset: 0,
        }
    }

    fn names(db: &DatabaseManager, taxonomy: &TaxonomyFilter) -> Vec<String> {
        db.query_catalog_with(&catalog_filter("live"), taxonomy).expect("query").into_iter().map(|i| i.name).collect()
    }

    fn sample() -> (DatabaseManager, i64) {
        db_with(&[
            live("a", "TF1", "FR| GENERALISTES", ""),
            live("b", "BFM", "FR| INFOS", ""),
            live("c", "L'Equipe", "FR| SPORTS", ""),
            live("d", "Sky News", "|UK| NEWS", ""),
            live("e", "Kids UK", "Animation;Kids;Music", "kids.uk"),
            live("f", "Rai 1", "Italy", ""),
            live("g", "Mystery", "Undefined", ""),
        ])
    }

    #[test]
    fn classifying_a_source_fills_country_theme_and_theme_rows() {
        let (db, source) = sample();
        let report = db.classify_source(source).expect("classify");
        assert_eq!(report.items, 7);
        let (country, src, theme): (Option<String>, Option<String>, String) = db
            .with_conn(|c| {
                Ok(c.query_row("SELECT tx_country, tx_country_src, tx_theme FROM iptv_items WHERE stable_hash = 'e'", [], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                })?)
            })
            .unwrap();
        assert_eq!((country.as_deref(), src.as_deref(), theme.as_str()), (Some("GB"), Some("tvg_id"), "kids"));
        let themes: i64 = db
            .with_conn(|c| Ok(c.query_row("SELECT COUNT(*) FROM item_themes WHERE item_id = (SELECT id FROM iptv_items WHERE stable_hash = 'e')", [], |r| r.get(0))?))
            .unwrap();
        assert_eq!(themes, 2, "kids + music");
    }

    #[test]
    fn country_and_theme_facets_cross_filter() {
        let (db, source) = sample();
        db.classify_source(source).unwrap();

        let by_country = facets(&db, CategoryAxis::Country, &TaxonomyFilter::default());
        assert_eq!(by_country, vec![("FR".into(), 3), ("GB".into(), 2), ("".into(), 1), ("IT".into(), 1)]);

        let fr = TaxonomyFilter { country: Some("FR".into()), ..Default::default() };
        let by_theme = facets(&db, CategoryAxis::Theme, &fr);
        assert_eq!(by_theme.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>(), vec!["general", "news", "sports"]);

        let sports = TaxonomyFilter { theme: Some("sports".into()), ..Default::default() };
        assert_eq!(facets(&db, CategoryAxis::Country, &sports), vec![("FR".into(), 1)]);

        assert_eq!(names(&db, &fr), vec!["BFM", "L'Equipe", "TF1"]);
        let fr_sports = TaxonomyFilter { country: Some("FR".into()), theme: Some("sports".into()), subtheme: None };
        assert_eq!(names(&db, &fr_sports), vec!["L'Equipe"]);
        let unknown = TaxonomyFilter { country: Some("".into()), ..Default::default() };
        assert_eq!(names(&db, &unknown), vec!["Mystery"]);
        let kids = TaxonomyFilter { theme: Some("kids".into()), subtheme: Some("animation".into()), country: None };
        assert_eq!(names(&db, &kids), vec!["Kids UK"]);
        let music = TaxonomyFilter { theme: Some("music".into()), ..Default::default() };
        assert_eq!(names(&db, &music), vec!["Kids UK"], "an item with two themes is found under both");
    }

    #[test]
    fn sub_themes_are_listed_under_their_theme() {
        let (db, source) = sample();
        db.classify_source(source).unwrap();
        let facets = db.get_category_facets("live", CategoryAxis::Theme, None, &TaxonomyFilter::default()).unwrap();
        let kids = facets.iter().find(|f| f.key == "kids").expect("kids");
        assert_eq!(kids.count, 1);
        assert_eq!(kids.subkeys.iter().map(|s| s.value.as_str()).collect::<Vec<_>>(), vec!["animation"]);
    }

    #[test]
    fn the_provider_axis_is_the_unchanged_group_list() {
        let (db, source) = sample();
        db.classify_source(source).unwrap();
        let provider = facets(&db, CategoryAxis::Provider, &TaxonomyFilter::default());
        let groups: Vec<(String, u32)> = db.get_groups("live", None, false).unwrap().into_iter().map(|g| (g.value, g.count)).collect();
        assert_eq!(provider, groups);
        assert!(provider.iter().any(|(k, _)| k == "Animation;Kids;Music"));
    }

    #[test]
    fn a_bare_country_channel_borrows_the_theme_of_the_same_tvg_id_elsewhere() {
        let (db, source_a) = db_with(&[live("a", "DHA", "News", "DHA.tr@SD"), live("b", "Other", "General", "Z.tr@SD")]);
        let source_b = db.add_source("B", "m3u", Some("http://y/list.m3u"), None, None, None).unwrap();
        insert(&db, source_b, &[live("c", "DHA TR", "Turkey", "DHA.tr"), live("d", "Lonely", "Turkey", "Lonely.tr"), live("e", "Z TR", "Turkey", "Z.tr")]);
        db.classify_source(source_a).unwrap();
        let report = db.classify_source(source_b).unwrap();
        assert_eq!(report.borrowed, 1, "only DHA has a themed twin; `general` is not a donor");
        let theme_of = |hash: &str| -> (String, String) {
            db.with_conn(|c| {
                Ok(c.query_row(
                    "SELECT i.tx_theme, t.src FROM iptv_items i JOIN item_themes t ON t.item_id = i.id WHERE i.stable_hash = ?1",
                    params![hash],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )?)
            })
            .unwrap()
        };
        assert_eq!(theme_of("c"), ("news".into(), "tvg_id".into()));
        assert_eq!(theme_of("d").0, "other");
        assert_eq!(theme_of("e").0, "other");
    }

    #[test]
    fn corrections_apply_at_once_survive_a_reclassification_and_can_be_cleared() {
        let (db, source) = sample();
        db.classify_source(source).unwrap();
        db.set_taxonomy_override("g", Some("be"), Some(&["sports".to_string()])).unwrap();
        let sports = TaxonomyFilter { theme: Some("sports".into()), country: Some("BE".into()), subtheme: None };
        assert_eq!(names(&db, &sports), vec!["Mystery"]);

        db.reclassify_all(&|_, _| {}, &AtomicBool::new(false)).unwrap();
        assert_eq!(names(&db, &sports), vec!["Mystery"], "kept after a full reclassification");

        db.clear_taxonomy_override("g").unwrap();
        assert!(names(&db, &sports).is_empty());
        assert_eq!(names(&db, &TaxonomyFilter { country: Some("".into()), ..Default::default() }), vec!["Mystery"]);

        assert!(db.set_taxonomy_override("g", None, Some(&["weather".to_string()])).is_err(), "closed list");
        assert!(db.set_taxonomy_override("g", Some("France"), None).is_err());
    }

    #[test]
    fn hidden_bouquets_and_adult_groups_stay_out_of_every_axis() {
        let (db, source) = db_with(&[
            live("a", "TF1", "FR| GENERALISTES", ""),
            live("b", "Sport FR", "FR| SPORTS", ""),
            live("c", "Night", "FR| ADULTS +18", ""),
        ]);
        db.classify_source(source).unwrap();
        let all = TaxonomyFilter::default();
        assert_eq!(facets(&db, CategoryAxis::Country, &all), vec![("FR".into(), 2)], "adult hidden by default");
        assert!(!facets(&db, CategoryAxis::Theme, &all).iter().any(|(k, _)| k == "adult"));

        db.hide_group(2, "live", "FR| SPORTS").unwrap();
        db.set_active_profile(2).unwrap();
        assert_eq!(facets(&db, CategoryAxis::Country, &all), vec![("FR".into(), 1)]);
        assert_eq!(names(&db, &all), vec!["TF1"]);
        db.set_active_profile(1).unwrap();
        assert_eq!(facets(&db, CategoryAxis::Country, &all), vec![("FR".into(), 2)]);
    }

    #[test]
    fn a_kids_profile_only_sees_what_it_was_given_on_every_axis() {
        let (db, source) = sample();
        db.classify_source(source).unwrap();
        let kids = db.create_profile("Kid", "person.crop.circle", true).unwrap();
        db.set_active_profile(kids.id).unwrap();
        assert!(facets(&db, CategoryAxis::Country, &TaxonomyFilter::default()).is_empty());
        assert!(facets(&db, CategoryAxis::Theme, &TaxonomyFilter::default()).is_empty());
        assert!(names(&db, &TaxonomyFilter::default()).is_empty());
        db.allow_group(kids.id, "live", "Animation;Kids;Music").unwrap();
        assert_eq!(names(&db, &TaxonomyFilter::default()), vec!["Kids UK"]);
        assert_eq!(facets(&db, CategoryAxis::Theme, &TaxonomyFilter::default()).len(), 2);
    }

    #[test]
    fn filter_values_never_reach_the_sql_text() {
        let (db, source) = sample();
        db.classify_source(source).unwrap();
        for bad in ["FR'; DROP TABLE iptv_items; --", "fr or 1=1", "FRA"] {
            let f = TaxonomyFilter { country: Some(bad.into()), ..Default::default() };
            assert!(names(&db, &f).is_empty(), "{bad}");
        }
        let f = TaxonomyFilter { theme: Some("sports' OR '1'='1".into()), ..Default::default() };
        assert!(names(&db, &f).is_empty());
        let f = TaxonomyFilter { theme: Some("sports".into()), subtheme: Some("x' OR '1'='1".into()), country: None };
        assert!(names(&db, &f).is_empty());
        assert!(db.get_category_facets("live; DROP", CategoryAxis::Country, None, &TaxonomyFilter::default()).is_err());
        assert_eq!(names(&db, &TaxonomyFilter::default()).len(), 7, "table intact");
    }

    #[test]
    fn series_are_classified_with_a_country_and_a_main_theme() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let source = db.add_source("S", "m3u", Some("http://x/list.m3u"), None, None, None).unwrap();
        db.with_conn(|c| {
            for (i, (title, group)) in [("Dix pour cent", "FR| SERIES"), ("Cartoon", "|UK| KIDS"), ("Mystery", "Undefined")].iter().enumerate() {
                c.execute(
                    "INSERT INTO series_catalog (source_id, canonical_key, stable_hash, title, group_title, episode_count, season_count, updated_at)
                     VALUES (?1, ?2, ?2, ?3, ?4, 0, 0, 0)",
                    params![source, format!("s{i}"), title, group],
                )?;
            }
            Ok(())
        })
        .unwrap();
        let report = db.classify_source(source).unwrap();
        assert_eq!(report.series, 3);
        let by_theme: Vec<(String, u32)> = db
            .get_category_facets("series", CategoryAxis::Theme, None, &TaxonomyFilter { country: Some("GB".into()), ..Default::default() })
            .unwrap()
            .into_iter()
            .map(|f| (f.key, f.count))
            .collect();
        assert_eq!(by_theme, vec![("kids".to_string(), 1)]);
        let found = db
            .query_series_with(&catalog_filter("series"), &TaxonomyFilter { theme: Some("series".into()), ..Default::default() })
            .unwrap();
        // A series whose label gives no theme is a `series` by kind.
        assert_eq!(found.iter().map(|s| s.title.as_str()).collect::<Vec<_>>(), vec!["Dix pour cent", "Mystery"]);
    }

    #[test]
    fn the_stored_version_triggers_one_background_reclassification() {
        let (db, _) = sample();
        assert_eq!(db.stored_taxonomy_version().unwrap(), 0);
        assert!(db.ensure_taxonomy_current(&|_, _| {}, &AtomicBool::new(false)).unwrap());
        assert_eq!(db.stored_taxonomy_version().unwrap(), TAXONOMY_VERSION);
        assert!(!db.ensure_taxonomy_current(&|_, _| {}, &AtomicBool::new(false)).unwrap(), "up to date: nothing to do");
        let status = db.taxonomy_status().unwrap();
        assert_eq!((status.live_total, status.live_without_country, status.stored_version), (7, 1, TAXONOMY_VERSION));
    }

    #[test]
    fn an_empty_catalogue_is_marked_current_without_a_reclassification() {
        let db = DatabaseManager::open_in_memory().unwrap();
        assert!(!db.ensure_taxonomy_current(&|_, _| {}, &AtomicBool::new(false)).unwrap());
        assert_eq!(db.stored_taxonomy_version().unwrap(), TAXONOMY_VERSION);
    }

    #[test]
    fn a_cancelled_reclassification_does_not_claim_to_be_up_to_date() {
        let (db, _) = sample();
        db.reclassify_all(&|_, _| {}, &AtomicBool::new(true)).unwrap();
        assert_eq!(db.stored_taxonomy_version().unwrap(), 0);
    }

    #[test]
    fn orphan_theme_rows_of_replaced_items_are_removed() {
        let (db, source) = sample();
        db.classify_source(source).unwrap();
        db.with_conn(|c| {
            c.execute("PRAGMA foreign_keys = OFF", [])?;
            c.execute("DELETE FROM iptv_items WHERE stable_hash = 'a'", [])?;
            c.execute("PRAGMA foreign_keys = ON", [])?;
            Ok(())
        })
        .unwrap();
        db.classify_source(source).unwrap();
        let orphans: i64 = db
            .with_conn(|c| Ok(c.query_row("SELECT COUNT(*) FROM item_themes WHERE item_id NOT IN (SELECT id FROM iptv_items)", [], |r| r.get(0))?))
            .unwrap();
        assert_eq!(orphans, 0);
    }

    #[tokio::test]
    async fn an_m3u_refresh_classifies_what_it_stores_and_keeps_the_provider_label() {
        let m3u = "#EXTM3U\n\
#EXTINF:-1 tvg-id=\"DHA.tr@SD\" group-title=\"News\",DHA\n\
http://iptv.local/live/1.ts\n\
#EXTINF:-1 tvg-id=\"B4U.in@SD\" group-title=\"Animation;Kids;Music\",B4U Kids\n\
http://iptv.local/live/2.ts\n\
#EXTINF:-1 group-title=\"Italy\",Rai Sport\n\
http://iptv.local/live/3.ts\n";
        let engine = crate::CndEngine::in_memory().expect("engine");
        let source = engine.add_source("T".into(), "m3u".into(), Some("http://iptv.local/p.m3u".into()), None, None, None).expect("source");
        let uuid = engine.list_sources().expect("sources").into_iter().find(|s| s.id == source).expect("source").uuid;
        engine
            .ingest_m3u_reader(source, &uuid, tokio::io::BufReader::new(m3u.as_bytes()), std::time::Instant::now())
            .await
            .expect("ingest");

        let countries: Vec<(String, u32)> = engine
            .get_category_facets("live".into(), CategoryAxis::Country, None, TaxonomyFilter::default())
            .expect("facets")
            .into_iter()
            .map(|f| (f.key, f.count))
            .collect();
        assert_eq!(countries, vec![("IN".to_string(), 1), ("IT".to_string(), 1), ("TR".to_string(), 1)]);
        let themes: Vec<String> = engine
            .get_category_facets("live".into(), CategoryAxis::Theme, None, TaxonomyFilter::default())
            .expect("facets")
            .into_iter()
            .map(|f| f.key)
            .collect();
        assert!(themes.contains(&"kids".to_string()) && themes.contains(&"music".to_string()) && themes.contains(&"news".to_string()));
        let groups = engine.get_groups("live".into(), None).expect("groups");
        assert!(groups.iter().any(|g| g.value == "Animation;Kids;Music"), "provider label untouched");

        // A refresh replaces the items; the new ones are classified again and no theme row is left behind.
        engine
            .ingest_m3u_reader(source, &uuid, tokio::io::BufReader::new(m3u.as_bytes()), std::time::Instant::now())
            .await
            .expect("second ingest");
        let status = engine.taxonomy_status().expect("status");
        assert_eq!((status.live_total, status.live_without_country), (3, 0));
    }

    /// Migrates and reclassifies a real catalogue and prints what the category column would show.
    /// Writes to the file it is given: pass a COPY, e.g.
    /// `CND_TAXONOMY_DB_COPY=/tmp/copy.db cargo test -p cnd-core --lib --release migrates_a_copy -- --ignored --nocapture`.
    #[test]
    #[ignore = "needs a copy of a real catalogue: set CND_TAXONOMY_DB_COPY"]
    fn migrates_a_copy_of_a_real_catalogue() {
        let Some(path) = std::env::var_os("CND_TAXONOMY_DB_COPY") else { return };
        let db = DatabaseManager::open(&path).expect("open the copy");
        let started = std::time::Instant::now();
        let ran = db.ensure_taxonomy_current(&|_, _| {}, &AtomicBool::new(false)).expect("reclassify");
        println!("reclassified: {ran} in {:?}", started.elapsed());
        println!("status: {:?}", db.taxonomy_status().expect("status"));
        for axis in [CategoryAxis::Country, CategoryAxis::Theme] {
            let started = std::time::Instant::now();
            let facets = db.get_category_facets("live", axis, None, &TaxonomyFilter::default()).expect("facets");
            let top: Vec<String> = facets.iter().take(12).map(|f| format!("{}={}", f.key, f.count)).collect();
            println!("{axis:?}: {} entries in {:?}: {}", facets.len(), started.elapsed(), top.join(", "));
        }
        let provider = db.get_category_facets("live", CategoryAxis::Provider, None, &TaxonomyFilter::default()).expect("facets");
        println!("Provider: {} entries (as before)", provider.len());
    }

    /// SLAs of PRD-33 (reclassification < 2 s and facets < 50 ms on 50 000 items), timed in
    /// optimised builds only (`cargo test --release`).
    #[test]
    fn reclassifying_and_listing_fifty_thousand_items_is_fast() {
        let db = DatabaseManager::open_in_memory().unwrap();
        let source = db.add_source("S", "m3u", Some("http://x/list.m3u"), None, None, None).unwrap();
        let groups = ["Animation;Kids;Music", "FR| SPORTS FHD", "Italy", "General", "Undefined", "|UK| ENTERTAINMENT", "News"];
        db.with_conn_mut(|conn| {
            let tx = conn.transaction()?;
            {
                let mut stmt = tx.prepare(
                    "INSERT INTO iptv_items (source_id, stable_hash, kind, name, name_clean, group_title, tvg_id, host, stream_url, created_at, updated_at)
                     VALUES (?1, ?2, 'live', ?3, ?3, ?4, ?5, 'x', 'http://x/1.ts', 0, 0)",
                )?;
                for i in 0..50_000 {
                    stmt.execute(params![source, format!("h{i}"), format!("Channel {i}"), groups[i % groups.len()], format!("c{}.fr@SD", i % 30_000)])?;
                }
            }
            tx.commit()?;
            Ok(())
        })
        .unwrap();
        let started = std::time::Instant::now();
        db.reclassify_all(&|_, _| {}, &AtomicBool::new(false)).unwrap();
        let reclassify = started.elapsed();
        let started = std::time::Instant::now();
        let filter = TaxonomyFilter { country: Some("FR".into()), ..Default::default() };
        let themes = db.get_category_facets("live", CategoryAxis::Theme, None, &filter).unwrap();
        let countries = db.get_category_facets("live", CategoryAxis::Country, None, &TaxonomyFilter::default()).unwrap();
        let facet_time = started.elapsed();
        println!("reclassify 50 000: {reclassify:?}, facets: {facet_time:?}");
        assert!(!themes.is_empty() && !countries.is_empty());
        if !cfg!(debug_assertions) {
            assert!(reclassify.as_millis() < 2_000, "reclassification took {reclassify:?}");
            assert!(facet_time.as_millis() < 100, "two facet queries took {facet_time:?}");
        }
    }
}
