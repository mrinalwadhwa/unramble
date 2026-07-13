import { describe, expect, it } from 'vitest';

import { autostartDesktopEntry, desktopExecArgument } from './autostart';

describe('Linux autostart integration', () => {
  it('quotes desktop entry arguments without exposing field codes', () => {
    expect(desktopExecArgument('/home/Gabriel/My App/$freeflow%')).toBe(
      '"/home/Gabriel/My App/\\$freeflow%%"'
    );
  });

  it('starts the packaged application without opening the settings window', () => {
    const entry = autostartDesktopEntry('/home/Gabriel/Applications/FreeFlow.AppImage');

    expect(entry).toContain(
      'Exec="/home/Gabriel/Applications/FreeFlow.AppImage" --hidden\n'
    );
    expect(entry).toContain('X-GNOME-Autostart-enabled=true\n');
    expect(entry.endsWith('\n')).toBe(true);
  });
});
