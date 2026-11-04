use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MediaKind {
    Video,
    Audio,
    Image,
}

impl MediaKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            MediaKind::Video => "video",
            MediaKind::Audio => "audio",
            MediaKind::Image => "image",
        }
    }

    pub fn parse_kind(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "video" => Some(MediaKind::Video),
            "audio" => Some(MediaKind::Audio),
            "image" | "images" => Some(MediaKind::Image),
            _ => None,
        }
    }
}

impl std::str::FromStr for MediaKind {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse_kind(s).ok_or(())
    }
}

pub fn classify_by_extension(path: &Path) -> Option<MediaKind> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    match ext.as_str() {
        // Video
        "mp4" | "m4v" | "mov" | "mkv" | "webm" | "avi" | "ts" | "m2ts" | "mts" | "mpg"
        | "mpeg" | "wmv" | "flv" | "3gp" | "ogv" => Some(MediaKind::Video),

        // Audio
        "mp3" | "m4a" | "aac" | "flac" | "alac" | "wav" | "aiff" | "aif" | "ogg" | "oga"
        | "opus" | "wma" | "ape" | "wv" => Some(MediaKind::Audio),

        // Images
        "jpg" | "jpeg" | "png" | "heic" | "heif" | "gif" | "webp" | "tif" | "tiff" | "bmp"
        | "avif" | "dng" | "cr2" | "nef" | "arw" => Some(MediaKind::Image),

        _ => None,
    }
}

pub fn is_subtitle_extension(ext: &str) -> bool {
    matches!(
        ext.to_ascii_lowercase().as_str(),
        "srt" | "ass" | "vtt" | "sub"
    )
}

pub fn is_subtitle_file(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(is_subtitle_extension)
}

pub fn is_cover_file_name(file_name: &str) -> bool {
    let lower = file_name.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        "cover.jpg"
            | "cover.jpeg"
            | "cover.png"
            | "cover.webp"
            | "folder.jpg"
            | "folder.jpeg"
            | "folder.png"
            | "folder.webp"
            | "albumart.jpg"
            | "albumart.png"
            | "poster.jpg"
            | "poster.png"
    )
}

pub fn is_cover_file(path: &Path) -> bool {
    path.file_name()
        .and_then(|f| f.to_str())
        .is_some_and(is_cover_file_name)
}

/// Fallback magic byte classifier if extension is absent or ambiguous.
pub fn classify_by_magic_bytes(header: &[u8]) -> Option<MediaKind> {
    if header.len() < 4 {
        return None;
    }

    // JPEG
    if header.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some(MediaKind::Image);
    }
    // PNG
    if header.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some(MediaKind::Image);
    }
    // GIF
    if header.starts_with(b"GIF87a") || header.starts_with(b"GIF89a") {
        return Some(MediaKind::Image);
    }
    // Matroska / WebM EBML
    if header.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
        return Some(MediaKind::Video);
    }
    // FLAC
    if header.starts_with(b"fLaC") {
        return Some(MediaKind::Audio);
    }
    // ID3 (MP3)
    if header.starts_with(b"ID3") {
        return Some(MediaKind::Audio);
    }
    // Ogg
    if header.starts_with(b"OggS") {
        // Can be Vorbis/Opus audio or Theora video. Default to Audio.
        return Some(MediaKind::Audio);
    }
    // MP4/MOV: bytes 4..8 usually ftyp
    if header.len() >= 8 && (&header[4..8] == b"ftyp" || &header[4..8] == b"moov") {
        return Some(MediaKind::Video);
    }
    // RIFF (WAV, AVI, WEBP)
    if header.starts_with(b"RIFF") && header.len() >= 12 {
        let tag = &header[8..12];
        if tag == b"WAVE" {
            return Some(MediaKind::Audio);
        } else if tag == b"AVI " {
            return Some(MediaKind::Video);
        } else if tag == b"WEBP" {
            return Some(MediaKind::Image);
        }
    }

    None
}

/// Helper to match companion subtitle files to corresponding video files.
/// E.g. "Movie.2023.fr.srt" or "Movie.2023.srt" matches "Movie.2023.mkv".
pub fn match_subtitle_to_video<'a>(
    sub_stem: &str,
    video_stems: &'a [&'a str],
) -> Option<&'a str> {
    let sub_stem_lower = sub_stem.to_ascii_lowercase();

    // 1. Exact stem match: "movie" == "movie"
    for &v in video_stems {
        if v.eq_ignore_ascii_case(sub_stem) {
            return Some(v);
        }
    }

    // 2. Prefix match: "movie.fr" starts with "movie"
    let mut best_match: Option<&'a str> = None;
    let mut best_len = 0;
    for &v in video_stems {
        let v_lower = v.to_ascii_lowercase();
        if sub_stem_lower.starts_with(&v_lower) && v_lower.len() > best_len {
            best_match = Some(v);
            best_len = v_lower.len();
        }
    }

    best_match
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_classify_extensions() {
        assert_eq!(classify_by_extension(Path::new("video.mkv")), Some(MediaKind::Video));
        assert_eq!(classify_by_extension(Path::new("song.flac")), Some(MediaKind::Audio));
        assert_eq!(classify_by_extension(Path::new("photo.heic")), Some(MediaKind::Image));
        assert_eq!(classify_by_extension(Path::new("document.pdf")), None);
        assert_eq!(classify_by_extension(Path::new("sub.srt")), None);
    }

    #[test]
    fn test_companion_detection() {
        assert!(is_subtitle_file(Path::new("Avatar.2009.fr.srt")));
        assert!(is_subtitle_file(Path::new("show.s01e01.vtt")));
        assert!(!is_subtitle_file(Path::new("video.mkv")));

        assert!(is_cover_file(Path::new("/Music/Album/cover.jpg")));
        assert!(is_cover_file(Path::new("/Movies/folder.png")));
        assert!(!is_cover_file(Path::new("/Movies/photo.jpg")));
    }

    #[test]
    fn test_match_subtitles() {
        let videos = ["Inception.2010.1080p", "Avatar.2009"];
        assert_eq!(
            match_subtitle_to_video("Inception.2010.1080p.fr", &videos),
            Some("Inception.2010.1080p")
        );
        assert_eq!(
            match_subtitle_to_video("Avatar.2009", &videos),
            Some("Avatar.2009")
        );
        assert_eq!(match_subtitle_to_video("Unrelated.2022", &videos), None);
    }

    #[test]
    fn test_magic_bytes() {
        let png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR";
        assert_eq!(classify_by_magic_bytes(png), Some(MediaKind::Image));

        let jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10];
        assert_eq!(classify_by_magic_bytes(&jpeg), Some(MediaKind::Image));

        let flac = b"fLaC\x00\x00\x00\x22";
        assert_eq!(classify_by_magic_bytes(flac), Some(MediaKind::Audio));

        let mkv = [0x1A, 0x45, 0xDF, 0xA3, 0x93, 0x42];
        assert_eq!(classify_by_magic_bytes(&mkv), Some(MediaKind::Video));
    }
}
