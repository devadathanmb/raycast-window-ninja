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
  isFullscreen: boolean;
  isAppHidden: boolean;
}

interface Preferences {
  showMinimizedWindows: boolean;
}

const BINARY_PATH = join(environment.assetsPath, 'list-windows');
const TRANSITION_REFRESH_DELAYS_MS = [120, 350, 700];

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

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

async function minimizeWindowAction(window: WindowInfo): Promise<void> {
  await execFileAsync(BINARY_PATH, ['minimize', String(window.pid), String(window.windowIndex)]);
  await showHUD(`Minimized "${window.windowTitle}"`);
}

async function makeWindowFullscreenAction(window: WindowInfo): Promise<void> {
  await execFileAsync(BINARY_PATH, ['fullscreen', String(window.pid), String(window.windowIndex)]);
  await showHUD(`Made "${window.windowTitle}" full screen`);
}

async function exitWindowFullscreenAction(window: WindowInfo): Promise<void> {
  await execFileAsync(BINARY_PATH, [
    'unfullscreen',
    String(window.pid),
    String(window.windowIndex),
  ]);
  await showHUD(`Exited full screen for "${window.windowTitle}"`);
}

async function maximizeWindowAction(window: WindowInfo): Promise<void> {
  await execFileAsync(BINARY_PATH, ['maximize', String(window.pid), String(window.windowIndex)]);
  await showHUD(`Maximized "${window.windowTitle}"`);
}

async function hideApplicationAction(window: WindowInfo): Promise<void> {
  await execFileAsync(BINARY_PATH, ['hide-app', String(window.pid)]);
  await showHUD(`Hid "${window.processName}"`);
}

async function showApplicationAction(window: WindowInfo): Promise<void> {
  await execFileAsync(BINARY_PATH, ['show-app', String(window.pid)]);
  await showHUD(`Showed "${window.processName}"`);
}

export default function SwitchWindows() {
  const [windows, setWindows] = useState<WindowInfo[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const { showMinimizedWindows } = getPreferenceValues<Preferences>();

  const filterWindows = useCallback(
    (allWindows: WindowInfo[]) =>
      showMinimizedWindows ? allWindows : allWindows.filter((w) => !w.isMinimized),
    [showMinimizedWindows],
  );

  const loadWindows = useCallback(async () => {
    setIsLoading(true);
    try {
      const allWindows = await getWindows();
      setWindows(filterWindows(allWindows));
    } catch (error) {
      console.error('Failed to list windows:', error);
      setWindows([]);
    } finally {
      setIsLoading(false);
    }
  }, [filterWindows]);

  const refreshAfterAction = useCallback(
    async (transitionAware = false) => {
      if (!transitionAware) {
        await loadWindows();
        return;
      }

      setIsLoading(true);
      try {
        for (const waitMs of TRANSITION_REFRESH_DELAYS_MS) {
          await delay(waitMs);
          const allWindows = await getWindows();
          setWindows(filterWindows(allWindows));
        }
      } catch (error) {
        console.error('Failed to refresh windows after transition:', error);
        try {
          const allWindows = await getWindows();
          setWindows(filterWindows(allWindows));
        } catch {
          setWindows([]);
        }
      } finally {
        setIsLoading(false);
      }
    },
    [filterWindows, loadWindows],
  );

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
                {window.isMinimized ? (
                  <Action
                    title="Maximize Window"
                    icon={Icon.ArrowsExpand}
                    shortcut={{ modifiers: ['cmd'], key: 'm' }}
                    onAction={async () => {
                      await maximizeWindowAction(window);
                      await refreshAfterAction();
                    }}
                  />
                ) : !window.isFullscreen ? (
                  <Action
                    title="Minimize Window"
                    icon={Icon.Minus}
                    shortcut={{ modifiers: ['cmd'], key: 'm' }}
                    onAction={async () => {
                      await minimizeWindowAction(window);
                      await refreshAfterAction(true);
                    }}
                  />
                ) : null}
                <Action
                  title={window.isFullscreen ? 'Exit Full Screen' : 'Make Full Screen'}
                  icon={window.isFullscreen ? Icon.ArrowsContract : Icon.ArrowsExpand}
                  shortcut={{ modifiers: ['cmd'], key: 'f' }}
                  onAction={async () => {
                    if (window.isFullscreen) {
                      await exitWindowFullscreenAction(window);
                    } else {
                      await makeWindowFullscreenAction(window);
                    }
                    await refreshAfterAction(true);
                  }}
                />
                <Action
                  title="Close Window"
                  icon={Icon.XMarkCircle}
                  style={Action.Style.Destructive}
                  shortcut={{ modifiers: ['cmd', 'shift'], key: 'w' }}
                  onAction={async () => {
                    await closeWindowAction(window);
                    await refreshAfterAction();
                  }}
                />
                <Action
                  title={window.isAppHidden ? 'Show Application' : 'Hide Application'}
                  icon={window.isAppHidden ? Icon.Eye : Icon.EyeDisabled}
                  shortcut={{ modifiers: ['cmd'], key: 'h' }}
                  onAction={async () => {
                    if (window.isAppHidden) {
                      await showApplicationAction(window);
                    } else {
                      await hideApplicationAction(window);
                    }
                    await refreshAfterAction();
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
