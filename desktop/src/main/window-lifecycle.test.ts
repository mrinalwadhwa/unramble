import { describe, expect, it, vi } from 'vitest';

import { liveWindow, sendToWindow, useWindow, type WindowLike } from './window-lifecycle';

function fakeWindow(options: { windowDestroyed?: boolean; contentsDestroyed?: boolean } = {}): {
  target: WindowLike;
  send: ReturnType<typeof vi.fn>;
} {
  const send = vi.fn();
  return {
    target: {
      isDestroyed: () => options.windowDestroyed ?? false,
      webContents: {
        isDestroyed: () => options.contentsDestroyed ?? false,
        send
      }
    },
    send
  };
}

describe('window lifecycle guards', () => {
  it('sends only to a live window', () => {
    const { target, send } = fakeWindow();

    expect(sendToWindow(target, 'freeflow:notification', 'status.changed', {})).toBe(true);
    expect(send).toHaveBeenCalledOnce();
    expect(liveWindow(target)).toBe(target);
  });

  it('ignores destroyed windows and web contents', () => {
    const destroyedWindow = fakeWindow({ windowDestroyed: true });
    const destroyedContents = fakeWindow({ contentsDestroyed: true });

    expect(sendToWindow(destroyedWindow.target, 'event')).toBe(false);
    expect(sendToWindow(destroyedContents.target, 'event')).toBe(false);
    expect(destroyedWindow.send).not.toHaveBeenCalled();
    expect(destroyedContents.send).not.toHaveBeenCalled();
  });

  it('absorbs teardown races during send and window actions', () => {
    const { target, send } = fakeWindow();
    send.mockImplementation(() => {
      throw new Error('Object has been destroyed');
    });

    expect(sendToWindow(target, 'event')).toBe(false);
    expect(
      useWindow(target, () => {
        throw new Error('Object has been destroyed');
      })
    ).toBe(false);
  });
});
