# How to Run the SuperSync Manual Test Suite

This document covers everything you need to set up a working test environment
and install the plugin before working through `TESTING_CHECKLIST.md`.

---

## 1. KOReader: Use the Linux AppImage, Not Android VMs

Android emulators are the hardest path. KOReader ships a **Linux desktop
simulator** — a native x86_64 AppImage that runs the exact same Lua plugin
code as device builds. It is much faster to work with.

Download the latest AppImage from the KOReader releases page, then:

```bash
chmod +x koreader-linux-x86_64-*.AppImage
./koreader-linux-x86_64-*.AppImage
```

### Two instances for conflict testing

Several checklist items (sections 10c and 11c) require two independent
KOReader installations to simulate two separate devices. You do not need a
second machine or VM — just run two AppImage instances with different `HOME`
directories so each has its own config and sync cache:

```bash
# Terminal 1 — "Device A"
HOME=/tmp/koreader-a ./koreader-linux-x86_64-*.AppImage

# Terminal 2 — "Device B"
HOME=/tmp/koreader-b ./koreader-linux-x86_64-*.AppImage
```

---

## 2. Installing the Plugin

KOReader automatically scans `~/.config/koreader/plugins/` for user plugins on
startup. Copy the plugin folder there:

```bash
mkdir -p ~/.config/koreader/plugins/
cp -r supersync.koplugin ~/.config/koreader/plugins/
```

For the two-instance setup, install into both:

```bash
mkdir -p /tmp/koreader-a/.config/koreader/plugins/
mkdir -p /tmp/koreader-b/.config/koreader/plugins/
cp -r supersync.koplugin /tmp/koreader-a/.config/koreader/plugins/
cp -r supersync.koplugin /tmp/koreader-b/.config/koreader/plugins/
```

### Development tip: use a symlink

If you are actively editing the plugin source, symlink instead of copying so
that changes take effect on the next KOReader launch without re-copying:

```bash
ln -s /path/to/supersync.koplugin ~/.config/koreader/plugins/supersync.koplugin
```

### Verify the plugin loaded

After launching, open the main menu and look for **Super Sync** under the
**Tools** section. If it is missing, check for Lua errors:

```bash
# AppImage log (if the window is still open, stdout shows Lua errors directly)
~/.config/koreader/crash.log
```

A missing `_meta.lua` or any Lua syntax error will cause KOReader to silently
skip the plugin without crashing.

---

## 3. Cloud Storage Infrastructure

You need three things:

| What | Why | Notes |
|---|---|---|
| Dropbox free account | Dropbox tests (sections 4b, 9, 10) | Must use the real API; no self-hosted alternative |
| WebDAV server | WebDAV tests (sections 4c, 9, 10) | Self-host with Docker (see below) |
| FTP server with MDTM | FTP bidirectional sync (section 11) | Self-host with Docker |
| FTP server without MDTM | Upload-only fallback test (section 12) | Second Docker container, MDTM disabled |

All three server-side services can run as Docker containers on the same machine
as KOReader.

### Docker Compose setup

Create a `docker-compose.yml` file:

```yaml
services:

  webdav:
    image: bytemark/webdav
    ports: ["8080:80"]
    environment:
      AUTH_TYPE: Basic
      USERNAME: test
      PASSWORD: test

  ftp-mdtm:
    image: fauria/vsftpd
    ports: ["21:21", "21100-21110:21100-21110"]
    environment:
      FTP_USER: test
      FTP_PASS: test
      PASV_ADDRESS: 127.0.0.1
      PASV_MIN_PORT: 21100
      PASV_MAX_PORT: 21110
      # vsftpd supports MDTM by default

  ftp-no-mdtm:
    image: fauria/vsftpd
    ports: ["2121:21", "21200-21210:21200-21210"]
    environment:
      FTP_USER: test
      FTP_PASS: test
      PASV_ADDRESS: 127.0.0.1
      PASV_MIN_PORT: 21200
      PASV_MAX_PORT: 21210
    volumes:
      - ./vsftpd-no-mdtm.conf:/etc/vsftpd/vsftpd.conf:ro
```

Create `vsftpd-no-mdtm.conf` to disable MDTM on the second FTP container:

```ini
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
xferlog_enable=YES
connect_from_port_20=YES
xferlog_std_format=YES
listen=YES
pam_service_name=vsftpd
userlist_enable=YES
tcp_wrappers=YES
mdtm_enable=NO
```

Start everything:

```bash
docker compose up -d
```

### Configure the servers in KOReader

In each KOReader instance, go to **Tools → Cloud Storage → Add server**:

| Server | Type | Address | User | Password |
|---|---|---|---|---|
| My WebDAV | WebDAV | `http://127.0.0.1:8080` | `test` | `test` |
| My FTP (MDTM) | FTP | `127.0.0.1` | `test` | `test` |
| My FTP (no MDTM) | FTP | `127.0.0.1:2121` | `test` | `test` |
| My Dropbox | Dropbox | *(OAuth flow)* | — | — |

---

## 4. Summary: Minimum Requirements

- One Linux machine (physical or VM) capable of running AppImages and Docker
- Docker and Docker Compose installed
- One free Dropbox account
- No real e-reader hardware required
- No Android emulators required
- No second physical machine required

---

## 5. Suggested Test Order

Run the checklist sections roughly in this order to catch foundational problems
early before spending time on the more complex scenarios:

1. **Section 1–3** — plugin loads and menu structure is correct
2. **Section 4–6** — configuration and enable/disable work
3. **Section 7–8** — status screen and sync pre-condition guards
4. **Section 9** — first successful sync (Dropbox or WebDAV)
5. **Section 11** — FTP with MDTM (most complex code path)
6. **Section 12** — FTP without MDTM fallback
7. **Section 10** — bidirectional conflict merge (requires two instances)
8. **Section 13–14** — auto-sync triggers
9. **Sections 15–18** — Dispatcher, error handling, edge cases
