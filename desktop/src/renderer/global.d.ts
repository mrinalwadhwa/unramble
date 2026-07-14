import type { DesktopBridge } from '../shared/bridge';

declare global {
  interface Window {
    freeflow: DesktopBridge;
  }
}

export {};
