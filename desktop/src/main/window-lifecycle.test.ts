import { describe, expect, it, vi } from 'vitest';

import {
  liveWindow,
  sendToWindow,
  useWindow,
  useWindowOrRecover,
  type WindowLike
} from './window-lifecycle';

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

  it('requests recovery when a window or its renderer is gone', () => {
    const destroyedWindow = fakeWindow({ windowDestroyed: true });
    const destroyedContents = fakeWindow({ contentsDestroyed: true });
    const recoverWindow = vi.fn();
    const recoverContents = vi.fn();

    expect(useWindowOrRecover(destroyedWindow.target, vi.fn(), recoverWindow)).toBe(false);
    expect(useWindowOrRecover(destroyedContents.target, vi.fn(), recoverContents)).toBe(false);
    expect(recoverWindow).toHaveBeenCalledOnce();
    expect(recoverContents).toHaveBeenCalledOnce();
  });

  it('requests recovery after a renderer teardown race', () => {
    const { target } = fakeWindow();
    const recover = vi.fn();

    expect(
      useWindowOrRecover(
        target,
        () => {
          throw new Error('Render frame was disposed');
        },
        recover
      )
    ).toBe(false);
    expect(recover).toHaveBeenCalledOnce();
  });

  it('does not request recovery while the window action succeeds', () => {
    const { target } = fakeWindow();
    const action = vi.fn();
    const recover = vi.fn();

    expect(useWindowOrRecover(target, action, recover)).toBe(true);
    expect(action).toHaveBeenCalledOnce();
    expect(recover).not.toHaveBeenCalled();
  });
});
