/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Show Minimized Windows - Show minimized (hidden) windows in the list */
  "showMinimizedWindows": boolean
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `window-ninja` command */
  export type WindowNinja = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `window-ninja` command */
  export type WindowNinja = {}
}

