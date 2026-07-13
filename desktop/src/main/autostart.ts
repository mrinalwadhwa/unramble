export const AUTOSTART_DESKTOP_FILENAME = 'com.freeflow.FreeFlow.Linux.desktop';

export function desktopExecArgument(value: string): string {
  const escaped = value
    .replaceAll('\\', '\\\\')
    .replaceAll('"', '\\"')
    .replaceAll('`', '\\`')
    .replaceAll('$', '\\$')
    .replaceAll('%', '%%');
  return `"${escaped}"`;
}

export function autostartDesktopEntry(executable: string): string {
  return [
    '[Desktop Entry]',
    'Type=Application',
    'Name=FreeFlow',
    'Comment=Keep push-to-talk dictation ready',
    `Exec=${desktopExecArgument(executable)} --hidden`,
    'Icon=freeflow',
    'Terminal=false',
    'Categories=Utility;',
    'StartupNotify=false',
    'X-GNOME-Autostart-enabled=true',
    ''
  ].join('\n');
}
