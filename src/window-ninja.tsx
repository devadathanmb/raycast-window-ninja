import {
  Action,
  ActionPanel,
  closeMainWindow,
  environment,
  getPreferenceValues,
  Icon,
  Image,
  List,
  popToRoot,
  showHUD,
} from '@raycast/api';
import { execFile } from 'child_process';
import { join } from 'path';
import { useCallback, useEffect, useState } from 'react';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

interface WindowInfo {
  processName: string;
  windowTitle: string;
  bundleId: string;
  appPath: string;
  pid: number;
  windowIndex: number;
  isMinimized: boolean;
}

interface Preferences {
  showMinimizedWindows: boolean;
}

const BINARY_PATH = join(environment.assetsPath, 'list-windows');

async function getWindows(): Promise<WindowInfo[]> {
  const { stdout } = await execFileAsync(BINARY_PATH);
  return JSON.parse(stdout);
}

async function focusWindow(window: WindowInfo): Promise<void> {
  await execFileAsync(BINARY_PATH, ['focus', String(window.pid), String(window.windowIndex)]);
  await closeMainWindow();
  await popToRoot();
}

async function closeWindowAction(window: WindowInfo): Promise<void> {
  await execFileAsync(BINARY_PATH, ['close', String(window.pid), String(window.windowIndex)]);
  await showHUD(`Closed "${window.windowTitle}"`);
}

export default function SwitchWindows() {
  const [windows, setWindows] = useState<WindowInfo[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const { showMinimizedWindows } = getPreferenceValues<Preferences>();

  const loadWindows = useCallback(async () => {
    setIsLoading(true);
    try {
      const allWindows = await getWindows();
      setWindows(showMinimizedWindows ? allWindows : allWindows.filter((w) => !w.isMinimized));
    } catch (error) {
      console.error('Failed to list windows:', error);
      setWindows([]);
    } finally {
      setIsLoading(false);
    }
  }, [showMinimizedWindows]);

  useEffect(() => {
    loadWindows();
  }, [loadWindows]);

  function getWindowIcon(window: WindowInfo): Image.ImageLike {
    if (window.appPath) {
      return { fileIcon: window.appPath };
    }
    return Icon.Window;
  }

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="Filter by application name or window title..."
    >
      {windows.length === 0 && !isLoading ? (
        <List.EmptyView icon={Icon.Window} title="No open windows found" />
      ) : (
        windows.map((window, index) => (
          <List.Item
            key={`${window.bundleId}-${window.windowTitle}-${index}`}
            icon={getWindowIcon(window)}
            title={window.windowTitle}
            accessories={[{ text: window.processName }]}
            keywords={[window.processName, window.windowTitle]}
            actions={
              <ActionPanel>
                <Action
                  title="Switch to Window"
                  icon={Icon.Window}
                  onAction={async () => {
                    await focusWindow(window);
                  }}
                />
                <Action
                  title="Close Window"
                  icon={Icon.XMarkCircle}
                  style={Action.Style.Destructive}
                  shortcut={{ modifiers: ['ctrl'], key: 'x' }}
                  onAction={async () => {
                    await closeWindowAction(window);
                    await loadWindows();
                  }}
                />
                <Action.CopyToClipboard
                  title="Copy Window Title"
                  content={window.windowTitle}
                  shortcut={{ modifiers: ['cmd', 'shift'], key: 'c' }}
                />
                <Action
                  title="Refresh Window List"
                  icon={Icon.ArrowClockwise}
                  shortcut={{ modifiers: ['cmd'], key: 'r' }}
                  onAction={loadWindows}
                />
              </ActionPanel>
            }
          />
        ))
      )}
    </List>
  );
}
