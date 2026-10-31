# cliamp-listenbrainz-radio

**Endless ListenBrainz radio for [cliamp](https://github.com/bjarneo/cliamp) — automatically tops up your playback queue with similar tracks using the ListenBrainz and MusicBrainz APIs.**

---

## What it does

`listenbrainz-radio` monitors cliamp's queue. When fewer than `min_ahead` tracks remain, it inspects your **Station Seed** (anchored to the manually played artist), queries **ListenBrainz Radio** for similar artists and top recordings, resolves them to playable audio streams, and appends fresh tracks to your playback queue.

Because recommendations stay anchored to your **Station Seed** rather than unconstrained random-walk drift, your radio stays faithful to your chosen vibe without getting permanently trapped in absorbent genre clusters (such as endless 90s rap loops). Whenever you manually select or queue a new track, the station seed automatically pivots to your new artist!

## Highlights

- 📻 **Station Seed Anchoring:** Recommends tracks consistent with your manually chosen artist instead of drifting endlessly into repetitive sub-genres. Can also be manually locked to any artist via CLI.
- ⚡ **Zero Setup / Tokenless by default:** Works immediately out of the box using public MusicBrainz and ListenBrainz radio endpoints. No API keys or accounts required.
- 🔑 **Optional ListenBrainz Account Mode:** If you provide your ListenBrainz User Token, it can utilize the `/1/explore/lb-radio` prompt-based radio engine.
- 🎯 **Configurable Radio Modes:** Choose between `"easy"` (similar/popular hits), `"medium"` (balanced exploration), and `"hard"` (deep cuts and obscure gems).
- 🧠 **Multi-Part Title & Video Fluff Cleaner:** Intelligently parses YouTube titles with channel prefixes (e.g. `mypassionfruit - Kinobe - Slip Into Something More Comfortable` or `kinobe official - Kinobe - Slip into Something (Official Audio)`), removes video fluff and tags, and cross-references MusicBrainz artist & recording databases.
- 🔄 **Anti-Repeat History & Caching:** Remembers recently queued tracks in `cliamp.store` to avoid repeats across refills and sessions, and caches artist MBIDs to respect API rate limits.

---

## Requirements

- **[cliamp](https://github.com/bjarneo/cliamp) ≥ 2.0.0** (with Lua plugin runtime enabled). Plugins run inside the TUI.
- Permissions granted on trust: **`control`** (to append recommended tracks to the queue) and **`exec`** (for subprocesses/yt-dlp).

---

## Installation

### Method 1: Using `cliamp plugins install` (cliamp ≥ 2.0.0)

```sh
cliamp plugins install 2gn/cliamp-listenbrainz-radio
```

Approve the trust prompt when requested.

### Method 2: Manual Directory Install (Universal)

```sh
mkdir -p ~/.config/cliamp/plugins/listenbrainz-radio
curl -fsSL https://raw.githubusercontent.com/2gn/cliamp-listenbrainz-radio/main/listenbrainz-radio.lua \
  -o ~/.config/cliamp/plugins/listenbrainz-radio/init.lua
cliamp plugins trust listenbrainz-radio --yes
```

Verify the installation:
```sh
cliamp plugins list
```
You should see `listenbrainz-radio` listed with status `trusted`.

---

## Configuration

All configuration keys are optional. Add them under `[plugins.listenbrainz-radio]` in `~/.config/cliamp/config.toml`:

```toml
[plugins.listenbrainz-radio]
start_on      = true      # Auto-refill active on startup
min_ahead     = 3         # Refill when fewer than N tracks remain
batch         = 5         # Number of tracks to add per refill
mode          = "easy"    # Radio mode: "easy", "medium", or "hard"
cooldown_secs = 20        # Minimum seconds between automatic refills
history_max   = 300       # Max remembered tracks to prevent repeats
token         = ""        # (Optional) ListenBrainz User Token
resolver      = "auto"    # "auto", "http", or "ytdlp"
```

### Configuration Options Reference

| Key | Default | Description |
|---|---|---|
| `start_on` | `true` | Whether auto-refill is active when cliamp loads. Can be toggled at runtime via CLI. |
| `min_ahead` | `3` | Refill when fewer than `min_ahead` tracks remain ahead in the queue. |
| `batch` | `5` | Maximum number of recommended tracks to append per refill. |
| `mode` | `"easy"` | ListenBrainz exploration mode (`"easy"`, `"medium"`, or `"hard"`). |
| `pop_begin` | `0` | Popularity percentage lower bound (0–100). |
| `pop_end` | `100` | Popularity percentage upper bound (0–100). |
| `cooldown_secs`| `20` | Debounce time in seconds between auto-refills to prevent event storms. |
| `history_max` | `300` | How many recent tracks to remember in local store to avoid duplicate recommendations. |
| `token` | `""` | Optional ListenBrainz User Token (find yours at [listenbrainz.org/profile](https://listenbrainz.org/profile/)). Enables `/1/explore/lb-radio`. |
| `resolver` | `"auto"` | How to find audio streams: `"auto"` (HTTP with fallback), `"http"` (pure HTTP, zero external dependencies), or `"ytdlp"`. |

---

## Usage

### Automatic Mode
Simply start playing any song in cliamp. As the queue plays down to `min_ahead` tracks, `listenbrainz-radio` queries ListenBrainz for the current artist and tops up the queue. You'll see `LB radio +N` flash in the status bar.

### Manual Commands

You can control the plugin at runtime from your terminal:

```sh
# Inspect or manually set the Station Seed artist
cliamp plugins call listenbrainz-radio station
cliamp plugins call listenbrainz-radio station "Kinobe"

# Force an immediate refill based on the station seed (ignores cooldown & min_ahead)
cliamp plugins call listenbrainz-radio start

# Toggle auto-refill on/off
cliamp plugins call listenbrainz-radio toggle
cliamp plugins call listenbrainz-radio on
cliamp plugins call listenbrainz-radio off

# Change or view the radio mode ("easy", "medium", "hard")
cliamp plugins call listenbrainz-radio mode hard
cliamp plugins call listenbrainz-radio mode

# Check plugin status and settings
cliamp plugins call listenbrainz-radio status

# Clear the anti-repeat history and candidate buffer
cliamp plugins call listenbrainz-radio clear

# Complete reset (station seed, history, and recommendation buffer)
cliamp plugins call listenbrainz-radio reset
```

---

## How It Works

1. **Seed Track Identification:** The plugin listens to `track.change`, `queue.change`, and `app.start`. When a refill is needed, it inspects the playing track and extracts the artist name and title.
2. **ListenBrainz Radio API:**
   - **Tokenless mode (Default):**
     1. Queries the MusicBrainz API to find the artist's MusicBrainz Identifier (`artist_mbid`).
     2. Calls ListenBrainz `/1/lb-radio/artist/<artist_mbid>` with the configured `mode` and popularity range to get similar artists and recommended recording MBIDs.
     3. Batch-resolves recording titles via `/1/metadata/recording/?recording_mbids=...`.
   - **Token mode:**
     Calls `/1/explore/lb-radio?prompt=artist:(<artist>)` with your User Token and parses the returned JSPF playlist.
3. **Filtering & Deduplication:** Removes any tracks currently in the queue or already recorded in the persistent history store.
4. **Playback Resolution:** Resolves each track to a streaming URL and appends it to `cliamp.queue`.

---

## Troubleshooting

- **Logs:** To inspect plugin activity or errors, tail cliamp's plugin log:
  ```sh
  tail -f ~/.config/cliamp/plugins.log
  ```
- **Untrusted Plugin:** If `cliamp plugins list` displays `untrusted`, re-approve the plugin contents:
  ```sh
  cliamp plugins trust listenbrainz-radio --yes
  ```
- **No recommendations added:**
  - Verify your internet connection.
  - If the playing song lacks artist tags, check the log to verify if seed extraction identified the artist. You can also run `cliamp plugins call listenbrainz-radio start` to test manual triggering.

---

## License

[MIT](./LICENSE) © 2026
