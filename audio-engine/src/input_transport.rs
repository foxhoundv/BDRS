use anyhow::Result;

pub const DANTE_MAX_SOURCES_LIMIT: u16 = 64;
pub const DANTE_SUPPORTED_SAMPLE_RATES_HZ: [u32; 3] = [44_100, 48_000, 96_000];

#[derive(Debug, Clone)]
pub struct DanteTransportConfig {
    pub sample_rate_hz: u32,
    pub max_sources: u16,
}

pub trait InputTransportBackend {
    fn backend_name(&self) -> &'static str;
    fn validate_contract(&self) -> Result<()>;
}

#[derive(Debug, Clone)]
pub struct DanteBackend {
    pub config: DanteTransportConfig,
}

impl InputTransportBackend for DanteBackend {
    fn backend_name(&self) -> &'static str {
        "dante"
    }

    fn validate_contract(&self) -> Result<()> {
        if !DANTE_SUPPORTED_SAMPLE_RATES_HZ.contains(&self.config.sample_rate_hz) {
            anyhow::bail!(
                "unsupported Dante sample rate {}. Supported: 44100, 48000, 96000",
                self.config.sample_rate_hz
            );
        }

        if self.config.max_sources == 0 || self.config.max_sources > DANTE_MAX_SOURCES_LIMIT {
            anyhow::bail!(
                "invalid Dante source count {}. Allowed range: 1..={} sources",
                self.config.max_sources,
                DANTE_MAX_SOURCES_LIMIT
            );
        }

        Ok(())
    }
}

pub fn build_dante_placeholder(config: DanteTransportConfig) -> Result<DanteBackend> {
    let backend = DanteBackend { config };
    backend.validate_contract()?;
    Ok(backend)
}
