import { useCallback, useEffect, useState } from 'react';

import type {
  AppSettings,
  AppStatus,
  AudioDevice,
  CredentialStatus,
  Diagnostics,
  PermissionStatus,
  RecordingState,
  Shortcut
} from '../../shared/models';
import { shortcutLabel, stateLabel } from './format';

type View = 'flow' | 'voice' | 'delivery' | 'diagnostics';

interface Snapshot {
  status: AppStatus;
  settings: AppSettings;
  credentials: CredentialStatus;
  devices: AudioDevice[];
  permissions: PermissionStatus;
  diagnostics: Diagnostics;
}

export function App(): React.JSX.Element {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [view, setView] = useState<View>('flow');
  const [busy, setBusy] = useState<string | null>(null);
  const [notice, setNotice] = useState<{ tone: 'error' | 'success'; text: string } | null>(null);
  const [level, setLevel] = useState(0);
  const [showOnboarding, setShowOnboarding] = useState(false);

  const load = useCallback(async () => {
    const [status, settings, credentials, devices, permissions, diagnostics] =
      await Promise.all([
        window.freeflow.invoke<AppStatus>('app.getStatus'),
        window.freeflow.invoke<AppSettings>('settings.get'),
        window.freeflow.invoke<CredentialStatus>('credentials.hasApiKey'),
        window.freeflow.invoke<AudioDevice[]>('audio.listDevices').catch(() => []),
        window.freeflow.invoke<PermissionStatus>('permissions.getStatus'),
        window.freeflow.invoke<Diagnostics>('diagnostics.get')
      ]);
    setSnapshot({ status, settings, credentials, devices, permissions, diagnostics });
    if (!credentials.hasApiKey && localStorage.getItem('freeflow-onboarding') !== 'done') {
      setShowOnboarding(true);
    }
  }, []);

  useEffect(() => {
    void load().catch((error) => {
      setNotice({ tone: 'error', text: messageFor(error) });
    });
    return window.freeflow.onNotification((method, params) => {
      if (method === 'recording.level') {
        setLevel((params as { level?: number }).level ?? 0);
      }
      if (method === 'status.changed') {
        const state = (params as { state?: RecordingState }).state;
        if (state) {
          setSnapshot((current) =>
            current ? { ...current, status: { ...current.status, state } } : current
          );
        }
      }
      if (method === 'error.occurred' || method === 'injection.failed') {
        setNotice({ tone: 'error', text: (params as { message?: string }).message ?? 'Action failed' });
      }
      if (method === 'injection.completed') {
        setNotice({ tone: 'success', text: 'Transcript delivered.' });
        void load();
      }
    });
  }, [load]);

  useEffect(
    () =>
      window.freeflow.onNavigate((destination) => {
        if (['flow', 'voice', 'delivery', 'diagnostics'].includes(destination)) {
          setView(destination as View);
        }
      }),
    []
  );

  const run = useCallback(
    async <T,>(label: string, action: () => Promise<T>, success?: string): Promise<T | null> => {
      setBusy(label);
      try {
        const result = await action();
        if (success) setNotice({ tone: 'success', text: success });
        await load();
        return result;
      } catch (error) {
        setNotice({ tone: 'error', text: messageFor(error) });
        return null;
      } finally {
        setBusy(null);
      }
    },
    [load]
  );

  if (!snapshot) {
    return (
      <main className="boot">
        <span className="boot__mark">F</span>
        <p>Connecting the signal path…</p>
      </main>
    );
  }

  const { status, settings, credentials, devices, permissions, diagnostics } = snapshot;
  const state = status.state;
  const recording = state === 'recording' || state === 'preparing';
  const processing = !['idle', 'failed', 'injectionFailed', 'recording', 'preparing'].includes(state);
  const shortcut = shortcutLabel(settings.shortcut);

  const dictate = (): void => {
    if (recording) {
      void run('stop', () => window.freeflow.invoke('dictation.stop'));
    } else if (processing) {
      void run('cancel', () => window.freeflow.invoke('dictation.cancel'));
    } else {
      void run('start', () => window.freeflow.invoke('dictation.start'));
    }
  };

  return (
    <main className="shell">
      <aside className="rail">
        <div className="brand">
          <span className="brand__stamp">F</span>
          <div><strong>FreeFlow</strong><small>LINUX / EXPERIMENTAL</small></div>
        </div>
        <nav aria-label="FreeFlow sections">
          <NavButton active={view === 'flow'} onClick={() => setView('flow')} index="01" label="Flow" />
          <NavButton active={view === 'voice'} onClick={() => setView('voice')} index="02" label="Voice input" />
          <NavButton active={view === 'delivery'} onClick={() => setView('delivery')} index="03" label="Delivery" />
          <NavButton active={view === 'diagnostics'} onClick={() => setView('diagnostics')} index="04" label="Diagnostics" />
        </nav>
        <div className="rail__footer">
          <StatusLamp active={status.hotkeyRegistered} />
          <span>{status.sessionType.toUpperCase()}</span>
          <small>v{diagnostics.version}</small>
        </div>
      </aside>

      <section className="workspace">
        <header className="topline">
          <div>
            <span className="eyebrow">DICTATION INSTRUMENT</span>
            <h1>{headingFor(view)}</h1>
          </div>
          <button className="window-close" onClick={() => window.freeflow.window.hide()} aria-label="Hide FreeFlow">×</button>
        </header>

        {permissions.sessionType === 'wayland' && (
          <div className="wayland-note">
            <span>WAYLAND</span>
            <p>{permissions.message ?? 'Use the on-screen control. Text remains copied when automatic paste is blocked.'}</p>
          </div>
        )}

        {view === 'flow' && (
          <FlowView
            status={status}
            shortcut={shortcut}
            level={level}
            busy={busy !== null}
            onDictate={dictate}
            onCopy={() => void run('copy', () => window.freeflow.invoke('dictation.copyLastTranscript'), 'Last transcript copied.')}
            onPaste={() => void run('paste', () => window.freeflow.invoke('dictation.injectLastTranscript'))}
            onCancel={() => void run('cancel', () => window.freeflow.invoke('dictation.cancel'))}
          />
        )}
        {view === 'voice' && (
          <VoiceView
            settings={settings}
            credentials={credentials}
            devices={devices}
            level={level}
            busy={busy}
            onSaveKey={(apiKey, persist) => void run('api-key', () => window.freeflow.invoke('credentials.setApiKey', { apiKey, persist }), persist ? 'API key saved in Secret Service.' : 'API key active for this session.')}
            onDeleteKey={() => void run('delete-key', () => window.freeflow.invoke('credentials.deleteApiKey'), 'API key removed.')}
            onDevice={(id) => void run('device', () => window.freeflow.invoke('audio.selectDevice', { id }), 'Microphone updated.')}
            onPreview={(active) => void run('preview', () => window.freeflow.invoke(active ? 'audio.stopPreview' : 'audio.startPreview'))}
            onSettings={(updates) => void run('settings', () => window.freeflow.invoke('settings.update', updates), 'Voice settings saved.')}
          />
        )}
        {view === 'delivery' && (
          <DeliveryView
            settings={settings}
            status={status}
            permissions={permissions}
            onShortcut={(shortcut) => void run('shortcut', () => window.freeflow.invoke('hotkey.set', { shortcut }), 'Shortcut registered.')}
            onSettings={(updates) => void run('settings', () => window.freeflow.invoke('settings.update', updates), 'Delivery settings saved.')}
          />
        )}
        {view === 'diagnostics' && (
          <DiagnosticsView
            diagnostics={diagnostics}
            status={status}
            permissions={permissions}
            onExport={() => void run('export', () => window.freeflow.invoke('diagnostics.export'), 'Sanitized diagnostics exported.')}
          />
        )}
      </section>

      {notice && (
        <button className={`toast toast--${notice.tone}`} onClick={() => setNotice(null)}>
          <span>{notice.tone === 'error' ? '!' : '✓'}</span>{notice.text}<b>×</b>
        </button>
      )}
      {showOnboarding && (
        <Onboarding
          credentials={credentials}
          devices={devices}
          settings={settings}
          permissions={permissions}
          onSaveKey={async (apiKey, persist) => {
            const result = await run('api-key', () => window.freeflow.invoke('credentials.setApiKey', { apiKey, persist }));
            return result !== null;
          }}
          onDevice={async (id) => {
            const result = await run('device', () => window.freeflow.invoke('audio.selectDevice', { id }));
            return result !== null;
          }}
          onTest={async () => {
            const result = await run('preview', () => window.freeflow.invoke('audio.startPreview'));
            if (result !== null) setTimeout(() => void window.freeflow.invoke('audio.stopPreview'), 1800);
            return result !== null;
          }}
          onFinish={() => {
            localStorage.setItem('freeflow-onboarding', 'done');
            setShowOnboarding(false);
            void load();
          }}
        />
      )}
    </main>
  );
}

function FlowView(props: {
  status: AppStatus;
  shortcut: string;
  level: number;
  busy: boolean;
  onDictate(): void;
  onCopy(): void;
  onPaste(): void;
  onCancel(): void;
}): React.JSX.Element {
  const { status, shortcut, level } = props;
  const active = status.state === 'recording' || status.state === 'preparing';
  const processing = ['finalizing', 'transcribing', 'polishing', 'injecting'].includes(status.state);
  return (
    <div className="flow-grid reveal">
      <section className="dictation-deck panel">
        <div className="deck-label"><span>LIVE CHANNEL</span><b>{stateLabel(status.state)}</b></div>
        <div className="signal-field" aria-hidden="true">
          {Array.from({ length: 19 }, (_, index) => (
            <i key={index} style={{ '--signal': Math.max(0.1, Math.min(1, level * 2 + ((index * 7) % 5) / 20)) } as React.CSSProperties} />
          ))}
        </div>
        <button
          className={`record-control ${active ? 'record-control--active' : ''} ${processing ? 'record-control--processing' : ''}`}
          onClick={props.onDictate}
          disabled={props.busy}
        >
          <span className="record-control__core">{processing ? '×' : active ? '■' : '●'}</span>
          <span>{processing ? 'Cancel' : active ? 'Stop & transcribe' : 'Start dictation'}</span>
        </button>
        <p className="shortcut-callout">Hold <kbd>{shortcut}</kbd> · speak · release</p>
      </section>

      <section className="panel health-panel">
        <span className="panel-index">SIGNAL PATH / 01</span>
        <h2>Ready where your cursor is.</h2>
        <dl className="health-list">
          <div><dt>Microphone</dt><dd>{status.selectedDevice?.name ?? 'System default'}</dd></div>
          <div><dt>Global trigger</dt><dd>{status.hotkeyRegistered ? 'Armed' : 'Window control'}</dd></div>
          <div><dt>Delivery</dt><dd>{status.sessionType === 'x11' ? 'Automatic paste' : 'Clipboard safe'}</dd></div>
        </dl>
      </section>

      <section className="panel recovery-panel">
        <span className="panel-index">RECOVERY / 02</span>
        <div><h3>Last transcript</h3><p>{status.hasLastTranscript ? 'Retained and ready.' : 'Nothing captured yet.'}</p></div>
        <div className="button-row">
          <button className="button button--quiet" disabled={!status.hasLastTranscript} onClick={props.onCopy}>Copy</button>
          <button className="button button--acid" disabled={!status.hasLastTranscript} onClick={props.onPaste}>Paste again</button>
        </div>
      </section>
    </div>
  );
}

function VoiceView(props: {
  settings: AppSettings;
  credentials: CredentialStatus;
  devices: AudioDevice[];
  level: number;
  busy: string | null;
  onSaveKey(apiKey: string, persist: boolean): void;
  onDeleteKey(): void;
  onDevice(id: string | null): void;
  onPreview(active: boolean): void;
  onSettings(updates: Partial<AppSettings>): void;
}): React.JSX.Element {
  const [key, setKey] = useState('');
  const [preview, setPreview] = useState(false);
  return (
    <div className="settings-stack reveal">
      <section className="panel form-panel key-panel">
        <div className="section-heading"><span className="panel-index">CLOUD ACCESS / 01</span><h2>OpenAI-compatible service</h2></div>
        <div className="credential-state"><StatusLamp active={props.credentials.hasApiKey} /><strong>{props.credentials.hasApiKey ? 'Credential configured' : 'Credential required'}</strong><span>{props.credentials.secureStoreAvailable ? 'Secret Service available' : 'Session storage only'}</span></div>
        <label className="field field--wide"><span>API key</span><input type="password" value={key} autoComplete="off" placeholder={props.credentials.hasApiKey ? 'Replace existing credential' : 'Paste API key'} onChange={(event) => setKey(event.target.value)} /></label>
        {!props.credentials.secureStoreAvailable && <p className="field-warning">No Secret Service is available. The key will stay in memory and disappear when FreeFlow quits.</p>}
        <div className="button-row"><button className="button button--acid" disabled={key.length < 8} onClick={() => { props.onSaveKey(key, props.credentials.secureStoreAvailable); setKey(''); }}>Save credential</button>{props.credentials.hasApiKey && <button className="button button--danger" onClick={props.onDeleteKey}>Delete</button>}</div>
      </section>

      <section className="panel form-panel">
        <div className="section-heading"><span className="panel-index">INPUT / 02</span><h2>Microphone</h2></div>
        <div className="form-grid">
          <label className="field field--wide"><span>Capture device</span><select value={props.settings.selectedAudioDevice ?? ''} onChange={(event) => props.onDevice(event.target.value || null)}><option value="">System default</option>{props.devices.map((device) => <option key={device.id} value={device.id}>{device.name} · {device.backend}{device.isDefault ? ' · default' : ''}</option>)}</select></label>
          <div className="meter"><div style={{ width: `${Math.round(props.level * 100)}%` }} /><span>{preview ? 'Listening…' : 'Input level'}</span></div>
          <button className="button button--quiet" onClick={() => { props.onPreview(preview); setPreview(!preview); }}>{preview ? 'Stop test' : 'Test microphone'}</button>
        </div>
      </section>

      <section className="panel form-panel">
        <div className="section-heading"><span className="panel-index">TRANSCRIPTION / 03</span><h2>Language & models</h2></div>
        <div className="form-grid form-grid--two">
          <label className="field"><span>Spoken language</span><select value={props.settings.language} onChange={(event) => props.onSettings({ language: event.target.value })}><option value="auto">Auto detect</option><option value="en">English</option><option value="es">Spanish</option><option value="fr">French</option><option value="de">German</option><option value="it">Italian</option><option value="pt">Portuguese</option><option value="ja">Japanese</option></select></label>
          <label className="field"><span>API base URL</span><input defaultValue={props.settings.apiBaseUrl} onBlur={(event) => props.onSettings({ apiBaseUrl: event.target.value })} /></label>
          <label className="field"><span>Realtime model</span><input defaultValue={props.settings.realtimeModel} onBlur={(event) => props.onSettings({ realtimeModel: event.target.value })} /></label>
          <label className="field"><span>Fallback model</span><input defaultValue={props.settings.transcriptionModel} onBlur={(event) => props.onSettings({ transcriptionModel: event.target.value })} /></label>
        </div>
      </section>
    </div>
  );
}

function DeliveryView(props: {
  settings: AppSettings;
  status: AppStatus;
  permissions: PermissionStatus;
  onShortcut(shortcut: Shortcut): void;
  onSettings(updates: Partial<AppSettings>): void;
}): React.JSX.Element {
  const [key, setKey] = useState(props.settings.shortcut.key ?? 'space');
  const modifiers = props.settings.shortcut.modifiers;
  const toggleModifier = (modifier: string): void => {
    const next = modifiers.includes(modifier) ? modifiers.filter((value) => value !== modifier) : [...modifiers, modifier];
    props.onShortcut({ modifiers: next, key });
  };
  return (
    <div className="settings-stack reveal">
      <section className="panel form-panel">
        <div className="section-heading"><span className="panel-index">PUSH TO TALK / 01</span><h2>Global shortcut</h2></div>
        <div className="shortcut-builder">
          {['control', 'alt', 'shift', 'super'].map((modifier) => <button key={modifier} className={modifiers.includes(modifier) ? 'chip chip--active' : 'chip'} onClick={() => toggleModifier(modifier)}>{modifier === 'control' ? 'CTRL' : modifier.toUpperCase()}</button>)}
          <span>+</span>
          <input value={key} aria-label="Shortcut key" onChange={(event) => setKey(event.target.value)} onBlur={() => props.onShortcut({ modifiers, key: key || null })} />
        </div>
        <p className="field-note">{props.status.sessionType === 'wayland' ? 'Your compositor blocks this global trigger. The tray and Flow button remain available.' : props.status.hotkeyRegistered ? 'Registered globally. Key auto-repeat is ignored.' : 'Not registered. Choose a combination that another application does not own.'}</p>
      </section>

      <section className="panel form-panel">
        <div className="section-heading"><span className="panel-index">TEXT CLEANUP / 02</span><h2>Polish without rewriting</h2></div>
        <Toggle label="Polish transcript" detail="Remove fillers, spoken corrections, and dictated punctuation." checked={props.settings.polishEnabled} onChange={(polishEnabled) => props.onSettings({ polishEnabled })} />
        <div className="segmented"><button className={props.settings.polishMode === 'minimal' ? 'active' : ''} onClick={() => props.onSettings({ polishMode: 'minimal' })}>Minimal</button><button className={props.settings.polishMode === 'normal' ? 'active' : ''} onClick={() => props.onSettings({ polishMode: 'normal' })}>Normal</button></div>
        <Toggle label="Share application context" detail="Send the app name, title, and nearby editable text to the polish model." checked={props.settings.shareContext} onChange={(shareContext) => props.onSettings({ shareContext })} />
      </section>

      <section className="panel form-panel">
        <div className="section-heading"><span className="panel-index">DELIVERY / 03</span><h2>Cursor insertion</h2></div>
        <dl className="health-list health-list--compact"><div><dt>Shortcut permission</dt><dd>{props.permissions.globalShortcut}</dd></div><div><dt>Text path</dt><dd>{props.permissions.textInjection}</dd></div><div><dt>Failure behavior</dt><dd>Keep transcript in clipboard</dd></div></dl>
        <Toggle label="Start FreeFlow on login" detail="Keep push-to-talk ready after you sign in." checked={props.settings.startOnLogin} onChange={(startOnLogin) => props.onSettings({ startOnLogin })} />
      </section>
    </div>
  );
}

function DiagnosticsView(props: { diagnostics: Diagnostics; status: AppStatus; permissions: PermissionStatus; onExport(): void }): React.JSX.Element {
  const rows = [
    ['Session', `${props.diagnostics.desktopEnvironment} / ${props.diagnostics.sessionType}`],
    ['Audio backend', props.diagnostics.audioBackend],
    ['Shortcut backend', props.diagnostics.shortcutBackend],
    ['Injection backend', props.diagnostics.injectionBackend],
    ['Credential store', props.diagnostics.credentialStoreAvailable ? 'Secret Service available' : 'Unavailable'],
    ['Config', props.diagnostics.configPath],
    ['Logs', props.diagnostics.logPath || 'Captured by desktop shell']
  ];
  return (
    <div className="diagnostics-grid reveal">
      <section className="panel diagnostic-summary"><span className="panel-index">ENVIRONMENT / 01</span><div className="diagnostic-score"><strong>{props.status.state === 'failed' ? '!' : 'OK'}</strong><span>{props.status.state === 'failed' ? 'Needs attention' : 'Daemon connected'}</span></div><p>Exports never include API keys, authorization headers, transcripts, raw audio, or clipboard contents.</p><button className="button button--acid" onClick={props.onExport}>Export sanitized report</button></section>
      <section className="panel diagnostic-table"><span className="panel-index">SYSTEM MAP / 02</span><dl>{rows.map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl></section>
      {props.status.lastError && <section className="panel last-error"><span className="panel-index">LAST ERROR</span><p>{props.status.lastError}</p></section>}
    </div>
  );
}

function Onboarding(props: {
  credentials: CredentialStatus;
  devices: AudioDevice[];
  settings: AppSettings;
  permissions: PermissionStatus;
  onSaveKey(key: string, persist: boolean): Promise<boolean>;
  onDevice(id: string | null): Promise<boolean>;
  onTest(): Promise<boolean>;
  onFinish(): void;
}): React.JSX.Element {
  const [step, setStep] = useState(0);
  const [key, setKey] = useState('');
  const [device, setDevice] = useState(props.settings.selectedAudioDevice ?? '');
  const steps = ['Welcome', 'Cloud key', 'Microphone', 'Ready'];
  return (
    <div className="onboarding">
      <div className="onboarding__card">
        <div className="onboarding__progress">{steps.map((label, index) => <div key={label} className={index <= step ? 'active' : ''}><span>{String(index + 1).padStart(2, '0')}</span>{label}</div>)}</div>
        <div className="onboarding__content">
          {step === 0 && <><span className="eyebrow">PUSH-TO-TALK, NOW ON LINUX</span><h2>Speak where the cursor already is.</h2><p>FreeFlow captures only while you ask it to, cleans the transcript without changing your voice, and pastes it back—or keeps it safely copied when Linux blocks injection.</p><div className="onboarding__diagram"><i>HOLD</i><b>→</b><i>SPEAK</i><b>→</b><i>RELEASE</i></div></>}
          {step === 1 && <><span className="eyebrow">CLOUD TRANSCRIPTION</span><h2>Add an API credential.</h2><p>The desktop sends audio directly to your configured OpenAI-compatible endpoint. FreeFlow never runs an intermediary server.</p><label className="field field--wide"><span>API key</span><input autoFocus type="password" value={key} onChange={(event) => setKey(event.target.value)} placeholder="Stored by Secret Service" /></label>{!props.credentials.secureStoreAvailable && <p className="field-warning">Secret Service is unavailable. This credential will be session-only and disappear on quit.</p>}</>}
          {step === 2 && <><span className="eyebrow">INPUT CHECK</span><h2>Choose the voice channel.</h2><label className="field field--wide"><span>Microphone</span><select value={device} onChange={(event) => setDevice(event.target.value)}><option value="">System default</option>{props.devices.map((item) => <option key={item.id} value={item.id}>{item.name} · {item.backend}</option>)}</select></label><button className="button button--quiet" onClick={() => void props.onTest()}>Run 1.8 second level test</button></>}
          {step === 3 && <><span className="eyebrow">SIGNAL PATH READY</span><h2>{props.permissions.sessionType === 'wayland' ? 'Use the tray or Flow control.' : `Hold ${shortcutLabel(props.settings.shortcut)} to dictate.`}</h2><p>{props.permissions.message ?? 'Focus any text field, hold the shortcut, speak, and release. FreeFlow will return the cleaned words at your cursor.'}</p><div className="ready-seal"><strong>F</strong><span>READY<br />TO FLOW</span></div></>}
          <div className="onboarding__actions"><button className="button button--quiet" disabled={step === 0} onClick={() => setStep((value) => value - 1)}>Back</button><button className="button button--acid" disabled={step === 1 && key.length < 8} onClick={async () => { if (step === 1 && !(await props.onSaveKey(key, props.credentials.secureStoreAvailable))) return; if (step === 2 && !(await props.onDevice(device || null))) return; if (step === 3) props.onFinish(); else setStep((value) => value + 1); }}>{step === 3 ? 'Start using FreeFlow' : 'Continue'}</button></div>
        </div>
      </div>
    </div>
  );
}

function NavButton(props: { active: boolean; index: string; label: string; onClick(): void }): React.JSX.Element {
  return <button className={props.active ? 'nav-button nav-button--active' : 'nav-button'} onClick={props.onClick}><span>{props.index}</span>{props.label}<b>↗</b></button>;
}

function StatusLamp({ active }: { active: boolean }): React.JSX.Element {
  return <i className={active ? 'status-lamp status-lamp--active' : 'status-lamp'} aria-label={active ? 'available' : 'unavailable'} />;
}

function Toggle(props: { label: string; detail: string; checked: boolean; onChange(value: boolean): void }): React.JSX.Element {
  return <label className="toggle-row"><span><strong>{props.label}</strong><small>{props.detail}</small></span><input type="checkbox" checked={props.checked} onChange={(event) => props.onChange(event.target.checked)} /><i /></label>;
}

function headingFor(view: View): string {
  return ({ flow: 'Your words, in place.', voice: 'Tune the voice channel.', delivery: 'Choose how text lands.', diagnostics: 'Inspect the signal path.' })[view];
}

function messageFor(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
