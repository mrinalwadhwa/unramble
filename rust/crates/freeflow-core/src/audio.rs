use crate::{
    AMBIENT_MULTIPLIER, AudioBuffer, CAPTURE_BITS_PER_SAMPLE, CAPTURE_SAMPLE_RATE,
    DEFAULT_SILENCE_THRESHOLD, FAR_FIELD_SILENCE_THRESHOLD, FreeFlowError,
    MAXIMUM_ADAPTIVE_THRESHOLD, MINIMUM_ADAPTIVE_THRESHOLD, MicProximity, Result,
};

pub const WAV_HEADER_SIZE: usize = 44;
pub const AMBIENT_CALIBRATION_SAMPLES: usize = (CAPTURE_SAMPLE_RATE as usize) / 2;
pub const TARGET_GAIN_RMS: f32 = 0.02;
pub const MAX_GAIN: f32 = 16.0;

#[must_use]
pub fn rms_i16(samples: &[i16]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum = samples.iter().fold(0.0_f64, |acc, sample| {
        let normalized = f64::from(*sample) / 32_768.0;
        acc + normalized * normalized
    });
    ((sum / samples.len() as f64).sqrt() as f32).min(1.0)
}

#[must_use]
pub fn rms_f32(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum = samples.iter().fold(0.0_f64, |acc, sample| {
        let clamped = f64::from(sample.clamp(-1.0, 1.0));
        acc + clamped * clamped
    });
    ((sum / samples.len() as f64).sqrt() as f32).min(1.0)
}

#[must_use]
pub fn compute_gain_factor(ambient_rms: f32, proximity: MicProximity) -> f32 {
    if proximity != MicProximity::FarField || ambient_rms <= 0.0 {
        return 1.0;
    }
    (TARGET_GAIN_RMS / ambient_rms).clamp(1.0, MAX_GAIN)
}

#[must_use]
pub fn apply_gain(samples: &[i16], gain: f32) -> Vec<i16> {
    if gain <= 1.0 {
        return samples.to_vec();
    }
    samples
        .iter()
        .map(|sample| {
            let amplified = (f32::from(*sample) * gain) as i32;
            amplified.clamp(i32::from(i16::MIN), i32::from(i16::MAX)) as i16
        })
        .collect()
}

#[must_use]
pub fn effective_silence_threshold(
    ambient_rms: f32,
    proximity: MicProximity,
    fallback: f32,
) -> f32 {
    if proximity == MicProximity::FarField {
        return FAR_FIELD_SILENCE_THRESHOLD;
    }
    if ambient_rms > 0.0 {
        return (ambient_rms * AMBIENT_MULTIPLIER)
            .clamp(MINIMUM_ADAPTIVE_THRESHOLD, MAXIMUM_ADAPTIVE_THRESHOLD);
    }
    fallback
}

/// Track raw microphone levels while preserving the native silence semantics.
#[derive(Debug, Clone)]
pub struct AudioMeter {
    peak_rms: f32,
    ambient_sum_squares: f64,
    ambient_samples: usize,
    ambient_rms: f32,
    gain: f32,
    proximity: MicProximity,
}

impl AudioMeter {
    #[must_use]
    pub fn new(proximity: MicProximity) -> Self {
        Self {
            peak_rms: 0.0,
            ambient_sum_squares: 0.0,
            ambient_samples: 0,
            ambient_rms: 0.0,
            gain: 1.0,
            proximity,
        }
    }

    /// Observe normalized mono samples and return the HUD level in `0...1`.
    pub fn observe(&mut self, samples: &[f32]) -> f32 {
        let rms = rms_f32(samples);
        self.peak_rms = self.peak_rms.max(rms);

        if self.ambient_samples < AMBIENT_CALIBRATION_SAMPLES {
            let remaining = AMBIENT_CALIBRATION_SAMPLES - self.ambient_samples;
            let accepted = samples.len().min(remaining);
            for sample in &samples[..accepted] {
                let sample = f64::from(sample.clamp(-1.0, 1.0));
                self.ambient_sum_squares += sample * sample;
            }
            self.ambient_samples += accepted;
            if self.ambient_samples >= AMBIENT_CALIBRATION_SAMPLES {
                self.ambient_rms =
                    (self.ambient_sum_squares / self.ambient_samples as f64).sqrt() as f32;
                self.gain = compute_gain_factor(self.ambient_rms, self.proximity);
            }
        }

        ((rms * self.gain * 25.0).sqrt()).clamp(0.0, 1.0)
    }

    #[must_use]
    pub fn peak_rms(&self) -> f32 {
        self.peak_rms
    }

    #[must_use]
    pub fn ambient_rms(&self) -> f32 {
        self.ambient_rms
    }

    #[must_use]
    pub fn gain(&self) -> f32 {
        self.gain
    }
}

/// Incrementally resample normalized mono samples using linear interpolation.
#[derive(Debug, Clone)]
pub struct StreamingResampler {
    source_rate: u32,
    target_rate: u32,
    source_position: f64,
    buffered: Vec<f32>,
    total_input: usize,
    total_output: usize,
}

impl StreamingResampler {
    #[must_use]
    pub fn new(source_rate: u32, target_rate: u32) -> Self {
        Self {
            source_rate,
            target_rate,
            source_position: 0.0,
            buffered: Vec::new(),
            total_input: 0,
            total_output: 0,
        }
    }

    pub fn process(&mut self, samples: &[f32]) -> Vec<f32> {
        if samples.is_empty() || self.source_rate == 0 || self.target_rate == 0 {
            return Vec::new();
        }
        self.total_input += samples.len();
        self.buffered.extend_from_slice(samples);

        if self.source_rate == self.target_rate {
            let output = std::mem::take(&mut self.buffered);
            self.total_output += output.len();
            return output;
        }

        let step = f64::from(self.source_rate) / f64::from(self.target_rate);
        let mut output = Vec::new();
        while self.source_position + 1.0 < self.buffered.len() as f64 {
            let left = self.source_position.floor() as usize;
            let fraction = (self.source_position - left as f64) as f32;
            let value =
                self.buffered[left] + (self.buffered[left + 1] - self.buffered[left]) * fraction;
            output.push(value);
            self.source_position += step;
        }

        let consumed = self.source_position.floor() as usize;
        if consumed > 0 {
            self.buffered.drain(..consumed);
            self.source_position -= consumed as f64;
        }
        self.total_output += output.len();
        output
    }

    pub fn finish(&mut self) -> Vec<f32> {
        if self.source_rate == 0 || self.target_rate == 0 || self.total_input == 0 {
            self.buffered.clear();
            return Vec::new();
        }
        let expected = ((self.total_input as f64 * f64::from(self.target_rate)
            / f64::from(self.source_rate))
        .round()) as usize;
        let mut output = Vec::with_capacity(expected.saturating_sub(self.total_output));
        let last = self.buffered.last().copied().unwrap_or(0.0);
        self.buffered.push(last);
        let step = f64::from(self.source_rate) / f64::from(self.target_rate);
        while self.total_output + output.len() < expected
            && self.source_position + 1.0 < self.buffered.len() as f64
        {
            let left = self.source_position.floor() as usize;
            let fraction = (self.source_position - left as f64) as f32;
            output.push(
                self.buffered[left] + (self.buffered[left + 1] - self.buffered[left]) * fraction,
            );
            self.source_position += step;
        }
        self.total_output += output.len();
        self.buffered.clear();
        output
    }
}

#[must_use]
pub fn normalized_to_i16(samples: &[f32]) -> Vec<i16> {
    samples
        .iter()
        .map(|sample| {
            let scaled = sample.clamp(-1.0, 1.0) * 32_768.0;
            scaled.clamp(f32::from(i16::MIN), f32::from(i16::MAX)) as i16
        })
        .collect()
}

#[must_use]
pub fn resample_i16(samples: &[i16], source_rate: u32, target_rate: u32) -> Vec<i16> {
    if source_rate == target_rate {
        return samples.to_vec();
    }
    let normalized: Vec<f32> = samples
        .iter()
        .map(|sample| f32::from(*sample) / 32_768.0)
        .collect();
    let mut resampler = StreamingResampler::new(source_rate, target_rate);
    let mut output = resampler.process(&normalized);
    output.extend(resampler.finish());
    normalized_to_i16(&output)
}

#[must_use]
pub fn encode_wav(samples: &[i16], sample_rate: u32, channels: u16) -> Vec<u8> {
    let data_size = samples.len().saturating_mul(2);
    let data_size_u32 = u32::try_from(data_size).unwrap_or(u32::MAX - WAV_HEADER_SIZE as u32);
    let block_align = channels.saturating_mul(CAPTURE_BITS_PER_SAMPLE / 8);
    let byte_rate = sample_rate.saturating_mul(u32::from(block_align));
    let mut output = Vec::with_capacity(WAV_HEADER_SIZE + data_size);
    output.extend_from_slice(b"RIFF");
    output.extend_from_slice(&(36_u32.saturating_add(data_size_u32)).to_le_bytes());
    output.extend_from_slice(b"WAVE");
    output.extend_from_slice(b"fmt ");
    output.extend_from_slice(&16_u32.to_le_bytes());
    output.extend_from_slice(&1_u16.to_le_bytes());
    output.extend_from_slice(&channels.to_le_bytes());
    output.extend_from_slice(&sample_rate.to_le_bytes());
    output.extend_from_slice(&byte_rate.to_le_bytes());
    output.extend_from_slice(&block_align.to_le_bytes());
    output.extend_from_slice(&CAPTURE_BITS_PER_SAMPLE.to_le_bytes());
    output.extend_from_slice(b"data");
    output.extend_from_slice(&data_size_u32.to_le_bytes());
    for sample in samples.iter().take(data_size_u32 as usize / 2) {
        output.extend_from_slice(&sample.to_le_bytes());
    }
    output
}

pub fn decode_wav(bytes: &[u8]) -> Result<AudioBuffer> {
    if bytes.len() < WAV_HEADER_SIZE || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err(FreeFlowError::InvalidResponse(
            "audio file is not a RIFF/WAV stream".into(),
        ));
    }
    let channels = u16::from_le_bytes([bytes[22], bytes[23]]);
    let sample_rate = u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]);
    let bits = u16::from_le_bytes([bytes[34], bytes[35]]);
    if channels == 0 || bits != 16 {
        return Err(FreeFlowError::InvalidResponse(
            "only 16-bit PCM WAV audio is supported".into(),
        ));
    }

    let mut offset = 12;
    let mut data = None;
    while offset + 8 <= bytes.len() {
        let chunk_id = &bytes[offset..offset + 4];
        let size = u32::from_le_bytes([
            bytes[offset + 4],
            bytes[offset + 5],
            bytes[offset + 6],
            bytes[offset + 7],
        ]) as usize;
        let start = offset + 8;
        let end = start.saturating_add(size).min(bytes.len());
        if chunk_id == b"data" {
            data = Some(&bytes[start..end]);
            break;
        }
        offset = start.saturating_add(size + (size % 2));
    }
    let data =
        data.ok_or_else(|| FreeFlowError::InvalidResponse("WAV stream has no data chunk".into()))?;
    let samples: Vec<i16> = data
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    let peak_rms = rms_i16(&samples);
    Ok(AudioBuffer {
        samples,
        sample_rate,
        channels,
        peak_rms,
        ambient_rms: 0.0,
        gain: 1.0,
        device_name: "WAV file".into(),
        proximity: MicProximity::NearField,
    })
}

#[must_use]
pub fn is_silent(buffer: &AudioBuffer) -> bool {
    let threshold = effective_silence_threshold(
        buffer.ambient_rms,
        buffer.proximity,
        DEFAULT_SILENCE_THRESHOLD,
    );
    buffer.peak_rms <= threshold
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rms_matches_known_signal() {
        let samples = [3_000, -3_000, 3_000, -3_000];
        let expected = 3_000.0 / 32_768.0;
        assert!((rms_i16(&samples) - expected).abs() < 0.000_01);
        assert_eq!(rms_i16(&[]), 0.0);
    }

    #[test]
    fn adaptive_threshold_is_clamped() {
        assert_eq!(
            effective_silence_threshold(0.0001, MicProximity::NearField, 0.005),
            0.0005
        );
        assert_eq!(
            effective_silence_threshold(0.02, MicProximity::NearField, 0.005),
            0.01
        );
        assert_eq!(
            effective_silence_threshold(0.0, MicProximity::FarField, 0.005),
            0.001
        );
    }

    #[test]
    fn far_field_gain_clamps_and_prevents_clipping() {
        assert_eq!(compute_gain_factor(0.001, MicProximity::FarField), 16.0);
        assert!((compute_gain_factor(0.002, MicProximity::FarField) - 10.0).abs() < 0.001);
        assert_eq!(compute_gain_factor(0.001, MicProximity::NearField), 1.0);
        assert_eq!(apply_gain(&[3_000, -3_000], 16.0), [i16::MAX, i16::MIN]);
    }

    #[test]
    fn resampling_preserves_duration_and_endpoints() {
        let input: Vec<i16> = (0..16_000)
            .map(|index| {
                (((index as f32 / 16_000.0) * std::f32::consts::TAU * 440.0).sin() * 10_000.0)
                    as i16
            })
            .collect();
        let output = resample_i16(&input, 16_000, 24_000);
        assert_eq!(output.len(), 24_000);
        assert!(rms_i16(&output) > 0.2);
    }

    #[test]
    fn streaming_resampler_matches_one_shot_length() {
        let input = vec![0.25_f32; 16_000];
        let mut resampler = StreamingResampler::new(16_000, 24_000);
        let mut output = Vec::new();
        for chunk in input.chunks(137) {
            output.extend(resampler.process(chunk));
        }
        output.extend(resampler.finish());
        assert_eq!(output.len(), 24_000);
        assert!(
            output
                .iter()
                .all(|value| (*value - 0.25).abs() < f32::EPSILON)
        );
    }

    #[test]
    fn wav_round_trip_has_standard_header() {
        let samples = [0, 1, -1, i16::MAX, i16::MIN];
        let wav = encode_wav(&samples, 16_000, 1);
        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(&wav[36..40], b"data");
        assert_eq!(wav.len(), 44 + samples.len() * 2);
        let decoded = decode_wav(&wav).unwrap();
        assert_eq!(decoded.samples, samples);
        assert_eq!(decoded.sample_rate, 16_000);
        assert_eq!(decoded.channels, 1);
    }

    #[test]
    fn meter_calibrates_after_half_second() {
        let mut meter = AudioMeter::new(MicProximity::FarField);
        let samples = vec![0.002_f32; AMBIENT_CALIBRATION_SAMPLES];
        meter.observe(&samples);
        assert!((meter.ambient_rms() - 0.002).abs() < 0.000_01);
        assert!((meter.gain() - 10.0).abs() < 0.001);
        assert!((meter.peak_rms() - 0.002).abs() < 0.000_01);
    }
}
