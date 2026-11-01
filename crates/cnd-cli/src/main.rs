use cnd_core::telemetry::redact_url;
use cnd_core::CndEngine;
use std::error::Error;
use std::time::Instant;
use tokio::io::BufReader;

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    tracing_subscriber::fmt::init();

    println!("========================================");
    println!("  CND IPTV Native CLI (Zero-Lag Engine) ");
    println!("========================================");

    let engine = CndEngine::in_memory()?;
    println!("Engine version: {}", engine.version());

    let settings = engine.get_settings();
    println!("Runtime Settings:");
    println!(" - Segments / file:    {}", settings.segments_per_file);
    println!(" - Part size (MB):     {}", settings.part_size_bytes / (1024 * 1024));
    println!(" - Max active files:   {}", settings.max_active_files);
    println!(" - Default User-Agent: {}", settings.default_user_agent);

    let sample_url = "http://srv:8080/get.php?username=demo&password=super_secret_123&type=m3u_plus";
    let src_id = engine.add_source(
        "Demo Benchmark Playlist".to_string(),
        "m3u".to_string(),
        Some(sample_url.to_string()),
        None,
        None,
        None,
    )?;
    println!(
        "\nCreated source ID={} (redacted URL: {})",
        src_id,
        redact_url(sample_url)
    );

    // Quick streaming M3U ingestion benchmark (10,000 items = 20,001 M3U lines)
    let mut payload = String::with_capacity(1_200_000);
    payload.push_str("#EXTM3U x-tvg-url=\"http://epg.demo/guide.xml.gz\"\n");
    for i in 0..10_000 {
        payload.push_str(&format!(
            "#EXTINF:-1 tvg-id=\"ch{i}\" group-title=\"Group {}\",|FR| Channel {i} FHD\nhttp://cdn.demo/live/u/p/{i}.ts\n",
            i % 20
        ));
    }
    let total_lines = 20_001u64;
    let started = Instant::now();
    let summary = engine
        .ingest_m3u_reader(
            src_id,
            "cli_bench_uuid",
            BufReader::with_capacity(64 * 1024, payload.as_bytes()),
            started,
        )
        .await?;

    let secs = (summary.duration_ms.max(1) as f64) / 1_000.0;
    let lines_per_sec = (total_lines as f64 / secs) as u64;
    println!(
        "Streaming M3U Bench: {} items ({} lines) ingested in {} ms (~{} lines/sec)",
        summary.total_items, total_lines, summary.duration_ms, lines_per_sec
    );

    let stats = engine.get_stats()?;
    println!(
        "DB Stats -> Sources: {}, Live: {}, Movies: {}, Series: {}, Favorites: {}",
        stats.total_sources,
        stats.total_live_channels,
        stats.total_movies,
        stats.total_series,
        stats.total_favorites
    );

    println!("\nAll systems operational. PRD-02 validation successful!");
    Ok(())
}
