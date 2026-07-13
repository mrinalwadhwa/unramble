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

const allowedMethods = new Set<string>(RPC_METHODS);

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => showSettings());
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
      broadcastNotification('error.occurred', {
        category: 'daemon',
        message,
        recoverable: false
      });
      void dialog.showMessageBox({
        type: 'error',
        title: 'FreeFlow background service stopped',
        message,
        buttons: ['Open settings', 'Close']
      }).then(({ response }) => {
        if (response === 0) showSettings();
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
      app.setLoginItemSettings({ openAtLogin: settings.startOnLogin });
    }
    rebuildTray();
    showSettings();
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
      settingsWindow?.hide();
    }
  });
  settingsWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  void loadRenderer(settingsWindow, 'app');

  hudWindow = new BrowserWindow({
    width: 360,
    height: 96,
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
  hudWindow.setAlwaysOnTop(true, 'floating');
  hudWindow.setIgnoreMouseEvents(true);
  void loadRenderer(hudWindow, 'hud');
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
        settingsWindow?.webContents.send('freeflow:navigate', 'diagnostics');
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
        app.setLoginItemSettings({ openAtLogin: settings.startOnLogin });
      }
    }
    return result;
  });
  ipcMain.on('freeflow:window-hide', () => settingsWindow?.hide());
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
    hudHideTimer = setTimeout(() => hudWindow?.hide(), method === 'injection.failed' ? 2_400 : 750);
  }
  broadcastNotification(method, params);
}

function broadcastNotification(method: RpcNotificationMethod, params: unknown): void {
  settingsWindow?.webContents.send('freeflow:notification', method, params);
  hudWindow?.webContents.send('freeflow:notification', method, params);
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
  if (!hudWindow) return;
  if (state === 'idle') {
    if (hudHideTimer) clearTimeout(hudHideTimer);
    hudHideTimer = setTimeout(() => hudWindow?.hide(), 600);
    return;
  }
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const { x, y, width, height } = display.workArea;
  hudWindow.setPosition(Math.round(x + (width - 360) / 2), y + height - 130, false);
  hudWindow.showInactive();
}

function showSettings(): void {
  if (!settingsWindow) return;
  settingsWindow.show();
  settingsWindow.focus();
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
  if (supervisor) {
    void supervisor.stop().finally(() => app.exit(0));
  } else {
    app.exit(0);
  }
});

app.on('window-all-closed', () => {
  // FreeFlow remains available from the tray.
});
