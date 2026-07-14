import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

export const HUD_TITLE = 'FreeFlow HUD';
export const HUD_TOP_MARGIN = 18;

const execFileAsync = promisify(execFile);

export interface WorkArea {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface HyprlandClient {
  address?: unknown;
  title?: unknown;
  initialTitle?: unknown;
  pid?: unknown;
  mapped?: unknown;
  floating?: unknown;
  size?: unknown;
}

interface HyprlandMonitor {
  focused?: unknown;
  x?: unknown;
  y?: unknown;
  width?: unknown;
  reserved?: unknown;
}

export function topCenterHudPosition(
  workArea: WorkArea,
  hudWidth: number
): { x: number; y: number } {
  return {
    x: Math.round(workArea.x + (workArea.width - hudWidth) / 2),
    y: workArea.y + HUD_TOP_MARGIN
  };
}

export function findHyprlandHudClient(
  clients: HyprlandClient[],
  title: string,
  pid: number,
  expectedSize: readonly [number, number]
): { address: string; floating: boolean } | null {
  const matches = clients.filter((client) => {
    const size = Array.isArray(client.size) ? client.size : [];
    return (
      client.mapped === true &&
      (client.title === title || client.initialTitle === title) &&
      (client.pid === pid || client.pid === undefined) &&
      size[0] === expectedSize[0] &&
      size[1] === expectedSize[1]
    );
  });
  const client = matches.at(-1);
  return typeof client?.address === 'string'
    ? { address: client.address, floating: client.floating === true }
    : null;
}

export function hyprlandHudPosition(
  monitors: HyprlandMonitor[],
  hudWidth: number,
  fallback: { x: number; y: number }
): { x: number; y: number } {
  const monitor = monitors.find((candidate) => candidate.focused === true) ?? monitors[0];
  const reserved = Array.isArray(monitor?.reserved) ? monitor.reserved : [];
  if (
    typeof monitor?.x !== 'number' ||
    typeof monitor.y !== 'number' ||
    typeof monitor.width !== 'number'
  ) {
    return fallback;
  }
  const reservedTop = typeof reserved[1] === 'number' ? reserved[1] : 0;
  return {
    x: Math.round(monitor.x + (monitor.width - hudWidth) / 2),
    y: monitor.y + reservedTop + HUD_TOP_MARGIN
  };
}

export async function resolveHyprlandHudPosition(
  fallback: { x: number; y: number },
  hudWidth: number
): Promise<{ x: number; y: number }> {
  if (process.platform !== 'linux' || !process.env.HYPRLAND_INSTANCE_SIGNATURE) return fallback;
  try {
    const { stdout } = await execFileAsync('hyprctl', ['monitors', '-j'], {
      timeout: 500,
      maxBuffer: 128 * 1024
    });
    return hyprlandHudPosition(JSON.parse(stdout) as HyprlandMonitor[], hudWidth, fallback);
  } catch {
    return fallback;
  }
}

export async function moveHyprlandHud(
  position: { x: number; y: number },
  pid: number,
  expectedSize: readonly [number, number]
): Promise<boolean> {
  if (process.platform !== 'linux' || !process.env.HYPRLAND_INSTANCE_SIGNATURE) return false;

  for (const retryDelay of [0, 16, 40]) {
    if (retryDelay > 0) {
      await new Promise((resolve) => setTimeout(resolve, retryDelay));
    }
    try {
      const { stdout } = await execFileAsync('hyprctl', ['clients', '-j'], {
        timeout: 500,
        maxBuffer: 512 * 1024
      });
      const clients = JSON.parse(stdout) as HyprlandClient[];
      const client = findHyprlandHudClient(clients, HUD_TITLE, pid, expectedSize);
      if (!client) continue;
      if (!client.floating) {
        await execFileAsync('hyprctl', [
          'dispatch',
          'togglefloating',
          `address:${client.address}`
        ], { timeout: 500 });
      }
      await execFileAsync('hyprctl', [
        'dispatch',
        'movewindowpixel',
        `exact ${position.x} ${position.y},address:${client.address}`
      ], { timeout: 500 });
      return true;
    } catch {
      // Other compositors retain Electron's best-effort requested position.
    }
  }
  return false;
}
