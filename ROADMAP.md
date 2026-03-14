# SuperSync Features Roadmap

> This roadmap assumes all current functionality (bidirectional `.sdr` sync across Dropbox, WebDAV, and FTP with three-way merge) is tested and confirmed working. Primary use case: **multi-device personal sync**.

---

## Tier 1: Quick Wins (Low complexity, high user value)

### 1.1 Book Catalog & On-Demand Download
- **Always sync metadata** (current behavior, lightweight)
- **Catalog remote books:** Maintain an index of all books available across devices in "sync land"
- **Browse available books:** UI to see what books exist on other devices but not locally
- **On-demand download:** User taps to pull a specific book to their device
- Could show: title, author, file size, last read date, reading progress
- Storage-friendly: essential for e-ink devices with limited space
- Architecture TBD: could be integrated with metadata sync or a separate feature sharing the same provider config

### 1.2 Local Folder Sync Target
- **The big idea:** Allow syncing to a local directory path instead of a cloud API
- Users point SuperSync at a local folder (e.g., `/mnt/syncthing/koreader-sync/`)
- That folder is managed by whatever external tool the user prefers: **Syncthing, rclone, Nextcloud client, Resilio Sync, Dropbox desktop, Google Drive desktop, OneDrive, etc.**
- SuperSync handles `.sdr` discovery, merge logic, and conflict resolution; the external tool handles transport
- **Massive benefit:** Instantly supports every cloud/sync service without implementing OAuth or provider-specific APIs
- Simplest possible implementation: just use `lfs` file operations (copy, stat) instead of network calls

### 1.3 Sync Progress Bar
- Replace file-by-file InfoMessage with a proper progress bar widget
- Show: current file name, N/M files complete, bytes transferred
- Use KOReader's `ProgressWidget` patterns

### 1.4 Dry Run / Preview Mode
- "Preview sync" option that shows what *would* happen without transferring files
- Summary: X files to upload, Y to download, Z conflicts, W unchanged
- Builds user trust before committing to a sync operation

### 1.5 Sync History Log
- Record each sync operation (timestamp, files uploaded/downloaded/merged/skipped, errors) to a local log file
- Add "Sync history" menu item showing last N syncs with summary stats
- Useful for debugging and user confidence

---

## Tier 2: Reliability & Performance (Medium complexity, essential for real-world use)

### 2.1 Retry & Resilience
- Per-file retry with backoff on transient network errors
- Resume interrupted syncs (track which files completed)
- Partial sync success: report which files failed without blocking the rest

### 2.2 Atomic Sync State
- Ensure a crash mid-sync doesn't leave cache in inconsistent state
- Add sync "transaction" concept: only update last_sync_time if all files succeeded (or record partial state)

### 2.3 Delta Sync (Changed Files Only)
- Track per-file content hashes locally
- Only upload files whose hash changed since last sync
- Dramatically reduces bandwidth for users with many books

### 2.4 Selective Sync (Exclude List)
- Allow users to exclude specific books/`.sdr` directories from sync
- Store exclusion list in settings

### 2.5 Device Identification
- Generate a unique device ID on first run (stored in settings)
- Tag remote files/folders with device origin
- Foundation for multi-device merge strategies in Tier 3

---

## Tier 3: Multi-Device Intelligence (Higher complexity, differentiating features)

### 3.1 Multi-Device Aware Merge
- Build on device IDs (2.5) to maintain per-device sync state
- Resolve conflicts with awareness of which device made which change
- Strategies: "merge all" (default), "last device wins", "prompt user"
- Key differentiator over KOReader's built-in progress sync

### 3.2 Conflict Resolution UI
- When a merge conflict can't be auto-resolved, show a dialog:
  - "Book X was modified on both devices. Keep: [Local] [Remote] [Merge] [Skip]"
- Show diff summary (e.g., "Local: 3 new highlights, Remote: 1 new bookmark")
- Queue conflicts for batch resolution after sync completes

### 3.3 Metadata-Type Selective Sync
- Choose *what* to sync per provider:
  - Reading position only (lightweight)
  - Highlights & annotations
  - Document settings (fonts, margins)
  - Reading statistics
  - Everything (current default)
- Useful: position sync to cloud, full backup to local folder

### 3.4 Sync Scheduling / Background Sync
- Periodic sync at configurable intervals via `UIManager:scheduleIn()`
- Respect battery/connectivity constraints
- Conservative defaults for e-ink power profiles

---

## Tier 4: Ecosystem Expansion

### 4.1 SSH/SFTP Support
- More secure than FTP, widely available on Linux/NAS devices
- Investigate KOReader's bundled libraries or shell out to `sftp` command
- Natural complement to the local folder approach for remote servers

### 4.2 Versioned Backups
- Keep N versions of each synced file in the sync target
- "Restore from backup" to roll back to a previous state
- Recovery for "I accidentally deleted all my highlights"

### 4.3 Export / Import Formats
- Export highlights/annotations to standard formats (JSON, Markdown, CSV)
- Import from other reading apps or tools
- Interop with Readwise, Zotero, Calibre

### 4.4 Calibre Integration (Nice-to-Have)
- Two-way metadata sync with a Calibre library
- Push reading progress to Calibre, pull Calibre metadata to KOReader
- Could use Calibre's content server API

---

## Tier 5: Advanced / Experimental

### 5.1 Peer-to-Peer Sync (Device-to-Device)
- Direct sync between two KOReader devices on the same LAN
- Extend KOReader's existing OPDS HTTP server with a sync endpoint
- No cloud server needed at all

### 5.2 Sync Plugins/Hooks API
- Let other KOReader plugins register data for sync
- Generic "sync this file/table" API
- Makes SuperSync a platform, not just a standalone feature

### 5.3 Compression
- ZIP `.sdr` folders before upload for bandwidth savings
- Trade-off: adds complexity to conflict resolution flow

---

## Suggested Implementation Phases

```
Phase 1 (Foundation):   1.2, 1.3, 2.1, 2.2      -- Local folder sync + trust & reliability
Phase 2 (Usability):    1.4, 1.5, 2.4, 2.5       -- Preview, history, selective sync, device IDs
Phase 3 (Library):      1.1, 2.3                  -- Book catalog + delta sync
Phase 4 (Intelligence): 3.1, 3.2, 3.3             -- Multi-device merge + conflict UI
Phase 5 (Expansion):    4.1, 4.2, 3.4             -- SFTP, versioned backups, scheduling
Phase 6 (Ecosystem):    4.3, 4.4, 5.1-5.3         -- Export/import, Calibre, P2P, plugin API
```

**Phase 1 is the critical path.** Local folder sync (1.2) is the single highest-impact feature because it:
- Eliminates OAuth implementation burden for new providers
- Lets users leverage their existing sync infrastructure
- Works offline (sync to local folder, external tool syncs when online)
- Simplest to implement (filesystem operations only)

**Book catalog (1.1)** is placed in Phase 3 because it depends on having a working sync target and needs more design thought around architecture (integrated vs. separate from metadata sync).

---

## What NOT to Build

- **Account system / central server:** Keep it decentralized. Users bring their own storage.
- **Real-time sync:** E-ink devices aren't suited for it. Event-triggered (on close, on suspend) is the right model.
- **OAuth for Google Drive / OneDrive directly:** The local folder approach (1.2) makes this unnecessary. Let dedicated sync clients handle auth.
- **Automatic full library mirror:** Don't blindly download all books to all devices. Book downloads should always be user-initiated (see 1.1 catalog approach).
