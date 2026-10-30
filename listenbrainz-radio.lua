-- listenbrainz-radio: endless ListenBrainz radio for cliamp.
-- Automatically tops up the playback queue with recommended tracks
-- fetched from the ListenBrainz & MusicBrainz APIs.
--
-- License: MIT (c) 2026
-- Compatible with cliamp Lua 5.1 plugin runtime.

local p = plugin.register({
  name        = "listenbrainz-radio",
  type        = "hook",
  version     = "0.1.4",
  description = "Endless ListenBrainz radio: queues recommended songs using ListenBrainz API",
  permissions = { "control", "exec" },
})

-- =========================================================================
-- Configuration Helpers ([plugins.listenbrainz-radio] in config.toml)
-- =========================================================================

local function clean_str(s)
  if s == nil then return nil end
  s = tostring(s)
  -- Remove inline comment starting with #
  s = s:gsub("%s*#.*$", "")
  -- Trim whitespace and surrounding quotes
  s = s:gsub("^%s*[\"']*", "")
  s = s:gsub("[\"']*[%s\r\n]*$", "")
  if s == "" then return nil end
  return s
end

local function cfg_str(key, def)
  local v = clean_str(p:config(key))
  if v == nil then return def end
  return v
end

local function cfg_num(key, def)
  local raw = clean_str(p:config(key))
  if raw == nil then return def end
  local v = tonumber(raw)
  if v == nil then return def end
  return v
end

local function cfg_bool(key, def)
  local raw = clean_str(p:config(key))
  if raw == nil then return def end
  if raw == true or raw == "true" or raw == "1" or raw == 1 or raw == "yes" or raw == "on" then return true end
  if raw == false or raw == "false" or raw == "0" or raw == 0 or raw == "no" or raw == "off" then return false end
  return def
end

local function sanitize_mode(m)
  local s = clean_str(m)
  if s == "medium" or s == "hard" then
    return s
  end
  return "easy"
end

-- =========================================================================
-- Settings
-- =========================================================================

local MIN_AHEAD           = math.max(1, math.floor(cfg_num("min_ahead", 3)))
local BATCH               = math.max(1, math.floor(cfg_num("batch", 3)))
local COOLDOWN            = math.max(0, math.floor(cfg_num("cooldown_secs", 20)))
local HIST_MAX            = math.max(0, math.floor(cfg_num("history_max", 300)))
local START_ON            = cfg_bool("start_on", true)
local LB_MODE             = sanitize_mode(cfg_str("mode", "easy"))
local POP_BEGIN           = math.max(0, math.min(100, math.floor(cfg_num("pop_begin", 0))))
local POP_END             = math.max(0, math.min(100, math.floor(cfg_num("pop_end", 100))))
local MAX_SIMILAR_ARTISTS = math.max(1, math.floor(cfg_num("max_similar_artists", 5)))
local MAX_REC_PER_ARTIST  = math.max(1, math.floor(cfg_num("max_recordings_per_artist", 3)))
local LB_TOKEN            = cfg_str("token", nil)
local RESOLVER            = cfg_str("resolver", "auto")
local CLEAN_TITLES        = cfg_bool("clean_titles", true)

local USER_AGENT = "cliamp-listenbrainz-radio/0.1.4 ( https://github.com/2gn/cliamp-listenbrainz-radio )"

-- =========================================================================
-- Runtime State
-- =========================================================================

local refilling = false
local last_run  = 0

local function auto_on()
  local v = cliamp.store.get("auto")
  if v == nil then return START_ON end
  return v == true
end

local function set_auto(on)
  cliamp.store.set("auto", on == true)
end

local function get_active_mode()
  return sanitize_mode(cliamp.store.get("mode") or LB_MODE)
end

local function set_active_mode(m)
  local s = sanitize_mode(m)
  cliamp.store.set("mode", s)
  return true
end

-- =========================================================================
-- Persistent History & Cache
-- =========================================================================

local function history()
  return cliamp.store.get("recent_keys") or {}
end

local function remember(keys)
  local h = history()
  for _, k in ipairs(keys) do
    h[#h + 1] = k
  end
  while #h > HIST_MAX do
    table.remove(h, 1)
  end
  cliamp.store.set("recent_keys", h)
end

local function in_history(key)
  for _, x in ipairs(history()) do
    if x == key then return true end
  end
  return false
end

local function normalize_key(artist, title)
  local a = (artist or ""):lower():gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
  local t = (title or ""):lower():gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
  return a .. " - " .. t
end

-- Cache artist name -> MusicBrainz artist MBID
local function get_cached_artist_mbid(artist_name)
  local cache = cliamp.store.get("mbid_cache") or {}
  return cache[artist_name:lower()]
end

local function cache_artist_mbid(artist_name, mbid)
  local cache = cliamp.store.get("mbid_cache") or {}
  cache[artist_name:lower()] = mbid
  cliamp.store.set("mbid_cache", cache)
end

-- Buffered recommendations queue to avoid duplicate API calls
local function get_buffered_recs()
  return cliamp.store.get("buffered_recs") or {}
end

local function set_buffered_recs(recs)
  cliamp.store.set("buffered_recs", recs)
end

-- =========================================================================
-- URL Encoding Utility
-- =========================================================================

local function urlencode(str)
  if str == nil then return "" end
  str = tostring(str)
  str = str:gsub("\n", "\r\n")
  str = str:gsub("([^%w_%-%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return str
end

-- =========================================================================
-- Track Metadata Extraction
-- =========================================================================

local function extract_seed(item)
  -- 1. Try currently playing track from cliamp.track (populated during playback)
  local t_artist = cliamp.track.artist()
  local t_title = cliamp.track.title()

  if t_artist and type(t_artist) == "string" and #t_artist > 0 then
    return t_artist, t_title
  end

  if t_title and type(t_title) == "string" and #t_title > 0 and t_title ~= "watch" then
    local a, t = t_title:match("^%s*(.-)%s*[%-–—]%s*(.-)%s*$")
    if a and t and #a > 0 and #t > 0 then
      a = a:gsub("%s*%- Topic$", "")
      return a, t
    end
  end

  -- 2. Try item from queue list
  if item then
    local artist = item.artist
    local title = item.title

    if artist and type(artist) == "string" and #artist > 0 then
      return artist, title
    end

    if title and type(title) == "string" and #title > 0 and title ~= "watch" then
      local a, t = title:match("^%s*(.-)%s*[%-–—]%s*(.-)%s*$")
      if a and t and #a > 0 and #t > 0 then
        a = a:gsub("%s*%- Topic$", "")
        return a, t
      end
    end

    -- 3. If item path is a YouTube URL, fetch title from YouTube oEmbed
    local path = item.path or ""
    local vid = path:match("[?&]v=([%w%-_]+)") or path:match("youtu%.be/([%w%-_]+)")
    if vid then
      local oembed_url = "https://www.youtube.com/oembed?url=" .. urlencode("https://www.youtube.com/watch?v=" .. vid) .. "&format=json"
      local ok, body, status = pcall(function()
        return cliamp.http.get(oembed_url, {
          headers = { ["User-Agent"] = USER_AGENT }
        })
      end)
      if ok and status == 200 and body then
        local dec_ok, data = pcall(cliamp.json.decode, body)
        if dec_ok and type(data) == "table" and data.title then
          local a, t = data.title:match("^%s*(.-)%s*[%-–—]%s*(.-)%s*$")
          if a and t and #a > 0 and #t > 0 then
            a = a:gsub("%s*%- Topic$", "")
            return a, t
          end
          if data.author_name then
            local a = data.author_name:gsub("VEVO$", ""):gsub("%s*%- Topic$", "")
            return a, data.title
          end
        end
      end
    end
  end

  return nil, nil
end

-- =========================================================================
-- MusicBrainz & ListenBrainz API Clients
-- =========================================================================

-- Look up artist MBID using MusicBrainz Search API
local function resolve_artist_mbid(artist_name)
  local cached = get_cached_artist_mbid(artist_name)
  if cached then return cached end

  local query = "artist:" .. urlencode(artist_name)
  local url = "https://musicbrainz.org/ws/2/artist/?query=" .. query .. "&fmt=json"
  local ok, body, status = pcall(function()
    return cliamp.http.get(url, {
      headers = { ["User-Agent"] = USER_AGENT }
    })
  end)

  if not ok or status ~= 200 or not body then
    cliamp.log.warn("lb-radio: MusicBrainz search failed with status " .. tostring(status))
    return nil
  end

  local dec_ok, data = pcall(cliamp.json.decode, body)
  if not dec_ok or type(data) ~= "table" or not data.artists or #data.artists == 0 then
    cliamp.log.warn("lb-radio: artist not found on MusicBrainz: " .. artist_name)
    return nil
  end

  local mbid = data.artists[1].id
  if mbid then
    cache_artist_mbid(artist_name, mbid)
  end
  return mbid
end

-- Fetch recommendations using public ListenBrainz Artist Radio endpoint
local function fetch_lb_artist_radio(seed_artist_mbid, mode)
  local clean_m = sanitize_mode(mode)
  local url = string.format(
    "https://api.listenbrainz.org/1/lb-radio/artist/%s?mode=%s&max_similar_artists=%d&max_recordings_per_artist=%d&pop_begin=%d&pop_end=%d",
    seed_artist_mbid, clean_m, MAX_SIMILAR_ARTISTS, MAX_REC_PER_ARTIST, POP_BEGIN, POP_END
  )

  local ok, body, status = pcall(function()
    return cliamp.http.get(url, {
      headers = { ["User-Agent"] = USER_AGENT }
    })
  end)

  if not ok or status ~= 200 or not body then
    cliamp.log.warn("lb-radio: ListenBrainz artist radio failed with status " .. tostring(status))
    return {}
  end

  local dec_ok, data = pcall(cliamp.json.decode, body)
  if not dec_ok or type(data) ~= "table" then
    cliamp.log.warn("lb-radio: failed to parse ListenBrainz artist radio response")
    return {}
  end

  local candidates = {}
  local mbids_to_fetch = {}

  for _, recs in pairs(data) do
    if type(recs) == "table" then
      for _, item in ipairs(recs) do
        if item.recording_mbid and item.similar_artist_name then
          local rmbid = item.recording_mbid
          candidates[#candidates + 1] = {
            mbid   = rmbid,
            artist = item.similar_artist_name,
          }
          mbids_to_fetch[#mbids_to_fetch + 1] = rmbid
        end
      end
    end
  end

  if #mbids_to_fetch == 0 then
    return {}
  end

  -- Batch lookup recording titles from ListenBrainz metadata endpoint
  local rec_url = "https://api.listenbrainz.org/1/metadata/recording/?recording_mbids=" .. table.concat(mbids_to_fetch, ",")
  local meta_ok, meta_body, meta_status = pcall(function()
    return cliamp.http.get(rec_url, {
      headers = { ["User-Agent"] = USER_AGENT }
    })
  end)

  local meta_map = {}
  if meta_ok and meta_status == 200 and meta_body then
    local d_ok, meta_data = pcall(cliamp.json.decode, meta_body)
    if d_ok and type(meta_data) == "table" then
      meta_map = meta_data
    end
  end

  local results = {}
  for _, cand in ipairs(candidates) do
    local info = meta_map[cand.mbid]
    local rec_name = info and info.recording and info.recording.name
    if rec_name and #rec_name > 0 then
      results[#results + 1] = {
        artist = cand.artist,
        title  = rec_name,
        mbid   = cand.mbid,
      }
    end
  end

  return results
end

-- Fetch recommendations using ListenBrainz explore endpoint (when token is configured)
local function fetch_lb_explore_radio(seed_artist, mode, token)
  local clean_m = sanitize_mode(mode)
  local prompt = "artist:(" .. seed_artist .. ")"
  local url = "https://api.listenbrainz.org/1/explore/lb-radio?prompt=" .. urlencode(prompt) .. "&mode=" .. clean_m

  local ok, body, status = pcall(function()
    return cliamp.http.get(url, {
      headers = {
        ["User-Agent"]    = USER_AGENT,
        ["Authorization"] = "Token " .. token,
      }
    })
  end)

  if not ok or status ~= 200 or not body then
    cliamp.log.warn("lb-radio: explore/lb-radio failed with status " .. tostring(status))
    return {}
  end

  local dec_ok, data = pcall(cliamp.json.decode, body)
  if not dec_ok or type(data) ~= "table" then return {} end

  local tracks = data.payload and data.payload.jspf and data.payload.jspf.playlist and data.payload.jspf.playlist.track
  if type(tracks) ~= "table" then return {} end

  local results = {}
  for _, t in ipairs(tracks) do
    if t.title and t.creator then
      results[#results + 1] = {
        artist = t.creator,
        title  = t.title,
        mbid   = t.identifier,
      }
    end
  end

  return results
end

-- =========================================================================
-- Audio Stream Resolver (YouTube search via HTTP)
-- =========================================================================

-- Clean remix / dub / mix suffixes when searching for original studio audio
local function clean_track_title(title)
  if not title or not CLEAN_TITLES then return title end
  local cleaned = title:gsub("%s*%b()", function(inside)
    local lower = inside:lower()
    if lower:find("mix") or lower:find("remix") or lower:find("dub") or
       lower:find("edit") or lower:find("version") or lower:find("live") or
       lower:find("instrumental") or lower:find("bonus") or lower:find("beats") then
      return ""
    end
    return inside
  end)
  cleaned = cleaned:gsub("%s*%b[]", function(inside)
    local lower = inside:lower()
    if lower:find("mix") or lower:find("remix") or lower:find("dub") or
       lower:find("edit") or lower:find("version") or lower:find("live") or
       lower:find("instrumental") or lower:find("bonus") or lower:find("beats") then
      return ""
    end
    return inside
  end)
  cleaned = cleaned:gsub("^%s*(.-)%s*$", "%1")
  if #cleaned == 0 then return title end
  return cleaned
end

local function resolve_via_http(artist, title)
  local search_title = clean_track_title(title)
  local query = urlencode(artist .. " " .. search_title .. " audio")
  local url = "https://www.youtube.com/results?search_query=" .. query
  local body, status = cliamp.http.get(url, {
    headers = {
      ["User-Agent"]      = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      ["Accept-Language"] = "en-US,en;q=0.9",
    }
  })

  if status == 200 and body then
    -- In Lua pattern matching: [%w%-_] captures alphanumeric, hyphen and underscore
    local vid = body:match('"videoId":"([%w%-_]+)"')
    if vid and #vid == 11 then
      return vid
    end
  end
  return nil
end

-- Safely resolve video ID with pcall
local function resolve_track_video_id(artist, title)
  if RESOLVER == "http" or RESOLVER == "auto" then
    local ok, vid = pcall(resolve_via_http, artist, title)
    if ok and vid then return vid end
  end
  return nil
end

-- =========================================================================
-- Core Refill Engine
-- =========================================================================

local function refill(force)
  if refilling then return end
  if not force and not auto_on() then return end
  if not force and COOLDOWN > 0 and (os.time() - last_run) < COOLDOWN then return end

  local list  = cliamp.queue.list()
  local cur   = cliamp.queue.current() -- 0-based
  local ahead = #list - (cur + 1)
  if not force and ahead >= MIN_AHEAD then return end

  local cur_item = list[cur + 1]
  local seed_artist, seed_title = extract_seed(cur_item)
  if not seed_artist then
    cliamp.log.warn("lb-radio: could not determine seed artist from current track")
    return
  end

  refilling = true
  last_run  = os.time()
  local mode = get_active_mode()

  -- Check existing queue items to avoid duplicates
  local in_queue = {}
  for _, it in ipairs(list) do
    local norm = normalize_key(it.artist, it.title)
    in_queue[norm] = true
  end

  -- Get candidate recommendations from buffer or fresh API fetch
  local buffered = get_buffered_recs()
  if #buffered < BATCH then
    local fresh = {}
    if LB_TOKEN and #LB_TOKEN > 0 then
      cliamp.log.info(("lb-radio: fetching explore radio for %q (mode: %s)"):format(seed_artist, mode))
      fresh = fetch_lb_explore_radio(seed_artist, mode, LB_TOKEN)
    end

    if #fresh == 0 then
      cliamp.log.info(("lb-radio: fetching artist radio for %q (mode: %s)"):format(seed_artist, mode))
      local artist_mbid = resolve_artist_mbid(seed_artist)
      if artist_mbid then
        fresh = fetch_lb_artist_radio(artist_mbid, mode)
      end
    end

    -- Append fresh candidates to buffer
    for _, item in ipairs(fresh) do
      buffered[#buffered + 1] = item
    end
  end

  -- Pick tracks to add (bound attempts to 3 to strictly respect the 5s hook deadline)
  local added_count = 0
  local attempts    = 0
  local max_attempts = math.min(BATCH, 3)
  local added_keys  = {}
  local remaining_buffered = {}

  for _, item in ipairs(buffered) do
    local key = normalize_key(item.artist, item.title)
    if added_count < BATCH and attempts < max_attempts then
      if not in_queue[key] and not in_history(key) then
        attempts = attempts + 1
        local vid = resolve_track_video_id(item.artist, item.title)
        if vid then
          local track_url = "https://www.youtube.com/watch?v=" .. vid
          cliamp.queue.add(track_url)
          in_queue[key] = true
          added_keys[#added_keys + 1] = key
          added_count = added_count + 1
        else
          cliamp.log.debug(("lb-radio: could not resolve stream for %s - %s"):format(item.artist, item.title))
        end
      end
    else
      remaining_buffered[#remaining_buffered + 1] = item
    end
  end

  set_buffered_recs(remaining_buffered)

  if added_count > 0 then
    remember(added_keys)
    cliamp.log.info(("lb-radio: added %d tracks (seed: %s, mode: %s)"):format(added_count, seed_artist, mode))
    cliamp.message("LB radio +" .. added_count)
  else
    cliamp.log.warn("lb-radio: no new recommendations added")
  end

  refilling = false
end

-- =========================================================================
-- Event Triggers
-- =========================================================================

p:on("track.change", function() refill(false) end)
p:on("queue.change", function() refill(false) end)
p:on("app.start",    function() refill(false) end)

-- =========================================================================
-- Shell Commands (cliamp plugins call listenbrainz-radio <cmd> [args])
-- =========================================================================

p:command("start", function()
  refill(true)
  return "listenbrainz-radio: forced refill"
end)

p:command("on", function()
  set_auto(true)
  return "listenbrainz-radio: auto-refill on"
end)

p:command("off", function()
  set_auto(false)
  return "listenbrainz-radio: auto-refill off"
end)

p:command("toggle", function()
  local now = not auto_on()
  set_auto(now)
  return "listenbrainz-radio: auto-refill " .. (now and "on" or "off")
end)

p:command("mode", function(args)
  local arg = nil
  if type(args) == "table" then
    arg = args[1]
  elseif type(args) == "string" then
    arg = args
  end
  if arg and #arg > 0 then
    local clean_arg = clean_str(arg)
    if clean_arg == "easy" or clean_arg == "medium" or clean_arg == "hard" then
      set_active_mode(clean_arg)
      set_buffered_recs({}) -- clear buffer so new mode takes effect
      return "listenbrainz-radio: mode set to " .. clean_arg
    else
      return "listenbrainz-radio: invalid mode '" .. tostring(arg) .. "'. Choose 'easy', 'medium', or 'hard'."
    end
  end
  return "listenbrainz-radio: current mode is " .. get_active_mode()
end)

p:command("status", function()
  return ("listenbrainz-radio: auto=%s | mode=%s | min_ahead=%d batch=%d cooldown=%ds history=%d buffer=%d"):format(
    auto_on() and "on" or "off", get_active_mode(), MIN_AHEAD, BATCH, COOLDOWN, #history(), #get_buffered_recs()
  )
end)

p:command("clear", function()
  cliamp.store.set("recent_keys", {})
  cliamp.store.set("buffered_recs", {})
  return "listenbrainz-radio: history and buffer cleared"
end)
