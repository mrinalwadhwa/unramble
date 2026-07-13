use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

use async_trait::async_trait;
use freeflow_core::{
    FreeFlowError, HotkeyEvent, HotkeyProvider, Result, SessionType, Shortcut, ShortcutModifier,
};
use tokio::sync::broadcast;
use x11rb::{
    connection::Connection,
    protocol::{
        Event,
        xproto::{ConnectionExt, GrabMode, Keycode, ModMask},
    },
};

use crate::{PortalHotkeyProvider, detect_session_type, x11};

enum Command {
    Stop,
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct GrabBinding {
    key: Keycode,
    modifiers: ModMask,
}

#[derive(Clone)]
pub struct X11HotkeyProvider {
    events: broadcast::Sender<HotkeyEvent>,
    command: Arc<Mutex<Option<mpsc::Sender<Command>>>>,
    registered: Arc<AtomicBool>,
}

impl Default for X11HotkeyProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl X11HotkeyProvider {
    #[must_use]
    pub fn new() -> Self {
        let (events, _) = broadcast::channel(32);
        Self {
            events,
            command: Arc::new(Mutex::new(None)),
            registered: Arc::new(AtomicBool::new(false)),
        }
    }
}

#[async_trait]
impl HotkeyProvider for X11HotkeyProvider {
    async fn register(&self, shortcut: Shortcut) -> Result<()> {
        shortcut.validate()?;
        if self.registered.swap(true, Ordering::SeqCst) {
            return Err(FreeFlowError::Hotkey(
                "a global shortcut is already registered".into(),
            ));
        }

        let (command_sender, command_receiver) = mpsc::channel();
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        let event_sender = self.events.clone();
        let registered = self.registered.clone();
        std::thread::Builder::new()
            .name("freeflow-x11-hotkey".into())
            .spawn(move || {
                let result = run_hotkey_loop(
                    shortcut,
                    command_receiver,
                    event_sender,
                    ready_sender.clone(),
                );
                if let Err(error) = result {
                    let _ = ready_sender.send(Err(error));
                }
                registered.store(false, Ordering::SeqCst);
            })
            .map_err(|error| {
                self.registered.store(false, Ordering::SeqCst);
                FreeFlowError::Hotkey(format!("could not start shortcut listener: {error}"))
            })?;

        let result = tokio::task::spawn_blocking(move || ready_receiver.recv())
            .await
            .map_err(|error| FreeFlowError::Internal(error.to_string()))?
            .map_err(|_| FreeFlowError::Hotkey("shortcut listener exited during startup".into()))?;
        if let Err(error) = result {
            self.registered.store(false, Ordering::SeqCst);
            return Err(error);
        }
        *self
            .command
            .lock()
            .map_err(|_| FreeFlowError::Hotkey("shortcut command lock was poisoned".into()))? =
            Some(command_sender);
        Ok(())
    }

    async fn unregister(&self) -> Result<()> {
        if let Some(sender) = self
            .command
            .lock()
            .map_err(|_| FreeFlowError::Hotkey("shortcut command lock was poisoned".into()))?
            .take()
        {
            let _ = sender.send(Command::Stop);
        }
        self.registered.store(false, Ordering::SeqCst);
        Ok(())
    }

    fn events(&self) -> broadcast::Receiver<HotkeyEvent> {
        self.events.subscribe()
    }

    async fn is_registered(&self) -> bool {
        self.registered.load(Ordering::SeqCst)
    }
}

#[derive(Clone)]
pub struct LinuxHotkeyProvider {
    x11: X11HotkeyProvider,
    portal: PortalHotkeyProvider,
}

impl Default for LinuxHotkeyProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl LinuxHotkeyProvider {
    #[must_use]
    pub fn new() -> Self {
        Self {
            x11: X11HotkeyProvider::new(),
            portal: PortalHotkeyProvider::new(),
        }
    }
}

#[async_trait]
impl HotkeyProvider for LinuxHotkeyProvider {
    async fn register(&self, shortcut: Shortcut) -> Result<()> {
        match detect_session_type() {
            SessionType::X11 => self.x11.register(shortcut).await,
            SessionType::Wayland => self.portal.register(shortcut).await,
            SessionType::Unknown => Err(FreeFlowError::Hotkey(
                "no supported desktop shortcut service is available".into(),
            )),
        }
    }

    async fn unregister(&self) -> Result<()> {
        match detect_session_type() {
            SessionType::X11 => self.x11.unregister().await,
            SessionType::Wayland => self.portal.unregister().await,
            SessionType::Unknown => Ok(()),
        }
    }

    fn events(&self) -> broadcast::Receiver<HotkeyEvent> {
        match detect_session_type() {
            SessionType::Wayland => self.portal.events(),
            SessionType::X11 | SessionType::Unknown => self.x11.events(),
        }
    }

    async fn is_registered(&self) -> bool {
        match detect_session_type() {
            SessionType::X11 => self.x11.is_registered().await,
            SessionType::Wayland => self.portal.is_registered().await,
            SessionType::Unknown => false,
        }
    }
}

fn run_hotkey_loop(
    shortcut: Shortcut,
    commands: mpsc::Receiver<Command>,
    events: broadcast::Sender<HotkeyEvent>,
    ready: mpsc::SyncSender<Result<()>>,
) -> Result<()> {
    let (connection, screen) = x11::connect()
        .map_err(|error| FreeFlowError::Hotkey(format!("X11 is unavailable: {error}")))?;
    let root = connection.setup().roots[screen].root;
    let bindings = shortcut_bindings(&connection, &shortcut)?;
    let lock_variants = [
        ModMask::default(),
        ModMask::LOCK,
        ModMask::M2,
        ModMask::LOCK | ModMask::M2,
    ];
    for binding in &bindings {
        for locks in lock_variants {
            connection
                .grab_key(
                    false,
                    root,
                    binding.modifiers | locks,
                    binding.key,
                    GrabMode::ASYNC,
                    GrabMode::ASYNC,
                )
                .map_err(hotkey_error)?
                .check()
                .map_err(|error| {
                    FreeFlowError::Hotkey(format!(
                        "the shortcut is unavailable or owned by another application: {error}"
                    ))
                })?;
        }
    }
    connection.flush().map_err(hotkey_error)?;
    let _ = ready.send(Ok(()));

    let mut pressed = false;
    let mut pending_release: Option<Instant> = None;
    loop {
        match commands.try_recv() {
            Ok(Command::Stop) | Err(mpsc::TryRecvError::Disconnected) => break,
            Err(mpsc::TryRecvError::Empty) => {}
        }
        if pending_release.is_some_and(|time| time.elapsed() >= Duration::from_millis(25)) {
            pending_release = None;
            if pressed {
                pressed = false;
                let _ = events.send(HotkeyEvent::Released);
            }
        }
        match connection.poll_for_event().map_err(hotkey_error)? {
            Some(Event::KeyPress(event))
                if bindings.iter().any(|binding| binding.key == event.detail) =>
            {
                if pending_release
                    .take()
                    .is_some_and(|time| time.elapsed() < Duration::from_millis(25))
                {
                    continue;
                }
                if !pressed {
                    pressed = true;
                    let _ = events.send(HotkeyEvent::Pressed);
                }
            }
            Some(Event::KeyRelease(event))
                if bindings.iter().any(|binding| binding.key == event.detail) =>
            {
                pending_release = Some(Instant::now());
            }
            Some(_) | None => std::thread::sleep(Duration::from_millis(4)),
        }
    }
    for binding in bindings {
        for locks in lock_variants {
            let _ = connection.ungrab_key(binding.key, root, binding.modifiers | locks);
        }
    }
    let _ = connection.flush();
    Ok(())
}

fn shortcut_bindings(
    connection: &x11rb::rust_connection::RustConnection,
    shortcut: &Shortcut,
) -> Result<Vec<GrabBinding>> {
    if let Some(key) = shortcut.key.as_deref() {
        return Ok(vec![GrabBinding {
            key: x11::keycode_for_name(connection, key)?,
            modifiers: x11::modifier_mask(&shortcut.modifiers),
        }]);
    }

    let mut bindings = Vec::new();
    for (keysym, modifiers) in modifier_binding_specs(&shortcut.modifiers) {
        let Some(key) = x11::keycode_for_keysym(connection, keysym) else {
            continue;
        };
        let binding = GrabBinding { key, modifiers };
        if !bindings.contains(&binding) {
            bindings.push(binding);
        }
    }
    if bindings.is_empty() {
        return Err(FreeFlowError::Hotkey(
            "the current X11 keymap has no keys for the configured modifier chord".into(),
        ));
    }
    Ok(bindings)
}

fn modifier_binding_specs(modifiers: &[ShortcutModifier]) -> Vec<(u32, ModMask)> {
    let mut specs = Vec::new();
    for (index, trigger) in modifiers.iter().enumerate() {
        let required = modifiers
            .iter()
            .enumerate()
            .filter_map(|(candidate, modifier)| (candidate != index).then_some(*modifier))
            .collect::<Vec<_>>();
        let required_mask = x11::modifier_mask(&required);
        for keysym in modifier_keysyms(*trigger) {
            let spec = (*keysym, required_mask);
            if !specs.contains(&spec) {
                specs.push(spec);
            }
        }
    }
    specs
}

fn modifier_keysyms(modifier: ShortcutModifier) -> &'static [u32] {
    match modifier {
        ShortcutModifier::Control => &[xkeysym::key::Control_L, xkeysym::key::Control_R],
        ShortcutModifier::Alt => &[xkeysym::key::Alt_L, xkeysym::key::Alt_R],
        ShortcutModifier::Shift => &[xkeysym::key::Shift_L, xkeysym::key::Shift_R],
        ShortcutModifier::Super => &[xkeysym::key::Super_L, xkeysym::key::Super_R],
        ShortcutModifier::LeftControl => &[xkeysym::key::Control_L],
        ShortcutModifier::RightControl => &[xkeysym::key::Control_R],
        ShortcutModifier::LeftAlt => &[xkeysym::key::Alt_L],
        ShortcutModifier::RightAlt => &[xkeysym::key::Alt_R],
        ShortcutModifier::LeftShift => &[xkeysym::key::Shift_L],
        ShortcutModifier::RightShift => &[xkeysym::key::Shift_R],
        ShortcutModifier::LeftSuper => &[xkeysym::key::Super_L],
        ShortcutModifier::RightSuper => &[xkeysym::key::Super_R],
    }
}

fn hotkey_error(error: impl std::fmt::Display) -> FreeFlowError {
    FreeFlowError::Hotkey(format!("X11 shortcut operation failed: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_super_chord_can_activate_in_either_key_order() {
        let specs = modifier_binding_specs(&[ShortcutModifier::Control, ShortcutModifier::Super]);

        assert!(specs.contains(&(xkeysym::key::Control_L, ModMask::M4)));
        assert!(specs.contains(&(xkeysym::key::Control_R, ModMask::M4)));
        assert!(specs.contains(&(xkeysym::key::Super_L, ModMask::CONTROL)));
        assert!(specs.contains(&(xkeysym::key::Super_R, ModMask::CONTROL)));
    }
}
