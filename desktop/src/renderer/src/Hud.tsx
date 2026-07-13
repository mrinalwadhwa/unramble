import { useEffect, useMemo, useState } from 'react';

import type { RecordingState } from '../../shared/models';

const stateCopy: Record<RecordingState, { label: string; detail: string }> = {
  idle: { label: 'Ready', detail: 'Hold to speak' },
  preparing: { label: 'Warming up', detail: 'Opening microphone' },
  recording: { label: 'Listening', detail: 'Release to finish' },
  finalizing: { label: 'Finishing', detail: 'Closing microphone' },
  transcribing: { label: 'Transcribing', detail: 'Speech → text' },
  polishing: { label: 'Cleaning', detail: 'Keeping your wording' },
  injecting: { label: 'Delivering', detail: 'Pasting at cursor' },
  injectionFailed: { label: 'Copied', detail: 'Press paste manually' },
  failed: { label: 'Not completed', detail: 'Open FreeFlow' }
};

export function Hud(): React.JSX.Element {
  const [state, setState] = useState<RecordingState>('preparing');
  const [level, setLevel] = useState(0);
  const [message, setMessage] = useState<string | null>(null);

  useEffect(
    () =>
      window.freeflow.onNotification((method, params) => {
        if (method === 'status.changed') {
          const next = (params as { state?: RecordingState }).state;
          if (next) setState(next);
        } else if (method === 'recording.level') {
          setLevel((params as { level?: number }).level ?? 0);
        } else if (method === 'injection.failed' || method === 'hotkey.registrationFailed') {
          setMessage((params as { message?: string }).message ?? 'Manual action needed');
        } else if (method === 'error.occurred') {
          setMessage((params as { message?: string }).message ?? 'Dictation failed');
        }
      }),
    []
  );

  const bars = useMemo(
    () =>
      Array.from({ length: 13 }, (_, index) => {
        const distance = Math.abs(index - 6) / 6;
        const threshold = 0.06 + distance * 0.48;
        return Math.max(0.14, Math.min(1, level * 1.8 - threshold + 0.35));
      }),
    [level]
  );
  const copy = stateCopy[state];

  return (
    <div className={`hud hud--${state}`}>
      <div className="hud__signal" aria-hidden="true">
        {bars.map((height, index) => (
          <i key={index} style={{ '--bar': height } as React.CSSProperties} />
        ))}
      </div>
      <div className="hud__copy">
        <strong>{copy.label}</strong>
        <span>{message ?? copy.detail}</span>
      </div>
      <span className="hud__lamp" aria-hidden="true" />
    </div>
  );
}
