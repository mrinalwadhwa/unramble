use std::process::Command;

use freeflow_core::AudioProvider;
use freeflow_platform_linux::LinuxAudioProvider;
use serde_json::Value;

fn cpal_pulse_clients_for_current_process() -> usize {
    let output = Command::new("pw-dump")
        .output()
        .expect("pw-dump must be installed for the live PulseAudio test");
    assert!(output.status.success(), "pw-dump should succeed");
    let graph: Vec<Value> =
        serde_json::from_slice(&output.stdout).expect("pw-dump should return JSON");
    let expected_name = format!("cpal-pulseaudio-{}", std::process::id());
    graph
        .iter()
        .filter(|object| {
            object.get("type").and_then(Value::as_str) == Some("PipeWire:Interface:Client")
        })
        .filter(|object| {
            object
                .pointer("/info/props/application.name")
                .and_then(Value::as_str)
                == Some(expected_name.as_str())
        })
        .count()
}

#[tokio::test]
#[ignore = "requires a live PulseAudio-compatible PipeWire session"]
async fn repeated_device_listing_reuses_one_pulse_connection() {
    let provider = LinuxAudioProvider::new();
    let before = cpal_pulse_clients_for_current_process();

    for _ in 0..96 {
        provider
            .available_devices()
            .await
            .expect("audio devices should remain enumerable");
    }

    let after = cpal_pulse_clients_for_current_process();
    assert!(
        after <= before + 1,
        "device listing opened {} new PulseAudio connections",
        after.saturating_sub(before)
    );
}
