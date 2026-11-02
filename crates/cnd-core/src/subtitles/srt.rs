use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SubtitleCue {
    pub index: u32,
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
}

/// Parses an SRT timestamp format `HH:MM:SS,mmm` or `HH:MM:SS.mmm` into milliseconds.
pub fn parse_timestamp(s: &str) -> Option<i64> {
    let s = s.trim();
    // Expected format: 00:01:20,000 or 00:01:20.000
    let parts: Vec<&str> = s.split(':').collect();
    if parts.len() != 3 {
        return None;
    }

    let hours: i64 = parts[0].trim().parse().ok()?;
    let minutes: i64 = parts[1].trim().parse().ok()?;

    let sec_millis: Vec<&str> = parts[2].split([',', '.']).collect();
    if sec_millis.len() != 2 {
        return None;
    }

    let seconds: i64 = sec_millis[0].trim().parse().ok()?;
    let millis_str = sec_millis[1].trim();
    // Pad or truncate millis to 3 digits
    let millis: i64 = match millis_str.len() {
        1 => millis_str.parse::<i64>().ok()? * 100,
        2 => millis_str.parse::<i64>().ok()? * 10,
        3 => millis_str.parse::<i64>().ok()?,
        _ => millis_str[..3].parse::<i64>().ok()?,
    };

    Some(hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + millis)
}

/// Strips common HTML/SRT styling tags (`<i>`, `<b>`, `<u>`, `<font...>`, `{y:i}`, etc.).
pub fn strip_tags(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut inside_tag = false;

    for ch in input.chars() {
        if ch == '<' || ch == '{' {
            inside_tag = true;
        } else if (ch == '>' || ch == '}') && inside_tag {
            inside_tag = false;
        } else if !inside_tag {
            out.push(ch);
        }
    }
    out
}

/// Parses full SRT subtitle text into a list of cues, sorted by `start_ms`.
pub fn parse_srt(content: &str) -> Vec<SubtitleCue> {
    let normalized = content.replace("\r\n", "\n").replace('\r', "\n");
    let blocks = normalized.split("\n\n");
    let mut cues = Vec::new();

    for block in blocks {
        let lines: Vec<&str> = block.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
        if lines.is_empty() {
            continue;
        }

        let mut line_idx = 0;
        let mut index: u32 = 0;

        // First line might be numeric cue index
        if let Ok(idx) = lines[line_idx].parse::<u32>() {
            index = idx;
            line_idx += 1;
        }

        if line_idx >= lines.len() {
            continue;
        }

        // Next line should contain `-->`
        let timing_line = lines[line_idx];
        if !timing_line.contains("-->") {
            continue;
        }
        line_idx += 1;

        let time_parts: Vec<&str> = timing_line.split("-->").collect();
        if time_parts.len() != 2 {
            continue;
        }

        let start_ms = match parse_timestamp(time_parts[0]) {
            Some(ms) => ms,
            None => continue,
        };

        // Note: end part may contain extra positioning directives like `X1:000 Y1:000`
        let end_clean = time_parts[1].split_whitespace().next().unwrap_or("");
        let end_ms = match parse_timestamp(end_clean) {
            Some(ms) => ms,
            None => continue,
        };

        // Remaining lines are text
        let text_lines: Vec<String> = lines[line_idx..]
            .iter()
            .map(|l| strip_tags(l).trim().to_string())
            .filter(|l| !l.is_empty())
            .collect();

        if text_lines.is_empty() {
            continue;
        }

        let text = text_lines.join("\n");
        if index == 0 {
            index = (cues.len() + 1) as u32;
        }

        cues.push(SubtitleCue {
            index,
            start_ms,
            end_ms,
            text,
        });
    }

    cues.sort_by_key(|c| c.start_ms);
    cues
}

/// Binary searches for the active subtitle cue at a given playback timestamp in ms.
pub fn find_active_cue(cues: &[SubtitleCue], position_ms: i64) -> Option<&SubtitleCue> {
    if cues.is_empty() {
        return None;
    }

    // Binary search to find partition point
    let idx = cues.partition_point(|c| c.start_ms <= position_ms);
    if idx == 0 {
        return None;
    }

    // Check recent preceding cues (in case of slightly overlapping or active cues)
    let candidate = &cues[idx - 1];
    if candidate.start_ms <= position_ms && position_ms <= candidate.end_ms {
        return Some(candidate);
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_timestamps() {
        assert_eq!(parse_timestamp("00:00:01,500"), Some(1500));
        assert_eq!(parse_timestamp("01:02:03.456"), Some(3600000 + 120000 + 3000 + 456));
        assert_eq!(parse_timestamp("invalid"), None);
    }

    #[test]
    fn test_strip_tags() {
        assert_eq!(strip_tags("<i>Italic text</i>"), "Italic text");
        assert_eq!(strip_tags("<font color=\"#ff0000\">Red</font>"), "Red");
        assert_eq!(strip_tags("{y:i}Subtitle text{/y:i}"), "Subtitle text");
    }

    #[test]
    fn test_parse_full_srt() {
        let sample = r#"
1
00:01:20,000 --> 00:01:23,400
Hello, <i>world</i>!
Second line of cue 1.

2
00:01:24,100 --> 00:01:26,800 X1:0 Y1:0
This is cue 2.
"#;
        let cues = parse_srt(sample);
        assert_eq!(cues.len(), 2);
        assert_eq!(cues[0].index, 1);
        assert_eq!(cues[0].start_ms, 80000);
        assert_eq!(cues[0].end_ms, 83400);
        assert_eq!(cues[0].text, "Hello, world!\nSecond line of cue 1.");

        assert_eq!(cues[1].index, 2);
        assert_eq!(cues[1].start_ms, 84100);
        assert_eq!(cues[1].end_ms, 86800);
        assert_eq!(cues[1].text, "This is cue 2.");
    }

    #[test]
    fn test_find_active_cue() {
        let sample = r#"
1
00:00:10,000 --> 00:00:15,000
First

2
00:00:20,000 --> 00:00:25,000
Second
"#;
        let cues = parse_srt(sample);
        assert_eq!(find_active_cue(&cues, 5000), None);
        assert_eq!(find_active_cue(&cues, 12000).map(|c| c.text.as_str()), Some("First"));
        assert_eq!(find_active_cue(&cues, 17000), None);
        assert_eq!(find_active_cue(&cues, 22000).map(|c| c.text.as_str()), Some("Second"));
        assert_eq!(find_active_cue(&cues, 30000), None);
    }
}
