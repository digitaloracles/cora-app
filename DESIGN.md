# Cora for macOS: design system

A native utility: it lives in the menu bar, reads at a glance, and opens into a calm live view. It follows Quota's conventions so the two apps feel related, with Cora's agents as the subject: their colors and faces carry the identity, the chrome stays system.

## Principles

- **Agents first.** People recognize agents by face and color, so the avatar (picture from the space, or initial on the agent's color) leads every row. Working agents get a 2 pt ring in their own color; switched-off agents are dimmed to 45%.
- **What is happening now.** The popover row shows the step an agent is on (its last thought in italics) instead of static metadata; static metadata (model, 7-day tokens) appears only when nothing runs.
- **Color means state.** Quota levels use green, orange (≤ 20% left) and red (≤ 5% left). Step kinds have one tint each. Agent colors come from the space and are used only for avatars, rings and live-turn outlines.
- **Native materials.** System font, semantic colors, popover and window materials: light, dark and accessibility settings work for free.

## Color

| Token | Value | Use |
| --- | --- | --- |
| `level.normal` | `Color.green` | quota bar, more than 20% left |
| `level.warning` | `Color.orange` | 6–20% left; menu bar text too |
| `level.critical` | `Color.red` | 5% or less left; menu bar text too |
| `state.working` | `Color.green` | state dot |
| `state.listening` | `Color.blue` | state dot |
| `state.idle` / `state.off` | secondary at 60% / 30% | state dot |
| `step.thinking` | `Color.purple` | brain glyph; text italic secondary |
| `step.tool` | `Color.blue` | wrench glyph; name monospaced semibold |
| `step.text` | `Color.green` | speech glyph; primary text |
| `step.note` | secondary | info glyph |
| `surface.card` | primary at 5% | account cards, usage strip |
| `surface.row` | primary at 3.5% (7% when working) | agent rows |
| `surface.track` | primary at 9% | empty part of bars |
| `surface.badge` | primary at 7% | plan and state badges |

## Typography

SF Pro only; digits `monospacedDigit()`. Monospaced design only for tool names, arguments and results.

| Role | Size | Weight |
| --- | --- | --- |
| Menu bar count and percent | 12 | medium, monospaced digits |
| Popover title, agent and provider names | 13 | semibold |
| Section titles | 11 | semibold, secondary |
| Row secondary, live step, reset countdown | 11 | regular, secondary |
| Badges | 10 | medium |
| Window agent name | 20 | semibold |
| Usage figures | 17 | semibold |
| Steps | 12 (tool args/results 11) | regular |

## Spacing and shape

- Popover 360 pt wide; header padding 16 horizontal, 14 top, 12 bottom; content padding 10; 14 between sections; 8 between rows.
- Cards and rows: 10–12 pt padding, 10 pt continuous corner radius. Thread rows 8 pt radius.
- Usage bar: 5 pt capsule; non-zero values at least 5 pt wide.
- Live window: 820×560 minimum, sidebar 180–210 pt, detail padding 20, 18 between blocks. Live turn outline 1 pt in the agent's color at 50%.

## Components

- **Menu bar label**: `person.2.wave.2` (filled while someone works) + working count + tightest quota left, joined by a middle dot; 55% opacity while not connected or failing.
- **Agent row** (`AgentRow`): avatar 30, name, state badge, today's tokens on the right; second line is the live step, else the live thread name, else model and 7-day tokens.
- **Subscription row** (`SubscriptionRow`): one line per subscription, all of them visible at a glance — provider mark 14 pt (`ProviderMark`), name (provider, plus label or mailbox only when two share a provider), reset countdown of the tightest window (window name and absolute date on hover), `LeftBar` 56 pt (full = untouched, empty = at the limit, level color), % left 12 semibold (orange/red near the limit), pin glyph (accent `pin.fill` when pinned). No reading: a short issue word and `–`. Stale readings at 60% opacity. Rows sit in one grouped block (primary at 4%, radius 10) separated by inset dividers.
- **Tokens summary** (`TokensSummary`): the Tokens tab of the popover and the window's Tokens page (`TokensPage`, max 560 pt wide) are the same view: subscription rows, a one-line hint about pins, then one line per agent with tokens in the last 7 days (avatar 20, name, bar in the agent's color proportional to the busiest agent, figure), total in the section title. Nothing else: no emails, plans, in/out or turns.
- **Connect panel** (`ConnectPanel`): title, one explanatory line, space address field, small prominent Connect button with progress text, issue line, read-only footnote.
- **Live window** (`LiveWindow`): split view; the sidebar starts with a Tokens entry (`TokensPage`), then the agents section with `AgentDetail` — header (avatar 44, name, state, model), usage strip (today / 7 days / 30 days with in·out·turns, 30-day bars, tightest window per account), live turns (`LiveTurn`: thread name, elapsed timer, tokens, link, goal, auto-scrolling step list), threads (`ThreadList`: expand to the thread's recent turns with their last steps and output).
- **Step row** (`StepRow`): kind glyph, content, time on the right.

## Copy

English with Italian localization. Sentence case, short, no exclamation marks. Countdowns `2h 10m`, `3d 4h` (`3g 4h`). Token counts `950`, `45.2k`, `1.25M`.
