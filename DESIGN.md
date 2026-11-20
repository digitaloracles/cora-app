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
| `heat.0`…`heat.4` | primary 8%, amber `#F2A93B` at 22/45/70/100% | token heatmap squares, as in the panel |

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
- Live window: 640×480 minimum, sidebar 180–210 pt, detail padding 20, 18 between blocks. Live turn outline 1 pt in the agent's color at 50%.

## Components

- **Menu bar label**: the Cora sphere (template image) with the number of working agents small at its top right, then the pinned quotas; 55% opacity while not connected or failing.
- **Agent row** (`AgentRow`): avatar 30, name, state badge, today's tokens on the right; second line is the live step, else the live thread name, else model and 7-day tokens.
- **Subscription row** (`SubscriptionRow`): provider mark 14 pt, always one line tall and aligned to the first line (`ProviderMark`); name (provider, plus label or mailbox only when two share a provider) then the account-wide windows, shortest first, one line each (`WindowFigures`): length tag (`5h`, `24h`, `7d`/`7g`, `30d`; 10 semibold secondary on a primary-7% capsule, 28 pt), reset countdown (42 pt, right-aligned), `LeftBar` 36 pt (full = untouched, empty = at the limit, level color), % left 12 semibold in 38 pt, never wrapped (orange/red near the limit). The first window sits on the name's line, the second on the line under it, aligned to the same columns: two lines only where there are two limits. Pay-as-you-go: `Balance` and the amount. No reading: a short issue word and `–`. Pin glyph on the first line (accent `pin.fill` when pinned). Stale readings at 60% opacity. Rows sit in one grouped block (primary at 4%, radius 10) separated by inset dividers.
- **Subscription details** (`SubscriptionDetail`): a click on a row opens it under the name (the store keeps it open while the app runs). Inset card (primary at 4%, radius 8): every window with its full name (`5-hour session`, `Weekly · Fable`), % left, full-width `LeftBar`, exact reset (countdown, then the time today, weekday and time within a week, else the date) and % used; model-scoped windows after the account-wide ones; every balance (total in semibold); then plan, mailbox, the agents that run on it and when it was last read, 10 pt secondary.
- **Menu bar quotas** (`MenuBarTitle`): per pinned subscription the provider icon and what is left at 12 pt. A subscription with two limits stacks them at 9 pt with an 8 pt secondary tag (`5h 64%` over `7d 80%`); subscriptions of one provider share the icon, one column each; single-figure ones of one provider share one column.
- **Tokens summary** (`TokensSummary`): the Tokens tab of the popover shows it whole; the window's Tokens page uses its subscription rows only, in two blocks side by side from 720 pt of content width: subscription rows, a one-line hint about pins, then one line per agent with tokens in the last 7 days (avatar 20, name, bar in the agent's color proportional to the busiest agent, figure), total in the section title. Nothing else: no emails, plans, in/out or turns.
- **Tokens page** (`TokensPage`): follows the window's width, content up to 1100 pt: title, subscriptions (one or two columns), then `UsageHeatmaps`: a `Usage` heading with the `less ▢▢▢▢▢ more` legend, an `All together` card, then one card per agent sorted by tokens spent, one to three per row (each at least 288 pt). Cards: primary at 4%, radius 10, padding 12; header avatar 22, name 13 semibold, total 11 secondary.
- **Token heatmap** (`TokenHeatmap`, the panel's heatmap): one square per day from the first recorded use to today, weeks as columns from Monday, month labels 9 pt where three columns apart, date range 10 pt above, a readout line under it (the hovered day `18 Nov · 1.2M tokens · 14 turns`, else the model or a hint). Five levels relative to the busiest day: empty primary at 8%, then amber `#F2A93B` at 22, 45, 70 and 100%; radius 2.5, gap 3. Squares grow with the width (10–18 pt together, 10–14 pt per agent) and below 10 pt the map scrolls sideways, opened on today. Data: `/app/v1/usage` (a year), else the snapshot's 31 days.
- **Connect panel** (`ConnectPanel`): title, one explanatory line, space address field, small prominent Connect button with progress text, issue line, read-only footnote.
- **Live window** (`LiveWindow`): split view; the sidebar starts with a Tokens entry (`TokensPage`) and a Plans entry (`PlansPage`), then the agents section with `AgentDetail` — header (avatar 44, name, state, model), usage strip (today / 7 days / 30 days with in·out·turns, 30-day bars, tightest window per account), live turns (`LiveTurn`: thread name, elapsed timer, tokens, link, goal, auto-scrolling step list), threads (`ThreadList`: expand to the thread's recent turns with their last steps and output).
- **Plans page** (`PlansPage`): third sidebar entry, `checklist` glyph with the number of open plans as badge. Content up to 900 pt: title 20 semibold with `N in progress · M finished` (11 secondary) on the right; `In progress`: one `PlanCard` per open plan; `History`: finished plans in one grouped block (primary at 4%, radius 10, dividers inset 38) of `PlanHistoryRow`, newest first, then a small `Show older plans` button while the server has more. A server without plans shows one secondary line asking for an update.
- **Plan card** (`PlanCard`): primary at 4%, radius 10, padding 12, 1 pt outline in the agent's color at 35% (orange when blocked). Agent face 28, plan name 13 semibold (two lines), `agent · thread` 11 secondary, `PlanStatusBadge` (as `StateBadge`: green in progress, orange blocked, faded green completed, grey closed) and the thread link; `PlanProgress` (5 pt capsule, agent color, max 260) with `2 of 5 steps` and the last change; the blocker as an orange `exclamationmark.triangle.fill` line; then `PlanChecklist`. In an agent's page its open plans sit between live turns and threads, without the face.
- **Popover Plans tab**: the fifth tab after Threads. Every open plan as a compact `PlanCard` head only (face 24, padding 10, spacing 8: name, place, badge, thread link, progress and the blocker, no checklist), then `Finished` with the five latest as compact `PlanHistoryRow`s (no status badge, relative time, chevron that does not turn), then an `All plans` link. A click on a card or a row opens the window on the Plans page scrolled to that plan (a finished one unfolded), its outline at full color and 2 pt for two seconds; the header window button opens that page too while the tab is shown.
- **Plan checklist** (`PlanChecklist`): one line per item, `N. text` at 12: done `checkmark.circle.fill` green with secondary text, current `arrow.right.circle.fill` accent in semibold, blocked `exclamationmark.circle.fill` orange, pending `circle` secondary, left undone by a closed plan `minus.circle` faded. Items with linked reasoning show `12 steps` and a chevron; a click opens their `StepRow`s in the live-turn well (text background at 60%, radius 8), read from `/app/v1/threads/{id}/plans/{plan}/tasks/{item}`.
- **Spaces** (`Spaces`, `SpaceSwitcher`): one Mac reads several spaces, each with its own token and stream. With two or more, the popover shows a row of chips under the header (22 pt high, capsule, primary at 4% / 12% when selected, a 6 pt dot: green ready, amber with the count while agents work, orange offline) ending with `+`; the window shows a menu picker on top of the sidebar. The menu bar adds up the working agents and the pinned subscriptions of every space. "Add another space…" lives in the header menu; the address panel then has a Cancel button.
- **Step row** (`StepRow`): kind glyph, content, time on the right.

## Copy

English with Italian localization. Sentence case, short, no exclamation marks. Countdowns `2h 10m`, `3d 4h` (`3g 4h`). Token counts `950`, `45.2k`, `1.25M`.

## iOS: live work

- **What runs now updates by itself.** While the app is in front, the event stream moves every running turn step by step; a full snapshot is read again on start, end and plan events and once a minute.
- **Live dot** (`LiveDot`): the green state dot pulses (opacity 1 ↔ 0.3, 0.8 s) while an agent works; still otherwise.
- **Live line** (`LiveNowLine`): in thread and plan rows, in place of the last reasoning: pulsing dot 7, «Buzz sta lavorando» footnote semibold green, elapsed time caption2 secondary; under it the step the agent is on, footnote secondary, italic for thinking, two lines at most.
- **Thread and plan details**: each running turn in its own section (in a thread before the finished turns, in a plan after the checklist) headed by the live dot, «<agent> sta lavorando» and the elapsed time, steps newest first as they arrive; the finished turns follow and are read again whenever a turn starts or ends.
