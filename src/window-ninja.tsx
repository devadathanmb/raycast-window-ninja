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

const BINARY_PATH = join(environment.assetsPath, 'win-ninja');
const TRANSITION_REFRESH_DELAYS_MS = [120, 350, 700];

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function getWindows(): Promise<WindowInfo[]> {
  const { stdout } = await execFileAsync(BINARY_PATH, ['list']);
  return JSON.parse(stdout);
}

interface BinaryResponse {
  success: boolean;
  error?: string;
}

// Run a window command (pid + windowIndex) and show a HUD with the result.
async function windowAction(
  command: string,
  window: WindowInfo,
  successMessage: string,
): Promise<void> {
  const { stdout } = await execFileAsync(BINARY_PATH, [
    command,
    String(window.pid),
    String(window.windowIndex),
  ]);
  const result: BinaryResponse = JSON.parse(stdout);
  if (result.success) {
    await showHUD(successMessage);
  } else {
    await showHUD(result.error ?? `Failed to ${command} window`);
  }
}

// Run an app-level command (pid only) and show a HUD with the result.
async function appAction(
  command: string,
  window: WindowInfo,
  successMessage: string,
): Promise<void> {
  const { stdout } = await execFileAsync(BINARY_PATH, [command, String(window.pid)]);
  const result: BinaryResponse = JSON.parse(stdout);
  if (result.success) {
    await showHUD(successMessage);
  } else {
    await showHUD(result.error ?? `Failed to ${command}`);
  }
}

async function focusWindow(window: WindowInfo): Promise<void> {
  await execFileAsync(BINARY_PATH, ['focus', String(window.pid), String(window.windowIndex)]);
  await closeMainWindow();
  await popToRoot();
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
        let previousSnapshot = '';
        for (const waitMs of TRANSITION_REFRESH_DELAYS_MS) {
          await delay(waitMs);
          const allWindows = await getWindows();
          const filtered = filterWindows(allWindows);
          setWindows(filtered);

          // Short-circuit: if window state matches the previous fetch, the transition
          // is complete and there's no need to keep polling.
          const snapshot = JSON.stringify(filtered);
          if (snapshot === previousSnapshot) break;
          previousSnapshot = snapshot;
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
                      await windowAction('maximize', window, `Maximized "${window.windowTitle}"`);
                      await refreshAfterAction();
                    }}
                  />
                ) : !window.isFullscreen ? (
                  <Action
                    title="Minimize Window"
                    icon={Icon.Minus}
                    shortcut={{ modifiers: ['cmd'], key: 'm' }}
                    onAction={async () => {
                      await windowAction('minimize', window, `Minimized "${window.windowTitle}"`);
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
                      await windowAction(
                        'unfullscreen',
                        window,
                        `Exited full screen for "${window.windowTitle}"`,
                      );
                    } else {
                      await windowAction(
                        'fullscreen',
                        window,
                        `Made "${window.windowTitle}" full screen`,
                      );
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
                    await windowAction('close', window, `Closed "${window.windowTitle}"`);
                    await refreshAfterAction();
                  }}
                />
                <Action
                  title={window.isAppHidden ? 'Show Application' : 'Hide Application'}
                  icon={window.isAppHidden ? Icon.Eye : Icon.EyeDisabled}
                  shortcut={{ modifiers: ['cmd'], key: 'h' }}
                  onAction={async () => {
                    if (window.isAppHidden) {
                      await appAction('show-app', window, `Showed "${window.processName}"`);
                    } else {
                      await appAction('hide-app', window, `Hid "${window.processName}"`);
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
