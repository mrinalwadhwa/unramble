export interface WindowLike {
  isDestroyed(): boolean;
  webContents: {
    isDestroyed(): boolean;
    send(channel: string, ...args: unknown[]): void;
  };
}

export function liveWindow<T extends WindowLike>(window: T | null): T | null {
  if (!window || window.isDestroyed() || window.webContents.isDestroyed()) {
    return null;
  }
  return window;
}

export function sendToWindow(
  window: WindowLike | null,
  channel: string,
  ...args: unknown[]
): boolean {
  const target = liveWindow(window);
  if (!target) return false;
  try {
    target.webContents.send(channel, ...args);
    return true;
  } catch {
    // Electron can destroy a webContents between the liveness check and send.
    return false;
  }
}

export function useWindow<T extends WindowLike>(
  window: T | null,
  action: (target: T) => void
): boolean {
  const target = liveWindow(window);
  if (!target) return false;
  try {
    action(target);
    return true;
  } catch {
    // Window teardown races with delayed HUD and daemon callbacks during quit.
    return false;
  }
}

export function useWindowOrRecover<T extends WindowLike>(
  window: T | null,
  action: (target: T) => void,
  recover: () => void
): boolean {
  const target = liveWindow(window);
  if (!target) {
    recover();
    return false;
  }
  try {
    action(target);
    return true;
  } catch {
    // Ask the owner to replace a renderer that disappears during an action.
    recover();
    return false;
  }
}
