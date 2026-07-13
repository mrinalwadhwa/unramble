import { describe, expect, it } from 'vitest';

import { shortcutLabel, stateLabel } from './format';

describe('desktop status formatting', () => {
  it('formats ordinary and modifier-only shortcuts', () => {
    expect(shortcutLabel({ modifiers: ['control', 'alt'], key: 'space' })).toBe(
      'Ctrl + Alt + Space'
    );
    expect(shortcutLabel({ modifiers: ['rightControl'], key: null })).toBe('RightControl');
  });

  it('keeps recovery states actionable', () => {
    expect(stateLabel('injectionFailed')).toContain('PASTE MANUALLY');
    expect(stateLabel('failed')).toBe('NEEDS ATTENTION');
  });
});
