import { mkdir, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import {
  BrowserWindow,
  Menu,
  Tray,
  app,
  dialog,
  ipcMain,
  nativeImage,
  screen
} from 'electron';

import { DaemonSupervisor } from './daemon';
import { AUTOSTART_DESKTOP_FILENAME, autostartDesktopEntry } from './autostart';
import {
  HUD_TITLE,
  moveHyprlandHud,
  resolveHyprlandHudPosition,
  topCenterHudPosition
} from './hud-position';
import {
  liveWindow,
  sendToWindow,
  useWindow,
  useWindowOrRecover
} from './window-lifecycle';
import type { AppStatus, RecordingState } from '../shared/models';
import {
  RPC_METHODS,
  type RpcMethod,
  type RpcNotificationMethod
} from '../shared/rpc.generated';

let settingsWindow: BrowserWindow | null = null;
let hudWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let supervisor: DaemonSupervisor | null = null;
let quitting = false;
let connected = false;
let currentStatus: AppStatus | null = null;
let hudHideTimer: NodeJS.Timeout | null = null;
let hudRecoveryTimer: NodeJS.Timeout | null = null;
let hudRecoveryResetTimer: NodeJS.Timeout | null = null;
let hudRecoveryAttempts = 0;
let hudRecoveryWindowStartedAt = 0;
let hudUpdateSequence = 0;
const HUD_WIDTH = 104;
const HUD_HEIGHT = 46;
const HUD_RECOVERY_LIMIT = 3;
const HUD_RECOVERY_WINDOW_MS = 30_000;
const HUD_RECOVERY_DELAY_MS = 200;
const HUD_RECOVERY_STABILITY_MS = 5_000;

const allowedMethods = new Set<string>(RPC_METHODS);
const launchHidden = process.env.FREEFLOW_START_HIDDEN === '1';

if (!app.requestSingleInstanceLock({ launchHidden })) {
  app.quit();
} else {
  app.on('second-instance', (_event, _commandLine, _workingDirectory, additionalData) => {
    const hidden =
      typeof additionalData === 'object' &&
      additionalData !== null &&
      (additionalData as { launchHidden?: unknown }).launchHidden === true;
    if (!hidden) showSettings();
  });
  void app.whenReady().then(startApplication);
}

async function startApplication(): Promise<void> {
  app.setAppUserModelId('com.freeflow.FreeFlow.Linux');
  createWindows();
  createTray();
  registerIpc();

  supervisor = new DaemonSupervisor({
    onNotification: receiveNotification,
    onCrash: (message) => {
      if (quitting) return;
      broadcastNotification('error.occurred', {
        category: 'daemon',
        message,
        recoverable: false
      });
      if (!app.isReady()) return;
      void dialog.showMessageBox({
        type: 'error',
        title: 'FreeFlow background service stopped',
        message,
        buttons: ['Open settings', 'Close']
      }).then(({ response }) => {
        if (!quitting && response === 0) showSettings();
      });
    },
    onConnectionChange: (value) => {
      connected = value;
      rebuildTray();
      broadcastNotification('status.changed', {
        state: value ? currentStatus?.state ?? 'idle' : 'failed',
        connected: value
      });
    }
  });

  try {
    await supervisor.start();
    currentStatus = await supervisor.request<AppStatus>('app.getStatus');
    const settings = await supervisor.request<{ startOnLogin?: boolean }>('settings.get');
    if (typeof settings.startOnLogin === 'boolean') {
      try {
        await applyStartOnLogin(settings.startOnLogin);
      } catch (error) {
        await reportStartOnLoginError(error);
      }
    }
    rebuildTray();
    if (!launchHidden) showSettings();
  } catch (error) {
    await dialog.showMessageBox({
      type: 'error',
      title: 'FreeFlow could not start',
      message: error instanceof Error ? error.message : String(error),
      detail: 'Build the Rust daemon or set FREEFLOW_DAEMON_PATH, then restart FreeFlow.'
    });
    app.quit();
  }

  app.on('activate', showSettings);
}

function createWindows(): void {
  const preload = join(__dirname, '../preload/index.js');
  settingsWindow = new BrowserWindow({
    width: 1040,
    height: 760,
    minWidth: 900,
    minHeight: 650,
    show: false,
    backgroundColor: '#111512',
    title: 'FreeFlow',
    autoHideMenuBar: true,
    webPreferences: {
      preload,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  settingsWindow.on('close', (event) => {
    if (!quitting) {
      event.preventDefault();
      useWindow(settingsWindow, (window) => window.hide());
    }
  });
  settingsWindow.on('closed', () => {
    settingsWindow = null;
  });
  settingsWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  void loadRenderer(settingsWindow, 'app');

  createHudWindow(preload);
}

function createHudWindow(
  preload = join(__dirname, '../preload/index.js')
): BrowserWindow | null {
  if (quitting) return null;
  const existing = liveWindow(hudWindow);
  if (existing) return existing;

  const window = new BrowserWindow({
    title: HUD_TITLE,
    width: HUD_WIDTH,
    height: HUD_HEIGHT,
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    show: false,
    focusable: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    hasShadow: false,
    webPreferences: {
      preload,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  hudWindow = window;
  window.setAlwaysOnTop(true, 'floating');
  window.setIgnoreMouseEvents(true);
  window.on('closed', () => {
    if (hudWindow === window) hudWindow = null;
  });
  window.on('page-title-updated', (event) => event.preventDefault());
  window.on('unresponsive', () => recoverHudWindow(window, 'became unresponsive'));
  window.webContents.on('render-process-gone', (_event, details) => {
    recoverHudWindow(window, `renderer exited (${details.reason}, code ${details.exitCode})`);
  });
  window.webContents.on(
    'did-fail-load',
    (_event, errorCode, errorDescription, _validatedUrl, isMainFrame) => {
      if (isMainFrame && errorCode !== -3) {
        recoverHudWindow(window, `failed to load (${errorDescription}, code ${errorCode})`);
      }
    }
  );
  void loadRenderer(window, 'hud')
    .then(() => {
      if (hudWindow !== window || !liveWindow(window)) return;
      scheduleHudRecoveryReset(window);
      window.setTitle(HUD_TITLE);
      const state = currentStatus?.state;
      if (state) {
        sendToWindow(window, 'freeflow:notification', 'status.changed', { state });
        if (state !== 'idle') updateHud(state);
      }
    })
    .catch((error: unknown) => {
      const detail = error instanceof Error ? error.message : String(error);
      recoverHudWindow(window, `could not load (${detail})`);
    });
  return window;
}

function recoverHudWindow(window: BrowserWindow, reason: string): void {
  if (quitting || hudWindow !== window) return;
  console.error(`FreeFlow HUD ${reason}; recreating the widget`);
  if (hudRecoveryResetTimer) {
    clearTimeout(hudRecoveryResetTimer);
    hudRecoveryResetTimer = null;
  }
  hudWindow = null;
  if (!window.isDestroyed()) window.destroy();
  scheduleHudRecovery();
}

function scheduleHudRecovery(): void {
  if (quitting || hudRecoveryTimer) return;
  const now = Date.now();
  if (now - hudRecoveryWindowStartedAt > HUD_RECOVERY_WINDOW_MS) {
    hudRecoveryAttempts = 0;
    hudRecoveryWindowStartedAt = now;
  }
  if (hudRecoveryAttempts >= HUD_RECOVERY_LIMIT) {
    console.error('FreeFlow HUD stopped restarting after repeated renderer failures');
    return;
  }
  const delay = HUD_RECOVERY_DELAY_MS * 2 ** hudRecoveryAttempts;
  hudRecoveryAttempts += 1;
  hudRecoveryTimer = setTimeout(() => {
    hudRecoveryTimer = null;
    createHudWindow();
  }, delay);
}

function scheduleHudRecoveryReset(window: BrowserWindow): void {
  if (hudRecoveryResetTimer) clearTimeout(hudRecoveryResetTimer);
  hudRecoveryResetTimer = setTimeout(() => {
    hudRecoveryResetTimer = null;
    if (hudWindow !== window || !liveWindow(window)) return;
    hudRecoveryAttempts = 0;
    hudRecoveryWindowStartedAt = 0;
  }, HUD_RECOVERY_STABILITY_MS);
}

function ensureHudWindow(): BrowserWindow | null {
  const window = liveWindow(hudWindow);
  if (window) return window;
  if (hudWindow) {
    recoverHudWindow(hudWindow, 'was no longer available');
  } else {
    scheduleHudRecovery();
  }
  return null;
}

async function loadRenderer(window: BrowserWindow, route: string): Promise<void> {
  const developmentUrl = process.env.ELECTRON_RENDERER_URL;
  if (developmentUrl) {
    await window.loadURL(`${developmentUrl}#${route}`);
  } else {
    await window.loadFile(join(__dirname, '../renderer/index.html'), { hash: route });
  }
}

function createTray(): void {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><rect x="2" y="2" width="20" height="20" rx="6" fill="#171d18"/><path d="M7 7h10v3H10v2h6v3h-6v4H7z" fill="#d9ff73"/></svg>`;
  const icon = nativeImage.createFromDataURL(
    `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`
  );
  tray = new Tray(icon.resize({ width: 22, height: 22 }));
  tray.setToolTip('FreeFlow');
  tray.on('double-click', showSettings);
  rebuildTray();
}

function rebuildTray(): void {
  if (!tray) return;
  const state = currentStatus?.state ?? (connected ? 'idle' : 'failed');
  const recording = state === 'recording' || state === 'preparing';
  const busy = !['idle', 'failed', 'injectionFailed'].includes(state);
  const microphone = currentStatus?.selectedDevice?.name ?? 'System default microphone';
  const menu = Menu.buildFromTemplate([
    { label: `FreeFlow · ${labelForState(state)}`, enabled: false },
    { label: microphone, enabled: false },
    { type: 'separator' },
    {
      label: 'Start dictation',
      enabled: connected && !busy,
      click: () => void call('dictation.start')
    },
    {
      label: 'Stop dictation',
      enabled: connected && recording,
      click: () => void call('dictation.stop')
    },
    {
      label: 'Cancel dictation',
      enabled: connected && busy,
      click: () => void call('dictation.cancel')
    },
    { type: 'separator' },
    {
      label: 'Paste last transcript',
      enabled: Boolean(currentStatus?.hasLastTranscript),
      click: () => void call('dictation.injectLastTranscript')
    },
    {
      label: 'Copy last transcript',
      enabled: Boolean(currentStatus?.hasLastTranscript),
      click: () => void call('dictation.copyLastTranscript')
    },
    { type: 'separator' },
    { label: 'Open settings', click: showSettings },
    {
      label: 'Open diagnostics',
      click: () => {
        showSettings();
        sendToWindow(settingsWindow, 'freeflow:navigate', 'diagnostics');
      }
    },
    { type: 'separator' },
    {
      label: 'Quit FreeFlow',
      click: () => app.quit()
    }
  ]);
  tray.setContextMenu(menu);
}

function registerIpc(): void {
  ipcMain.handle('freeflow:rpc', async (_event, method: string, params?: unknown) => {
    if (!allowedMethods.has(method)) {
      throw new Error(`Unsupported FreeFlow method: ${method}`);
    }
    if (!supervisor) throw new Error('FreeFlow background service is starting');
    const result = await supervisor.request(method as RpcMethod, params);
    if (method === 'app.getStatus') currentStatus = result as AppStatus;
    if (method === 'settings.update' || method === 'settings.reset') {
      const settings = result as { startOnLogin?: boolean };
      if (typeof settings.startOnLogin === 'boolean') {
        await applyStartOnLogin(settings.startOnLogin);
      }
    }
    return result;
  });
  ipcMain.on('freeflow:window-hide', () => {
    useWindow(settingsWindow, (window) => window.hide());
  });
  ipcMain.on('freeflow:open-settings', showSettings);
}

function receiveNotification(method: RpcNotificationMethod, params: unknown): void {
  if (method === 'status.changed') {
    const next = (params as { state?: RecordingState }).state;
    if (next && currentStatus) currentStatus = { ...currentStatus, state: next };
    if (next) updateHud(next);
    void refreshStatus();
  }
  if (method === 'injection.completed' || method === 'injection.failed') {
    if (hudHideTimer) clearTimeout(hudHideTimer);
    hudHideTimer = setTimeout(
      () => useWindow(hudWindow, (window) => window.hide()),
      method === 'injection.failed' ? 2_400 : 90
    );
  }
  broadcastNotification(method, params);
}

function broadcastNotification(method: RpcNotificationMethod, params: unknown): void {
  sendToWindow(settingsWindow, 'freeflow:notification', method, params);
  sendToWindow(hudWindow, 'freeflow:notification', method, params);
}

async function refreshStatus(): Promise<void> {
  if (!supervisor || !connected) return;
  try {
    currentStatus = await supervisor.request<AppStatus>('app.getStatus');
    rebuildTray();
  } catch {
    // Connection lifecycle reports failures separately.
  }
}

function updateHud(state: RecordingState): void {
  const sequence = ++hudUpdateSequence;
  if (state === 'idle') {
    if (hudHideTimer) clearTimeout(hudHideTimer);
    hudHideTimer = setTimeout(() => useWindow(hudWindow, (window) => window.hide()), 90);
    return;
  }
  const target = ensureHudWindow();
  if (!target) return;
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const fallback = topCenterHudPosition(display.workArea, HUD_WIDTH);
  void resolveHyprlandHudPosition(fallback, HUD_WIDTH).then((position) => {
    if (sequence !== hudUpdateSequence || hudWindow !== target) return;
    useWindowOrRecover(
      target,
      (window) => {
        window.setPosition(position.x, position.y, false);
        window.showInactive();
        void moveHyprlandHud(position, process.pid, [HUD_WIDTH, HUD_HEIGHT]);
      },
      () => {
        recoverHudWindow(target, 'became unavailable while showing');
      }
    );
  });
}

function showSettings(): void {
  useWindow(settingsWindow, (window) => {
    window.show();
    window.focus();
  });
}

async function applyStartOnLogin(enabled: boolean): Promise<void> {
  if (process.platform !== 'linux') {
    app.setLoginItemSettings({ openAtLogin: enabled });
    return;
  }

  const autostartDirectory = join(app.getPath('appData'), 'autostart');
  const autostartPath = join(autostartDirectory, AUTOSTART_DESKTOP_FILENAME);
  if (!enabled) {
    await rm(autostartPath, { force: true });
    return;
  }

  // Development mode depends on a transient Vite process and cannot be
  // relaunched by a persistent desktop entry.
  if (!app.isPackaged && !process.env.APPIMAGE) return;

  const executable = process.env.APPIMAGE || app.getPath('exe');
  const temporaryPath = `${autostartPath}.${process.pid}.tmp`;
  await mkdir(autostartDirectory, { recursive: true, mode: 0o700 });
  try {
    await writeFile(temporaryPath, autostartDesktopEntry(executable), { mode: 0o644 });
    await rename(temporaryPath, autostartPath);
  } catch (error) {
    await rm(temporaryPath, { force: true });
    throw error;
  }
}

async function reportStartOnLoginError(error: unknown): Promise<void> {
  const detail = error instanceof Error ? error.message : String(error);
  console.error(`Could not configure FreeFlow startup: ${detail}`);
  await dialog.showMessageBox({
    type: 'warning',
    title: 'FreeFlow could not start automatically',
    message: 'FreeFlow is running, but it could not enable start-on-login.',
    detail,
    buttons: ['OK']
  });
}

async function call(method: RpcMethod): Promise<void> {
  try {
    await supervisor?.request(method);
  } catch (error) {
    receiveNotification('error.occurred', {
      category: 'desktop',
      message: error instanceof Error ? error.message : String(error),
      recoverable: true
    });
  }
}

function labelForState(state: RecordingState): string {
  return {
    idle: 'Ready',
    preparing: 'Preparing',
    recording: 'Listening',
    finalizing: 'Finishing',
    transcribing: 'Transcribing',
    polishing: 'Cleaning text',
    injecting: 'Pasting',
    injectionFailed: 'Paste needed',
    failed: 'Needs attention'
  }[state];
}

app.on('before-quit', (event) => {
  if (quitting) return;
  event.preventDefault();
  quitting = true;
  if (hudRecoveryTimer) {
    clearTimeout(hudRecoveryTimer);
    hudRecoveryTimer = null;
  }
  if (hudRecoveryResetTimer) {
    clearTimeout(hudRecoveryResetTimer);
    hudRecoveryResetTimer = null;
  }
  if (supervisor) {
    void supervisor.stop().finally(() => app.exit(0));
  } else {
    app.exit(0);
  }
});

app.on('window-all-closed', () => {
  // FreeFlow remains available from the tray.
});
