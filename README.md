# CS2 Dedicated Server Installer

A simple Bash installer for running a Counter-Strike 2 dedicated server on Debian/Ubuntu.

## Features

* Installs SteamCMD and CS2 Dedicated Server
* Creates a dedicated Linux user
* Configures systemd service and automatic restarts
* Automatic CS2 update checks with RCON countdown warnings
* Configurable bind IP, port, slots, map and game mode
* GSLT and RCON support
* Workshop collection/map support
* Includes a helper to switch between normal maps and Workshop mode
* Applies the required Linux V8 library fixes automatically

## Installation

```bash
chmod +x cs2-install-en-v3.sh
sudo ./cs2-install-en-v3.sh
```

Follow the prompts. For the bind address, `0.0.0.0` is usually the correct choice if the server should listen on all network interfaces.

## Server Commands

```bash
sudo systemctl start cs2
sudo systemctl stop cs2
sudo systemctl restart cs2
sudo systemctl status cs2
journalctl -fu cs2
```

## Workshop Maps

Enable a Workshop collection and start map:

```bash
sudo cs2-workshop enable <collection_id> <map_id>
```

Example:

```bash
sudo cs2-workshop enable 3791159560 3722688576
```

Check the current mode:

```bash
sudo cs2-workshop status
```

Return to the normal configured map:

```bash
sudo cs2-workshop disable
```

You can also run the interactive menu:

```bash
sudo cs2-workshop
```

## Auto Updates

The installer enables a systemd timer that checks Steam for CS2 updates. If an update is found, connected players receive RCON warnings before the server is restarted and updated.

```bash
systemctl status cs2-autoupdate.timer
journalctl -u cs2-autoupdate.service
```

## Important Files

```text
/etc/cs2/runtime.conf
/etc/cs2/workshop.conf
/usr/local/bin/cs2-start
/usr/local/bin/cs2-workshop
/usr/local/sbin/cs2-autoupdate
```

For a public server, configure a valid Steam Game Server Login Token (GSLT) for App ID `730`.
