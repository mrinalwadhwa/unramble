import { ChildProcessWithoutNullStreams, spawn } from 'node:child_process';
import { constants as fsConstants, createWriteStream, existsSync } from 'node:fs';
import { access, mkdir } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { app } from 'electron';
import WebSocket from 'ws';

import type {
  JsonRpcResponse,
  RpcMethod,
  RpcNotification,
  RpcNotificationMethod
} from '../shared/rpc.generated';
import { PROTOCOL_VERSION } from '../shared/rpc.generated';

interface ReadyRecord {
  ready: true;
  rpcPort: number;
  sessionToken: string;
  protocolVersion: number;
  pid: number;
}

interface PendingRequest {
  resolve(value: unknown): void;
  reject(error: Error): void;
  timer: NodeJS.Timeout;
}

export class RpcCallError extends Error {
  constructor(
    message: string,
    readonly code: number,
    readonly data?: unknown
  ) {
    super(message);
    this.name = 'RpcCallError';
  }
}

export interface DaemonSupervisorOptions {
  onNotification(method: RpcNotificationMethod, params: unknown): void;
  onCrash(message: string): void;
  onConnectionChange(connected: boolean): void;
}

export class DaemonSupervisor {
  private process: ChildProcessWithoutNullStreams | null = null;
  private socket: WebSocket | null = null;
  private nextId = 1;
  private pending = new Map<number, PendingRequest>();
  private stopping = false;
  private restartAttempts = 0;
  private startPromise: Promise<void> | null = null;

  constructor(private readonly options: DaemonSupervisorOptions) {}

  start(): Promise<void> {
    this.startPromise ??= this.startOnce();
    return this.startPromise;
  }

  async request<T = unknown>(method: RpcMethod, params?: unknown): Promise<T> {
    await this.start();
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      throw new Error('FreeFlow background service is not connected');
    }
    const id = this.nextId++;
    const timeoutMs =
      method === 'dictation.stop' || method === 'dictation.retryLast' ? 310_000 : 30_000;
    return new Promise<T>((resolveRequest, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => resolveRequest(value as T),
        reject,
        timer
      });
      socket.send(
        JSON.stringify({
          jsonrpc: '2.0',
          id,
          method,
          ...(params === undefined ? {} : { params })
        })
      );
    });
  }

  async stop(): Promise<void> {
    this.stopping = true;
    if (this.socket?.readyState === WebSocket.OPEN) {
      try {
        await this.request('app.shutdown');
      } catch {
        // The daemon may close before acknowledging shutdown.
      }
    }
    const child = this.process;
    if (child && child.exitCode === null) {
      const timer = setTimeout(() => child.kill('SIGTERM'), 1_200);
      await new Promise<void>((resolveExit) => child.once('exit', () => resolveExit()));
      clearTimeout(timer);
    }
    this.socket?.close();
    this.rejectPending(new Error('FreeFlow is shutting down'));
  }

  private async startOnce(): Promise<void> {
    const daemonPath = this.daemonPath();
    if (!existsSync(daemonPath)) {
      throw new Error(`FreeFlow daemon was not found at ${daemonPath}`);
    }
    if (app.isPackaged) {
      try {
        await access(daemonPath, fsConstants.X_OK);
      } catch {
        throw new Error('The bundled FreeFlow daemon is not executable; reinstall the package');
      }
    }
    const logPath = join(app.getPath('logs'), 'freeflow-daemon.log');
    await mkdir(dirname(logPath), { recursive: true });
    const log = createWriteStream(logPath, { flags: 'a', mode: 0o600 });
    const child = spawn(daemonPath, ['serve'], {
      env: {
        ...process.env,
        FREEFLOW_LOG_PATH: logPath,
        RUST_LOG: process.env.RUST_LOG ?? 'freeflow=info'
      },
      stdio: ['pipe', 'pipe', 'pipe']
    });
    child.stdin.end();
    this.process = child;
    child.stderr.pipe(log, { end: false });
    const ready = await this.readReadyRecord(child);
    if (ready.protocolVersion !== PROTOCOL_VERSION) {
      child.kill('SIGTERM');
      throw new Error(
        `RPC version mismatch: desktop ${PROTOCOL_VERSION}, daemon ${ready.protocolVersion}`
      );
    }
    await this.connect(ready);
    this.restartAttempts = 0;
    child.once('exit', (code, signal) => {
      log.end();
      this.process = null;
      this.socket = null;
      this.options.onConnectionChange(false);
      this.rejectPending(
        new Error(`FreeFlow background service exited (${signal ?? String(code)})`)
      );
      if (!this.stopping) {
        void this.restart();
      }
    });
  }

  private daemonPath(): string {
    if (process.env.FREEFLOW_DAEMON_PATH) {
      return resolve(process.env.FREEFLOW_DAEMON_PATH);
    }
    if (app.isPackaged) {
      return join(process.resourcesPath, 'bin', 'freeflow-daemon');
    }
    return resolve(__dirname, '../../../rust/target/debug/freeflow-daemon');
  }

  private readReadyRecord(child: ChildProcessWithoutNullStreams): Promise<ReadyRecord> {
    return new Promise((resolveReady, reject) => {
      let buffer = '';
      const timeout = setTimeout(() => {
        reject(new Error('FreeFlow daemon did not announce its RPC endpoint'));
        child.kill('SIGTERM');
      }, 15_000);
      const onData = (chunk: Buffer): void => {
        buffer += chunk.toString('utf8');
        const lineEnd = buffer.indexOf('\n');
        if (lineEnd === -1) return;
        child.stdout.off('data', onData);
        clearTimeout(timeout);
        try {
          const record = JSON.parse(buffer.slice(0, lineEnd)) as ReadyRecord;
          if (
            record.ready !== true ||
            !Number.isInteger(record.rpcPort) ||
            typeof record.sessionToken !== 'string'
          ) {
            throw new Error('invalid ready record');
          }
          resolveReady(record);
        } catch (error) {
          reject(new Error(`FreeFlow daemon returned an invalid ready record: ${String(error)}`));
          child.kill('SIGTERM');
        }
      };
      child.stdout.on('data', onData);
      child.once('error', (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      child.once('exit', (code) => {
        clearTimeout(timeout);
        reject(new Error(`FreeFlow daemon exited during startup (${String(code)})`));
      });
    });
  }

  private connect(ready: ReadyRecord): Promise<void> {
    return new Promise((resolveConnect, reject) => {
      const socket = new WebSocket(
        `ws://127.0.0.1:${ready.rpcPort}/rpc?token=${encodeURIComponent(ready.sessionToken)}`
      );
      this.socket = socket;
      const timeout = setTimeout(() => {
        socket.terminate();
        reject(new Error('Could not connect to the FreeFlow background service'));
      }, 8_000);
      socket.once('open', () => {
        clearTimeout(timeout);
        this.options.onConnectionChange(true);
        resolveConnect();
      });
      socket.on('message', (data) => this.receive(data.toString()));
      socket.once('error', (error) => {
        clearTimeout(timeout);
        reject(error);
      });
    });
  }

  private receive(raw: string): void {
    let message: JsonRpcResponse | RpcNotification;
    try {
      message = JSON.parse(raw) as JsonRpcResponse | RpcNotification;
    } catch {
      this.options.onCrash('The background service sent an unreadable response.');
      return;
    }
    if ('method' in message) {
      try {
        this.options.onNotification(message.method, message.params);
      } catch {
        console.error(`FreeFlow could not display the ${message.method} notification`);
      }
      return;
    }
    if (typeof message.id !== 'number') return;
    const pending = this.pending.get(message.id);
    if (!pending) return;
    clearTimeout(pending.timer);
    this.pending.delete(message.id);
    if (message.error) {
      pending.reject(
        new RpcCallError(message.error.message, message.error.code, message.error.data)
      );
    } else {
      pending.resolve(message.result);
    }
  }

  private async restart(): Promise<void> {
    if (this.restartAttempts >= 3) {
      this.options.onCrash(
        'The FreeFlow background service stopped repeatedly. Open diagnostics for its log.'
      );
      return;
    }
    const delay = [300, 1_000, 2_500][this.restartAttempts] ?? 2_500;
    this.restartAttempts += 1;
    await new Promise((resolveDelay) => setTimeout(resolveDelay, delay));
    this.startPromise = null;
    try {
      await this.start();
    } catch (error) {
      this.options.onCrash(`Could not restart FreeFlow: ${String(error)}`);
      await this.restart();
    }
  }

  private rejectPending(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}
