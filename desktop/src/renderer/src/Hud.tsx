import { useEffect, useMemo, useState } from 'react';

import type { RecordingState } from '../../shared/models';

const stateLabel: Record<RecordingState, string> = {
  idle: 'FreeFlow is ready',
  preparing: 'FreeFlow is opening the microphone',
  recording: 'FreeFlow is listening',
  finalizing: 'FreeFlow is finishing the recording',
  transcribing: 'FreeFlow is transcribing',
  polishing: 'FreeFlow is polishing the transcript',
  injecting: 'FreeFlow is inserting the transcript',
  injectionFailed: 'FreeFlow could not insert the transcript',
  failed: 'FreeFlow dictation failed'
};

export function Hud(): React.JSX.Element {
  const [state, setState] = useState<RecordingState>('preparing');
  const [level, setLevel] = useState(0);

  useEffect(
    () =>
      window.freeflow.onNotification((method, params) => {
        if (method === 'status.changed') {
          const next = (params as { state?: RecordingState }).state;
          if (next) setState(next);
        } else if (method === 'recording.level') {
          setLevel((params as { level?: number }).level ?? 0);
        }
      }),
    []
  );

  const bars = useMemo(
    () =>
      Array.from({ length: 11 }, (_, index) => {
        const distance = Math.abs(index - 5) / 5;
        const threshold = 0.05 + distance * 0.5;
        return Math.max(0.12, Math.min(1, level * 1.8 - threshold + 0.34));
      }),
    [level]
  );

  return (
    <div className={`hud hud--${state}`} role="status" aria-label={stateLabel[state]}>
      <div className="hud__signal" aria-hidden="true">
        {bars.map((height, index) => (
          <i key={index} style={{ '--bar': height } as React.CSSProperties} />
        ))}
      </div>
    </div>
  );
}
