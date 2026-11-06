//! Android logcat sink for `tracing` and `TelemetryHub` (PRD-37 § 3).
//! Single responsibility: forward already-redacted log lines to `__android_log_write` on Android;
//! compile to a zero-cost no-op on every other target.

#[cfg(target_os = "android")]
mod imp {
    use crate::telemetry::LogLevel;
    use std::ffi::{c_char, c_int, CString};
    use std::sync::Once;
    use tracing::Subscriber;
    use tracing_subscriber::layer::{Context, SubscriberExt};
    use tracing_subscriber::util::SubscriberInitExt;
    use tracing_subscriber::Layer;

    const ANDROID_LOG_DEBUG: c_int = 3;
    const ANDROID_LOG_INFO: c_int = 4;
    const ANDROID_LOG_WARN: c_int = 5;
    const ANDROID_LOG_ERROR: c_int = 6;

    #[link(name = "log")]
    extern "C" {
        fn __android_log_write(prio: c_int, tag: *const c_char, text: *const c_char) -> c_int;
    }

    fn write_raw(prio: c_int, tag: &str, message: &str) {
        let clean_tag = CString::new(tag.replace('\0', "")).unwrap_or_default();
        let clean_msg = CString::new(message.replace('\0', " ")).unwrap_or_default();
        // SAFETY: both pointers come from valid NUL-terminated `CString`s alive for the call.
        unsafe {
            let _ = __android_log_write(prio, clean_tag.as_ptr(), clean_msg.as_ptr());
        }
    }

    struct LogcatTracingLayer;

    #[derive(Default)]
    struct MessageVisitor {
        message: String,
    }

    impl tracing::field::Visit for MessageVisitor {
        fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
            if field.name() == "message" {
                self.message = format!("{value:?}");
            } else if self.message.is_empty() {
                self.message = format!("{}={value:?}", field.name());
            } else {
                self.message.push_str(&format!(" {}={value:?}", field.name()));
            }
        }

        fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
            if field.name() == "message" {
                self.message = value.to_string();
            } else if self.message.is_empty() {
                self.message = format!("{}={value}", field.name());
            } else {
                self.message.push_str(&format!(" {}={value}", field.name()));
            }
        }
    }

    impl<S: Subscriber> Layer<S> for LogcatTracingLayer {
        fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
            let prio = match *event.metadata().level() {
                tracing::Level::ERROR => ANDROID_LOG_ERROR,
                tracing::Level::WARN => ANDROID_LOG_WARN,
                tracing::Level::INFO => ANDROID_LOG_INFO,
                tracing::Level::DEBUG | tracing::Level::TRACE => ANDROID_LOG_DEBUG,
            };
            let mut visitor = MessageVisitor::default();
            event.record(&mut visitor);
            let safe = crate::telemetry::redact_text(&visitor.message);
            write_raw(prio, "BuntuRust", &safe);
        }
    }

    pub fn init_once() {
        static INIT: Once = Once::new();
        INIT.call_once(|| {
            let _ = tracing_subscriber::registry()
                .with(LogcatTracingLayer)
                .try_init();
        });
    }

    pub fn write_telemetry(level: LogLevel, category: &str, redacted_url: Option<&str>, safe_msg: &str) {
        let prio = match level {
            LogLevel::Debug => ANDROID_LOG_DEBUG,
            LogLevel::Info => ANDROID_LOG_INFO,
            LogLevel::Warn => ANDROID_LOG_WARN,
            LogLevel::Error => ANDROID_LOG_ERROR,
        };
        let line = match redacted_url {
            Some(u) => format!("[{category}] {safe_msg} ({u})"),
            None => format!("[{category}] {safe_msg}"),
        };
        write_raw(prio, "BuntuCore", &line);
    }
}

#[cfg(not(target_os = "android"))]
mod imp {
    use crate::telemetry::LogLevel;

    pub fn init_once() {}

    pub fn write_telemetry(
        _level: LogLevel,
        _category: &str,
        _redacted_url: Option<&str>,
        _safe_msg: &str,
    ) {
    }
}

pub use imp::{init_once, write_telemetry};

