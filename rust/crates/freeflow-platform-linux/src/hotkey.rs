use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

use async_trait::async_trait;
use freeflow_core::{FreeFlowError, HotkeyEvent, HotkeyProvider, Result, Shortcut};
use tokio::sync::broadcast;
use x11rb::{
    connection::Connection,
    protocol::{
        Event,
        xproto::{ConnectionExt, GrabMode, ModMask},
    },
};

use crate::x11;

enum Command {
    Stop,
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
        if shortcut.is_modifier_only() {
            return Err(FreeFlowError::Hotkey(
                "modifier-only shortcuts require XInput2 and are not available in this build; choose a modifier-plus-key shortcut"
                    .into(),
            ));
        }
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

fn run_hotkey_loop(
    shortcut: Shortcut,
    commands: mpsc::Receiver<Command>,
    events: broadcast::Sender<HotkeyEvent>,
    ready: mpsc::SyncSender<Result<()>>,
) -> Result<()> {
    let (connection, screen) = x11::connect()
        .map_err(|error| FreeFlowError::Hotkey(format!("X11 is unavailable: {error}")))?;
    let root = connection.setup().roots[screen].root;
    let key = x11::keycode_for_name(
        &connection,
        shortcut
            .key
            .as_deref()
            .expect("validated ordinary shortcut"),
    )?;
    let modifiers = x11::modifier_mask(&shortcut.modifiers);
    let lock_variants = [
        ModMask::default(),
        ModMask::LOCK,
        ModMask::M2,
        ModMask::LOCK | ModMask::M2,
    ];
    for locks in lock_variants {
        connection
            .grab_key(
                false,
                root,
                modifiers | locks,
                key,
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
            Some(Event::KeyPress(event)) if event.detail == key => {
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
            Some(Event::KeyRelease(event)) if event.detail == key => {
                pending_release = Some(Instant::now());
            }
            Some(_) | None => std::thread::sleep(Duration::from_millis(4)),
        }
    }
    for locks in lock_variants {
        let _ = connection.ungrab_key(key, root, modifiers | locks);
    }
    let _ = connection.flush();
    Ok(())
}

fn hotkey_error(error: impl std::fmt::Display) -> FreeFlowError {
    FreeFlowError::Hotkey(format!("X11 shortcut operation failed: {error}"))
}
