import { describe, expect, it } from 'vitest';

import {
  findHyprlandHudClient,
  hyprlandHudPosition,
  topCenterHudPosition
} from './hud-position';

describe('HUD positioning', () => {
  it('places the HUD at the top center of the active work area', () => {
    expect(topCenterHudPosition({ x: 100, y: 30, width: 1_200, height: 800 }, 104)).toEqual({
      x: 648,
      y: 48
    });
  });

  it('selects only the mapped HUD surface owned by this process', () => {
    const clients = [
      {
        address: '0xsettings',
        title: 'FreeFlow',
        pid: 42,
        mapped: true,
        floating: false,
        size: [1_040, 760]
      },
      {
        address: '0xstale',
        title: 'FreeFlow HUD',
        pid: 9,
        mapped: true,
        floating: true,
        size: [104, 46]
      },
      {
        address: '0xhud',
        title: 'FreeFlow HUD',
        pid: 42,
        mapped: true,
        floating: true,
        size: [104, 46]
      }
    ];

    expect(findHyprlandHudClient(clients, 'FreeFlow HUD', 42, [104, 46])).toEqual({
      address: '0xhud',
      floating: true
    });
  });

  it('keeps the HUD below a compositor-reserved top panel', () => {
    expect(
      hyprlandHudPosition(
        [{ focused: true, x: 0, y: 0, width: 1_920, reserved: [0, 38, 0, 0] }],
        104,
        { x: 0, y: 18 }
      )
    ).toEqual({ x: 908, y: 56 });
  });
});
