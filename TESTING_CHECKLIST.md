# SuperSync Plugin – Manual Testing Checklist

Use this checklist when testing the plugin on a real KOReader device. Mark each
item `[x]` when it passes, `[!]` when it fails (note the failure), or `[-]` to
skip (with a reason).

---

## 1. Plugin Installation & Load

- [ ] Plugin folder copied to `koreader/plugins/supersync.koplugin/`
- [ ] KOReader starts without a Lua error dialog
- [ ] "Super Sync" entry appears in the **Tools** section of the main menu
- [ ] Warning banner ("not ready for use") is **not** shown after the initial
  warning commits were integrated (verify in menu label/description)

---

## 2. Menu Structure

Navigate to **Tools → Super Sync** and verify the sub-menu contains:

- [ ] **Sync now** (greyed out until configured & enabled)
- [ ] **Status**
- [ ] **Settings** (expands to sub-menu)

Navigate to **Settings** and verify it contains:

- [ ] **Enabled / Disabled** toggle (checkbox)
- [ ] **Cloud storage** (expands to server list or "not configured" item)
- [ ] **Sync folder: /KOReader-SuperSync** (default value shown)
- [ ] **Auto-sync options** (expands to sub-menu)
- [ ] **Configure cloud storage** (opens the built-in cloud storage UI)

Navigate to **Auto-sync options**:

- [ ] **Sync on document close** (checkbox)
- [ ] **Sync on suspend** (checkbox)

---

## 3. Initial Configuration – No Cloud Storage

With no cloud storage configured in KOReader:

- [ ] **Cloud storage** sub-menu shows "No cloud storage configured" (disabled)
  and a "Configure cloud storage" item
- [ ] **Sync now** is greyed out / disabled
- [ ] **Status** shows "Status: Not configured" with "No cloud storage selected"

---

## 4. Cloud Storage Configuration

### 4a. Open built-in cloud storage UI

- [ ] **Settings → Configure cloud storage** opens KOReader's cloud storage
  browser without crashing

### 4b. After adding a Dropbox account

- [ ] **Settings → Cloud storage** lists the Dropbox server as
  `<name> (dropbox)`
- [ ] Selecting it shows a 2-second confirmation toast
- [ ] The item shows a checkmark after selection
- [ ] `G_reader_settings` persists the selection after a restart

### 4c. After adding a WebDAV account

- [ ] Server appears as `<name> (webdav)` in the list
- [ ] Can be selected and checkmark appears

### 4d. After adding an FTP account

- [ ] Server appears as `<name> (ftp)` in the list
- [ ] Can be selected and checkmark appears

---

## 5. Sync Folder Setting

- [ ] Default value is `/KOReader-SuperSync`
- [ ] Dialog opens when tapping the sync folder item
- [ ] Entering a path without a leading `/` prepends one automatically
  (e.g., type `MyFolder` → saved as `/MyFolder`)
- [ ] Entering an empty string does **not** save (dialog stays open)
- [ ] Confirmation toast shows the new path after saving
- [ ] Change persists after navigating away and returning

---

## 6. Enable/Disable Toggle

- [ ] Plugin starts **disabled** by default (text reads "Disabled")
- [ ] Tapping the toggle changes text to "Enabled" and checkbox is filled
- [ ] **Sync now** becomes active once enabled *and* cloud storage is selected
- [ ] Tapping the toggle again disables it; **Sync now** is greyed out again
- [ ] State persists across a KOReader restart

---

## 7. Status Screen

### 7a. When disabled

- [ ] Shows "Status: Disabled"
- [ ] Last sync shows "Last sync: Never" on first use

### 7b. When enabled but not fully configured

- [ ] Shows "Status: Not configured"
- [ ] Lists which parts are missing (no cloud storage / no sync folder)

### 7c. When fully configured

- [ ] Shows "Status: Ready"
- [ ] Shows correct cloud storage name and sync folder
- [ ] Shows correct auto-sync flags (Yes/No)
- [ ] After a successful sync, shows formatted date/time for last sync

---

## 8. Sync Now – Pre-conditions

- [ ] Tapping **Sync now** while **disabled** shows "Super Sync is disabled"
  info message
- [ ] Tapping **Sync now** while enabled but not configured shows "not
  configured" info message
- [ ] Tapping **Sync now** while offline prompts to turn Wi-Fi on; sync runs
  after connecting

---

## 9. First Sync – Dropbox / WebDAV (Bidirectional via SyncService)

Prerequisites: at least one book opened so `.sdr` metadata files exist.

- [ ] "Super Sync: Initializing..." toast appears briefly
- [ ] Sync completes and shows "Super Sync completed! N files uploaded."
- [ ] Remote folder `<sync_folder>/<bookname>.sdr/` is created on the server
- [ ] `metadata.<ext>.lua` and any other `.sdr` files appear on the server
- [ ] **Status** screen now shows a last-sync timestamp
- [ ] Running sync again immediately shows "No files needed uploading" (nothing
  changed)

---

## 10. Bidirectional Sync – Dropbox / WebDAV

### 10a. Remote-only change (download)

1. Manually edit a metadata file on the server (change a value)
2. Trigger sync on device

- [ ] Changed file is downloaded to device
- [ ] File content on device matches the server version

### 10b. Local-only change (upload)

1. Open a book, add a bookmark or highlight
2. Trigger sync

- [ ] Updated `.sdr` file is uploaded
- [ ] Server copy reflects the new bookmark/highlight

### 10c. Conflict (both changed)

1. Sync Device A (establishes cache baseline)
2. Add bookmark X on Device A; **do not sync**
3. On the server, add bookmark Y to the same metadata file
4. Sync Device A

- [ ] Both bookmarks X and Y are present after sync (three-way merge)
- [ ] No data lost; no crash

### 10d. Delete propagation

1. Delete a `.sdr` directory locally (or remove the book)
2. Trigger sync

- [ ] Corresponding remote folder is removed (or file removed per sync logic)

---

## 11. FTP Sync – with MDTM support

Prerequisites: FTP server that supports the `MDTM` command (e.g., vsftpd,
FileZilla Server, ProFTPD).

- [ ] Sync runs without errors
- [ ] Remote `.sdr` directories and files are created
- [ ] `supersync_cache.json` is created at
  `~/.config/koreader/settings/supersync_cache.json`
- [ ] Cache contains `local_mtime`, `remote_mtime`, and `synced_at` for each
  synced file

### 11a. FTP upload

- [ ] New local file → uploaded to FTP server
- [ ] Stats show correct `uploaded` count

### 11b. FTP download

1. Put a new file in the remote `.sdr` folder on the server (not in cache)
2. Trigger sync

- [ ] File is downloaded to device
- [ ] Stats show correct `downloaded` count

### 11c. FTP conflict resolution

1. Sync (establish cache)
2. Modify file locally; do not sync
3. Modify the same file on the server
4. Sync

- [ ] Three-way merge runs; merged result uploaded
- [ ] No data lost from either side
- [ ] Stats show `conflicts` count = 1

### 11d. FTP delete propagation – local delete

1. Sync (establish cache)
2. Delete a local file
3. Sync

- [ ] Remote file is deleted (`ACTION_DELETE_REMOTE`)
- [ ] File removed from cache

### 11e. FTP delete propagation – remote delete

1. Sync (establish cache)
2. Delete file from FTP server
3. Sync

- [ ] Local file is deleted (`ACTION_DELETE_LOCAL`)
- [ ] File removed from cache

### 11f. FTP – no changes

1. Sync twice in a row without changing anything

- [ ] Second sync shows all `skipped`, zero uploads/downloads
- [ ] Cache is not corrupted

---

## 12. FTP Sync – MDTM Not Supported (Upload-only Fallback)

Use an FTP server without `MDTM` support (or simulate by blocking the command).

- [ ] Warning message shown: "FTP server does not support MDTM – falling back
  to upload-only"
- [ ] Sync proceeds in upload-only mode
- [ ] All local files are uploaded (no download, no conflict detection)
- [ ] No crash or error dialog

---

## 13. Auto-sync – Sync on Document Close

- [ ] Enable "Sync on document close" in Auto-sync options
- [ ] Open a book, make a highlight, close the book
- [ ] While online: sync runs automatically in background (check log or last
  sync timestamp)
- [ ] While offline: sync is silently skipped (no error dialog)

---

## 14. Auto-sync – Sync on Suspend

- [ ] Enable "Sync on suspend" in Auto-sync options
- [ ] Make a change to a book's metadata, then press the power button (suspend)
- [ ] While online: sync runs before device suspends
- [ ] Last sync timestamp updates after waking
- [ ] While offline: sync is silently skipped

---

## 15. Dispatcher / Gesture Integration

- [ ] "Super Sync: Sync Now" action is available in
  **Gesture Manager** / **Dispatcher**
- [ ] Assigning a gesture and triggering it calls `performSync()` correctly

---

## 16. Error Handling

- [ ] Invalid cloud storage name (manually corrupt settings): shows "Cloud
  storage server not found" error message, does not crash
- [ ] Network drops mid-sync: error shown, last sync time not updated, no
  corrupted files left behind
- [ ] FTP credentials wrong: sync fails gracefully with an error message
- [ ] Sync folder path that doesn't exist on server: folder is created
  automatically; sync succeeds

---

## 17. Cache Integrity (FTP only)

- [ ] `supersync_cache.json` is valid JSON after every sync
- [ ] Manually corrupt the cache file (write garbage); plugin reinitializes
  with an empty cache on next sync without crashing
- [ ] Cache version mismatch (change `version` field manually): cache is reset
  and a log message appears

---

## 18. Edge Cases

- [ ] Device with **no books / no `.sdr` directories**: sync completes
  successfully, shows "No files needed uploading" (or "0 files")
- [ ] Book path containing **spaces or special characters**: files sync
  correctly
- [ ] Very large metadata file (e.g., hundreds of highlights): sync completes
  without timeout or memory error
- [ ] Sync folder path that already exists on server: no duplicate folder
  created, sync runs normally

---

## Notes

Record any failures below with the test number, steps to reproduce, and
observed vs. expected behavior.

| # | Test | Observed | Expected | Fixed? |
|---|------|----------|----------|--------|
|   |      |          |          |        |
