use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

use ashpd::desktop::{
    CreateSessionOptions, Session,
    global_shortcuts::{BindShortcutsOptions, GlobalShortcuts, NewShortcut},
};
use async_trait::async_trait;
use freeflow_core::{FreeFlowError, HotkeyEvent, HotkeyProvider, Result, Shortcut};
use futures_util::StreamExt;
use serde_json::Value;
use tokio::{process::Command, sync::Mutex, task::JoinHandle, time::timeout};

const SHORTCUT_ID: &str = "push-to-talk";
const SHORTCUT_DESCRIPTION: &str = "Hold to dictate with FreeFlow";
const HYPRLAND_BIND_DESCRIPTION: &str = "FreeFlow push-to-talk";
const PORTAL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(8);

struct PortalRegistration {
    session: Session<GlobalShortcuts>,
    event_task: JoinHandle<()>,
    hyprland_bindings: Vec<HyprlandBinding>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct HyprlandBinding {
    modifiers: String,
    modmask: u64,
    key: String,
}

#[derive(Clone)]
pub struct PortalHotkeyProvider {
    events: tokio::sync::broadcast::Sender<HotkeyEvent>,
    registration: Arc<Mutex<Option<PortalRegistration>>>,
    registered: Arc<AtomicBool>,
}

impl Default for PortalHotkeyProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl PortalHotkeyProvider {
    #[must_use]
    pub fn new() -> Self {
        let (events, _) = tokio::sync::broadcast::channel(32);
        Self {
            events,
            registration: Arc::new(Mutex::new(None)),
            registered: Arc::new(AtomicBool::new(false)),
        }
    }

    async fn create_registration(&self, shortcut: &Shortcut) -> Result<PortalRegistration> {
        let portal = GlobalShortcuts::new().await.map_err(portal_error)?;
        let mut activated = portal.receive_activated().await.map_err(portal_error)?;
        let mut deactivated = portal.receive_deactivated().await.map_err(portal_error)?;
        let session = portal
            .create_session(CreateSessionOptions::default())
            .await
            .map_err(portal_error)?;
        let session_handle = serde_json::to_value(&session)
            .ok()
            .and_then(|value| value.as_str().map(ToOwned::to_owned))
            .ok_or_else(|| {
                FreeFlowError::Hotkey(
                    "the desktop portal returned an invalid shortcut session".into(),
                )
            })?;
        let mut descriptor = NewShortcut::new(SHORTCUT_ID, SHORTCUT_DESCRIPTION);
        let preferred = portal_trigger(shortcut);
        if let Some(preferred) = preferred.as_deref() {
            descriptor = descriptor.preferred_trigger(preferred);
        }
        let response = match portal
            .bind_shortcuts(
                &session,
                &[descriptor],
                None,
                BindShortcutsOptions::default(),
            )
            .await
            .map_err(portal_error)
            .and_then(|request| request.response().map_err(portal_error))
        {
            Ok(response) => response,
            Err(error) => {
                let _ = session.close().await;
                return Err(error);
            }
        };
        if !response
            .shortcuts()
            .iter()
            .any(|registered| registered.id() == SHORTCUT_ID)
        {
            let _ = session.close().await;
            return Err(FreeFlowError::Hotkey(
                "the desktop portal did not register the push-to-talk action".into(),
            ));
        }

        let hyprland_bindings = if is_hyprland() {
            match install_hyprland_bindings(shortcut).await {
                Ok(bindings) => bindings,
                Err(error) => {
                    let _ = session.close().await;
                    return Err(error);
                }
            }
        } else {
            Vec::new()
        };

        let events = self.events.clone();
        let registered = self.registered.clone();
        let event_task = tokio::spawn(async move {
            let mut pressed = false;
            loop {
                tokio::select! {
                    event = activated.next() => match event {
                        Some(event)
                            if event.session_handle().as_str() == session_handle
                                && event.shortcut_id() == SHORTCUT_ID
                                && !pressed => {
                            pressed = true;
                            let _ = events.send(HotkeyEvent::Pressed);
                        }
                        Some(_) => {}
                        None => break,
                    },
                    event = deactivated.next() => match event {
                        Some(event)
                            if event.session_handle().as_str() == session_handle
                                && event.shortcut_id() == SHORTCUT_ID
                                && pressed => {
                            pressed = false;
                            let _ = events.send(HotkeyEvent::Released);
                        }
                        Some(_) => {}
                        None => break,
                    },
                }
            }
            if pressed {
                let _ = events.send(HotkeyEvent::Released);
            }
            registered.store(false, Ordering::SeqCst);
        });

        Ok(PortalRegistration {
            session,
            event_task,
            hyprland_bindings,
        })
    }
}

#[async_trait]
impl HotkeyProvider for PortalHotkeyProvider {
    async fn register(&self, shortcut: Shortcut) -> Result<()> {
        shortcut.validate()?;
        if self.registered.swap(true, Ordering::SeqCst) {
            return Err(FreeFlowError::Hotkey(
                "a global shortcut is already registered".into(),
            ));
        }
        let registration = match timeout(PORTAL_TIMEOUT, self.create_registration(&shortcut)).await
        {
            Ok(Ok(registration)) => registration,
            Ok(Err(error)) => {
                self.registered.store(false, Ordering::SeqCst);
                return Err(error);
            }
            Err(_) => {
                self.registered.store(false, Ordering::SeqCst);
                return Err(FreeFlowError::Hotkey(
                    "the desktop portal did not respond while registering the shortcut".into(),
                ));
            }
        };
        *self.registration.lock().await = Some(registration);
        Ok(())
    }

    async fn unregister(&self) -> Result<()> {
        if let Some(registration) = self.registration.lock().await.take() {
            registration.event_task.abort();
            remove_hyprland_bindings(&registration.hyprland_bindings).await;
            registration.session.close().await.map_err(portal_error)?;
        }
        self.registered.store(false, Ordering::SeqCst);
        Ok(())
    }

    fn events(&self) -> tokio::sync::broadcast::Receiver<HotkeyEvent> {
        self.events.subscribe()
    }

    async fn is_registered(&self) -> bool {
        self.registered.load(Ordering::SeqCst)
    }
}

fn is_hyprland() -> bool {
    ["XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP"]
        .iter()
        .filter_map(|name| std::env::var(name).ok())
        .any(|value| value.to_ascii_lowercase().contains("hyprland"))
        || std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some()
}

async fn install_hyprland_bindings(shortcut: &Shortcut) -> Result<Vec<HyprlandBinding>> {
    let action = hyprland_global_action().await?;
    let bindings = hyprland_bindings(shortcut)?;
    let mut existing = hyprland_existing_bindings().await?;
    remove_stale_owned_hyprland_bindings(&existing, &bindings, &action).await?;
    existing = hyprland_existing_bindings().await?;
    let mut installed = Vec::new();
    for binding in &bindings {
        let conflicting = existing
            .iter()
            .find(|entry| hyprland_binding_matches(entry, binding));
        if let Some(conflicting) = conflicting {
            let description = conflicting
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if description == HYPRLAND_BIND_DESCRIPTION {
                if hyprland_binding_is_current(conflicting, &action) {
                    installed.push(binding.clone());
                    continue;
                }
                let binding_name = format!("{},{}", binding.modifiers, binding.key);
                run_hyprctl(&["keyword", "unbind", &binding_name]).await?;
            } else {
                rollback_hyprland_bindings(&installed).await;
                return Err(FreeFlowError::Hotkey(format!(
                    "{} is already assigned to {description}; change either shortcut and retry",
                    shortcut.display_name()
                )));
            }
        }
        let definition = format!(
            "{},{},{},global,{}",
            binding.modifiers, binding.key, HYPRLAND_BIND_DESCRIPTION, action
        );
        if let Err(error) = run_hyprctl(&["keyword", "bindd", &definition]).await {
            rollback_hyprland_bindings(&installed).await;
            return Err(error);
        }
        installed.push(binding.clone());
    }
    Ok(installed)
}

async fn remove_stale_owned_hyprland_bindings(
    existing: &[Value],
    desired: &[HyprlandBinding],
    action: &str,
) -> Result<()> {
    for entry in existing {
        if entry.get("description").and_then(Value::as_str) != Some(HYPRLAND_BIND_DESCRIPTION) {
            continue;
        }
        if desired
            .iter()
            .any(|binding| hyprland_binding_matches(entry, binding))
            && hyprland_binding_is_current(entry, action)
        {
            continue;
        }
        let Some(key) = entry.get("key").and_then(Value::as_str) else {
            continue;
        };
        let Some(modmask) = entry.get("modmask").and_then(Value::as_u64) else {
            continue;
        };
        if !safe_hyprland_key(key) {
            continue;
        }
        let binding_name = format!("{},{}", hyprland_modifiers_from_mask(modmask), key);
        run_hyprctl(&["keyword", "unbind", &binding_name]).await?;
    }
    Ok(())
}

fn hyprland_binding_matches(entry: &Value, binding: &HyprlandBinding) -> bool {
    entry.get("modmask").and_then(Value::as_u64) == Some(binding.modmask)
        && entry.get("key").and_then(Value::as_str) == Some(binding.key.as_str())
}

fn hyprland_binding_is_current(entry: &Value, action: &str) -> bool {
    entry.get("description").and_then(Value::as_str) == Some(HYPRLAND_BIND_DESCRIPTION)
        && entry.get("dispatcher").and_then(Value::as_str) == Some("global")
        && entry.get("arg").and_then(Value::as_str) == Some(action)
}

async fn hyprland_global_action() -> Result<String> {
    let output = run_hyprctl(&["-j", "globalshortcuts"]).await?;
    let shortcuts: Vec<Value> = serde_json::from_str(&output).map_err(|error| {
        FreeFlowError::Hotkey(format!(
            "Hyprland returned invalid shortcut metadata: {error}"
        ))
    })?;
    let candidates: Vec<String> = shortcuts
        .iter()
        .filter(|shortcut| {
            shortcut.get("description").and_then(Value::as_str) == Some(SHORTCUT_DESCRIPTION)
                && shortcut
                    .get("name")
                    .and_then(Value::as_str)
                    .is_some_and(|name| name.ends_with(&format!(":{SHORTCUT_ID}")))
        })
        .filter_map(|shortcut| shortcut.get("name"))
        .filter_map(Value::as_str)
        .filter(|name| {
            name.chars()
                .all(|character| character.is_ascii_alphanumeric() || "._:-".contains(character))
        })
        .map(ToOwned::to_owned)
        .collect();
    select_hyprland_action(&candidates, &process_ancestry_names()).ok_or_else(|| {
        FreeFlowError::Hotkey(
            "Hyprland did not expose the registered FreeFlow portal shortcut".into(),
        )
    })
}

fn select_hyprland_action(candidates: &[String], process_names: &[String]) -> Option<String> {
    let process_names: Vec<String> = process_names
        .iter()
        .map(|name| normalize_application_name(name))
        .filter(|name| !name.is_empty())
        .collect();
    candidates
        .iter()
        .filter_map(|candidate| {
            let prefix = candidate.split(':').next().unwrap_or_default();
            let prefix = normalize_application_name(prefix);
            process_names
                .iter()
                .position(|name| name == &prefix)
                .map(|distance| (distance, candidate))
        })
        .min_by_key(|(distance, _)| *distance)
        .map(|(_, candidate)| candidate.clone())
        .or_else(|| (candidates.len() == 1).then(|| candidates[0].clone()))
}

fn normalize_application_name(name: &str) -> String {
    name.chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

fn process_ancestry_names() -> Vec<String> {
    let mut names = Vec::new();
    let mut pid = std::process::id();
    for _ in 0..8 {
        if let Ok(name) = std::fs::read_to_string(format!("/proc/{pid}/comm")) {
            let name = name.trim();
            if !name.is_empty() {
                names.push(name.to_owned());
            }
        }
        if let Ok(path) = std::fs::read_link(format!("/proc/{pid}/exe"))
            && let Some(name) = path.file_name().and_then(|name| name.to_str())
        {
            names.push(name.to_owned());
        }
        let Ok(status) = std::fs::read_to_string(format!("/proc/{pid}/status")) else {
            break;
        };
        let Some(parent) = status
            .lines()
            .find_map(|line| line.strip_prefix("PPid:").map(str::trim))
            .and_then(|value| value.parse::<u32>().ok())
        else {
            break;
        };
        if parent == 0 || parent == pid {
            break;
        }
        pid = parent;
    }
    names
}

async fn hyprland_existing_bindings() -> Result<Vec<Value>> {
    let output = run_hyprctl(&["-j", "binds"]).await?;
    serde_json::from_str(&output).map_err(|error| {
        FreeFlowError::Hotkey(format!(
            "Hyprland returned invalid binding metadata: {error}"
        ))
    })
}

fn hyprland_bindings(shortcut: &Shortcut) -> Result<Vec<HyprlandBinding>> {
    let modifiers = hyprland_modifiers(shortcut);
    if let Some(key) = shortcut.key.as_deref() {
        if !safe_hyprland_key(key) {
            return Err(FreeFlowError::Hotkey(
                "the configured key name is not safe for a Hyprland binding".into(),
            ));
        }
        return Ok(vec![HyprlandBinding {
            modifiers,
            modmask: hyprland_modmask(shortcut),
            key: key.to_owned(),
        }]);
    }

    let mut bindings = Vec::new();
    for modifier in &shortcut.modifiers {
        let excluded_family = hyprland_modifier_name(modifier);
        let modifiers = hyprland_modifiers_except(shortcut, Some(excluded_family));
        let modmask = hyprland_modmask(shortcut) & !hyprland_modifier_mask(modifier);
        for key in hyprland_key_candidates(modifier) {
            if !bindings
                .iter()
                .any(|binding: &HyprlandBinding| binding.key == *key)
            {
                bindings.push(HyprlandBinding {
                    modifiers: modifiers.clone(),
                    modmask,
                    key: (*key).into(),
                });
            }
        }
    }
    Ok(bindings)
}

fn hyprland_modifiers(shortcut: &Shortcut) -> String {
    hyprland_modifiers_except(shortcut, None)
}

fn hyprland_modifiers_except(shortcut: &Shortcut, excluded: Option<&str>) -> String {
    let mut result = String::new();
    for name in ["SHIFT", "CTRL", "ALT", "SUPER"] {
        if excluded != Some(name)
            && shortcut
                .modifiers
                .iter()
                .any(|modifier| hyprland_modifier_name(modifier) == name)
        {
            result.push_str(name);
        }
    }
    result
}

fn hyprland_modmask(shortcut: &Shortcut) -> u64 {
    shortcut
        .modifiers
        .iter()
        .fold(0, |mask, modifier| mask | hyprland_modifier_mask(modifier))
}

fn hyprland_modifier_name(modifier: &freeflow_core::ShortcutModifier) -> &'static str {
    match modifier {
        freeflow_core::ShortcutModifier::Shift
        | freeflow_core::ShortcutModifier::LeftShift
        | freeflow_core::ShortcutModifier::RightShift => "SHIFT",
        freeflow_core::ShortcutModifier::Control
        | freeflow_core::ShortcutModifier::LeftControl
        | freeflow_core::ShortcutModifier::RightControl => "CTRL",
        freeflow_core::ShortcutModifier::Alt
        | freeflow_core::ShortcutModifier::LeftAlt
        | freeflow_core::ShortcutModifier::RightAlt => "ALT",
        freeflow_core::ShortcutModifier::Super
        | freeflow_core::ShortcutModifier::LeftSuper
        | freeflow_core::ShortcutModifier::RightSuper => "SUPER",
    }
}

fn hyprland_modifier_mask(modifier: &freeflow_core::ShortcutModifier) -> u64 {
    match modifier {
        freeflow_core::ShortcutModifier::Shift
        | freeflow_core::ShortcutModifier::LeftShift
        | freeflow_core::ShortcutModifier::RightShift => 1,
        freeflow_core::ShortcutModifier::Control
        | freeflow_core::ShortcutModifier::LeftControl
        | freeflow_core::ShortcutModifier::RightControl => 4,
        freeflow_core::ShortcutModifier::Alt
        | freeflow_core::ShortcutModifier::LeftAlt
        | freeflow_core::ShortcutModifier::RightAlt => 8,
        freeflow_core::ShortcutModifier::Super
        | freeflow_core::ShortcutModifier::LeftSuper
        | freeflow_core::ShortcutModifier::RightSuper => 64,
    }
}

fn hyprland_modifiers_from_mask(mask: u64) -> String {
    let mut result = String::new();
    for (bit, name) in [(1, "SHIFT"), (4, "CTRL"), (8, "ALT"), (64, "SUPER")] {
        if mask & bit != 0 {
            result.push_str(name);
        }
    }
    result
}

fn hyprland_key_candidates(modifier: &freeflow_core::ShortcutModifier) -> &'static [&'static str] {
    match modifier {
        freeflow_core::ShortcutModifier::Control => &["Control_L", "Control_R"],
        freeflow_core::ShortcutModifier::LeftControl => &["Control_L"],
        freeflow_core::ShortcutModifier::RightControl => &["Control_R"],
        freeflow_core::ShortcutModifier::Alt => &["Alt_L", "Alt_R"],
        freeflow_core::ShortcutModifier::LeftAlt => &["Alt_L"],
        freeflow_core::ShortcutModifier::RightAlt => &["Alt_R"],
        freeflow_core::ShortcutModifier::Shift => &["Shift_L", "Shift_R"],
        freeflow_core::ShortcutModifier::LeftShift => &["Shift_L"],
        freeflow_core::ShortcutModifier::RightShift => &["Shift_R"],
        freeflow_core::ShortcutModifier::Super => &["Super_L", "Super_R"],
        freeflow_core::ShortcutModifier::LeftSuper => &["Super_L"],
        freeflow_core::ShortcutModifier::RightSuper => &["Super_R"],
    }
}

fn safe_hyprland_key(key: &str) -> bool {
    !key.is_empty()
        && key
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "_:-".contains(character))
}

async fn remove_hyprland_bindings(bindings: &[HyprlandBinding]) {
    let existing = hyprland_existing_bindings().await.unwrap_or_default();
    for binding in bindings {
        let owned = existing.iter().any(|entry| {
            entry.get("key").and_then(Value::as_str) == Some(binding.key.as_str())
                && entry.get("description").and_then(Value::as_str)
                    == Some(HYPRLAND_BIND_DESCRIPTION)
        });
        if owned {
            let binding_name = format!("{},{}", binding.modifiers, binding.key);
            let _ = run_hyprctl(&["keyword", "unbind", &binding_name]).await;
        }
    }
}

async fn rollback_hyprland_bindings(bindings: &[HyprlandBinding]) {
    for binding in bindings {
        let binding_name = format!("{},{}", binding.modifiers, binding.key);
        let _ = run_hyprctl(&["keyword", "unbind", &binding_name]).await;
    }
}

async fn run_hyprctl(arguments: &[&str]) -> Result<String> {
    let output = Command::new("hyprctl")
        .args(arguments)
        .output()
        .await
        .map_err(|error| {
            FreeFlowError::Hotkey(format!("could not run Hyprland shortcut control: {error}"))
        })?;
    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr);
        return Err(FreeFlowError::Hotkey(format!(
            "Hyprland rejected the shortcut: {}",
            message.trim().chars().take(240).collect::<String>()
        )));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn portal_trigger(shortcut: &Shortcut) -> Option<String> {
    let key = shortcut.key.as_deref()?;
    let mut trigger = String::new();
    for modifier in &shortcut.modifiers {
        trigger.push_str(match modifier {
            freeflow_core::ShortcutModifier::Control
            | freeflow_core::ShortcutModifier::LeftControl
            | freeflow_core::ShortcutModifier::RightControl => "<Control>",
            freeflow_core::ShortcutModifier::Alt
            | freeflow_core::ShortcutModifier::LeftAlt
            | freeflow_core::ShortcutModifier::RightAlt => "<Alt>",
            freeflow_core::ShortcutModifier::Shift
            | freeflow_core::ShortcutModifier::LeftShift
            | freeflow_core::ShortcutModifier::RightShift => "<Shift>",
            freeflow_core::ShortcutModifier::Super
            | freeflow_core::ShortcutModifier::LeftSuper
            | freeflow_core::ShortcutModifier::RightSuper => "<Super>",
        });
    }
    trigger.push_str(key);
    Some(trigger)
}

fn portal_error(error: impl std::fmt::Display) -> FreeFlowError {
    FreeFlowError::Hotkey(format!("desktop portal shortcut operation failed: {error}"))
}

#[cfg(test)]
mod tests {
    use freeflow_core::ShortcutModifier;

    use super::*;

    #[test]
    fn builds_an_xdg_trigger_for_key_shortcuts() {
        let shortcut = Shortcut {
            modifiers: vec![ShortcutModifier::Control, ShortcutModifier::Super],
            key: Some("space".into()),
        };
        assert_eq!(
            portal_trigger(&shortcut).as_deref(),
            Some("<Control><Super>space")
        );
    }

    #[test]
    fn leaves_modifier_only_shortcuts_for_the_compositor() {
        assert_eq!(portal_trigger(&Shortcut::default_linux()), None);
    }

    #[test]
    fn expands_modifier_only_hyprland_bindings_for_both_key_orders() {
        let bindings = hyprland_bindings(&Shortcut::default_linux()).unwrap();
        assert_eq!(bindings.len(), 4);
        assert!(bindings.contains(&HyprlandBinding {
            modifiers: "SUPER".into(),
            modmask: 64,
            key: "Control_L".into(),
        }));
        assert!(bindings.contains(&HyprlandBinding {
            modifiers: "CTRL".into(),
            modmask: 4,
            key: "Super_L".into(),
        }));
        assert_eq!(hyprland_modmask(&Shortcut::default_linux()), 68);
        assert_eq!(hyprland_modifiers_from_mask(68), "CTRLSUPER");
    }

    #[test]
    fn rejects_a_stale_owned_hyprland_action() {
        let entry = serde_json::json!({
            "modmask": 68,
            "key": "Super_L",
            "description": HYPRLAND_BIND_DESCRIPTION,
            "dispatcher": "global",
            "arg": "old-app:push-to-talk"
        });
        assert!(hyprland_binding_matches(
            &entry,
            &HyprlandBinding {
                modifiers: "CTRLSUPER".into(),
                modmask: 68,
                key: "Super_L".into(),
            }
        ));
        assert!(!hyprland_binding_is_current(
            &entry,
            "freeflow:push-to-talk"
        ));
    }

    #[test]
    fn selects_the_portal_action_owned_by_the_current_application() {
        let candidates = vec!["t3code:push-to-talk".into(), "FreeFlow:push-to-talk".into()];
        let process_names = vec![
            "freeflow-daemon".into(),
            "freeflow".into(),
            "T3-Code".into(),
        ];
        assert_eq!(
            select_hyprland_action(&candidates, &process_names).as_deref(),
            Some("FreeFlow:push-to-talk")
        );
    }
}
