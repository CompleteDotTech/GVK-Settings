---
title: KOTH client (HUD panel, boundary, fireworks)
covers:
  - ModScripts/GVK_KothClient.cs
scripts:
  - ModScripts/GVK_KothClient.cs: Client only: KOTH capture panel, zone boundary and fireworks from the GVK KOTH plugin
---

# KOTH client (HUD panel, boundary, fireworks)

The player side of the GVK KOTH Torch plugin ([GV-Server-Mods/GVK-KOTH-Plugin](https://github.com/GV-Server-Mods/GVK-KOTH-Plugin), hub #741). The plugin runs KOTH on the server; this script only shows it. Without the plugin it receives nothing and draws nothing.

## Zone state from the server
- Listens on network channel `47410` (`RegisterSecureMessageHandler`, server messages only). The format is in the plugin's `docs/CLIENT_PROTOCOL.md`.
- About once a second while a KOTH is open (every 10 seconds otherwise) the plugin sends every open zone (name, position, radius, bar %, players counted, grid entity ID and current eligible faction tags) and the next slot's zone with its start time. Each message replaces the whole list in `KothClientData`, including faction state; omitted zones do not retain their old tags.
- The version 1 `O` record extends the existing nine fields with a tenth field containing distinct, ordinally sorted tags such as `[AAA] [BBB]`. An empty tenth field means there are no eligible factions in the current scan. Legacy eight- or nine-field `O` records have faction information **unavailable**, not an empty faction result. The server refreshes tags from current participant faction IDs during capture scans, including scans with no eligible factions and without a completion.
- Tags are current state, not winners inferred from `C` completion events. The existing `C` completion and `N` next-zone records, capture/scoring behavior, channel and cadence are unchanged.
- No message for 30 seconds (plugin stopped or not installed): the list is cleared.
- `KothClientData` is shared with the `/gvk` navigation HUD, which shows KOTH markers from it (see [Zone navigation HUD](zone-nav-hud.md)).

## Capture panel
- Shown while the player is inside an open KOTH: name, bar %, a 20-step bar, the number of players counted and current faction tags. Left side of the screen, under Text HUD API. The faction line shows `none` for an empty tenth field and `unavailable` for a legacy record.
- Checked every 10 ticks; text is rebuilt when the displayed percent, count, zone name, faction tags or faction page changes, including a tag-only update. Leaving the zone, a full-state replacement that removes it, or stale-state clearing hides the panel; the next display rebuilds its text.
- Server formatting filters blank tags, sanitizes delimiters, line breaks and angle brackets, and deduplicates them. The client sanitizes faction text into deterministic pages of up to 24 characters, preferring whitespace breaks, so all faction text remains available. With multiple pages, the label includes page/total and rotates every 300 simulation ticks (about 5 seconds at 60 TPS, not a guaranteed wall-clock interval). A faction list or zone change, or re-entry, resets to page 1.
- The zone name is length-truncated for display. The client keeps the capture bar and participant count visible and measures and fits the panel font to prevent overflow; server text is restricted to a safe single line to prevent HUD markup injection.

## Zone boundary
- A faint orange wireframe sphere at the capture radius, drawn only when the camera is within the radius plus 1 km. Zones are visual only; nothing about them is a safe zone.
- For NPC zones (Flying KOTH) the server sends the grid's entity id, and the sphere and the inside-zone check follow that grid every frame while it is loaded on the client, so a moving zone's boundary moves smoothly. If the grid isn't loaded, they use the last position the server sent (about once a second).

## Fireworks
- When a capture bar completes, players within 5 km see 8 vanilla firework bursts (`Explosion_Firework_*`) above the zone over a few seconds.

## Performance notes
- Parsing runs once per message (about once a second). Per-tick work is the firework queue (empty almost always) and a distance-squared check against open zones every 10 ticks.
- Faction resolution is performed on the game thread during the existing server capture scan, not by a new per-frame client scan. Panel text measurement and fitting happen only on a displayed text change.
- The boundary is drawn in `Draw()` only near an open zone.

## Runtime validation
- The protocol and panel changes require integrated testing with the plugin and a Space Engineers client; documentation or core protocol tests alone cannot verify Text HUD API layout, game-thread faction resolution, or live network behavior.
- In game, check current tags and participant count while factions enter, leave or change without a bar/count change; verify an empty scan shows `none`, legacy records show `unavailable`, and full replacement or 30-second staleness clears old state. Use enough tags for multiple pages and check page progression, page/total, and resets after faction list or zone changes and re-entry. Exercise long or unsafe tag text, moving-zone fallback, navigation and completion fireworks as well. These are validation targets, not claims of a completed runtime or paging pass.
