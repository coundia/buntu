use crate::ai::local_matcher::channel_name_tokens;
use crate::db::{DatabaseManager, DbError, IptvItemRecord};
use rusqlite::params;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ChannelQuality {
    Sd = 1,
    Hd = 2,
    Fhd = 3,
    Uhd4k = 4,
}

pub fn detect_channel_quality(name: &str) -> ChannelQuality {
    let lower = name.to_lowercase();
    if lower.contains("4k") || lower.contains("uhd") || lower.contains("2160") {
        ChannelQuality::Uhd4k
    } else if lower.contains("fhd") || lower.contains("1080") {
        ChannelQuality::Fhd
    } else if lower.contains("hd") || lower.contains("720") {
        ChannelQuality::Hd
    } else {
        ChannelQuality::Sd
    }
}

pub fn normalize_tvg_id(tvg_id: Option<&str>) -> Option<String> {
    tvg_id
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_lowercase())
}

pub fn channel_equivalence_key(name: &str) -> String {
    channel_name_tokens(name).join(" ")
}

pub fn find_mirrors(
    db: &DatabaseManager,
    item_id: i64,
) -> Result<Vec<IptvItemRecord>, DbError> {
    let target = match db.get_item_by_id(item_id)? {
        Some(item) => item,
        None => return Ok(Vec::new()),
    };

    if target.kind != "live" {
        return Ok(Vec::new());
    }

    let target_tvg = normalize_tvg_id(target.tvg_id.as_deref());
    let target_tokens = channel_equivalence_key(&target.name);
    let target_source_id = target.source_id;

    // First search candidate items in SQLite
    let first_token = channel_name_tokens(&target.name)
        .into_iter()
        .next()
        .unwrap_or_default();

    let (candidates, health_map) = db.with_conn(|conn| {
        let pattern = if first_token.is_empty() {
            String::new()
        } else {
            format!("%{}%", first_token.to_lowercase())
        };

        let sql = "SELECT i.id, i.source_id, i.series_id, i.stable_hash, i.kind, i.season_num, i.episode_num,
                          i.name, i.name_clean, i.year, i.group_title, i.tvg_id, i.logo_url, i.chno, i.host,
                          i.container_ext, i.stream_url, i.user_agent, i.referer, i.headers_json,
                          i.catchup_type, i.catchup_source, i.catchup_days, i.plot, i.imdb_id, i.imdb_rating,
                          (fav.stable_hash IS NOT NULL) AS is_favorite,
                          (bf.stable_hash IS NOT NULL) AS is_broken,
                          COALESCE(wh.position_ms, 0) AS resume_position_ms,
                          COALESCE(wh.duration_ms, 0) AS duration_ms,
                          COALESCE(wh.completed, 0) AS is_completed,
                          sh.status AS health_status,
                          sh.latency_ms AS health_latency_ms
                   FROM iptv_items i
                   LEFT JOIN favorites fav ON fav.profile_id = (SELECT id FROM temp.active_profile) AND fav.stable_hash = i.stable_hash
                   LEFT JOIN broken_flags bf ON bf.stable_hash = i.stable_hash
                   LEFT JOIN watch_history wh ON wh.profile_id = (SELECT id FROM temp.active_profile) AND wh.stable_hash = i.stable_hash
                   LEFT JOIN stream_health sh ON sh.stable_hash = i.stable_hash
                   WHERE i.kind = 'live'
                     AND i.id != ?1
                     AND bf.stable_hash IS NULL
                     AND (
                         (?2 IS NOT NULL AND LOWER(TRIM(COALESCE(i.tvg_id, ''))) = ?2)
                         OR (?3 != '' AND LOWER(i.name_clean) LIKE ?3)
                     )";

        let mut stmt = conn.prepare(sql)?;
        let mut items = Vec::new();
        let mut healths = std::collections::HashMap::new();

        let rows = stmt.query_map(
            params![item_id, target_tvg, pattern],
            |row| {
                let item = IptvItemRecord {
                    id: row.get(0)?,
                    source_id: row.get(1)?,
                    series_id: row.get(2)?,
                    stable_hash: row.get(3)?,
                    kind: row.get(4)?,
                    season_num: row.get(5)?,
                    episode_num: row.get(6)?,
                    name: row.get(7)?,
                    name_clean: row.get(8)?,
                    year: row.get(9)?,
                    group_title: row.get(10)?,
                    tvg_id: row.get(11)?,
                    logo_url: row.get(12)?,
                    chno: row.get(13)?,
                    host: row.get(14)?,
                    container_ext: row.get(15)?,
                    stream_url: row.get(16)?,
                    user_agent: row.get(17)?,
                    referer: row.get(18)?,
                    headers_json: row.get(19)?,
                    catchup_type: row.get(20)?,
                    catchup_source: row.get(21)?,
                    catchup_days: row.get(22)?,
                    plot: row.get(23)?,
                    imdb_id: row.get(24)?,
                    imdb_rating: row.get(25)?,
                    is_favorite: row.get(26)?,
                    is_broken: row.get(27)?,
                    resume_position_ms: row.get(28)?,
                    duration_ms: row.get(29)?,
                    is_completed: row.get(30)?,
                };
                let h_status: Option<String> = row.get(31)?;
                let h_latency: Option<u32> = row.get(32)?;
                Ok((item, h_status, h_latency))
            },
        )?;

        for r in rows {
            let (item, status, latency) = r?;
            healths.insert(item.stable_hash.clone(), (status, latency));
            items.push(item);
        }

        Ok((items, healths))
    })?;

    // Filter by strict equivalence: tvg_id match OR normalized token key match
    let mut ranked = Vec::new();
    for cand in candidates {
        let cand_tvg = normalize_tvg_id(cand.tvg_id.as_deref());
        let tvg_matched = match (&target_tvg, &cand_tvg) {
            (Some(t), Some(c)) => t == c,
            _ => false,
        };

        let token_matched = if !target_tokens.is_empty() {
            channel_equivalence_key(&cand.name) == target_tokens
        } else {
            false
        };

        if !tvg_matched && !token_matched {
            continue;
        }

        let (h_status, h_latency) = health_map
            .get(&cand.stable_hash)
            .cloned()
            .unwrap_or((None, None));

        // Health rank: OK (3) > Unknown (2) > Failed/Other (1)
        let health_rank = match h_status.as_deref() {
            Some("ok") => 3,
            None => 2,
            _ => 1,
        };

        let quality = detect_channel_quality(&cand.name);
        let same_source = if cand.source_id == target_source_id { 1 } else { 0 };
        let latency = h_latency.unwrap_or(9999);

        ranked.push((cand, health_rank, quality, same_source, latency));
    }

    // Sort by:
    // 1. Health (OK > Unknown > Failed)
    // 2. Quality (4K > FHD > HD > SD)
    // 3. Same source before other source
    // 4. Lower latency
    // 5. Name
    ranked.sort_by(|a, b| {
        b.1.cmp(&a.1)
            .then_with(|| b.2.cmp(&a.2))
            .then_with(|| b.3.cmp(&a.3))
            .then_with(|| a.4.cmp(&b.4))
            .then_with(|| a.0.name.cmp(&b.0.name))
    });

    Ok(ranked.into_iter().map(|(item, ..)| item).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_channel_quality() {
        assert_eq!(detect_channel_quality("TF1 4K UHD"), ChannelQuality::Uhd4k);
        assert_eq!(detect_channel_quality("FR: France 2 FHD"), ChannelQuality::Fhd);
        assert_eq!(detect_channel_quality("M6 HD"), ChannelQuality::Hd);
        assert_eq!(detect_channel_quality("Arte"), ChannelQuality::Sd);
    }

    #[test]
    fn test_channel_equivalence_key() {
        assert_eq!(channel_equivalence_key("FR: TF1 4K"), "tf 1");
        assert_eq!(channel_equivalence_key("FR | TF1 FHD"), "tf 1");
        assert_eq!(channel_equivalence_key("TF1 HD"), "tf 1");
        assert_eq!(channel_equivalence_key("TF1"), "tf 1");
        assert_eq!(channel_equivalence_key("France 2"), "france 2");
    }
}
