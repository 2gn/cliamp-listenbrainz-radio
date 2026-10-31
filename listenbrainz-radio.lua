-- listenbrainz-radio: endless ListenBrainz radio for cliamp.
-- Automatically tops up the playback queue with recommended tracks
-- fetched from the ListenBrainz & MusicBrainz APIs with Station Seed.
--
-- License: MIT (c) 2026
-- Compatible with cliamp Lua 5.1 plugin runtime.

local p = plugin.register({
  name        = "listenbrainz-radio",
  type        = "hook",
  version     = "0.2.0",
  description = "Endless ListenBrainz radio: queues recommended songs using ListenBrainz API with Station Seed",
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
local CLEAN_TITLES        = cfg_bool("clean_titles", false)

local USER_AGENT = "cliamp-listenbrainz-radio/0.2.0 ( https://github.com/2gn/cliamp-listenbrainz-radio )"

-- =========================================================================
-- Runtime State & Controls
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
-- Station Seed Management
-- =========================================================================

local function get_station_seed()
  local artist = cliamp.store.get("station_seed_artist")
  local mbid   = cliamp.store.get("station_seed_mbid")
  return artist, mbid
end

local function set_station_seed(artist, mbid)
  cliamp.store.set("station_seed_artist", artist)
  cliamp.store.set("station_seed_mbid", mbid)
end

local function clear_station_seed()
  cliamp.store.set("station_seed_artist", nil)
  cliamp.store.set("station_seed_mbid", nil)
end

-- =========================================================================
-- Auto-Queued Tracking (Preventing recommendations from overriding station seed)
-- =========================================================================

local function auto_queued_map()
  return cliamp.store.get("auto_queued_keys") or {}
end

local function normalize_key(artist, title)
  local a = (artist or ""):lower():gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
  local t = (title or ""):lower():gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
  return a .. " - " .. t
end

local function mark_auto_queued(path, artist, title)
  local map = auto_queued_map()
  if path and #path > 0 then
    map[path] = true
    local vid = path:match("[?&]v=([%w%-_]+)") or path:match("youtu%.be/([%w%-_]+)")
    if vid then
      map["vid:" .. vid] = true
    end
  end
  if artist and title then
    map[normalize_key(artist, title)] = true
  end

  local count = 0
  for _ in pairs(map) do count = count + 1 end
  if count > 500 then
    map = {}
    if path and #path > 0 then map[path] = true end
    if artist and title then map[normalize_key(artist, title)] = true end
  end
  cliamp.store.set("auto_queued_keys", map)
end

local function is_auto_queued(item)
  if not item then return false end
  local map = auto_queued_map()
  if item.path and map[item.path] then
    return true
  end
  if item.path then
    local vid = item.path:match("[?&]v=([%w%-_]+)") or item.path:match("youtu%.be/([%w%-_]+)")
    if vid and map["vid:" .. vid] then
      return true
    end
  end
  if item.artist and item.title then
    local k = normalize_key(item.artist, item.title)
    if map[k] then
      return true
    end
  end
  return false
end

-- =========================================================================
-- Persistent History & MBID Cache
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

-- Cache artist name -> MusicBrainz artist MBID
local function get_cached_artist_mbid(artist_name)
  if not artist_name then return nil end
  local cache = cliamp.store.get("mbid_cache") or {}
  return cache[artist_name:lower()]
end

local function cache_artist_mbid(artist_name, mbid)
  if not artist_name or not mbid then return end
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
-- String Cleaning & Tag Stripping Utilities
-- =========================================================================

-- Clean common video fluff from YouTube titles
local function clean_video_fluff(s)
  if not s then return "" end
  local tag_patterns = {
    "%s*%([Oo]fficial%s+[Mm]usic%s+[Vv]ideo%)",
    "%s*%[[Oo]fficial%s+[Mm]usic%s+[Vv]ideo%]",
    "%s*%([Oo]fficial%s+[Vv]ideo%)",
    "%s*%[[Oo]fficial%s+[Vv]ideo%]",
    "%s*%([Oo]fficial%s+[Aa]udio%)",
    "%s*%[[Oo]fficial%s+[Aa]udio%]",
    "%s*%([Oo]fficial%s+[Vv]isualizer%)",
    "%s*%[[Oo]fficial%s+[Vv]isualizer%]",
    "%s*%([Oo]fficial%s+[Ll]yric%s+[Vv]ideo%)",
    "%s*%[[Oo]fficial%s+[Ll]yric%s+[Vv]ideo%]",
    "%s*%([Oo]fficial%s+[Hh][Dd]%s+[Vv]ideo%)",
    "%s*%[[Oo]fficial%s+[Hh][Dd]%s+[Vv]ideo%]",
    "%s*%([Ll]yric%s+[Vv]ideo%)",
    "%s*%[[Ll]yric%s+[Vv]ideo%]",
    "%s*%([Vv]isualizer%)",
    "%s*%[[Vv]isualizer%]",
    "%s*%([Aa]udio%)",
    "%s*%[[Aa]udio%]",
    "%s*%([Ll]yrics?%)",
    "%s*%[[Ll]yrics?%]",
    "%s*%([Mm]usic%s+[Vv]ideo%)",
    "%s*%[[Mm]usic%s+[Vv]ideo%]",
    "%s*%([Hh][Dd]%)",
    "%s*%[[Hh][Dd]%]",
    "%s*%([Hh][Qq]%)",
    "%s*%[[Hh][Qq]%]",
    "%s*%([4kK]%)",
    "%s*%[[4kK]%]",
    "%s*%([4kK]%s+[Uu][Hh][Dd]%)",
    "%s*%[[4kK]%s+[Uu][Hh][Dd]%]",
  }
  for _, pat in ipairs(tag_patterns) do
    s = s:gsub(pat, "")
  end
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Clean channel / topic tags from artist names
local function clean_artist_name(name)
  if not name then return "" end
  name = name:gsub("%s*%- Topic$", "")
  name = name:gsub("%s*VEVO$", "")
  name = name:gsub("%s*Official$", "")
  name = name:gsub("%s*Records$", "")
  name = name:gsub("%s*Music$", "")
  return (name:gsub("^%s*(.-)%s*$", "%1"))
end

-- Strip featured artists for cleaner MusicBrainz artist resolution
local function strip_featuring(artist)
  if not artist then return "" end
  local a = artist
  a = a:gsub("%s+[Ff][Tt]%.?%s+.*$", "")
  a = a:gsub("%s+[Ff][Ee][Aa][Tt]%.?%s+.*$", "")
  a = a:gsub("%s+[Ff][Ee][Aa][Tt][Uu][Rr][Ii][Nn][Gg]%s+.*$", "")
  a = a:gsub("%s*&%s+.*$", "")
  a = a:gsub("%s+[Ww][Ii][Tt][Hh]%s+.*$", "")
  return (a:gsub("^%s*(.-)%s*$", "%1"))
end

-- Split title string by hyphens (standard hyphen, en-dash, em-dash)
local function split_hyphens(str)
  if not str then return {} end
  local s = str:gsub("–", "-"):gsub("—", "-")
  local parts = {}
  for part in s:gmatch("[^%-]+") do
    local trimmed = part:gsub("^%s*(.-)%s*$", "%1")
    if #trimmed > 0 then
      parts[#parts + 1] = trimmed
    end
  end
  return parts
end

-- =========================================================================
-- MusicBrainz & ListenBrainz API Clients
-- =========================================================================

-- Look up artist MBID using MusicBrainz Search API
local function resolve_artist_mbid(artist_name)
  if not artist_name or #artist_name == 0 then return nil end
  local clean = clean_artist_name(artist_name)
  local cached = get_cached_artist_mbid(clean)
  if cached then return cached end

  local query = "artist:" .. urlencode(clean)
  local url = "https://musicbrainz.org/ws/2/artist/?query=" .. query .. "&fmt=json&limit=3"
  local ok, body, status = pcall(function()
    return cliamp.http.get(url, {
      headers = { ["User-Agent"] = USER_AGENT }
    })
  end)

  if not ok or status ~= 200 or not body then
    return nil
  end

  local dec_ok, data = pcall(cliamp.json.decode, body)
  if not dec_ok or type(data) ~= "table" or not data.artists or #data.artists == 0 then
    return nil
  end

  local clean_l = clean:lower()
  -- Try to find matching artist name in top results
  for i = 1, math.min(#data.artists, 3) do
    local a = data.artists[i]
    local name = a.name or ""
    local sort_name = a["sort-name"] or ""
    local score = tonumber(a.score) or 0
    if (name:lower() == clean_l or sort_name:lower() == clean_l) and score >= 70 then
      if a.id then
        cache_artist_mbid(clean, a.id)
        return a.id
      end
    end
  end

  -- If top score is 100, trust it
  local first = data.artists[1]
  if (tonumber(first.score) or 0) == 100 and first.id then
    cache_artist_mbid(clean, first.id)
    return first.id
  end

  -- Try stripping featuring / collaboration if present
  local stripped = strip_featuring(clean)
  if stripped ~= clean and #stripped > 0 then
    local s_cached = get_cached_artist_mbid(stripped)
    if s_cached then return s_cached end
    local sub_mbid = resolve_artist_mbid(stripped)
    if sub_mbid then
      cache_artist_mbid(clean, sub_mbid)
      return sub_mbid
    end
  end

  return nil
end

-- Fallback recording search on MusicBrainz (resolves ambiguous YouTube titles)
local function resolve_recording_mb(query_str)
  if not query_str or #query_str == 0 then return nil end
  local query = urlencode(query_str)
  local url = "https://musicbrainz.org/ws/2/recording/?query=" .. query .. "&fmt=json&limit=3"
  local ok, body, status = pcall(function()
    return cliamp.http.get(url, {
      headers = { ["User-Agent"] = USER_AGENT }
    })
  end)

  if not ok or status ~= 200 or not body then
    return nil
  end

  local dec_ok, data = pcall(cliamp.json.decode, body)
  if not dec_ok or type(data) ~= "table" or not data.recordings or #data.recordings == 0 then
    return nil
  end

  local rec = data.recordings[1]
  local score = tonumber(rec.score) or 0
  if score >= 70 and rec.title and rec["artist-credit"] and rec["artist-credit"][1] then
    local a_info = rec["artist-credit"][1]
    local a_name = a_info.name or (a_info.artist and a_info.artist.name)
    local a_id = a_info.artist and a_info.artist.id
    if a_name and #a_name > 0 then
      if a_id then
        cache_artist_mbid(a_name, a_id)
      end
      return {
        title = rec.title,
        artist = a_name,
        artist_mbid = a_id,
        recording_mbid = rec.id,
      }
    end
  end

  return nil
end

-- Parse raw YouTube title into artist, title, and mbid
local function parse_artist_and_title(raw_title, fallback_artist)
  local s = clean_video_fluff(raw_title or "")
  local parts = split_hyphens(s)

  if #parts == 0 then
    if fallback_artist and #fallback_artist > 0 then
      local ca = clean_artist_name(fallback_artist)
      return ca, raw_title, resolve_artist_mbid(ca)
    end
    return nil, raw_title, nil
  end

  if #parts == 1 then
    if fallback_artist and #fallback_artist > 0 then
      local ca = clean_artist_name(fallback_artist)
      return ca, parts[1], resolve_artist_mbid(ca)
    end
    -- Try recording search on MusicBrainz
    local rec = resolve_recording_mb(parts[1])
    if rec then
      return rec.artist, rec.title, rec.artist_mbid
    end
    return nil, parts[1], nil
  end

  if #parts == 2 then
    local p1 = clean_artist_name(parts[1])
    local p2 = clean_video_fluff(parts[2])
    local mbid = resolve_artist_mbid(p1)
    if not mbid and (p1:find("[Ff][Tt]%.?") or p1:find("&") or p1:find("[Ff][Ee][Aa][Tt]")) then
      mbid = resolve_artist_mbid(strip_featuring(p1))
    end
    if not mbid then
      local rec = resolve_recording_mb(s)
      if rec then
        return rec.artist, rec.title, rec.artist_mbid
      end
    end
    return p1, p2, mbid
  end

  -- #parts >= 3:
  -- Handle "channel - Artist - Title" (e.g. "mypassionfruit - Kinobe - Slip Into Something...")
  local p2_clean = clean_artist_name(parts[2])
  local mbid2 = resolve_artist_mbid(p2_clean)
  if mbid2 then
    local title_parts = {}
    for i = 3, #parts do
      title_parts[#title_parts + 1] = parts[i]
    end
    local title_str = clean_video_fluff(table.concat(title_parts, " - "))
    return p2_clean, title_str, mbid2
  end

  -- Handle "Artist - Title - Subtitle" (e.g. "Pink Floyd - Another Brick in the Wall - Part 2")
  local p1_clean = clean_artist_name(parts[1])
  local mbid1 = resolve_artist_mbid(p1_clean)
  if mbid1 then
    local title_parts = {}
    for i = 2, #parts do
      title_parts[#title_parts + 1] = parts[i]
    end
    local title_str = clean_video_fluff(table.concat(title_parts, " - "))
    return p1_clean, title_str, mbid1
  end

  -- Fallback to recording search
  local rec = resolve_recording_mb(s)
  if rec then
    return rec.artist, rec.title, rec.artist_mbid
  end

  -- Final fallback: part 1 as artist, remainder as title
  local fallback_title_parts = {}
  for i = 2, #parts do
    fallback_title_parts[#fallback_title_parts + 1] = parts[i]
  end
  return p1_clean, clean_video_fluff(table.concat(fallback_title_parts, " - ")), nil
end

-- Extract clean metadata from currently playing track or item
local function extract_clean_metadata(item)
  -- 1. Try currently playing track from cliamp.track
  local ok_t, t_artist = pcall(cliamp.track.artist)
  local ok_tt, t_title = pcall(cliamp.track.title)

  if ok_t and t_artist and type(t_artist) == "string" and #t_artist > 0 and not t_artist:find("%- Topic$") and t_artist ~= "Topic" then
    local clean_a = clean_artist_name(t_artist)
    local clean_t = clean_video_fluff(t_title or "")
    local mbid = resolve_artist_mbid(clean_a)
    return clean_a, clean_t, mbid
  end

  if ok_tt and t_title and type(t_title) == "string" and #t_title > 0 and t_title ~= "watch" then
    local a, t, m = parse_artist_and_title(t_title, (ok_t and t_artist) or nil)
    if a and #a > 0 then
      return a, t, m
    end
  end

  -- 2. Try item from queue list
  if item then
    local artist = item.artist
    local title = item.title

    if artist and type(artist) == "string" and #artist > 0 and not artist:find("%- Topic$") and artist ~= "Topic" then
      local clean_a = clean_artist_name(artist)
      local clean_t = clean_video_fluff(title or "")
      local mbid = resolve_artist_mbid(clean_a)
      return clean_a, clean_t, mbid
    end

    if title and type(title) == "string" and #title > 0 and title ~= "watch" then
      local a, t, m = parse_artist_and_title(title, artist)
      if a and #a > 0 then
        return a, t, m
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
          local a, t, m = parse_artist_and_title(data.title, data.author_name)
          if a and #a > 0 then
            return a, t, m
          end
        end
      end
    end
  end

  return nil, nil, nil
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
    local vid = body:match('{"videoRenderer":{"videoId":"([%w%-_]+)"') or body:match('"videoId":"([%w%-_]+)"')
    if vid and #vid == 11 then
      return vid
    end
  end
  return nil
end

local function resolve_track_video_id(artist, title)
  if RESOLVER == "http" or RESOLVER == "auto" then
    local ok, vid = pcall(resolve_via_http, artist, title)
    if ok and vid then return vid end
  end
  return nil
end

-- =========================================================================
-- Core Refill Engine (Station Seed Driven)
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
  local st_artist, st_mbid = get_station_seed()

  -- Check if the current track was manually started by user
  -- (i.e. not queued by listenbrainz-radio, or no station seed exists)
  local is_manual = false
  if cur_item and not is_auto_queued(cur_item) then
    is_manual = true
  end

  if is_manual or not st_artist then
    local a, t, m = extract_clean_metadata(cur_item)
    if a and #a > 0 then
      if a ~= st_artist then
        cliamp.log.info(("lb-radio: manual track detected (%s - %s), anchoring station seed to %q"):format(a, t or "", a))
        set_station_seed(a, m)
        set_buffered_recs({}) -- clear buffer so recommendations match new seed
        st_artist, st_mbid = a, m
      end
    end
  end

  if not st_artist then
    cliamp.log.warn("lb-radio: could not determine station seed artist")
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
      cliamp.log.info(("lb-radio: fetching explore radio for station seed %q (mode: %s)"):format(st_artist, mode))
      fresh = fetch_lb_explore_radio(st_artist, mode, LB_TOKEN)
    end

    if #fresh == 0 then
      cliamp.log.info(("lb-radio: fetching artist radio for station seed %q (mode: %s)"):format(st_artist, mode))
      local artist_mbid = st_mbid or resolve_artist_mbid(st_artist)
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
          -- In cliamp >= 2.1.0, queue.add accepts a table with clean metadata
          local ok_add = pcall(cliamp.queue.add, {
            path   = track_url,
            title  = item.title,
            artist = item.artist,
          })
          if not ok_add then
            cliamp.queue.add(track_url)
          end
          -- Mark this track as auto-queued so playing it won't overwrite station seed
          mark_auto_queued(track_url, item.artist, item.title)
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
    cliamp.log.info(("lb-radio: added %d tracks (station seed: %s, mode: %s)"):format(added_count, st_artist, mode))
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

p:command("station", function(args)
  local arg = nil
  if type(args) == "table" then
    arg = table.concat(args, " ")
  elseif type(args) == "string" then
    arg = args
  end
  arg = clean_str(arg)
  if arg and #arg > 0 then
    local mbid = resolve_artist_mbid(arg)
    set_station_seed(arg, mbid)
    set_buffered_recs({})
    refill(true)
    return ("listenbrainz-radio: station seed manually set to %q (mbid: %s)"):format(arg, tostring(mbid or "unresolved"))
  end
  local st_artist, st_mbid = get_station_seed()
  if not st_artist then
    return "listenbrainz-radio: no station seed currently set"
  end
  return ("listenbrainz-radio: station seed = %q (mbid: %s, mode: %s)"):format(
    st_artist, tostring(st_mbid or "none"), get_active_mode()
  )
end)

p:command("status", function()
  local st_artist, st_mbid = get_station_seed()
  return ("listenbrainz-radio: station=%q | auto=%s | mode=%s | ahead=%d/%d | history=%d buffer=%d"):format(
    st_artist or "(none)", auto_on() and "on" or "off", get_active_mode(), MIN_AHEAD, BATCH, #history(), #get_buffered_recs()
  )
end)

p:command("clear", function()
  cliamp.store.set("recent_keys", {})
  cliamp.store.set("buffered_recs", {})
  return "listenbrainz-radio: history and buffer cleared"
end)

p:command("reset", function()
  clear_station_seed()
  cliamp.store.set("auto_queued_keys", {})
  cliamp.store.set("recent_keys", {})
  cliamp.store.set("buffered_recs", {})
  return "listenbrainz-radio: station seed, history, and recommendation buffer reset"
end)
