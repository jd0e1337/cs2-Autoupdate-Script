# 🎮 cs2-Autoupdate-Script

An interactive installation and auto-update script for a **Counter-Strike 2 Dedicated Server** on Debian/Ubuntu.

The installer sets up the CS2 server, SteamCMD, systemd services, automatic update checks, and a **5-minute RCON restart warning** when Valve releases a new CS2 server build.

## ✨ Features

- 🎮 Installs a Counter-Strike 2 Dedicated Server
- 📦 Installs and configures SteamCMD automatically
- ⚙️ Interactive setup
- 👤 Runs CS2 under a dedicated, unprivileged Linux user
- 🔄 Automatic CS2 update checks via `systemd`
- 🧠 Compares the local build ID with the current Steam `public` build
- 💬 Sends RCON restart warnings before an update
- ⏳ 5-minute restart countdown
- 🔒 Stores GSLT and RCON credentials with restricted file permissions
- 🛡️ Prevents multiple update jobs from running at the same time
- 🚀 Automatically restarts the CS2 server after an update
- 📋 Logs server and updater output through `journalctl`
- 💾 Creates a backup of an existing `server.cfg`
- 🧰 Includes its own lightweight Source RCON helper written in Python
- ✅ Uses `validate` for the initial installation only
- 🧩 Existing/modded installations are updated without forcing `validate`

## 🔁 Update Process

When a new CS2 build is detected, the updater performs the following sequence:

```text
New CS2 build detected
        │
        ├─ RCON: CS2 Released an Update - Restart in 5 minutes
        │
        ├─ Wait 4 minutes
        │
        ├─ RCON: Server restart for CS2 update in 1 minute
        │
        ├─ Wait 30 seconds
        │
        ├─ RCON: Server restart in 30 seconds
        │
        ├─ Wait 20 seconds
        │
        ├─ RCON: Server restart in 10 seconds
        │
        ├─ Wait 10 seconds
        │
        ├─ Stop CS2
        │
        ├─ Install the Steam update
        │
        └─ Start CS2 again
```

If no update is available, **the game server is not restarted**.

If the CS2 server is already offline when an update is detected, the countdown is skipped and the update is installed immediately.

## 📋 Requirements

- Debian or Ubuntu, or another Debian-based Linux distribution
- x86_64 / amd64 CPU architecture
- `systemd`
- Root access or `sudo`
- Internet connection
- Enough disk space for the CS2 Dedicated Server
- UDP game port accessible from the Internet if the server should be public

The installer automatically installs the required Linux packages.

## 🚀 Installation

Clone or download this repository and enter its directory.

Make the installer executable:

```bash
chmod +x cs2-install.sh
```

Run it as root:

```bash
sudo ./cs2-install.sh
```

The installer will guide you through the configuration.

## 🛠️ Interactive Configuration

During installation you will be asked for values such as:

- Linux user for the CS2 server
- CS2 installation directory
- Server name
- Game/RCON port
- Maximum player slots
- Game mode
- Start map
- GSLT
- RCON password
- Optional server password
- Auto-update check interval
- 5-minute RCON update message
- Whether the server should start immediately

### Default Configuration

The defaults are suitable for a small Deathmatch server:

```text
Slots:          16
Port:           27015
Game mode:      Deathmatch
game_type:      1
game_mode:      2
Start map:      de_dust2
Update checks:  Every 5 minutes
```

You can change these values during installation.

## 🔑 GSLT

For an Internet-accessible CS2 server, configure a **Game Server Login Token (GSLT)** for Steam App ID `730`.

The installer asks for the token during setup.

If you leave it empty, you can add it later to:

```text
/home/<server-user>/.config/cs2/gslt.token
```

Then restart the server:

```bash
sudo systemctl restart cs2
```

## 🔐 RCON

RCON is enabled using the same port configured for the CS2 server.

The generated startup command includes:

```text
-usercon
```

The RCON password is stored in:

```text
/home/<server-user>/.config/cs2/rcon.password
```

It is also written to:

```text
<cs2-install-dir>/game/csgo/cfg/server.cfg
```

The credential files are created with restricted permissions.

If no RCON password is entered during installation, the installer automatically generates a random one.

> ⚠️ Do not expose RCON unnecessarily to the Internet. Restrict TCP access to trusted IP addresses with your firewall whenever possible.

## 🌐 Firewall / NAT

For the default configuration, allow or forward:

```text
27015/UDP  CS2 game traffic
27015/TCP  RCON
```

The installer itself does **not** modify your firewall.

If you select another port during installation, use that port instead.

## ⚙️ Server Management

Start the server:

```bash
sudo systemctl start cs2
```

Stop the server:

```bash
sudo systemctl stop cs2
```

Restart the server:

```bash
sudo systemctl restart cs2
```

Check its status:

```bash
sudo systemctl status cs2
```

Follow the server log:

```bash
sudo journalctl -fu cs2
```

## 🔄 Auto-Updater

Check the updater timer:

```bash
sudo systemctl status cs2-autoupdate.timer
```

List the next scheduled runs:

```bash
systemctl list-timers cs2-autoupdate.timer
```

Trigger an update check manually:

```bash
sudo systemctl start cs2-autoupdate.service
```

View updater logs:

```bash
sudo journalctl -u cs2-autoupdate.service
```

Follow updater logs live:

```bash
sudo journalctl -fu cs2-autoupdate.service
```

## 🧠 How Update Detection Works

The updater reads the locally installed CS2 build ID from:

```text
steamapps/appmanifest_730.acf
```

It then asks SteamCMD for the current build ID of the Steam `public` branch.

If both build IDs are identical:

```text
Local build == Steam build
```

nothing happens.

If they differ:

```text
Local build != Steam build
```

the RCON countdown starts and the server is updated.

Immediately before stopping the server, the updater checks the remote build again in case another CS2 build was published during the countdown.

## 📁 Important Files

Default paths when using the `steam` user:

```text
/home/steam/cs2/
├── game/
│   └── csgo/
│       └── cfg/
│           └── server.cfg
└── steamapps/
    └── appmanifest_730.acf

/home/steam/steamcmd/

/home/steam/.config/cs2/
├── gslt.token
└── rcon.password

/etc/cs2/
├── runtime.conf
└── update-message.txt

/usr/local/bin/cs2-start
/usr/local/libexec/cs2-rcon
/usr/local/sbin/cs2-autoupdate

/etc/systemd/system/
├── cs2.service
├── cs2-autoupdate.service
└── cs2-autoupdate.timer
```

Paths can differ if you select a different server user or installation directory.

## 📝 Server Configuration

The main CS2 configuration is located at:

```text
<cs2-install-dir>/game/csgo/cfg/server.cfg
```

If a `server.cfg` already exists when the installer is executed, it is backed up using a timestamped filename such as:

```text
server.cfg.bak.20260831-120000
```

## 🧩 Plugins

This installer focuses on the **CS2 Dedicated Server and automatic updates**.

It does not automatically install third-party server plugins such as:

- Metamod:Source
- CounterStrikeSharp
- Admin plugins
- Deathmatch plugins
- MultiCFG plugins

These can be installed separately after the base server is working.

Normal automatic CS2 updates are intentionally performed **without `validate`**, which avoids unnecessarily validating the entire installation on every Valve update.

## 🐛 Troubleshooting

### Server does not start

Check the service:

```bash
sudo systemctl status cs2
```

Then inspect the latest logs:

```bash
sudo journalctl -u cs2 -n 100 --no-pager
```

### Update check fails

Run the updater manually:

```bash
sudo systemctl start cs2-autoupdate.service
```

Then inspect its log:

```bash
sudo journalctl -u cs2-autoupdate.service -n 100 --no-pager
```

### RCON warning is not displayed

Check that:

- the CS2 server is running
- `rcon_password` is configured
- the startup command contains `-usercon`
- the configured RCON/game port is correct
- localhost TCP connections to the port are not being blocked

A failed RCON warning does **not** prevent the update from being installed.

## ⚠️ Notes

- Always keep backups of important server configuration and plugin data.
- Valve updates can occasionally require plugin updates as well.
- Metamod, CounterStrikeSharp, or other third-party plugins may temporarily break after a major CS2 update.
- The update timer checks for new builds; it does not blindly restart the server on every timer run.
- Steam App ID `730` is used for the CS2 Dedicated Server installation.

## 📜 License

No license is included by default.

If you plan to publish this project publicly, consider adding a license such as the MIT License.
