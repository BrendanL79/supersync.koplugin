# How to Run the SuperSync Manual Test Suite (Windows + WSL2)

This document covers everything you need to set up a working test environment
and install the plugin before working through `TESTING_CHECKLIST.md`.

The development machine is **Windows 11**, so the whole environment runs inside
**WSL2** (Windows Subsystem for Linux). KOReader's Linux desktop simulator and
the cloud-storage test servers all run as native Linux software inside a WSL2
distro — there is no need for an e-reader, an Android emulator, or a separate
Linux PC.

> **Why WSL2 and not native Windows?** KOReader's emulator and the SuperSync
> code paths are developed and shipped against Linux. Running the exact same Lua
> under the Linux AppImage avoids platform-specific surprises, and WSL2 gives us
> Docker plus a real Linux filesystem for the `.config/koreader` tree.

---

## 0. One-Time WSL2 + Docker Setup

This machine already has what you need; this section is a checklist to confirm
it (and a reference if you ever rebuild the environment).

### 0a. Confirm WSL2 and a distro

From a Windows PowerShell or terminal:

```powershell
wsl -l -v
```

You should see an Ubuntu distro at **VERSION 2** (this machine has both
`Ubuntu-24.04` and `Ubuntu-22.04`). Use **Ubuntu-24.04** for testing:

```powershell
wsl -d Ubuntu-24.04
```

If you ever need to (re)install from scratch:

```powershell
wsl --install -d Ubuntu-24.04   # installs WSL2 + Ubuntu 24.04
wsl --set-default-version 2      # ensure new distros are WSL2, not WSL1
```

> **GUI works automatically.** Windows 11 ships **WSLg**, so Linux GUI apps
> display on the Windows desktop with no XServer, VcXsrv, or `DISPLAY` setup.
> (Older KOReader guides tell you to install an X server — ignore that on
> Windows 11.) If a GUI window never appears, run `wsl --update` to get the
> latest WSLg, then restart the distro with `wsl --shutdown`.

### 0b. Confirm Docker Desktop + WSL2 integration

This machine has **Docker Desktop** installed (it appears as the
`docker-desktop` WSL distro). The cloud-storage test servers run as Docker
containers, reached from KOReader over `localhost`.

1. Launch **Docker Desktop** on Windows.
2. **Settings → Resources → WSL Integration** → enable integration for
   **Ubuntu-24.04**.
3. Verify from inside the Ubuntu distro:

   ```bash
   docker version          # client + server respond
   docker compose version  # Compose v2 is available
   ```

With WSL2 integration enabled, containers you start from inside Ubuntu publish
their ports on `localhost`, so KOReader (also inside WSL2) can reach them at
`127.0.0.1` — exactly as it would on a native Linux host. No special networking
is required.

---

## 1. KOReader: Run the Linux AppImage Under WSL2

KOReader ships a **Linux desktop simulator** — a native x86_64 AppImage that
runs the exact same Lua plugin code as device builds. Run it inside the Ubuntu
WSL2 distro and it displays through WSLg.

Download the latest AppImage **from inside WSL** (so it lands on the Linux
filesystem) from the KOReader releases page, then make it executable:

```bash
chmod +x koreader-linux-x86_64-*.AppImage
```

### Run without FUSE (recommended on WSL2)

WSL2 does not provide FUSE by default, and an AppImage normally uses FUSE to
mount itself. The most reliable approach is to bypass FUSE entirely with
`--appimage-extract-and-run`:

```bash
./koreader-linux-x86_64-*.AppImage --appimage-extract-and-run
```

This extracts to a temporary `squashfs-root` and launches directly — no FUSE,
no errors. (Equivalently, extract once with `--appimage-extract` and run
`./squashfs-root/AppRun` thereafter.)

> **Alternative:** install FUSE 2 once and run the AppImage normally:
> ```bash
> sudo apt update && sudo apt install -y libfuse2
> ./koreader-linux-x86_64-*.AppImage
> ```
> Use this only if `--appimage-extract-and-run` gives you trouble.

### Two instances for conflict testing

Several checklist items (sections 10c and 11c) require two independent
KOReader installations to simulate two separate devices. You do not need a
second machine — just run two instances with different `HOME` directories so
each has its own config and sync cache:

```bash
# Terminal 1 — "Device A"
HOME=/tmp/koreader-a ./koreader-linux-x86_64-*.AppImage --appimage-extract-and-run

# Terminal 2 — "Device B"
HOME=/tmp/koreader-b ./koreader-linux-x86_64-*.AppImage --appimage-extract-and-run
```

Open a second Ubuntu shell with `wsl -d Ubuntu-24.04` from Windows, or run the
second instance in the background.

### Useful emulator shortcuts

The KOReader emulator maps device keys to your keyboard: **F2** toggles
power/suspend (handy for the *Sync on suspend* tests in section 14), **F6/F7**
turn pages.

---

## 2. Installing the Plugin

KOReader automatically scans `~/.config/koreader/plugins/` (inside whichever
`HOME` you launched with) for user plugins on startup.

The plugin source lives on the **Windows** side at
`C:\Users\brend\src\supersync.koplugin`, which WSL sees at
`/mnt/c/Users/brend/src/supersync.koplugin`.

### Recommended: copy into the WSL filesystem

Copying into the Linux filesystem avoids `/mnt/c` performance and
line-ending pitfalls:

```bash
mkdir -p ~/.config/koreader/plugins/
cp -r /mnt/c/Users/brend/src/supersync.koplugin ~/.config/koreader/plugins/
```

For the two-instance setup, install into both `HOME`s:

```bash
for H in /tmp/koreader-a /tmp/koreader-b; do
  mkdir -p "$H/.config/koreader/plugins/"
  cp -r /mnt/c/Users/brend/src/supersync.koplugin "$H/.config/koreader/plugins/"
done
```

### Development tip: symlink to the live source

If you are actively editing the plugin in Windows (e.g. VS Code), symlink the
WSL config dir straight at the Windows checkout so edits take effect on the next
KOReader launch without re-copying:

```bash
ln -s /mnt/c/Users/brend/src/supersync.koplugin \
      ~/.config/koreader/plugins/supersync.koplugin
```

> **Line endings matter.** KOReader's Lua loads fine with CRLF, but shell
> scripts and server config files (e.g. `vsftpd-no-mdtm.conf` below) must use
> **LF**. The safest habit is to create those files *inside* WSL. If you edit
> them in a Windows editor, set the file to LF (VS Code: click `CRLF` in the
> status bar → `LF`).

### Verify the plugin loaded

After launching, open the main menu and look for **Super Sync** under the
**Tools** section. If it is missing, check for Lua errors:

```bash
cat ~/.config/koreader/crash.log   # or $HOME/.config/koreader/crash.log
```

(If you launched from a shell, stdout also shows Lua errors directly.) A missing
`_meta.lua` or any Lua syntax error makes KOReader silently skip the plugin
without crashing.

---

## 3. Cloud Storage Infrastructure

You need four server-side endpoints:

| What | Why | Notes |
|---|---|---|
| Dropbox free account | Dropbox tests (sections 4b, 9, 10) | Must use the real API; no self-hosted alternative |
| WebDAV server | WebDAV tests (sections 4c, 9, 10) | Self-host with Docker (see below) |
| FTP server with MDTM | FTP bidirectional sync (section 11) | Self-host with Docker |
| FTP server without MDTM | Upload-only fallback test (section 12) | Second Docker container, MDTM disabled |

All three self-hosted services run as Docker containers via Docker Desktop's
WSL2 integration. Because KOReader runs inside the same WSL2 environment, it
reaches every container at `127.0.0.1` — including FTP passive mode, since the
client and server share the same `localhost` view. (The well-known FTP passive
mode breakage only happens with a *Windows-native* FTP client talking to the
container, which is not our setup.)

### Docker Compose setup

Create a `docker-compose.yml` file **inside WSL** (e.g. in `~/supersync-test/`):

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

Create `vsftpd-no-mdtm.conf` (also inside WSL, **LF endings**) to disable MDTM
on the second FTP container:

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

Start everything (from the directory containing `docker-compose.yml`):

```bash
docker compose up -d
docker compose ps    # confirm all three are running
```

> **PASV_ADDRESS note:** `127.0.0.1` is correct here because KOReader connects
> from inside WSL2. If you ever test from a Windows-native FTP client instead,
> change `PASV_ADDRESS` to the WSL2 VM's IP (`ip addr show eth0` inside WSL) and
> open the passive port range in Windows Firewall.

### Configure the servers in KOReader

In each KOReader instance, go to **Tools → Cloud Storage → Add server**:

| Server | Type | Address | User | Password |
|---|---|---|---|---|
| My WebDAV | WebDAV | `http://127.0.0.1:8080` | `test` | `test` |
| My FTP (MDTM) | FTP | `127.0.0.1` | `test` | `test` |
| My FTP (no MDTM) | FTP | `127.0.0.1:2121` | `test` | `test` |
| My Dropbox | Dropbox | *(OAuth flow)* | — | — |

> **Dropbox OAuth from WSL:** the OAuth flow opens a URL. WSLg/Windows will hand
> the link to your Windows browser; complete the login there and the token is
> returned to KOReader. If the link does not auto-open, copy it from the
> KOReader dialog into a Windows browser manually.

---

## 4. Summary: Minimum Requirements

- Windows 11 with **WSL2** and an **Ubuntu-24.04** distro (already installed)
- **Docker Desktop** with WSL2 integration enabled for that distro (already
  installed)
- One free Dropbox account
- No real e-reader hardware required
- No Android emulators required
- No second physical machine or VM required (two `HOME` dirs simulate two
  devices)

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
</content>
</invoke>
