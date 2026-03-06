/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `search-notnow-url` command */
  export type SearchNotnowUrl = ExtensionPreferences & {
  /** Store Path - SQLite path of NotNow store */
  "storePath"?: string,
  /** Max Results - Final number of displayed results after grouping/sorting */
  "maxResults": string,
  /** Include x.com Results - Whether to include x.com links in search results (kept lower priority) */
  "showXDomain": boolean
}
}

declare namespace Arguments {
  /** Arguments passed to the `search-notnow-url` command */
  export type SearchNotnowUrl = {}
}

