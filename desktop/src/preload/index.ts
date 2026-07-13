import { contextBridge, ipcRenderer } from 'electron';

import type { DesktopBridge } from '../shared/bridge';
import type { RpcMethod, RpcNotificationMethod } from '../shared/rpc.generated';

const bridge: DesktopBridge = {
  invoke: <T>(method: RpcMethod, params?: unknown) =>
    ipcRenderer.invoke('freeflow:rpc', method, params) as Promise<T>,
  onNotification: (listener) => {
    const wrapped = (
      _event: Electron.IpcRendererEvent,
      method: RpcNotificationMethod,
      params: unknown
    ): void => listener(method, params);
    ipcRenderer.on('freeflow:notification', wrapped);
    return () => ipcRenderer.off('freeflow:notification', wrapped);
  },
  onNavigate: (listener) => {
    const wrapped = (_event: Electron.IpcRendererEvent, destination: string): void =>
      listener(destination);
    ipcRenderer.on('freeflow:navigate', wrapped);
    return () => ipcRenderer.off('freeflow:navigate', wrapped);
  },
  window: {
    hide: () => ipcRenderer.send('freeflow:window-hide'),
    openSettings: () => ipcRenderer.send('freeflow:open-settings')
  }
};

contextBridge.exposeInMainWorld('freeflow', bridge);
