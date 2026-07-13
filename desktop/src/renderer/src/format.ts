import type { RecordingState, Shortcut } from '../../shared/models';

export function shortcutLabel(shortcut: Shortcut): string {
  const names = shortcut.modifiers.map((modifier) => {
    if (modifier === 'control') return 'Ctrl';
    if (modifier === 'super') return 'Win';
    return modifier.replace('control', 'Ctrl').replace(/^./, (letter) => letter.toUpperCase());
  });
  if (shortcut.key) names.push(shortcut.key === 'space' ? 'Space' : shortcut.key.toUpperCase());
  return names.join(' + ');
}

export function stateLabel(state: RecordingState): string {
  return {
    idle: 'READY',
    preparing: 'OPENING MIC',
    recording: 'LISTENING',
    finalizing: 'FINISHING',
    transcribing: 'TRANSCRIBING',
    polishing: 'CLEANING',
    injecting: 'PASTING',
    injectionFailed: 'COPIED · PASTE MANUALLY',
    failed: 'NEEDS ATTENTION'
  }[state];
}
