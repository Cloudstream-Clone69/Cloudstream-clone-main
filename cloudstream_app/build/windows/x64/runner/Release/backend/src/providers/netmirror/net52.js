/**
 * NetMirror / net52.cc Provider
 *
 * BYPASS MECHANISM (reverse-engineered from CNCVerse Utils.kt source):
 *   POST https://net52.cc/verify.php
 *   Body: g-recaptcha-response=<random-UUID>
 *   Headers: Origin: https://net22.cc, Referer: https://net22.cc/verify2
 *   Response: Set-Cookie: t_hash_t=...  (Max-Age=259200 = 3 DAYS)
 *
 * This is the exact same bypass the official NetMirror/CNCVerse Android app uses.
 * The g-recaptcha-response value is a random UUID — the server does not actually
 * verify it, it just issues a valid session token.
 *
 * VERIFIED working: 2026-07-13 via live testing
 *
 * FLOW:
 *  1. POST /verify.php (bypass) → get t_hash_t cookie (valid 3 days)
 *  2. GET /mobile/{ott}/search.php → search for content
 *  3. GET /mobile/{ott}/playlist.php → get m3u8 URLs (server generates in= token)
 *  4. Play m3u8 with correct headers → real multi-audio HLS, no warning video
 */

import { createDirectAxios } from '../../services/dnsAxios.js';
import crypto from 'crypto';
import fs from 'fs';
import path from 'path';

const axios = createDirectAxios();

// ── REMOTE CONFIG (from GitHub app_status.json) ───────────────────────────────

const APP_STATUS_URL = 'https://raw.githubusercontent.com/Cloudstream-Clone69/Cloudstream-clone-main/main/app_status.json';
const CONFIG_TTL_MS = 60 * 60 * 1000; // re-fetch config every 1 hour

/** Hardcoded fallback defaults — used if GitHub is unreachable */
const DEFAULTS = {
  base_url:        'https://net52.cc',
  ua_webview:      'Mozilla/5.0 (Linux; Android 13; Pixel 5 Build/TQ3A.230901.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/149.0.7827.91 Safari/537.36 /OS.Gatu v3.0',
  ua_desktop:      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36',
  x_requested_with:'app.netmirror.netmirrornew',
  referer_home:    'https://net52.cc/mobile/home?app=1',
  referer_browse:  'https://net52.cc/home',
  bypass: {
    url:         'https://net52.cc/verify.php',
    origin:      'https://net22.cc',
    referer:     'https://net22.cc/verify2',
    cookie_name: 't_hash_t',
  },
  ott: {
    nf: { search: '/mobile/search.php',    playlist: '/mobile/playlist.php'    },
    hs: { search: '/mobile/hs/search.php', playlist: '/mobile/hs/playlist.php' },
    pv: { search: '/mobile/pv/search.php', playlist: '/mobile/pv/playlist.php' },
  },
};

let remoteConfig   = null; // loaded from GitHub
let configFetchedAt = 0;
let configFetching  = null; // in-flight lock

/**
 * Fetch the netmirror block from app_status.json on GitHub.
 * Falls back to DEFAULTS silently if GitHub is unreachable.
 * Result is cached for 1 hour — no GitHub hit on every request.
 */
async function getRemoteConfig() {
  // Return cached config if still fresh
  if (remoteConfig && Date.now() - configFetchedAt < CONFIG_TTL_MS) {
    return remoteConfig;
  }
  // Deduplicate concurrent fetches
  if (configFetching) return configFetching;

  configFetching = (async () => {
    try {
      const res = await axios.get(APP_STATUS_URL, { timeout: 5000 });
      const nm  = res.data?.netmirror;
      if (nm && nm.enabled !== false) {
        remoteConfig    = nm;
        configFetchedAt = Date.now();
        console.log('[Net52] Remote config loaded from GitHub app_status.json');
      } else {
        console.warn('[Net52] netmirror block missing/disabled in app_status.json — using defaults');
        remoteConfig = DEFAULTS;
      }
    } catch (err) {
      console.warn('[Net52] Could not fetch app_status.json (' + err.message + ') — using defaults');
      if (!remoteConfig) remoteConfig = DEFAULTS; // keep previous if already loaded
    }
    configFetching = null;
    return remoteConfig;
  })();

  return configFetching;
}

/** Convenience getters — always use these instead of bare constants */
const cfg = {
  get baseUrl()      { return (remoteConfig || DEFAULTS).base_url; },
  get uaWebview()    { return (remoteConfig || DEFAULTS).ua_webview; },
  get uaDesktop()    { return (remoteConfig || DEFAULTS).ua_desktop; },
  get xrw()          { return (remoteConfig || DEFAULTS).x_requested_with; },
  get refererHome()  { return (remoteConfig || DEFAULTS).referer_home; },
  get refererBrowse(){ return (remoteConfig || DEFAULTS).referer_browse; },
  get bypass()       { return (remoteConfig || DEFAULTS).bypass; },
  get ott()          { return (remoteConfig || DEFAULTS).ott; },
  /** Premium ::m token from GitHub config — works for ALL OTTs (Netflix, Hotstar, PrimeVideo) */
  get mToken()       { return (remoteConfig || DEFAULTS).m_token || null; },
};


export const mainUrl = 'https://net52.cc'; // kept for backwards compat


// ── SESSION MANAGEMENT ────────────────────────────────────────────────────────

/** Cache for in-memory session (per-ott). Shared across requests. */
/**
 * Single universal token cache — token from verify.php works for ALL OTT platforms.
 * A lock prevents multiple simultaneous bypass calls on first load.
 */
const tokenCache = { token: null, expiresAt: 0 };
const deadTokens = new Set();
let bypassInProgress = null; // Promise lock

/** ~2.9 days (server gives 3 days, we refresh 2h early) */
const SESSION_TTL_MS = (3 * 24 * 60 - 120) * 60 * 1000;

const SETTINGS_PATH = path.join(process.cwd(), 'app-settings.json');

/** Read token from app-settings.json if available */
function readStoredToken() {
  try {
    if (fs.existsSync(SETTINGS_PATH)) {
      // Strip BOM if present
      let raw = fs.readFileSync(SETTINGS_PATH, 'utf8').replace(/^\uFEFF/, '');
      const s = JSON.parse(raw);
      const tok = s.netmirrorTHashVerify || s.netmirrorCookie || '';
      if (tok && tok.includes('::') && !tok.includes('unknown')) return tok;
    }
  } catch (_) {}
  return null;
}

/** Persist token to app-settings.json for reuse across restarts */
function storeToken(token) {
  try {
    let s = {};
    if (fs.existsSync(SETTINGS_PATH)) {
      const raw = fs.readFileSync(SETTINGS_PATH, 'utf8').replace(/^\uFEFF/, '');
      s = JSON.parse(raw);
    }
    s.netmirrorTHashVerify = token;
    s.netmirrorTHashVerifyAt = Date.now();
    fs.writeFileSync(SETTINGS_PATH, JSON.stringify(s, null, 2), 'utf8');
    console.log('[Net52] Token persisted to app-settings.json');
  } catch (e) {
    console.warn('[Net52] Failed to persist token:', e.message);
  }
}

/**
 * THE BYPASS — POST /verify.php with fake g-recaptcha-response = random UUID.
 * All parameters are read from the remote config (app_status.json on GitHub).
 * Falls back to hardcoded defaults if GitHub is unreachable.
 */
async function doVerifyBypass() {
  // Always ensure config is loaded before bypass
  const config = await getRemoteConfig();
  const bypassCfg = config.bypass || DEFAULTS.bypass;

  const uuid = crypto.randomUUID();
  console.log('[Net52] Running bypass →', bypassCfg.url, '| UUID:', uuid.substring(0, 18) + '...');

  const res = await axios.post(
    bypassCfg.url,
    'g-recaptcha-response=' + uuid,
    {
      headers: {
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
        'Accept-Encoding': 'gzip, deflate, br, zstd',
        'Accept-Language': 'en-US,en;q=0.9',
        'Cache-Control': 'max-age=0',
        'Connection': 'keep-alive',
        'Content-Type': 'application/x-www-form-urlencoded',
        'Origin': bypassCfg.origin,
        'Referer': bypassCfg.referer,
        'sec-ch-ua': '"Google Chrome";v="147", "Not.A/Brand";v="8", "Chromium";v="147"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"Windows"',
        'Sec-Fetch-Dest': 'document',
        'Sec-Fetch-Mode': 'navigate',
        'Sec-Fetch-Site': 'same-origin',
        'Sec-Fetch-User': '?1',
        'Upgrade-Insecure-Requests': '1',
        'User-Agent': cfg.uaDesktop,
      },
      maxRedirects: 0,
      validateStatus: (s) => s < 400,
      timeout: 10000,
    }
  );

  const cookieName = bypassCfg.cookie_name || 't_hash_t';
  const allCookies = res.headers['set-cookie'] || [];
  const arr = Array.isArray(allCookies) ? allCookies : [allCookies];
  const tHashCookie = arr.find(c => c.startsWith(cookieName + '='));

  if (!tHashCookie) {
    throw new Error('[Net52] bypass did not return ' + cookieName + ' cookie. Got: ' + arr.join(', ').substring(0, 200));
  }

  const token = decodeURIComponent(tHashCookie.split(';')[0].replace(cookieName + '=', ''));
  if (!token || token.includes('unknown')) {
    throw new Error('[Net52] bypass returned invalid token: ' + token);
  }

  console.log('[Net52] ✅ Bypass OK! Token:', token.substring(0, 40) + '...');
  return token;
}

/**
 * Get a valid t_hash_t token. Priority:
 *  1. ::m premium token from GitHub app_status.json — works for ALL OTTs (Netflix, Hotstar, PV)
 *  2. Universal in-memory cache (if not expired)
 *  3. Persisted in app-settings.json (survives restarts, valid 3 days)
 *  4. Fresh verify.php bypass (POST) — ::99 tier, works for PrimeVideo only
 */
export async function getToken(ott = 'pv', forceRefresh = false) {
  // Priority 1: Universal in-memory cache (fastest)
  if (!forceRefresh && tokenCache.token && Date.now() < tokenCache.expiresAt) {
    if (!deadTokens.has(tokenCache.token)) {
      return tokenCache.token;
    } else {
      console.log('[Net52] Cached token is blacklisted, ignoring');
      tokenCache.token = null;
      tokenCache.expiresAt = 0;
    }
  }

  // Priority 2: Stored / Manually Injected token from app-settings.json
  // This ensures the local Token Injector web page (Option 1) works instantly!
  if (!forceRefresh) {
    const stored = readStoredToken();
    if (stored) {
      if (!deadTokens.has(stored)) {
        const parts = stored.split('::');
        const ts = parts[2] ? parseInt(parts[2], 10) * 1000 : 0;
        const age = Date.now() - ts;
        if (age < SESSION_TTL_MS) {
          console.log('[Net52] Using fresh injected/stored token (age: ' + Math.round(age / 3600000) + 'h)');
          tokenCache.token = stored;
          tokenCache.expiresAt = ts + SESSION_TTL_MS;
          return stored;
        }
        console.log('[Net52] Stored token expired, checking other options...');
      } else {
        console.log('[Net52] Stored token is blacklisted, ignoring');
      }
    }
  }

  // Priority 3: ::m premium token from remote GitHub config (community fallback)
  if (!forceRefresh) {
    try {
      await getRemoteConfig(); // ensure config is loaded
      const mToken = cfg.mToken;
      if (mToken && mToken.includes('::m')) {
        if (!deadTokens.has(mToken)) {
          const parts = mToken.split('::');
          const ts = parts[2] ? parseInt(parts[2], 10) * 1000 : 0;
          const age = Date.now() - ts;
          if (age < SESSION_TTL_MS) {
            console.log('[Net52] Using ::m premium token from GitHub config ✅');
            tokenCache.token = mToken;
            tokenCache.expiresAt = ts + SESSION_TTL_MS;
            return mToken;
          }
        } else {
          console.log('[Net52] GitHub token is blacklisted, ignoring');
        }
      }
    } catch (err) {
      console.warn('[Net52] Remote config check failed:', err.message);
    }
  }

  // Priority 4: Fresh verify.php bypass (::99 tier fallback)
  if (bypassInProgress) {
    console.log('[Net52] Bypass already in progress, waiting...');
    return bypassInProgress;
  }

  bypassInProgress = doVerifyBypass().then(token => {
    tokenCache.token = token;
    tokenCache.expiresAt = Date.now() + SESSION_TTL_MS;
    storeToken(token);
    bypassInProgress = null;
    return token;
  }).catch(err => {
    bypassInProgress = null;
    throw err;
  });

  return bypassInProgress;
}


function buildCookie(token, ott) {
  return 't_hash_t=' + encodeURIComponent(token) + '; ott=' + ott + '; hd=on;';
}


// ── SEARCH ─────────────────────────────────────────────────────────────────────

/**
 * Search net52.cc for content on a given OTT platform.
 * Verified endpoint from Frida: /mobile/{ott}/search.php?s={q}&t={unixts}
 */
export async function searchNet52(query, ott = 'pv') {
  const token = await getToken(ott);
  await getRemoteConfig(); // ensure config is loaded
  const ottPaths = cfg.ott[ott] || cfg.ott.pv;
  const timestamp = Math.floor(Date.now() / 1000);
  const url = cfg.baseUrl + ottPaths.search + '?s=' + encodeURIComponent(query) + '&t=' + timestamp;

  try {
    const res = await axios.get(url, {
      headers: {
        'user-agent': cfg.uaDesktop,
        'referer': cfg.refererBrowse,
        'Cache-Control': 'max-age=0',
        'Connection': 'Keep-Alive',
        'Accept-Encoding': 'gzip',
        'cookie': buildCookie(token, ott),
      },
      timeout: 8000,
    });
    return (res.data?.searchResult || []).map(item => ({ id: item.id, title: item.t, ott }));
  } catch (err) {
    console.error('[Net52] search error (' + ott + '):', err.message);
    return [];
  }
}

// ── PLAYLIST (GETS SERVER-GENERATED in= TOKEN) ─────────────────────────────────

/**
 * Call playlist.php — server returns m3u8 URLs with the in= token already embedded.
 * Verified from Frida REQ #4323 and live testing.
 */
export async function getPlaylist(contentId, title, ott = 'pv', forceRefresh = false) {
  const token = await getToken(ott, forceRefresh);
  await getRemoteConfig(); // ensure config is loaded
  const ottPaths = cfg.ott[ott] || cfg.ott.pv;
  const timestamp = Math.floor(Date.now() / 1000);
  const url = cfg.baseUrl + ottPaths.playlist +
    '?id=' + encodeURIComponent(contentId) +
    '&t=' + encodeURIComponent(title || contentId) +
    '&tm=' + timestamp;

  console.log('[Net52] playlist.php =>', url);
  const res = await axios.get(url, {
    headers: {
      'user-agent': cfg.uaWebview,
      'accept': '*/*',
      'accept-language': 'en-IN,en-US;q=0.9,en;q=0.8',
      'connection': 'keep-alive',
      'referer': cfg.refererHome,
      'sec-ch-ua': '"Android WebView";v="149", "Chromium";v="149", "Not)A;Brand";v="24"',
      'sec-ch-ua-mobile': '?0',
      'sec-ch-ua-platform': '"Android"',
      'sec-fetch-dest': 'empty',
      'sec-fetch-mode': 'cors',
      'sec-fetch-site': 'same-origin',
      'x-requested-with': cfg.xrw,
      'Cache-Control': 'max-age=0',
      'Accept-Encoding': 'gzip',
      'cookie': buildCookie(token, ott),
    },
    timeout: 12000,
  });

  const playlist = Array.isArray(res.data) ? res.data[0] : res.data;
  if (!playlist) throw new Error('[Net52] playlist.php returned empty for ' + contentId);

  const sources = (playlist.sources || []).map(s => ({
    url: s.file.startsWith('http') ? s.file : mainUrl + s.file,
    label: s.label || 'Auto',
    type: s.type || 'application/vnd.apple.mpegurl',
    isDefault: s.default === 'true' || s.default === true,
  }));

  const tracks = (playlist.tracks || []).map(t => ({
    url: t.file.startsWith('//') ? 'https:' + t.file : t.file,
    label: t.label || 'Unknown',
    kind: t.kind || 'captions',
  }));

  return { title: playlist.title || title, poster: playlist.image2 || null, sources, tracks, token, ott };
}

// ── FULL PIPELINE ─────────────────────────────────────────────────────────────

/**
 * Complete stream resolver: bypass → search → playlist → return stream.
 * @param {string} query - Title to search for
 * @param {string} ott - 'nf' | 'hs' | 'pv'
 * @param {string} [preferredId] - Skip search if you know the content ID
 */
export async function resolveStream(query, ott = 'pv', preferredId = null) {
  let contentId = preferredId;
  let contentTitle = query;

  if (!contentId) {
    console.log('[Net52] Searching for "' + query + '" on ' + ott + '...');
    const results = await searchNet52(query, ott);
    if (results.length === 0) throw new Error('[Net52] No results for "' + query + '" on ' + ott);
    const best = results.find(r => r.title.toLowerCase().includes(query.toLowerCase())) || results[0];
    contentId = best.id;
    contentTitle = best.title;
    console.log('[Net52] Found: "' + contentTitle + '" id=' + contentId);
  }

  const playlist = await getPlaylist(contentId, contentTitle, ott);
  if (!playlist.sources || playlist.sources.length === 0) {
    throw new Error('[Net52] No sources from playlist.php for ' + contentId);
  }

  const playbackHeaders = {
    'user-agent': cfg.uaWebview,
    'referer': cfg.refererHome,
    'x-requested-with': cfg.xrw,
    'accept': '*/*',
    'accept-language': 'en-IN,en-US;q=0.9,en;q=0.8',
    'sec-fetch-dest': 'empty',
    'sec-fetch-mode': 'cors',
    'sec-fetch-site': 'same-origin',
    'cookie': buildCookie(playlist.token, ott),
  };

  console.log('[Net52] Resolved', playlist.sources.length, 'sources,', playlist.tracks.length, 'subtitles for "' + contentTitle + '"');
  return { title: playlist.title, poster: playlist.poster, sources: playlist.sources, tracks: playlist.tracks, headers: playbackHeaders, ott, token: playlist.token };
}

// ── BACKWARDS-COMPAT (keeps existing index.js working) ───────────────────────

/** Used by index.js via fetchHlsWithToken */
export async function fetchHlsWithToken(contentId, ott) {
  try {
    const playlist = await getPlaylist(contentId, contentId, ott);
    if (!playlist.sources || playlist.sources.length === 0) return null;
    const autoSource = playlist.sources.find(s => !s.url.includes('q=')) || playlist.sources[0];
    const headers = {
      'user-agent': cfg.uaWebview,
      'referer': cfg.refererHome,
      'x-requested-with': cfg.xrw,
      'cookie': buildCookie(playlist.token, ott),
    };
    const testRes = await axios.get(autoSource.url, { headers, timeout: 8000, validateStatus: () => true });
    const m3u8 = typeof testRes.data === 'string' ? testRes.data : '';
    // Detect warning/rate-limit video: freecdn4, unknown::ni in URL, or short manifest (<300 chars)
    const isWarningVideo = m3u8.includes('freecdn4') ||
      autoSource.url.includes('unknown%3A%3Ani') ||
      autoSource.url.includes('unknown::ni') ||
      m3u8.includes('warning') ||
      (m3u8.length > 0 && m3u8.length < 300 && !m3u8.includes('#EXT-X-STREAM-INF'));
    if (isWarningVideo) {
      console.warn('[Net52] Warning video detected — blacklisting token and forcing refresh:', playlist.token.substring(0, 30) + '...');
      deadTokens.add(playlist.token);
      tokenCache.token = null; // reset universal cache
      tokenCache.expiresAt = 0;
      // Clear stored dead token so bypass runs fresh
      try {
        if (fs.existsSync(SETTINGS_PATH)) {
          const raw = fs.readFileSync(SETTINGS_PATH, 'utf8').replace(/^\uFEFF/, '');
          const s = JSON.parse(raw);
          s.netmirrorTHashVerify = null;
          fs.writeFileSync(SETTINGS_PATH, JSON.stringify(s, null, 2), 'utf8');
        }
      } catch (_) {}
      const retry = await getPlaylist(contentId, contentId, ott, true);
      const rs = retry.sources.find(s => !s.url.includes('q=')) || retry.sources[0];
      return { type: 'hls', hlsUrl: rs.url, cdnToken: retry.token, audioTracks: [], variants: retry.sources, contentId };
    }
    const audioTracks = [];
    for (const line of m3u8.split('\n')) {
      if (line.startsWith('#EXT-X-MEDIA:TYPE=AUDIO')) {
        const l = line.match(/LANGUAGE="([^"]+)"/), n = line.match(/NAME="([^"]+)"/), u = line.match(/URI="([^"]+)"/);
        if (l && n && u) audioTracks.push({ lang: l[1], name: n[1], default: line.includes('DEFAULT=YES'), uri: u[1] });
      }
    }
    console.log('[Net52] ✅ HLS OK for', contentId, '—', audioTracks.length, 'audio tracks');
    return { type: 'hls', hlsUrl: autoSource.url, cdnToken: playlist.token, audioTracks, variants: playlist.sources, contentId };
  } catch (err) {
    console.warn('[Net52] fetchHlsWithToken failed for ' + contentId + ':', err.message);
    return null;
  }
}

export const net52MainUrl = mainUrl;

// ── LEGACY SEARCH EXPORT ──────────────────────────────────────────────────────
export const search = async (query, ott) => {
  const results = await searchNet52(query, ott);
  return results.map(r => ({
    title: r.title,
    url: JSON.stringify({ id: r.id }),
    poster: 'https://imgcdn.kim/' + (ott === 'nf' ? 'poster' : ott) + '/v/' + r.id + '.jpg',
  }));
};

// ── SESSION INJECTION & RESET (for app.js integration) ─────────────────────────
export async function injectToken(token) {
  try {
    const decoded = decodeURIComponent(token);
    tokenCache.token = decoded;
    tokenCache.expiresAt = Date.now() + SESSION_TTL_MS;
    storeToken(decoded);
    console.log('[Net52] Manually injected token:', decoded.substring(0, 40) + '...');
    return { ok: true, message: 'Token injected successfully', token: decoded };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

export async function resetSession() {
  try {
    // Clear BOTH in-memory cache AND persisted token so verify.php runs fresh
    tokenCache.token = null;
    tokenCache.expiresAt = 0;
    // Wipe stored token from file so it doesn't re-surface in getToken()
    try {
      if (fs.existsSync(SETTINGS_PATH)) {
        const raw = fs.readFileSync(SETTINGS_PATH, 'utf8').replace(/^\uFEFF/, '');
        const s = JSON.parse(raw);
        s.netmirrorTHashVerify = null;
        s.netmirrorTHashVerifyAt = 0;
        fs.writeFileSync(SETTINGS_PATH, JSON.stringify(s, null, 2), 'utf8');
        console.log('[Net52] Cleared stored token from app-settings.json');
      }
    } catch (_) {}
    const token = await getToken('pv', true);
    return { ok: true, source: 'verify.php', token };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

/**
 * Sync fresh ::m token directly from BlueStacks/Android device via ADB.
 * Call this after a Frida session to get the best quality token.
 * Falls back gracefully if ADB is unavailable.
 */
export async function syncTokenFromDevice() {
  const { exec } = await import('child_process');
  const { promisify } = await import('util');
  const execAsync = promisify(exec);
  try {
    // Try to read NetflixMirrorPrefsMobile.xml from device
    const adbCmd = 'adb exec-out "su -c cat /data/data/com.lagradost.cloudstream3/shared_prefs/NetflixMirrorPrefsMobile.xml"';
    const { stdout } = await execAsync(adbCmd, { timeout: 8000 });
    const match = stdout.match(/name="nf_cookie"[^>]*>([^<]+)</);
    if (!match) throw new Error('nf_cookie not found in device prefs');
    const rawToken = decodeURIComponent(match[1].trim());
    if (!rawToken.includes('::') || rawToken.includes('unknown')) {
      throw new Error('Invalid token from device: ' + rawToken);
    }
    tokenCache.token = rawToken;
    tokenCache.expiresAt = Date.now() + SESSION_TTL_MS;
    storeToken(rawToken);
    console.log('[Net52] ✅ Synced ::m token from device:', rawToken.substring(0, 40) + '...');
    return { ok: true, token: rawToken, source: 'adb_device' };
  } catch (e) {
    console.warn('[Net52] ADB device sync failed:', e.message);
    return { ok: false, error: e.message };
  }
}

