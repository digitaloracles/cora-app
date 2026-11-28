# Cora for macOS

A native menu bar app for a [Cora](https://usecora.space) space: every agent you can see, what each one is doing right now with its reasoning as it arrives, the subscriptions they run on with their quotas, and how many tokens each agent used.

In the spirit of [Quota](https://github.com/turinglabsorg/quota), but it reads one Cora space instead of local CLI logins.

It can also run a space on the Mac itself: the app carries the Cora server and a Linux VM where every agent gets its own computer. See [A space on this Mac](#a-space-on-this-mac).

## What it shows

- **Menu bar**: how many agents are working and the tightest quota left across the accounts your agents run on (orange under 20%, red under 5%).
- **Popover**: each agent with its state (working, listening, idle, off), its tokens today and the step it is on now; then each account (Claude, Codex, Grok, Muse Code, Gemini, Kimi…) with its 5-hour, weekly and model windows, reset countdowns and which agents use it.
- **Live window**: pick an agent to follow its running turns step by step (thoughts, tool calls with results, text it writes), its recent threads with their last reasoning, and its usage today, over 7 and 30 days.

Everything is read-only. The app sees exactly what your account sees in the panel: other people's private agents stay out.

## The Cora window

The window opens on first launch, or when you open Cora again from Finder or Launchpad. It shows the panel of one space; the menu at its top left switches between **This Mac** and the remote spaces, and adds them: **Create a space on this Mac…** and **Connect a remote space…**. Spaces are added only here, never from the menu bar: with no space yet the popover says **No space yet** and offers **Open Cora**. A space on this Mac and remote spaces live side by side in the same app.

## A space on this Mac

**Create a space on this Mac…** (or **On this Mac** on the first launch) runs a short wizard. It only installs and prepares; it asks for nothing, and it sets up no model, key or agent. Each step shows what it is doing:

1. **The space's folder**: `~/Library/Application Support/Cora/Local`, with the panel password and the session key it generates (`env`, mode 600).
2. **The agents' engine**: DeepSeek Harness (`@deepseek-ai/dsh`) from npm, with the app's own Node.
3. **The agents' Linux machine**: one Colima VM (profile `cora`, Apple Virtualization, Docker runtime) sized at half the Mac's cores (2 to 4), a quarter of its memory (4 to 8 GB) and a 60 GB disk. Colima, Lima and Docker keep their state in `~/.cora-local`, never in the user's `~/.colima` or `~/.docker`. A LaunchAgent (`space.usecora.vm`) boots it again at login.
4. **The agents' computer**: the `cora-box` image (Debian with desktop, browser and shell; one container per agent). The app downloads the image CI built for its version of `box/` and this Mac's architecture (about 700 MB) and loads it with `docker load`; it builds it inside the VM only when the download fails. An image whose `cora.box` label already matches is kept.
5. **Cora on this Mac**: the bundled server on `127.0.0.1:4370`, run by the LaunchAgent `space.usecora.local` at every login and restarted if it stops. Its `PATH` is the app's Node and the VM tools first, then the person's login shell `PATH`, so Claude Code, Codex and the other CLIs already installed are found. Log: `Local/cora.log`.
6. **Sign in to the panel** and **connect the menu bar**: the window opens the panel signed in, on **New agent**.

Agents are created from the panel as on any space, and each agent's model and key go in its **Brain** tab. The space keeps running with the app closed; the app brings the VM and the server back if they are down when it starts. On a clean Mac the wizard takes about 11 to 13 minutes, most of it the VM and the image.

## Connect a space

From the panel (for example `notseb.usecora.space`): **Settings → macOS app → Open in the app**. The browser opens `cora://connect…`, the app trades that one-time code for its own device token and starts reading.

From the app: in the Cora window choose **Connect a remote space…**, type the space address and press **Connect**. The panel opens in your browser, signed in through usecora.space; press **Authorize this Mac** and the app comes back connected.

The code lasts two minutes and works once. The device token is kept in the Keychain (`space.usecora.app`), lasts 180 days and is revoked from **Settings → macOS app → Connected Macs** or with **Disconnect this Mac**.

## Install

Download `Cora.dmg` from the latest [release](https://github.com/digitaloracles/cora-app/releases/latest), open it and drag Cora into Applications. The app is universal (Apple silicon and Intel), signed with Developer ID and notarized by Apple. To update, install the new version over the old one, choose **Quit Cora** from the popover's **⋯** menu and open it again: a space on this Mac keeps its data and its server restarts with the new app.

Or build it (macOS 14 or later, Xcode 16 or the Swift 6 toolchain):

```bash
git clone https://github.com/digitaloracles/cora-app.git
cd cora-app
scripts/build-app.sh --install                                   # menu bar and window only
CORA_SERVER_SRC=<digitaloracles/cora checkout> scripts/build-app.sh --install   # also a space on this Mac
open ~/Applications/Cora.app
```

With `CORA_SERVER_SRC` the bundle also carries universal Node, npm, the Cora server with its production dependencies (native modules for both architectures) and its `box/`, and Colima, Lima and the Docker client at pinned versions checked against their published SHA-256.

## Command line

```bash
Cora.app/Contents/MacOS/Cora --connect 'cora://connect?server=…&code=…'   # pair without the UI
Cora.app/Contents/MacOS/Cora --print                                       # agents, usage and quotas
Cora.app/Contents/MacOS/Cora --watch 30                                    # live reasoning for 30 s
Cora.app/Contents/MacOS/Cora --render-preview <dir>                        # screenshots with sample data
Cora.app/Contents/MacOS/Cora --render-live <dir>                           # screenshots with the space's data
Cora.app/Contents/MacOS/Cora --disconnect
```

`CORA_APP_HOME=<dir>` keeps the connection (and a separate Keychain service) elsewhere, for tests.

## The Cora API it uses

Served by Cora itself (`src/app-access.js`, `src/web.js`):

| Call | Auth | What |
| --- | --- | --- |
| `POST /api/app/pairings` `{state?}` | panel session | one-time `cora://connect` link, 2 minutes |
| `POST /app/v1/session` `{code, name, platform}` | the code | device token `cora_app_…` |
| `GET /app/v1/snapshot` | Bearer | space, user, accounts with quotas and the agents using them, agents with usage, live turns and threads |
| `GET /app/v1/events` | Bearer | server-sent events: `trace` start/step/end, `subscription-usage`, `agents`, `access-revoked` |
| `GET /app/v1/traces/:id`, `/app/v1/threads/:id`, `/app/v1/agents/:id/traces` | Bearer | one turn with its steps, one thread, an agent's recent turns |
| `DELETE /app/v1/session` | Bearer | signs this Mac out |
| `GET /api/app/devices`, `DELETE /api/app/devices/:id` | panel session | the person's connected Macs |

Device tokens and codes are stored as SHA-256 hashes; anything but `GET` with a device token answers 405.
