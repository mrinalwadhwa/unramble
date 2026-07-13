export type RecordingState =
  | 'idle'
  | 'preparing'
  | 'recording'
  | 'finalizing'
  | 'transcribing'
  | 'polishing'
  | 'injecting'
  | 'injectionFailed'
  | 'failed';

export type SessionType = 'x11' | 'wayland' | 'unknown';
export type PolishMode = 'minimal' | 'normal';

export interface Shortcut {
  modifiers: string[];
  key: string | null;
}

export interface AudioDevice {
  id: string;
  name: string;
  isDefault: boolean;
  backend: string;
}

export interface AppSettings {
  apiBaseUrl: string;
  realtimeModel: string;
  transcriptionModel: string;
  polishModel: string;
  language: string;
  polishEnabled: boolean;
  polishMode: PolishMode;
  shareContext: boolean;
  selectedAudioDevice: string | null;
  shortcut: Shortcut;
  startOnLogin: boolean;
  realtimeEnabled: boolean;
  requestTimeoutSeconds: number;
}

export interface AppStatus {
  state: RecordingState;
  hasApiKey: boolean;
  hasLastTranscript: boolean;
  hotkeyRegistered: boolean;
  selectedDevice: AudioDevice | null;
  sessionType: SessionType;
  lastError: string | null;
}

export interface PermissionStatus {
  microphone: string;
  globalShortcut: string;
  textInjection: string;
  sessionType: SessionType;
  message: string | null;
}

export interface Diagnostics {
  version: string;
  os: string;
  desktopEnvironment: string;
  sessionType: SessionType;
  audioBackend: string;
  shortcutBackend: string;
  injectionBackend: string;
  configPath: string;
  logPath: string;
  credentialStoreAvailable: boolean;
  details: Record<string, string>;
}

export interface CredentialStatus {
  hasApiKey: boolean;
  secureStoreAvailable: boolean;
}
