Now I have all the data. Let me compile the comprehensive report.

---

# Database Separation Audit: Echo Project

## Verdict: **YES — Fully Separated**

The history store and usage store are completely independent persistence layers. They share a parent directory (`Application Support/Echo/`) but use **different file formats**, **different file paths**, **different data schemas**, and **different storage engines**. No cross-contamination of data occurs.

---

## 1. Storage Backends

### TranscriptStore (History)
| Property | Value |
|---|---|
| **File** | `~/Library/Application Support/Echo/history.json` |
| **Format** | Plain JSON (human-readable, entire file read/written atomically) |
| **Engine** | Foundation `JSONEncoder`/`JSONDecoder` |
| **Model** | `TranscriptEntry(id: UUID, date: Date, text: String)` |
| **Cap** | 500 entries (configurable via `maxEntries` parameter) |
| **Source** | `TranscriptStore.swift:19-28` |

### UsageStore (Insights)
| Property | Value |
|---|---|
| **File** | `~/Library/Application Support/Echo/usage.sqlite` |
| **Format** | SQLite database (binary, indexed, append-only) |
| **Engine** | Raw `SQLite3` C API via `sqlite3_open`/`sqlite3_prepare_v2` |
| **Schema** | Single table `dictations` with columns: `id`, `created_at`, `word_count`, `duration_seconds`, `latency_seconds`, `app_bundle_id`, `app_name` |
| **Cap** | Unlimited (no row limit) |
| **Source** | `UsageStore.swift:29-45` |

Both stores resolve their directory identically:
```swift
// TranscriptStore.swift:23-26
let base = directory ?? FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Echo", isDirectory: true)
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
fileURL = base.appendingPathComponent("history.json")

// UsageStore.swift:29-33
let base = directory ?? FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Echo", isDirectory: true)
try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
let path = base.appendingPathComponent("usage.sqlite").path
```

---

## 2. Data Isolation

**No cross-contamination.** Each store manages completely disjoint data:

| Data | TranscriptStore | UsageStore |
|---|---|---|
| Full transcript text | ✅ `text: String` | ❌ Never stored |
| Word count | ✅ (derived via `wordCount` computed property) | ✅ `word_count` column |
| Dictation timestamp | ✅ `date: Date` | ✅ `created_at: REAL` (Unix timestamp) |
| Duration | ❌ | ✅ `duration_seconds` |
| Latency | ❌ | ✅ `latency_seconds` |
| Source app (bundle ID / name) | ❌ | ✅ `app_bundle_id`, `app_name` |
| UUID | ✅ `id: UUID` | ❌ (auto-increment integer `id`) |

The UsageStore's opening comment explicitly states the design intent:

> *"Permanent, local-only dictation statistics in SQLite. Stores counts and timings — never transcript text — so Insights works even with history off."*
> — `UsageStore.swift:11-13`

---

## 3. Saving Behavior (DictationController)

In `DictationController.swift` (~lines 139-152), the two stores are written in this sequence after transcription completes:

```swift
// GATED by settings.saveHistory:
if self.settings.saveHistory {
    self.transcripts?.add(text)    // ← only saves transcript text if toggle is ON
}

let frontApp = NSWorkspace.shared.frontmostApplication
let recordUsage = {
    self.usage?.record(             // ← ALWAYS records usage stats
        words: text.split(whereSeparator: \.isWhitespace).count,
        duration: duration,
        latency: Date().timeIntervalSince(releasedAt),
        appBundleID: frontApp?.bundleIdentifier,
        appName: frontApp?.localizedName
    )
}
```

**Key behavioral difference:**
- **TranscriptStore** (history) — **gated:** only saves when `settings.saveHistory == true` (default: `true`, `SettingsStore.swift:42`)
- **UsageStore** (insights) — **unconditional:** always records usage statistics regardless of the `saveHistory` toggle

This means:
- A user who disables `saveHistory` in Settings will **lose transcript text** but **continue accumulating usage statistics** (words per minute, streaks, app usage, etc.)
- The insights page functions independently of the history feature.

---

## 4. Data Sensitivity

### Does UsageStore ever store transcript text?
**No.** The `dictations` table schema contains no text column. The `record()` method at `UsageStore.swift:59-86` only binds:
- `created_at` (double — unix timestamp)
- `word_count` (integer)
- `duration_seconds` (double)
- `latency_seconds` (nullable double)
- `app_bundle_id` (nullable text)
- `app_name` (nullable text)

### Does TranscriptStore store anything beyond transcript text?
**Only `id`, `date`, `text`.** There is no application metadata, no duration, no app tracking, no latency data.

### Privacy implications:
- If a user turns off `saveHistory`, the only place transcript text existed (`history.json`) stops being written. Existing entries can be manually cleared ("Clear History" button in `HistoryView.swift:64-73`). The JSON file is deleted via overwrite.
- Usage statistics are **anonymous by design** — they store only counts, timestamps, and app identifiers. No speech content is persisted in the SQLite database.

---

## 5. Architecture Pattern

These are **truly separate databases** — not just different tables/collections in the same storage.

| Aspect | TranscriptStore | UsageStore |
|---|---|---|
| File | `history.json` | `usage.sqlite` |
| Engine | Foundation JSON (no query engine) | SQLite3 |
| Read pattern | Load entire file into memory | Indexed queries (e.g., `COALESCE(SUM(word_count), 0)`) |
| Write pattern | Rewrite entire file atomically | Insert one row per dictation |
| Data model | `[TranscriptEntry]` array | SQL `dictations` table |
| Concurrency | Single-threaded (`@MainActor`) | Single-threaded (`@MainActor`) |

### Dependency flow:

```
                     ┌─────────────────────────────────┐
                     │         EchoApp.swift            │
                     │  (wires everything together)     │
                     └──────┬────────────┬──────────────┘
                            │            │
              ┌─────────────▼──┐   ┌─────▼─────────────┐
              │ TranscriptStore│   │   UsageStore       │
              │ history.json   │   │   usage.sqlite     │
              │ @StateObject   │   │   @StateObject     │
              └────────┬───────┘   └────────┬───────────┘
                       │                    │
              ┌────────▼───────┐   ┌────────▼───────────┐
              │  HistoryView   │   │   InsightsView      │
              │ @EnvironmentObj│   │   @EnvironmentObj   │
              │ Search + clear │   │   Stats + heatmap   │
              └────────────────┘   └────────────────────┘
                       │                    │
              ┌────────▼────────────────────▼───────────┐
              │        DictationController               │
              │  transcripts?.add(text) [GATED]          │
              │  usage?.record(...)     [UNCONDITIONAL]  │
              └─────────────────────────────────────────┘
```

---

## 6. Implications of the Separation

### Privacy
- The `saveHistory` toggle in Settings (`SettingsStore.swift:40-43`) controls ONLY transcript text persistence.
- Usage statistics continue even with history off, giving the user privacy over their actual words while still providing insight dashboards.
- This is user-facing: `HistoryView.swift:87-89` shows "History is turned off in Settings." when history is disabled.

### Performance
- TranscriptStore loads the **entire JSON file** into memory on init and rewrites it atomically on every add. Capped at 500 entries, this is trivial (< 1 MB).
- UsageStore uses **indexed SQL queries** — it can handle millions of rows efficiently without loading everything. The `idx_dictations_created` index (`UsageStore.swift:43`) optimizes the date-range queries used by `totals()`, `averageWPM()`, `dailyWords()`, etc.

### Feature independence
- The insights feature (words per minute, streaks, heatmap, per-app breakdown, WPM gauge) **does not depend** on the history feature being enabled.
- A user can clear their entire transcript history without losing any aggregate statistics.

### Testability
- `Streaks.compute()` — the streak arithmetic — is extracted as a **pure function** with no database dependency (`UsageStore.swift:200-224`), making it independently testable.

---

## 7. Concerns & Gaps

### Minor concerns:

1. **No transactional guarantee** between the two stores (severity: **low**)
   - In `DictationController.swift`, the transcription task writes to both stores sequentially but there is no rollback if one fails. Since they are independent files with independent data, this is the correct design — there is no cross-store consistency requirement.
   
2. **No encryption at rest** (severity: **medium**)
   - Both `history.json` and `usage.sqlite` are stored in plaintext in `~/Library/Application Support/Echo/`. Neither file uses macOS-level encryption (e.g., `FileProtectionType` or CoreData with encryption). This is a privacy concern for users with sensitive dictation content, though the app is macOS-only where file system access is sandboxed.

3. **JSON file rewriting is not crash-safe** (severity: **low**)
   - `TranscriptStore.save()` uses `.atomic` write option (`TranscriptStore.swift:50`), which writes to a temp file then renames. This is crash-safe against partial writes, but if the app crashes between `load()` and `save()`, the in-memory `add()` would be lost. Acceptable for a per-dictation log.

4. **SQLite is never VACUUMed** (severity: **low**)
   - The UsageStore only inserts; it never deletes. No `VACUUM` or auto-vacuum is configured. For typical desktop usage this won't matter, but over years of heavy use the database file could grow. No out-of-band cleanup mechanism exists.

5. **Stores are singletons created in EchoApp.init()** (severity: **low**)
   - Both stores are allocated unconditionally when the app launches (`EchoApp.swift:10-12`). The `transcripts` and `usage` parameters in `DictationController.init()` are optional (`TranscriptStore?`, `UsageStore?`), but in practice they're always provided. No mechanism exists to create/test the controller without both stores.

6. **`todayWordCount` in TranscriptStore is duplicated from UsageStore data** (severity: **info**)
   - `TranscriptStore.todayWordCount` (line 46-48) derives today's word count from the in-memory JSON array. The same information could be queried from UsageStore. This is a minor redundancy, not a data integrity concern.

### No blockers identified.

---

## Acceptance Report