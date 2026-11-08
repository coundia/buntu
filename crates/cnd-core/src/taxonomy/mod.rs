//! Normalised categories: a country and themes of a closed list for every catalogue item (PRD-33).
//!
//! Pure functions, no SQLite: the same input always gives the same result. Raise
//! `TAXONOMY_VERSION` whenever the data or the rules change, so stored items get reclassified.

pub mod country;
pub mod data;
pub mod domain;
pub mod tokenize;

#[cfg(test)]
mod tests;

pub use country::{CountryMatch, CountrySource};
pub use domain::{DomainSource, DomainTag};

/// Version of the rules and the dictionaries (PRD-33 § 4.3).
pub const TAXONOMY_VERSION: u32 = 1;

/// The closed list of themes (PRD-33 § 3). Stored by `as_str`, never by position.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Domain {
    General,
    News,
    Sports,
    Entertainment,
    Movies,
    Series,
    Kids,
    Music,
    Documentary,
    Lifestyle,
    Education,
    Religious,
    Institutional,
    Shopping,
    Adult,
    Other,
}

impl Domain {
    pub const ALL: [Domain; 16] = [
        Domain::General,
        Domain::News,
        Domain::Sports,
        Domain::Entertainment,
        Domain::Movies,
        Domain::Series,
        Domain::Kids,
        Domain::Music,
        Domain::Documentary,
        Domain::Lifestyle,
        Domain::Education,
        Domain::Religious,
        Domain::Institutional,
        Domain::Shopping,
        Domain::Adult,
        Domain::Other,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Domain::General => "general",
            Domain::News => "news",
            Domain::Sports => "sports",
            Domain::Entertainment => "entertainment",
            Domain::Movies => "movies",
            Domain::Series => "series",
            Domain::Kids => "kids",
            Domain::Music => "music",
            Domain::Documentary => "documentary",
            Domain::Lifestyle => "lifestyle",
            Domain::Education => "education",
            Domain::Religious => "religious",
            Domain::Institutional => "institutional",
            Domain::Shopping => "shopping",
            Domain::Adult => "adult",
            Domain::Other => "other",
        }
    }

    pub fn parse(value: &str) -> Option<Domain> {
        Domain::ALL.into_iter().find(|d| d.as_str() == value)
    }
}

/// What the classifier reads from an item. Nothing else: no URL, no network.
#[derive(Debug, Clone, Copy)]
pub struct ClassifyInput<'a> {
    /// `live`, `movie`, `episode` or `series`.
    pub kind: &'a str,
    pub group_title: Option<&'a str>,
    pub tvg_id: Option<&'a str>,
    pub name: &'a str,
    /// `tvg-country` / `country` attribute of the M3U line.
    pub country_attr: Option<&'a str>,
}

/// A correction made by the user (PRD-33 § 7). `None` fields keep the computed value.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TaxonomyOverride {
    /// ISO code or `INT`.
    pub country: Option<String>,
    pub domains: Option<Vec<Domain>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Classification {
    pub country: Option<CountryMatch>,
    /// Never empty; `other` when nothing matched.
    pub domains: Vec<DomainTag>,
}

impl Classification {
    pub fn primary_domain(&self) -> Domain {
        domain::primary_domain(&self.domains)
    }

    pub fn country_code(&self) -> Option<&str> {
        self.country.as_ref().map(|c| c.code.as_str())
    }

    pub fn has_domain(&self, domain: Domain) -> bool {
        self.domains.iter().any(|t| t.domain == domain)
    }
}

pub fn classify(input: &ClassifyInput<'_>) -> Classification {
    Classification { country: country::resolve_country(input), domains: domain::resolve_domains(input) }
}

/// `classify`, then the user's correction on top. A correction never removes the `adult` theme
/// found by the parental rule (PRD-33 § 11).
pub fn classify_with_override(input: &ClassifyInput<'_>, correction: Option<&TaxonomyOverride>) -> Classification {
    let mut result = classify(input);
    let Some(correction) = correction else { return result };
    if let Some(code) = &correction.country {
        result.country = Some(CountryMatch { code: code.clone(), source: CountrySource::User });
    }
    if let Some(domains) = correction.domains.as_ref().filter(|d| !d.is_empty()) {
        let adult = result.has_domain(Domain::Adult);
        result.domains = domains
            .iter()
            .map(|d| DomainTag { domain: *d, subdomain: None, source: DomainSource::User })
            .collect();
        if adult && !result.has_domain(Domain::Adult) {
            result.domains.push(DomainTag { domain: Domain::Adult, subdomain: None, source: DomainSource::Group });
        }
    }
    result
}
