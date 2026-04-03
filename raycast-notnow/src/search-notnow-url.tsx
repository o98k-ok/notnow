import {
  Action,
  ActionPanel,
  Color,
  Detail,
  Icon,
  List,
  Toast,
  getPreferenceValues,
  open,
  showToast,
} from "@raycast/api";
import { execFile } from "node:child_process";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { useEffect, useMemo, useRef, useState } from "react";

const execFileAsync = promisify(execFile);
const DEFAULT_STORE_PATH = "~/Library/Application Support/default.store";
const DEFAULT_MAX_RESULTS = 200;
const MAX_FETCH_LIMIT = 2000;
const APPLE_REF_UNIX_OFFSET_SECONDS = 978307200;
const SEARCH_DEBOUNCE_MS = 180;
const TAG_DECODER_CACHE_DIR = path.join(
  os.homedir(),
  ".cache",
  "notnow-raycast",
);
const TAG_DECODER_BIN = path.join(TAG_DECODER_CACHE_DIR, "decode_tags");

let compiledBinaryReady: Promise<string> | null = null;

type BookmarkKind = "link" | "snippet" | "task" | "api";

type SQLiteRow = {
  id: string;
  title: string;
  url: string;
  kind: string;
  category: string;
  desc: string;
  snippet_content: string;
  api_method: string;
  api_query_params: string;
  is_completed: number;
  due_date_raw: number;
  updated_at_raw: number;
  tags_blob_hex: string;
};

type SearchResult = {
  id: string;
  title: string;
  url: string;
  kind: BookmarkKind;
  category: string;
  desc: string;
  tags: string[];
  snippetContent: string;
  apiMethod: string;
  apiQueryParams: string;
  isCompleted: boolean;
  dueDate?: Date;
  updatedAt?: Date;
  isXDomain: boolean;
};

type Preferences = {
  storePath?: string;
  maxResults?: string;
  showXDomain?: boolean;
};

const KIND_ORDER: BookmarkKind[] = ["link", "snippet", "task", "api"];

const KIND_META: Record<
  BookmarkKind,
  { title: string; icon: Icon; color: Color }
> = {
  link: { title: "Links", icon: Icon.Link, color: Color.Blue },
  snippet: { title: "Snippets", icon: Icon.Code, color: Color.Purple },
  task: { title: "Tasks", icon: Icon.CheckCircle, color: Color.Orange },
  api: { title: "APIs", icon: Icon.Terminal, color: Color.Green },
};

const TAG_PALETTE: Color[] = [
  Color.Blue,
  Color.Green,
  Color.Orange,
  Color.Purple,
  Color.Magenta,
  Color.Red,
  Color.Yellow,
];

const SWIFT_TAG_DECODER = `
import Foundation

func dataFromHex(_ hex: String) -> Data? {
    let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
    var data = Data(capacity: cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

func decodeTags(from hex: String) -> [String] {
    guard let blob = dataFromHex(hex) else { return [] }
    do {
        if let tags = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSArray.self, NSString.self],
            from: blob
        ) as? [String] {
            return tags
        }
    } catch {
        return []
    }
    return []
}

let inputPath = CommandLine.arguments[1]
let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
let list = try JSONDecoder().decode([String].self, from: data)
let unique = Array(Set(list))
var output: [String: [String]] = [:]
for hex in unique {
    output[hex] = decodeTags(from: hex)
}
let outputData = try JSONEncoder().encode(output)
print(String(data: outputData, encoding: .utf8) ?? "{}")
`;

const tagDecodeCache = new Map<string, string[]>();

export default function Command() {
  const preferences = getPreferenceValues<Preferences>();
  const [searchText, setSearchText] = useState("");
  const [kindFilter, setKindFilter] = useState<string>("link");
  const [isLoading, setIsLoading] = useState(true);
  const [results, setResults] = useState<SearchResult[]>([]);
  const [errorText, setErrorText] = useState<string>("");
  const requestSerial = useRef(0);

  const resolvedStorePath = useMemo(
    () => expandPath(preferences.storePath?.trim() || DEFAULT_STORE_PATH),
    [preferences.storePath],
  );
  const maxResults = useMemo(
    () => normalizeMaxResults(preferences.maxResults),
    [preferences.maxResults],
  );
  const showXDomain = preferences.showXDomain ?? true;

  useEffect(() => {
    const timer = setTimeout(() => {
      void load();
    }, SEARCH_DEBOUNCE_MS);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchText, kindFilter, resolvedStorePath, maxResults, showXDomain]);

  async function load() {
    const serial = ++requestSerial.current;
    setIsLoading(true);
    setErrorText("");

    try {
      const sqlRows = await queryRows({
        storePath: resolvedStorePath,
        query: searchText.trim(),
        kindFilter: kindFilter !== "all" ? kindFilter : undefined,
        fetchLimit: Math.min(MAX_FETCH_LIMIT, Math.max(maxResults * 2, 200)),
      });
      // Phase 1: hydrate without tags (no subprocess needed)
      const hydrated = hydrateResultsWithoutTags(sqlRows);
      const sorted = sortAndFilter(hydrated, showXDomain).slice(0, maxResults);

      // Phase 2: decode tags only for the final visible slice
      const withTags = await fillTags(sorted, sqlRows);

      if (serial !== requestSerial.current) return;
      setResults(withTags);
    } catch (error) {
      if (serial !== requestSerial.current) return;
      const message = error instanceof Error ? error.message : "Unknown error";
      setErrorText(message);
      setResults([]);
      await showToast({
        style: Toast.Style.Failure,
        title: "NotNow search failed",
        message,
      });
    } finally {
      if (serial === requestSerial.current) {
        setIsLoading(false);
      }
    }
  }

  const sections = useMemo(() => {
    const map = new Map<BookmarkKind, SearchResult[]>();
    for (const kind of KIND_ORDER) map.set(kind, []);
    for (const item of results) {
      map.get(item.kind)?.push(item);
    }
    return KIND_ORDER.map((kind) => ({
      kind,
      title: KIND_META[kind].title,
      items: map.get(kind) ?? [],
    })).filter((section) => section.items.length > 0);
  }, [results]);

  return (
    <List
      isLoading={isLoading}
      filtering={false}
      throttle
      onSearchTextChange={setSearchText}
      searchBarPlaceholder="Search by name, URL, desc..."
      searchBarAccessory={
        <List.Dropdown
          tooltip="Filter by Kind"
          value={kindFilter}
          onChange={setKindFilter}
        >
          <List.Dropdown.Item
            title="All"
            value="all"
            icon={Icon.AppWindowGrid3x3}
          />
          <List.Dropdown.Item
            title="Links"
            value="link"
            icon={KIND_META.link.icon}
          />
          <List.Dropdown.Item
            title="Snippets"
            value="snippet"
            icon={KIND_META.snippet.icon}
          />
          <List.Dropdown.Item
            title="Tasks"
            value="task"
            icon={KIND_META.task.icon}
          />
          <List.Dropdown.Item
            title="APIs"
            value="api"
            icon={KIND_META.api.icon}
          />
        </List.Dropdown>
      }
    >
      {!isLoading && errorText ? (
        <List.EmptyView
          title="Search Error"
          description={errorText}
          icon={Icon.ExclamationMark}
        />
      ) : null}
      {!isLoading && !errorText && sections.length === 0 ? (
        <List.EmptyView
          title="No Results"
          description="Try another keyword or switch the kind filter."
          icon={Icon.MagnifyingGlass}
        />
      ) : null}
      {sections.map((section) => (
        <List.Section
          key={section.kind}
          title={section.title}
          subtitle={String(section.items.length)}
        >
          {section.items.map((item) => (
            <List.Item
              key={item.id}
              icon={{
                source: KIND_META[item.kind].icon,
                tintColor: KIND_META[item.kind].color,
              }}
              title={item.title || "(untitled)"}
              subtitle={item.url}
              accessories={buildAccessories(item)}
              actions={<BookmarkActions item={item} />}
            />
          ))}
        </List.Section>
      ))}
    </List>
  );
}

function BookmarkActions({ item }: { item: SearchResult }) {
  const isHttpUrl = /^https?:\/\//i.test(item.url);
  const editTargetId = resolveEditTargetId(item);
  const editInNotNow =
    item.kind !== "link" ? (
      <Action
        title="Edit in NotNow"
        icon={Icon.Pencil}
        autoFocus
        onAction={() => {
          if (editTargetId) {
            open(`notnow://edit/${editTargetId}`);
          }
        }}
      />
    ) : null;
  return (
    <ActionPanel>
      {editInNotNow}
      {isHttpUrl ? (
        <Action.OpenInBrowser url={item.url} title="Open URL" />
      ) : (
        <Action
          title="Open URL"
          icon={Icon.ArrowRight}
          onAction={() => open(item.url)}
        />
      )}
      <Action.CopyToClipboard title="Copy URL" content={item.url} />
      {item.kind === "snippet" && item.snippetContent ? (
        <Action.CopyToClipboard
          title="Copy Snippet Content"
          content={item.snippetContent}
        />
      ) : null}
      {item.kind === "api" && item.apiQueryParams ? (
        <Action.CopyToClipboard
          title="Copy API Query Params"
          content={item.apiQueryParams}
        />
      ) : null}
      <Action.Push
        title="Show Details"
        icon={Icon.Sidebar}
        target={
          <Detail
            markdown={buildMarkdown(item)}
            metadata={buildMetadata(item)}
          />
        }
      />
    </ActionPanel>
  );
}

function buildMetadata(item: SearchResult): React.JSX.Element {
  return (
    <List.Item.Detail.Metadata>
      <List.Item.Detail.Metadata.Label title="Kind" text={item.kind} />
      <List.Item.Detail.Metadata.Label
        title="Category"
        text={item.category || "Uncategorized"}
      />
      <List.Item.Detail.Metadata.Link
        title="URL"
        text={item.url}
        target={item.url}
      />
      <List.Item.Detail.Metadata.Separator />
      {item.tags.length ? (
        <List.Item.Detail.Metadata.TagList title="Tags">
          {item.tags.map((tag) => (
            <List.Item.Detail.Metadata.TagList.Item
              key={tag}
              text={tag}
              color={colorForTag(tag)}
            />
          ))}
        </List.Item.Detail.Metadata.TagList>
      ) : null}
      {item.kind === "task" ? (
        <>
          <List.Item.Detail.Metadata.Label
            title="Completed"
            text={item.isCompleted ? "Yes" : "No"}
          />
          <List.Item.Detail.Metadata.Label
            title="Due Date"
            text={item.dueDate ? item.dueDate.toLocaleString() : "N/A"}
          />
        </>
      ) : null}
      {item.kind === "api" ? (
        <List.Item.Detail.Metadata.Label
          title="Method"
          text={item.apiMethod || "GET"}
        />
      ) : null}
      {item.updatedAt ? (
        <List.Item.Detail.Metadata.Label
          title="Updated At"
          text={item.updatedAt.toLocaleString()}
        />
      ) : null}
      {item.isXDomain ? (
        <List.Item.Detail.Metadata.Label
          title="Domain Priority"
          text="x.com (lower priority by default)"
        />
      ) : null}
    </List.Item.Detail.Metadata>
  );
}

function buildMarkdown(item: SearchResult): string {
  const lines: string[] = [];
  lines.push(`# ${escapeMarkdown(item.title || "(untitled)")}`);
  lines.push("");
  lines.push(`- Kind: \`${item.kind}\``);
  lines.push(
    `- Category: \`${escapeMarkdown(item.category || "Uncategorized")}\``,
  );
  lines.push(`- URL: ${item.url}`);
  if (item.desc) {
    lines.push("");
    lines.push("## Description");
    lines.push("");
    lines.push(escapeMarkdown(item.desc));
  }
  if (item.kind === "snippet" && item.snippetContent) {
    lines.push("");
    lines.push("## Snippet Content");
    lines.push("");
    lines.push("```");
    lines.push(item.snippetContent);
    lines.push("```");
  }
  if (item.kind === "api" && item.apiQueryParams) {
    lines.push("");
    lines.push("## API Query Params");
    lines.push("");
    lines.push("```json");
    lines.push(item.apiQueryParams);
    lines.push("```");
  }
  return lines.join("\n");
}

function buildAccessories(item: SearchResult): List.Item.Accessory[] {
  const accessories: List.Item.Accessory[] = [];

  if (item.category) {
    accessories.push({ text: item.category });
  }

  if (item.kind === "api") {
    accessories.push({
      tag: {
        value: item.apiMethod || "GET",
        color: methodColor(item.apiMethod || "GET"),
      },
    });
  }

  if (item.kind === "task") {
    accessories.push({
      tag: {
        value: item.isCompleted ? "DONE" : "TODO",
        color: item.isCompleted ? Color.Green : Color.Orange,
      },
    });
  }

  if (item.isXDomain) {
    accessories.push({ tag: { value: "x.com", color: Color.Red } });
  }

  for (const tag of item.tags.slice(0, 2)) {
    accessories.push({
      tag: { value: `#${tag}`, color: colorForTag(tag) },
      tooltip: `Tag: ${tag}`,
    });
  }

  return accessories.slice(0, 6);
}

function methodColor(method: string): Color {
  switch (method.toUpperCase()) {
    case "GET":
      return Color.Green;
    case "POST":
      return Color.Blue;
    case "PUT":
      return Color.Orange;
    case "DELETE":
      return Color.Red;
    case "PATCH":
      return Color.Purple;
    default:
      return Color.SecondaryText;
  }
}

function colorForTag(tag: string): Color {
  const idx = Math.abs(hash(tag)) % TAG_PALETTE.length;
  return TAG_PALETTE[idx];
}

function hash(input: string): number {
  let value = 0;
  for (let i = 0; i < input.length; i++) {
    value = (value << 5) - value + input.charCodeAt(i);
    value |= 0;
  }
  return value;
}

function normalizeKind(raw: string): BookmarkKind {
  const lower = (raw || "").toLowerCase();
  if (lower === "snippet" || lower === "task" || lower === "api") return lower;
  return "link";
}

function normalizeMaxResults(raw?: string): number {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) return DEFAULT_MAX_RESULTS;
  return Math.min(500, Math.max(20, Math.floor(parsed)));
}

function expandPath(inputPath: string): string {
  if (inputPath === "~") return os.homedir();
  if (inputPath.startsWith("~/"))
    return path.join(os.homedir(), inputPath.slice(2));
  return inputPath;
}

function toDateFromAppleRef(raw: number): Date | undefined {
  if (!Number.isFinite(raw) || raw <= 0) return undefined;
  return new Date((raw + APPLE_REF_UNIX_OFFSET_SECONDS) * 1000);
}

function isXDomain(url: string): boolean {
  try {
    const host = new URL(url).hostname.toLowerCase();
    return host === "x.com" || host.endsWith(".x.com");
  } catch {
    return false;
  }
}

function sortAndFilter(
  rows: SearchResult[],
  showXDomain: boolean,
): SearchResult[] {
  const filtered = showXDomain ? rows : rows.filter((row) => !row.isXDomain);
  return filtered.sort((a, b) => {
    const kindRank = KIND_ORDER.indexOf(a.kind) - KIND_ORDER.indexOf(b.kind);
    if (kindRank !== 0) return kindRank;
    const xRank = Number(a.isXDomain) - Number(b.isXDomain);
    if (xRank !== 0) return xRank;
    const updatedA = a.updatedAt?.getTime() ?? 0;
    const updatedB = b.updatedAt?.getTime() ?? 0;
    if (updatedA !== updatedB) return updatedB - updatedA;
    return a.title.localeCompare(b.title, "zh-Hans");
  });
}

function hydrateResultsWithoutTags(rows: SQLiteRow[]): SearchResult[] {
  return rows.map((row) => {
    const kind = normalizeKind(String(row.kind));
    return {
      id: String(row.id),
      title: String(row.title || ""),
      url: String(row.url || ""),
      kind,
      category: String(row.category || "Uncategorized"),
      desc: String(row.desc || ""),
      tags: [],
      snippetContent: String(row.snippet_content || ""),
      apiMethod: String(row.api_method || ""),
      apiQueryParams: String(row.api_query_params || ""),
      isCompleted: Number(row.is_completed || 0) !== 0,
      dueDate: toDateFromAppleRef(Number(row.due_date_raw || 0)),
      updatedAt: toDateFromAppleRef(Number(row.updated_at_raw || 0)),
      isXDomain: isXDomain(String(row.url || "")),
    };
  });
}

async function fillTags(
  results: SearchResult[],
  sqlRows: SQLiteRow[],
): Promise<SearchResult[]> {
  const idToHex = new Map<string, string>();
  for (const row of sqlRows) {
    const hex = String(row.tags_blob_hex || "").trim();
    if (hex) idToHex.set(String(row.id), hex);
  }

  const neededHex = new Set<string>();
  for (const r of results) {
    const hex = idToHex.get(r.id);
    if (hex && !tagDecodeCache.has(hex)) neededHex.add(hex);
  }

  if (neededHex.size > 0) {
    const decoded = await decodeTagsBatch([...neededHex]);
    for (const [hex, tags] of decoded.entries()) {
      tagDecodeCache.set(hex, tags);
    }
    for (const hex of neededHex) {
      if (!tagDecodeCache.has(hex)) tagDecodeCache.set(hex, []);
    }
  }

  return results.map((r) => {
    const hex = idToHex.get(r.id);
    const tags = hex ? (tagDecodeCache.get(hex) ?? []) : [];
    return tags.length > 0 ? { ...r, tags } : r;
  });
}

async function ensureCompiledDecoder(): Promise<string> {
  if (compiledBinaryReady) return compiledBinaryReady;

  compiledBinaryReady = (async () => {
    try {
      await fs.access(TAG_DECODER_BIN);
      return TAG_DECODER_BIN;
    } catch {
      // Binary doesn't exist yet — compile it
    }
    await fs.mkdir(TAG_DECODER_CACHE_DIR, { recursive: true });
    const srcPath = path.join(TAG_DECODER_CACHE_DIR, "decode_tags.swift");
    await fs.writeFile(srcPath, SWIFT_TAG_DECODER, "utf8");
    await execFileAsync("swiftc", ["-O", "-o", TAG_DECODER_BIN, srcPath], {
      timeout: 30_000,
    });
    return TAG_DECODER_BIN;
  })();

  // If compilation fails, reset so we can retry next time
  compiledBinaryReady.catch(() => {
    compiledBinaryReady = null;
  });

  return compiledBinaryReady;
}

async function decodeTagsBatch(
  hexList: string[],
): Promise<Map<string, string[]>> {
  const output = new Map<string, string[]>();
  if (hexList.length === 0) return output;

  const binPath = await ensureCompiledDecoder();
  const tempDir = await fs.mkdtemp(
    path.join(os.tmpdir(), "notnow-tag-decode-"),
  );
  const inputPath = path.join(tempDir, "input.json");

  try {
    await fs.writeFile(inputPath, JSON.stringify(hexList), "utf8");
    const { stdout } = await execFileAsync(binPath, [inputPath], {
      maxBuffer: 4 * 1024 * 1024,
    });

    const parsed = JSON.parse(stdout || "{}") as Record<string, unknown>;
    for (const [hex, value] of Object.entries(parsed)) {
      if (Array.isArray(value)) {
        output.set(
          hex,
          value
            .filter((item): item is string => typeof item === "string")
            .map((item) => item.trim())
            .filter(Boolean),
        );
      }
    }
    return output;
  } catch {
    return output;
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
}

function escapeLike(input: string): string {
  return input
    .replace(/\\/g, "\\\\")
    .replace(/%/g, "\\%")
    .replace(/_/g, "\\_")
    .replace(/'/g, "''");
}

async function queryRows(params: {
  storePath: string;
  query: string;
  kindFilter?: string;
  fetchLimit: number;
}): Promise<SQLiteRow[]> {
  const conditions: string[] = [];

  if (params.query.length > 0) {
    const escaped = escapeLike(params.query);
    conditions.push(
      `(lower(COALESCE(b.ZURL, '')) LIKE lower('%${escaped}%') ESCAPE '\\'
         OR lower(COALESCE(b.ZTITLE, '')) LIKE lower('%${escaped}%') ESCAPE '\\'
         OR lower(COALESCE(b.ZDESC, '')) LIKE lower('%${escaped}%') ESCAPE '\\'
         OR lower(COALESCE(c.ZNAME, '')) LIKE lower('%${escaped}%') ESCAPE '\\')`,
    );
  }

  if (params.kindFilter) {
    conditions.push(
      `lower(COALESCE(b.ZKIND, 'link')) = '${escapeLike(params.kindFilter)}'`,
    );
  }

  const whereClause = conditions.length > 0 ? conditions.join(" AND ") : "1=1";

  const sql = `
SELECT
  lower(hex(b.ZID)) AS id,
  REPLACE(REPLACE(COALESCE(NULLIF(trim(b.ZTITLE), ''), '(untitled)'), char(10), ' '), char(9), ' ') AS title,
  COALESCE(NULLIF(trim(b.ZURL), ''), '') AS url,
  COALESCE(NULLIF(trim(b.ZKIND), ''), 'link') AS kind,
  COALESCE(NULLIF(trim(c.ZNAME), ''), 'Uncategorized') AS category,
  REPLACE(REPLACE(COALESCE(b.ZDESC, ''), char(10), ' '), char(9), ' ') AS desc,
  COALESCE(b.ZSNIPPETCONTENT, '') AS snippet_content,
  COALESCE(NULLIF(trim(b.ZAPIMETHOD), ''), '') AS api_method,
  COALESCE(NULLIF(trim(b.ZAPIQUERYPARAMS), ''), '') AS api_query_params,
  COALESCE(b.ZISCOMPLETED, 0) AS is_completed,
  COALESCE(b.ZDUEDATE, 0) AS due_date_raw,
  COALESCE(b.ZUPDATEDAT, 0) AS updated_at_raw,
  COALESCE(hex(b.ZTAGS), '') AS tags_blob_hex
FROM ZBOOKMARK b
LEFT JOIN ZCATEGORY c ON c.Z_PK = b.ZCATEGORY
WHERE ${whereClause}
ORDER BY b.ZUPDATEDAT DESC
LIMIT ${Math.floor(params.fetchLimit)};
`;

  const { stdout } = await execFileAsync(
    "sqlite3",
    ["-readonly", "-json", params.storePath, sql],
    {
      maxBuffer: 16 * 1024 * 1024,
    },
  );

  const raw = (stdout || "").trim();
  if (!raw) return [];
  return JSON.parse(raw) as SQLiteRow[];
}

function escapeMarkdown(input: string): string {
  return input.replace(/([`*_{}[\]()#+\-.!>])/g, "\\$1");
}

function resolveEditTargetId(item: SearchResult): string | null {
  const rawId = String(item.id || "").trim();
  if (rawId.length === 32 && /^[0-9a-f]+$/i.test(rawId)) {
    return hexToUuid(rawId);
  }
  if (
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      rawId,
    )
  ) {
    return rawId.toLowerCase();
  }
  return null;
}

function hexToUuid(hex: string): string {
  const normalized = hex.toLowerCase();
  return `${normalized.slice(0, 8)}-${normalized.slice(8, 12)}-${normalized.slice(12, 16)}-${normalized.slice(16, 20)}-${normalized.slice(20, 32)}`;
}
