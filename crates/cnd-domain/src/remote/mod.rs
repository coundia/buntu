//! Remote playback and cross-device control ("Lire sur...", PRD-42).

pub mod handoff;
pub mod messages;
pub mod resolve;

#[cfg(test)]
mod tests;

pub use handoff::*;
pub use messages::*;
pub use resolve::*;
