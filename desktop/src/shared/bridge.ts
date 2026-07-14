import type { RpcMethod, RpcNotificationMethod } from './rpc.generated';

export interface DesktopBridge {
  invoke<T = unknown>(method: RpcMethod, params?: unknown): Promise<T>;
  onNotification(
    listener: (method: RpcNotificationMethod, params: unknown) => void
  ): () => void;
  onNavigate(listener: (destination: string) => void): () => void;
  window: {
    hide(): void;
    openSettings(): void;
  };
}
