# Cora for macOS

A native menu bar app for a [Cora](https://usecora.space) space: every agent you can see, what each one is doing right now with its reasoning as it arrives, the subscriptions they run on with their quotas, and how many tokens each agent used.

In the spirit of [Quota](https://github.com/turinglabsorg/quota), but it reads one Cora space instead of local CLI logins.

## What it shows

- **Menu bar**: how many agents are working and the tightest quota left across the accounts your agents run on (orange under 20%, red under 5%).
- **Popover**: each agent with its state (working, listening, idle, off), its tokens today and the step it is on now; then each account (Claude, Codex, Grok, Muse Code, Gemini, Kimi…) with its 5-hour, weekly and model windows, reset countdowns and which agents use it.
- **Live window**: pick an agent to follow its running turns step by step (thoughts, tool calls with results, text it writes), its recent threads with their last reasoning, and its usage today, over 7 and 30 days.

Everything is read-only. The app sees exactly what your account sees in the panel: other people's private agents stay out.

## Connect a space

From the panel (for example `notseb.usecora.space`): **Settings → macOS app → Open in the app**. The browser opens `cora://connect…`, the app trades that one-time code for its own device token and starts reading.

From the app: type the space address and press **Connect**. The panel opens in your browser, signed in through usecora.space; press **Authorize this Mac** and the app comes back connected.

The code lasts two minutes and works once. The device token is kept in the Keychain (`space.usecora.app`), lasts 180 days and is revoked from **Settings → macOS app → Connected Macs** or with **Disconnect this Mac**.

## Install

Download `Cora.zip` from the latest [release](https://github.com/digitaloracles/cora-app/releases/latest), unzip it into Applications, then right-click Cora.app and choose Open the first time (the build is ad-hoc signed).

Or build it (macOS 14 or later, Xcode 16 or the Swift 6 toolchain):

```bash
git clone https://github.com/digitaloracles/cora-app.git
cd cora-app
scripts/build-app.sh --install
open ~/Applications/Cora.app
```

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
