use freeflow_core::{AppContext, TextInjector};
use freeflow_platform_linux::LinuxTextInjector;

#[tokio::test]
#[ignore = "requires an interactive Wayland session and focused editable field"]
async fn pastes_into_the_focused_wayland_field() {
    let text = std::env::var("FREEFLOW_WAYLAND_TEST_TEXT")
        .expect("set FREEFLOW_WAYLAND_TEST_TEXT to run the interactive injection test");
    let result = LinuxTextInjector::new()
        .inject(&text, &AppContext::default())
        .await
        .expect("Wayland injection should succeed");

    assert!(result.pasted);
    assert!(!result.requires_manual_paste);
    assert_eq!(result.strategy, "waylandClipboardCtrlV");
}
