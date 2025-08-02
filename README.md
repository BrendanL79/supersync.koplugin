# Super Sync Plugin for KOReader

A comprehensive metadata synchronization plugin that backs up your complete reading data to cloud storage.

## Overview

Unlike the built-in KOReader sync that only syncs reading position, Super Sync backs up your entire `.sdr` metadata folders containing annotations, bookmarks, reading progress, document settings, and more to your existing cloud storage.

## What it Syncs

Super Sync automatically discovers and syncs all `.sdr` directories containing:
- **Annotations and highlights** with notes
- **Bookmarks** and reading progress
- **Document-specific settings** (fonts, margins, etc.)
- **Reading statistics** and time tracking
- **Custom metadata** and tags
- **Plugin data** stored per document

## Features

### 🔧 Easy Setup
- **No additional accounts**: Uses your existing cloud storage (Dropbox, WebDAV, FTP)
- **Integrated configuration**: Settings UI works with KOReader's cloud storage setup
- **Flexible folder structure**: Choose any folder path in your cloud storage

### 📱 Smart Integration
- **Main menu access**: Appears under "Super Sync" in the main menu
- **Real-time progress**: Shows detailed sync progress with file-by-file updates
- **Status monitoring**: Check last sync time and configuration status
- **Error handling**: Comprehensive logging and user-friendly error messages

### ⚡ Efficient Operation
- **Automatic discovery**: Finds `.sdr` directories in all storage locations:
  - Document-adjacent (`.../book.pdf` → `.../book.sdr/`)
  - Centralized directory (`docsettings/`)
  - Hash-based storage (`hashdocsettings/`)
- **Progress tracking**: Real-time updates during sync operations
- **Async operations**: Non-blocking UI with coroutine-based sync

### 🛡️ Robust Architecture
- **Modular design**: Separate sync engine for maintainability
- **Cloud provider abstraction**: Works with multiple storage types
- **Comprehensive error handling**: Graceful failure recovery
- **Extensive logging**: Detailed logs for troubleshooting

## Installation

1. Copy the `supersync.koplugin/` folder to your KOReader `plugins/` directory
2. Restart KOReader
3. The plugin will appear in the main menu under "Super Sync"

## Setup

### 1. Configure Cloud Storage (if not already done)
- Go to **Tools** → **Cloud Storage**
- Add your preferred provider (Dropbox, WebDAV, or FTP)
- Test the connection to ensure it works

### 2. Configure Super Sync
- Go to **Super Sync** → **Settings**
- **Enable Super Sync**: Check this box
- **Cloud Storage**: Select your configured cloud provider
- **Sync Folder Path**: Specify where to store sync data (e.g., `/KOReader-SuperSync`)
- **Auto-sync options**: Choose when to automatically sync
  - Auto-sync on document close
  - Periodic sync interval (hours)

### 3. Perform Initial Sync
- Go to **Super Sync** → **Manual Sync**
- Watch the progress as your metadata is uploaded
- Check **Status** to verify completion

## Usage

### Manual Sync
- **Super Sync** → **Manual Sync**
- Progress dialog shows real-time sync status
- Completion notification when finished

### Automatic Sync
Configure automatic syncing in Settings:
- **On document close**: Syncs when you close a book
- **Periodic interval**: Syncs every N hours (0 = disabled)

### Status Check
- **Super Sync** → **Status**
- Shows configuration status, last sync time, and settings summary

## File Structure

```
plugins/supersync.koplugin/
├── _meta.lua          # Plugin metadata and description
├── main.lua           # Main plugin UI and logic
├── syncengine.lua     # Core synchronization functionality
└── README.md          # This documentation
```

## Architecture

### Main Plugin (`main.lua`)
- **UI Integration**: Menu items, settings dialogs, progress widgets
- **Settings Management**: Configuration storage and validation
- **Event Handling**: Document close events, auto-sync triggers
- **Cloud Storage Interface**: Integration with existing cloud storage settings

### Sync Engine (`syncengine.lua`)
- **Directory Discovery**: Scans for `.sdr` directories across storage locations
- **Cloud Operations**: Upload/download files using cloud storage APIs
- **Progress Tracking**: Callback system for real-time progress updates
- **Error Handling**: Robust error recovery and logging

### Data Flow
1. **Discovery**: Scan local storage for `.sdr` directories
2. **Preparation**: Create remote directory structure
3. **Upload**: Transfer each file with progress updates
4. **Verification**: Log results and update sync status

## Cloud Storage Support

### Supported Providers
- **Dropbox**: Full API integration with OAuth
- **WebDAV**: Standard WebDAV protocol support  
- **FTP**: Traditional FTP file transfer

### API Integration
The plugin uses KOReader's existing cloud storage abstraction:
- `DropBoxApi`: Dropbox API v2 integration
- `WebDavApi`: WebDAV PROPFIND/PUT/GET operations
- `FtpApi`: FTP file operations

## Storage Locations

Super Sync handles all KOReader metadata storage patterns:

### Document-Adjacent ("doc")
```
/books/mybook.pdf
/books/mybook.sdr/
  ├── metadata.pdf.lua
  ├── custom_metadata.lua
  └── ...
```

### Centralized Directory ("dir")
```
~/.config/koreader/docsettings/
  ├── book1.sdr/
  ├── book2.sdr/
  └── ...
```

### Hash-Based ("hash")
```
~/.config/koreader/hashdocsettings/
  ├── ab/
  │   └── ab1234567890abcdef.sdr/
  ├── cd/
  │   └── cd9876543210fedcba.sdr/
  └── ...
```

## Configuration Files

### Plugin Settings
Stored in KOReader's global settings as `supersync`:
```lua
{
    enabled = true,
    cloud_storage = "my_dropbox",
    sync_folder = "/KOReader-SuperSync",
    sync_on_close = true,
    auto_sync_hours = 24
}
```

### Last Sync Tracking
Stored as `supersync_last_sync` timestamp for status display.

## Error Handling

### Network Issues
- Automatic retry on connection failures
- Graceful degradation when offline
- User notification of network requirements

### Storage Issues  
- Validates cloud storage configuration
- Creates remote directories as needed
- Handles permission and quota errors

### File Issues
- Logs individual file failures without stopping sync
- Validates local file accessibility
- Handles concurrent access conflicts

## Logging

All operations are logged with appropriate levels:
- **Info**: Normal sync operations and results
- **Warn**: Recoverable errors (individual file failures)
- **Error**: Critical failures (configuration, network, etc.)

View logs in KOReader's standard log output.

## Future Enhancements

### Planned Features
- **Bidirectional sync**: Download and merge remote changes
- **Conflict resolution**: Handle same document modified on multiple devices
- **Selective sync**: Choose specific documents or metadata types
- **Sync history**: Track detailed sync operations over time
- **Compression**: ZIP `.sdr` folders for efficient transfer
- **Delta sync**: Only upload changed files
- **Multiple devices**: Device identification and merge strategies

### API Extensions
- Support for additional cloud providers (Google Drive, OneDrive)
- Custom sync targets (SSH/SFTP, custom APIs)
- Local network sync (shared folders, NAS)

## Troubleshooting

### Common Issues

**"Super Sync is not properly configured"**
- Ensure cloud storage is configured and working
- Verify sync folder path is specified
- Check that Super Sync is enabled in settings

**Sync fails with network errors**
- Verify internet connection
- Test cloud storage connection independently
- Check cloud storage credentials and permissions

**Files not syncing**
- Check that documents have `.sdr` directories
- Verify KOReader metadata storage settings
- Look for permission issues in logs

**Progress dialog freezes**
- Check logs for specific error messages
- Verify sufficient cloud storage space
- Restart KOReader if needed

### Debug Information

Enable debug logging to get detailed sync information:
1. Check KOReader logs during sync operations
2. Look for "SuperSync:" prefixed messages
3. Note any error codes from cloud storage APIs

### Getting Help

1. **Check logs**: Look for error messages in KOReader logs
2. **Test cloud storage**: Verify cloud storage works independently
3. **Check configuration**: Ensure all settings are properly configured
4. **Report issues**: Include logs and configuration details when reporting problems

## License

This plugin follows KOReader's licensing terms and is distributed under the same AGPL v3 license.

## Contributing

Contributions welcome! Please follow KOReader's contribution guidelines:
- Use consistent code style with existing KOReader code
- Add appropriate logging and error handling
- Test with multiple cloud storage providers
- Update documentation for new features