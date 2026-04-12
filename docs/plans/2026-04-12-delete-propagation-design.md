# Delete Propagation for Dropbox/WebDAV

**Date:** 2026-04-12
**Status:** Approved
**Scope:** Single-device cleanup (not multi-device coordination)

## Problem

The FTP sync path (`FtpSync`) detects deleted local files via the sync cache and
propagates deletions to the remote server. The Dropbox/WebDAV path
(`SyncService`) has no equivalent — `syncengine.lua:performFullSync` only
iterates over locally-present `.sdr` directories, so a deleted book's remote
`.sdr` folder persists indefinitely.

## Design

### Approach: Extend SyncCache with a directory manifest

Add a `synced_directories` map to the existing per-server data in
`synccache.lua`. This tracks which `.sdr` directories were successfully synced.
On each sync, compare the manifest against the current local scan to detect
orphans (directories that were synced previously but no longer exist locally).

Orphaned remote `.sdr` folders are moved to a `.supersync-archive/` subfolder
rather than hard-deleted, so the user can recover if needed.

### Data Model

The existing cache structure gains a new `synced_directories` key per server.
Cache version stays at 1 (no production users to migrate).

```json
{
  "version": 1,
  "servers": {
    "My WebDAV": {
      "last_sync_time": 1706140800,
      "files": { ... },
      "cached_content": { ... },
      "synced_directories": {
        "MyBook.sdr": {
          "first_synced": 1706140800,
          "last_synced": 1706200000,
          "remote_path": "/KOReader-SuperSync/MyBook.sdr"
        }
      }
    }
  }
}
```

### Sync Flow

Delete detection runs after the normal sync completes:

1. Scan local `.sdr` directories (existing code)
2. Sync each directory (existing code)
3. Update `synced_directories` manifest with the current local set
4. Compare manifest vs local scan to find orphaned entries
5. For each orphan:
   a. Move remote `.sdr` folder to `<sync_folder>/.supersync-archive/<name>.<timestamp>/`
   b. Remove entry from manifest
6. Save cache

The manifest is only updated for directories that successfully synced. If sync
fails for a directory, it stays in the manifest but is not flagged as orphaned.

### Archive Path

Archived directories use timestamped names to avoid collisions:

```
/.supersync-archive/MyBook.sdr.2026-04-12T1430/
```

Format: `<original_name>.<ISO-date>T<HHMM>`. Minute-level precision is
sufficient.

### Provider Move Operations

Each provider needs a move/rename capability added to `cloudprovider.lua`:

- **Dropbox:** `DropBoxApi` move endpoint (`/files/move_v2`). Single API call.
- **WebDAV:** HTTP `MOVE` method with `Destination` header. Check if `WebDavApi`
  exposes this; if not, add it.
- **FTP:** Add `RNFR`/`RNTO` (rename) command pair to `ftphelper.lua`.

**Fallback:** If move/rename fails, leave the remote folder in place and log a
warning. No data loss. Can revisit with copy+delete fallback later.

### Error Handling & Edge Cases

| Scenario | Behavior |
|---|---|
| First sync (empty manifest) | Manifest populated, no orphans detected |
| Book removed between syncs | Next sync archives the remote `.sdr` |
| Book re-added after archiving | New `.sdr` uploaded normally; archive untouched |
| Archive folder doesn't exist | Created on first archive operation |
| Move fails mid-archive | Next sync retries; partial state is safe |
| Multiple providers | Independent `synced_directories` per server name |
| Second archive of same book | Timestamped name avoids collision |

### What This Design Does NOT Cover

- Multi-device delete coordination (out of scope)
- Automatic archive cleanup/expiry (future enhancement)
- Archive browsing or restore UI (future enhancement)
