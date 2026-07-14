import express from "express";
import cors from "cors";

import providersRoute from "./routes/providers.js";
import searchRoute from "./routes/search.js";
import searchAllRoute from "./routes/searchAll.js";
import detailsRoute from "./routes/details.js";
import streamRoute from "./routes/stream.js";
import proxyRoute from "./routes/proxy.js";
import homeRoute from "./routes/home.js";
import settingsRoute from "./routes/settings.js";
import sportsRoute from "./routes/sports.js";
import subtitlesRoute from "./routes/subtitles.js";
import tmdbRoute from "./routes/tmdb.js";
import malRoute from "./routes/mal.js";
import historyRoute from "./routes/history.js";

// ---------- AUTO‑UPDATE ----------
import { checkForUpdates, downloadAndUpdate } from "../src/updater.js";   // adjust path if needed
import { dnsAxios as sfAxios } from "./services/dnsAxios.js";
import { fetchHTML } from "./providers/common.js";
import { resetSession } from "./providers/netmirror/net52.js";

import { readFileSync, existsSync } from 'fs';
import { join } from 'path';

// ── app_status.json cache (5-min TTL) ────────────────────────────────────────
// Fetching from GitHub on EVERY request added 500-2000ms latency. Cache it.
let _appStatusCache = null;
let _appStatusTs    = 0;
const APP_STATUS_TTL = 5 * 60 * 1000; // 5 minutes

async function getAppStatus(ax) {
  const now = Date.now();
  if (_appStatusCache && (now - _appStatusTs) < APP_STATUS_TTL) return _appStatusCache;
  try {
    const cfg = await ax.get(
      'https://raw.githubusercontent.com/Cloudstream-Clone69/Cloudstream-clone-main/main/app_status.json',
      { timeout: 6000 }
    );
    _appStatusCache = cfg.data;
    _appStatusTs    = now;
    return _appStatusCache;
  } catch (_) {
    return _appStatusCache || null; // serve stale cache on error rather than failing
  }
}

const app = express();

// Explicitly allow all origins including file:// (null origin)
app.use(cors({
  origin: (origin, cb) => cb(null, true),
  credentials: true
}));
app.use(express.json());

// ---------- PLAYIT DEMO PLAYER (served same-origin to avoid file:// CORS) ----------
app.get("/", (req, res) => res.redirect("/player"));

app.get("/player", (req, res) => {
  res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, private');
  res.setHeader('Expires', '-1');
  res.setHeader('Pragma', 'no-cache');

  const paths = [
    'C:\\Users\\ayu12\\Desktop\\playit-demo\\index.html',
    join(process.cwd(), '..', '..', '..', '..', 'playit-demo', 'index.html'),
  ];
  for (const p of paths) {
    if (existsSync(p)) {
      let html = readFileSync(p, 'utf8');
      // Patch API constant to use relative path (same origin)
      html = html.replace(
        /const API\s*=\s*['"]http:\/\/127\.0\.0\.1:3000['"]/,
        "const API = ''"  // relative — same server
      );
      return res.type('html').send(html);
    }
  }
  res.status(404).send('Player not found at C:\\Users\\ayu12\\Desktop\\playit-demo\\index.html');
});

// Existing routes
app.use("/providers", providersRoute);
app.use("/search", searchRoute);
app.use("/search-all", searchAllRoute);
app.use("/details", detailsRoute);
app.use("/stream", streamRoute);
app.use("/proxy", proxyRoute);
app.use("/home", homeRoute);
app.use("/sports", sportsRoute);
app.use("/api/settings", settingsRoute);
app.use("/api/history", historyRoute);
app.use("/subtitles", subtitlesRoute);
app.use("/tmdb", tmdbRoute);
app.use("/mal", malRoute);

// Health check
app.get("/health", (req, res) => res.json({ ok: true, ts: Date.now() }));

// ---------- PLAYIT GLOBAL SEARCH ----------
// GET /api/player/search?q=The+Boys&type=tv
// Returns TMDB results + net52 availability across all OTTs
app.get("/api/player/search", async (req, res) => {
  const { dnsAxios: ax } = await import("./services/dnsAxios.js");
  const { q, type = "multi" } = req.query;
  if (!q) return res.status(400).json({ error: "Missing query" });

  const UA  = "Mozilla/5.0 (Linux; Android 13; Pixel 5 Build/TQ3A.230901.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/149.0.7827.91 Safari/537.36 /OS.Gatu v3.0";
  const ts  = Math.floor(Date.now() / 1000);

  // 1. Get m_token
  let M_TOKEN = "";
  try {
    const cfg = await ax.get("https://raw.githubusercontent.com/Cloudstream-Clone69/Cloudstream-clone-main/main/app_status.json", { timeout: 5000 });
    M_TOKEN = cfg.data?.netmirror?.m_token || "";
  } catch (_) {}

  // 2. TMDB search
  let tmdbResults = [];
  try {
    const searchType = type === "tv" ? "tv" : type === "movie" ? "movie" : "multi";
    const tmdbRes = await ax.get(
      `http://api.tmdb.org/3/search/${searchType}?query=${encodeURIComponent(q)}&page=1`,
      {
        headers: {
          Authorization: `Bearer eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJhYjY1OWFlMjQwYmM5ZGZmMTJhYWFiZjI2ZDdjZDVmMCIsIm5iZiI6MTc4MDQxNzkwMi4yNDk5OTk4LCJzdWIiOiI2YTFmMDU2ZTg4ZDU2ZDA5ZDgyNTBmYTgiLCJzY29wZXMiOlsiYXBpX3JlYWQiXSwidmVyc2lvbiI6MX0.BaaZkYd0cK84S-P2vujy5qUYYc2MM3BUkrosxG5dOZM`,
          Accept: "application/json"
        },
        timeout: 8000
      }
    );
    tmdbResults = (tmdbRes.data?.results || []).slice(0, 12).map(r => ({
      tmdbId:    r.id,
      title:     r.title || r.name || "",
      year:      (r.release_date || r.first_air_date || "").substring(0, 4),
      poster:    r.poster_path ? "https://image.tmdb.org/t/p/w300" + r.poster_path : "",
      type:      r.media_type || (r.first_air_date ? "tv" : "movie"),
      rating:    r.vote_average?.toFixed(1) || "?",
      overview:  (r.overview || "").substring(0, 120),
    }));
  } catch (_) {}

  // 3. For top 6 results, check net52 availability across all OTTs in parallel
  if (M_TOKEN && tmdbResults.length) {
    const OTT_LIST = ["pv", "nf", "hs"];
    const OTT_URLS = {
      pv: "/mobile/pv/search.php",
      nf: "/mobile/search.php",
      hs: "/mobile/hs/search.php",
    };
    const cookie = `t_hash_t=${encodeURIComponent(M_TOKEN)}; hd=on;`;
    const hdrs = { "user-agent": UA, "referer": "https://net52.cc/mobile/home?app=1", "x-requested-with": "app.netmirror.netmirrornew" };

    await Promise.all(tmdbResults.slice(0, 8).map(async item => {
      item.available = {};
      await Promise.all(OTT_LIST.map(async ott => {
        try {
          const cookieWithOtt = cookie + ` ott=${ott};`;
          const sr = await ax.get(`https://net52.cc${OTT_URLS[ott]}?s=${encodeURIComponent(item.title)}&t=${ts}`, {
            headers: { ...hdrs, "cookie": cookieWithOtt }, timeout: 6000
          });
          const results = sr.data?.searchResult || [];
          const match = results.find(r => r.y?.includes(item.year)) || results[0];
          if (match) item.available[ott] = match.id;
        } catch (_) {}
      }));
    }));
  }

  res.json({ ok: true, results: tmdbResults, query: q });
});

// ---------- PLAYIT AUTO-RESOLVE ----------
// GET /api/player/resolve?tmdbId=76479&type=tv&season=1&episode=1&preferOtt=pv
// Tries all OTTs, returns sources from first one that works
app.get("/api/player/resolve", async (req, res) => {
  const { dnsAxios: ax } = await import("./services/dnsAxios.js");
  const { tmdbId, type = "movie", season = "1", episode = "1", net52Id, preferOtt } = req.query;
  if (!tmdbId && !net52Id) return res.status(400).json({ error: "tmdbId or net52Id required" });

  const UA  = "Mozilla/5.0 (Linux; Android 13; Pixel 5 Build/TQ3A.230901.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/149.0.7827.91 Safari/537.36 /OS.Gatu v3.0";
  const REF = "https://net52.cc/mobile/home?app=1";
  const ts  = Math.floor(Date.now() / 1000);

  let M_TOKEN = "";
  try {
    const cfg = await ax.get("https://raw.githubusercontent.com/Cloudstream-Clone69/Cloudstream-clone-main/main/app_status.json", { timeout: 5000 });
    M_TOKEN = cfg.data?.netmirror?.m_token || "";
  } catch (_) {}
  // Fallback: use local getToken() (verify.php bypass — self-renewing, no GitHub needed)
  if (!M_TOKEN) {
    try {
      const { getToken } = await import('./providers/netmirror/net52.js');
      M_TOKEN = await getToken();
      console.log('[PlayerResolve] Using local verify.php token (GitHub m_token unavailable)');
    } catch (e) {
      console.error('[PlayerResolve] Local token also failed:', e.message);
      return res.status(503).json({ error: "Token unavailable — try /api/netmirror/reset" });
    }
  }
  if (!M_TOKEN) return res.status(503).json({ error: "Token unavailable" });


  // TMDB lookup
  let title = "", year = "", poster = "";
  if (tmdbId) {
    try {
      const tmdbType = type === "tv" ? "tv" : "movie";
      const tmdbRes = await ax.get(`http://api.tmdb.org/3/${tmdbType}/${tmdbId}`, {
        headers: {
          Authorization: `Bearer eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJhYjY1OWFlMjQwYmM5ZGZmMTJhYWFiZjI2ZDdjZDVmMCIsIm5iZiI6MTc4MDQxNzkwMi4yNDk5OTk4LCJzdWIiOiI2YTFmMDU2ZTg4ZDU2ZDA5ZDgyNTBmYTgiLCJzY29wZXMiOlsiYXBpX3JlYWQiXSwidmVyc2lvbiI6MX0.BaaZkYd0cK84S-P2vujy5qUYYc2MM3BUkrosxG5dOZM`,
          Accept: "application/json"
        },
        timeout: 6000
      });
      title  = tmdbRes.data.title || tmdbRes.data.name || "";
      year   = (tmdbRes.data.release_date || tmdbRes.data.first_air_date || "").substring(0, 4);
      poster = tmdbRes.data.poster_path ? "https://image.tmdb.org/t/p/w500" + tmdbRes.data.poster_path : "";
    } catch (_) {}
  }

  // OTT priority list
  const OTT_ORDER = preferOtt ? [preferOtt, ...["pv","nf","hs"].filter(o => o !== preferOtt)] : ["pv","nf","hs"];
  const OTT_URLS = {
    pv: { search: "/mobile/pv/search.php", playlist: "/mobile/pv/playlist.php" },
    nf: { search: "/mobile/search.php",    playlist: "/mobile/playlist.php" },
    hs: { search: "/mobile/hs/search.php", playlist: "/mobile/hs/playlist.php" },
  };

  // If net52Id already known, skip search
  const knownNet52 = net52Id || "";

  for (const ott of OTT_ORDER) {
    const cookie = `t_hash_t=${encodeURIComponent(M_TOKEN)}; ott=${ott}; hd=on;`;
    const hdrs = {
      "user-agent": UA, "referer": REF, "accept": "*/*",
      "accept-language": "en-IN,en-US;q=0.9,en;q=0.8",
      "x-requested-with": "app.netmirror.netmirrornew",
      "sec-fetch-dest": "empty", "sec-fetch-mode": "cors", "sec-fetch-site": "same-origin",
      "Cache-Control": "max-age=0",
      "cookie": cookie
    };


    try {
      // Find content ID
      let contentId = knownNet52;
      let contentTitle = title;
      if (!contentId && title) {
        const sr = await ax.get(`https://net52.cc${OTT_URLS[ott].search}?s=${encodeURIComponent(title)}&t=${ts}`, { headers: hdrs, timeout: 7000 });
        const results = sr.data?.searchResult || [];
        const match = results.find(r => r.y?.includes(year)) || results[0];
        if (!match) continue;
        contentId = match.id; contentTitle = match.t;
      }
      if (!contentId) continue;

      // For TV: get episodes
      let episodes = [], episodeId = contentId;
      if (type === "tv") {
        try {
          const tvHdrs = { "X-Requested-With": "NetmirrorNewTV v1.0", "User-Agent": "Mozilla/5.0 /OS.GatuNewTV v1.0", "ott": ott };
          const epRes = await ax.get(`https://tv.imgcdn.kim/newtv/episodes.php?id=${contentId}&page=1`, { headers: tvHdrs, timeout: 8000 });
          episodes = epRes.data?.episodes || [];
          const ep = episodes.find(e => String(e.ep) === String(episode));
          if (ep) episodeId = ep.id;
          // Paginate if episode not found
          if (!ep && episodes.length >= 20) {
            for (let p = 2; p <= 10; p++) {
              const r2 = await ax.get(`https://tv.imgcdn.kim/newtv/episodes.php?id=${contentId}&page=${p}`, { headers: tvHdrs, timeout: 6000 });
              const eps2 = r2.data?.episodes || [];
              if (!eps2.length) break;
              episodes.push(...eps2);
              const ep2 = eps2.find(e => String(e.ep) === String(episode));
              if (ep2) { episodeId = ep2.id; break; }
            }
          }
        } catch (_) {}
      }

      // Get playlist
      const pRes = await ax.get(`https://net52.cc${OTT_URLS[ott].playlist}?id=${episodeId}&t=${encodeURIComponent(contentTitle)}&tm=${ts}`, { headers: hdrs, timeout: 12000 });
      const raw = pRes.data?.[0] || {};
      const rawSources = raw.sources || [];
      if (!rawSources.length) continue;

      const hlsCookie = encodeURIComponent(`t_hash_t=${encodeURIComponent(M_TOKEN)}; ott=${ott}; hd=on;`);
      const refEnc = encodeURIComponent(REF);
      const uaEnc  = encodeURIComponent(UA);

      // Extract in= token from whichever source has it (Auto always does)
      // Quality variants (?q=1 etc.) arrive without it — causes warning video without it
      const autoSrc = rawSources.find(s => s.file?.includes('in='));
      const inMatch = autoSrc?.file?.match(/[?&]in=([^&]+)/);
      const inToken = inMatch ? inMatch[1] : '';

      const sources = rawSources.map(s => {
        let file = s.file || '';
        if (inToken && !file.includes('in=')) {
          file += (file.includes('?') ? '&' : '?') + 'in=' + inToken;
        }
        return {
          label: s.label || 'Auto',
          proxy: `http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent('https://net52.cc'+file)}&ref=${refEnc}&cookie=${hlsCookie}&ott=${ott}&ua=${uaEnc}`,
        };
      });
      const subtitles = (raw.tracks || []).map(t => ({ label: t.label || t.lang, url: 'https:' + (t.file || t.url || '') }));

      return res.json({ ok: true, ott, title: contentTitle, year, poster, contentId, episodeId, episodes, sources, subtitles });
    } catch (_) { continue; }
  }

  res.json({ error: "Not found on any OTT (pv/nf/hs)", title, year });
});

// ---------- PLAYIT PLAYER API ----------
// GET /api/player?tmdbId=76479&type=tv&season=1&episode=1
// GET /api/player?tmdbId=550&type=movie
// Returns: { title, year, poster, sources:[{label,proxyUrl}], subtitles:[{label,url}], episodes:[{id,t,ep}] }
app.get("/api/player", async (req, res) => {
  const { dnsAxios: ax } = await import("./services/dnsAxios.js");
  const { tmdbId, type = "movie", season = "1", episode = "1", net52Id, ott = "pv", title: titleParam = "" } = req.query;
  const UA  = "Mozilla/5.0 (Linux; Android 13; Pixel 5 Build/TQ3A.230901.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/149.0.7827.91 Safari/537.36 /OS.Gatu v3.0";
  const REF = "https://net52.cc/mobile/home?app=1";

  // ── 1+2. Fetch M-token AND TMDB title in PARALLEL ────────────────────────
  // Previously sequential (up to 12s wait). Now both happen at the same time.
  const t0 = Date.now();
  const [appStatus, tmdbData] = await Promise.all([
    getAppStatus(ax),
    tmdbId ? (async () => {
      try {
        const tmdbType = type === 'tv' ? 'tv' : 'movie';
        const r = await ax.get(`https://api.themoviedb.org/3/${tmdbType}/${tmdbId}?api_key=5b6b234ccb72c4e8b1cfe26c69302b6f`, { timeout: 6000 });
        return r.data;
      } catch (_) { return null; }
    })() : Promise.resolve(null)
  ]);
  console.log(`[Player] Step1+2 (token+TMDB) done in ${Date.now()-t0}ms`);

  const M_TOKEN_GITHUB = appStatus?.netmirror?.m_token || '';
  // Fallback: use local getToken() from net52.js (verify.php bypass)
  let M_TOKEN = M_TOKEN_GITHUB;
  if (!M_TOKEN) {
    try {
      const { getToken } = await import('./providers/netmirror/net52.js');
      M_TOKEN = await getToken();
      console.log('[Player] Using local verify.php token (GitHub m_token unavailable)');
    } catch (e) {
      console.error('[Player] Local token also failed:', e.message);
      return res.status(503).json({ error: 'Token unavailable — try /api/netmirror/reset to refresh' });
    }
  }
  if (!M_TOKEN) return res.status(503).json({ error: 'Token unavailable' });


  let title = titleParam || '', year = '', poster = '';
  if (tmdbData) {
    title  = tmdbData.title || tmdbData.name || titleParam || '';
    year   = (tmdbData.release_date || tmdbData.first_air_date || '').substring(0, 4);
    poster = tmdbData.poster_path ? 'https://image.tmdb.org/t/p/w500' + tmdbData.poster_path : '';
  }

  const cookie  = `t_hash_t=${encodeURIComponent(M_TOKEN)}; ott=${ott}; hd=on;`;
  const hdrs    = {
    "user-agent": UA, "referer": REF, "accept": "*/*",
    "accept-language": "en-IN,en-US;q=0.9,en;q=0.8",
    "x-requested-with": "app.netmirror.netmirrornew",
    "sec-fetch-dest": "empty", "sec-fetch-mode": "cors", "sec-fetch-site": "same-origin",
    "Cache-Control": "max-age=0",
    "cookie": cookie
  };

  const ts      = Math.floor(Date.now() / 1000);
  const ottCfg  = { pv: { search: "/mobile/pv/search.php", playlist: "/mobile/pv/playlist.php", episodes: "newtv/episodes.php" },
                    nf: { search: "/mobile/search.php",    playlist: "/mobile/playlist.php",    episodes: "newtv/episodes.php" },
                    hs: { search: "/mobile/hs/search.php", playlist: "/mobile/hs/playlist.php", episodes: "newtv/episodes.php" } };
  const o       = ottCfg[ott] || ottCfg.pv;

  // ── 3. Search net52 ──────────────────────────────────────────────────────
  let contentId = net52Id || "";
  let contentTitle = title;
  let searchResults = [];
  if (!contentId && title) {
    try {
      const t3 = Date.now();
      const sRes = await ax.get(`https://net52.cc${o.search}?s=${encodeURIComponent(title)}&t=${ts}`, { headers: hdrs, timeout: 10000 });
      searchResults = sRes.data?.searchResult || [];
      // Try to match by year or pick first result
      const match = searchResults.find(r => r.y?.includes(year)) || searchResults[0];
      if (match) { contentId = match.id; contentTitle = match.t; }
      console.log(`[Player] Step3 (net52 search) done in ${Date.now()-t3}ms — found: ${contentId}`);
    } catch (e) { console.warn(`[Player] Step3 search failed: ${e.message}`); }
  }
  if (!contentId) return res.json({ error: "Content not found on NetMirror", searchResults, title, year });

  // ── 4. For TV: list episodes, find episode ID ────────────────────────────
  let episodes = [], episodeId = contentId;
  if (type === "tv") {
    try {
      const t4 = Date.now();
      const tvHdrs = { "X-Requested-With": "NetmirrorNewTV v1.0", "User-Agent": "Mozilla/5.0 /OS.GatuNewTV v1.0", "ott": ott };
      const epRes = await ax.get(`https://tv.imgcdn.kim/${o.episodes}?id=${contentId}&page=1`, { headers: tvHdrs, timeout: 10000 });
      episodes = epRes.data?.episodes || [];
      const ep = episodes.find(e => String(e.ep) === String(episode));
      if (ep) episodeId = ep.id;
      console.log(`[Player] Step4 (episodes) done in ${Date.now()-t4}ms — ${episodes.length} eps`);
    } catch (e) { console.warn(`[Player] Step4 episodes failed: ${e.message}`); }
    // Fallback: all episodes pages
    if (episodes.length === 0) {
      try {
        const tvHdrs2 = { "X-Requested-With": "NetmirrorNewTV v1.0", "User-Agent": "Mozilla/5.0 /OS.GatuNewTV v1.0", "ott": ott };
        for (let p = 1; p <= 5; p++) {
          const r = await ax.get(`https://tv.imgcdn.kim/${o.episodes}?id=${contentId}&page=${p}`, { headers: tvHdrs2, timeout: 8000 });
          const eps = r.data?.episodes || [];
          if (!eps.length) break;
          episodes.push(...eps);
        }
        const ep = episodes.find(e => String(e.ep) === String(episode));
        if (ep) episodeId = ep.id;
      } catch (_) {}
    }
  }

  // ── 5. Fetch playlist for the episode/movie ───────────────────────────────
  let sources = [], subtitles = [];
  try {
    const t5 = Date.now();
    const pRes = await ax.get(`https://net52.cc${o.playlist}?id=${episodeId}&t=${encodeURIComponent(contentTitle)}&tm=${ts}`, { headers: hdrs, timeout: 12000 });
    console.log(`[Player] Step5 (playlist) done in ${Date.now()-t5}ms`);
    const raw = pRes.data?.[0] || {};
    const rawSources = raw.sources || [];
    const tracks = raw.tracks || [];

    const hlsCookie = encodeURIComponent(`t_hash_t=${encodeURIComponent(M_TOKEN)}; ott=${ott}; hd=on;`);
    const refEnc   = encodeURIComponent(REF);
    const uaEnc    = encodeURIComponent(UA);

    // Inject missing in= token into quality variants to prevent warning video
    const autoSrc2 = rawSources.find(s => s.file?.includes('in='));
    const inMatch2 = autoSrc2?.file?.match(/[?&]in=([^&]+)/);
    const inToken2 = inMatch2 ? inMatch2[1] : '';

    sources = rawSources.map(s => {
      let file = s.file || '';
      if (inToken2 && !file.includes('in=')) {
        file += (file.includes('?') ? '&' : '?') + 'in=' + inToken2;
      }
      const m3u8  = 'https://net52.cc' + file;
      const proxy = `http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent(m3u8)}&ref=${refEnc}&cookie=${hlsCookie}&ott=${ott}&ua=${uaEnc}`;
      return { label: s.label || 'Auto', proxy, direct: m3u8 };
    });
    subtitles = tracks.map(t => ({ label: t.label || t.lang, url: 'https:' + (t.file || t.url || '') }));
  } catch (e) {
    return res.status(500).json({ error: "Playlist fetch failed: " + e.message });
  }

  const totalMs = Date.now() - t0;
  console.log(`[Player] ✅ Total /api/player response time: ${totalMs}ms`);
  res.json({ ok: true, title: contentTitle, year, poster, contentId, episodeId, episodes, sources, subtitles });
});

// ---------- SOFASCORE IMAGE PROXY ----------
// Flutter can't access api.sofascore.app directly (CORS/auth blocks it).
// This route proxies the image server-side with proper browser-like headers.

app.get("/api/sofascore-image", async (req, res) => {
  const { id, type } = req.query; // type = 'team' | 'player' | 'tournament'
  if (!id) return res.status(400).send("Missing id");

  const entityType = type || "team";
  const sfUrl = `https://api.sofascore.app/api/v1/${entityType}/${id}/image`;

  try {
    const sfResp = await sfAxios.get(sfUrl, {
      responseType: "arraybuffer",
      timeout: 6000,
      headers: {
        "User-Agent": "SofaScore/211 CFNetwork/1568.100.1 Darwin/24.0.0",
        "Accept": "image/webp,image/png,image/*,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Referer": "https://www.sofascore.com/",
        "Origin": "https://www.sofascore.com",
        "Cache-Control": "no-cache",
      },
    });

    const contentType = sfResp.headers["content-type"] || "image/png";
    res.setHeader("Content-Type", contentType);
    res.setHeader("Cache-Control", "public, max-age=86400"); // cache 24h in client
    res.send(Buffer.from(sfResp.data));
  } catch (err) {
    console.warn(`[Sofascore] Image proxy failed for ${entityType}/${id}: ${err.message}`);
    res.status(404).send("Not found");
  }
});


// Debug HTML fetch
app.get("/debug/fetch", async (req, res) => {
  try {
    const html = await fetchHTML(req.query.url);
    res.send(html);
  } catch (e) {
    res.status(500).send(e.message);
  }
});


// ---------- PROVIDER PRIORITY INFO ----------
// GET /api/provider/info -- returns the active provider list with their roles
app.get("/api/provider/info", (req, res) => {
  res.json({
    ok: true,
    providers: {
      stream_4k:      { id: "4khdhub",   label: "4KHDHub",              priority: 1, type: "stream" },
      stream_pv:      { id: "netmirror", label: "Prime Video Mirror",   priority: 2, type: "stream", ott: "pv" },
      stream_nf:      { id: "netmirror", label: "Netflix Mirror",       priority: 3, type: "stream", ott: "nf" },
      stream_hs:      { id: "netmirror", label: "Disney+/Hotstar Mirror", priority: 4, type: "stream", ott: "hs" },
      stream_vidsrc:  { id: "cinestream", label: "VidSrc",              priority: 5, type: "stream", fallback: true },
      download_1:     { id: "bollyflix",  label: "Bollyflix",           priority: 1, type: "download" },
      download_2:     { id: "vegamovies", label: "Vegamovies",          priority: 2, type: "download" },
      download_3:     { id: "moviesdrive", label: "MoviesDrive",        priority: 3, type: "download" },
      anime:          { id: "anikoto",    label: "Anikoto",             priority: 1, type: "anime" },
    },
    eliminated: ["hotstarm","netflixm","primevideosm","watchanimeworld"],
    note: "4K sources always lead. Netmirror pv/nf/hs for ≤1080p streaming. Downloads grouped by quality."
  });
});

// ---------- AUTO‑UPDATE ENDPOINTS ----------
// Check for provider updates
app.get("/api/updates/check", async (req, res) => {
  try {
    const updates = await checkForUpdates();
    res.json({ updates });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Apply provider updates
app.post("/api/updates/apply", async (req, res) => {
  try {
    const { names } = req.body;   // expected: { names: ["anidao", ...] }
    if (!names || !Array.isArray(names)) {
      return res.status(400).json({ error: 'Missing or invalid "names" array' });
    }
    await downloadAndUpdate(names);
    res.json({ success: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ---------- NETMIRROR SESSION RESET ----------
// Wipes the in-memory token + clears app-settings.json + runs fresh bypass.
// Call this whenever the warning video appears and auto-recovery hasn't kicked in.
// Supports both POST (from Flutter/API) and GET (from browser / demo player button).
app.post("/api/netmirror/reset", async (req, res) => {
  try {
    const result = await resetSession();
    if (result.ok) {
      res.json({ ok: true, source: result.source, token: result.token, message: 'Session reset successfully. Reload the stream.' });
    } else {
      res.status(500).json({ ok: false, error: result.error, message: 'Reset failed — try again in 30s or switch to a different network.' });
    }
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get("/api/netmirror/reset", async (req, res) => {
  try {
    const result = await resetSession();
    if (result.ok) {
      res.json({ ok: true, source: result.source, token: result.token, message: 'Session reset successfully. Reload the stream.' });
    } else {
      res.status(500).json({ ok: false, error: result.error, message: 'Reset failed — try again in 30s or switch to a different network.' });
    }
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// Short alias — /gettoken redirects to the full inject page
app.get("/gettoken", (req, res) => res.redirect("/api/netmirror/inject"));

// ---------- ADB DEVICE TOKEN SYNC ----------
// Reads the fresh ::m (mobile premium) token from the BlueStacks Android device via ADB.
// Run this after a Frida session to get the best quality token automatically.
app.post("/api/netmirror/sync-from-device", async (req, res) => {
  try {
    const { syncTokenFromDevice } = await import('./providers/netmirror/net52.js');
    const result = await syncTokenFromDevice();
    if (result.ok) {
      res.json({ ok: true, source: 'adb_device', token: result.token, message: '::m token synced from device. All streams will now use premium quality.' });
    } else {
      res.status(500).json({ ok: false, error: result.error, message: 'ADB sync failed — try verify.php reset instead via /api/netmirror/reset' });
    }
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get("/api/netmirror/sync-from-device", async (req, res) => {
  try {
    const { syncTokenFromDevice } = await import('./providers/netmirror/net52.js');
    const result = await syncTokenFromDevice();
    if (result.ok) {
      res.json({ ok: true, source: 'adb_device', token: result.token, message: '::m token synced from device.' });
    } else {
      res.status(500).json({ ok: false, error: result.error });
    }
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

// ---------- NETMIRROR MANUAL TOKEN INJECT ----------
// Use this when verify.php is Cloudflare-blocked.
// Phone browser visits net52.cc (solves CF challenge), copies the t_hash_t cookie,
// then submits it here to inject it as the active session token.
app.post("/api/netmirror/inject", async (req, res) => {
  const token = req.body?.token || req.query?.token;
  if (!token) return res.status(400).json({ ok: false, error: 'Missing token field in body or ?token= query param' });
  if (token.length < 20) return res.status(400).json({ ok: false, error: 'Token too short — paste the full t_hash_t cookie value' });

  const { injectToken } = await import('./providers/netmirror/net52.js');
  const result = await injectToken(token);
  res.json(result);
});

app.get("/api/netmirror/inject", (req, res) => {
  const token = req.query?.token;
  if (!token) {
    const SERVER_IP = '10.106.157.104';
    res.send(`<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NetMirror Token Injector</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,sans-serif;background:#0d0d1a;color:#eee;min-height:100vh;padding:20px;display:flex;align-items:center;justify-content:center}
.card{background:#161628;border:1px solid #2a2a4a;border-radius:16px;padding:26px;max-width:500px;width:100%}
h1{font-size:1.25rem;color:#00ccff;margin-bottom:4px}
.sub{color:#777;font-size:.8rem;margin-bottom:18px}
.section{background:#0d0d1a;border:1px solid #1e1e3a;border-radius:10px;padding:16px;margin:12px 0}
.label{font-size:.7rem;color:#00ccff;font-weight:700;text-transform:uppercase;letter-spacing:1px;margin-bottom:8px}
code{background:#0a0a1a;color:#00ff88;padding:3px 8px;border-radius:5px;font-size:.78rem;word-break:break-all;display:block;margin:6px 0;line-height:1.6}
textarea{width:100%;background:#0a0a1a;border:1px solid #2a2a4a;border-radius:8px;color:#eee;padding:12px;font-family:monospace;font-size:.78rem;height:72px;margin:8px 0 4px;resize:vertical}
.btn{display:block;width:100%;background:#00ccff;color:#000;border:none;padding:13px;border-radius:8px;font-weight:700;font-size:.95rem;cursor:pointer;margin-top:8px;text-align:center}
.btn:hover{background:#00aadd}
.btn-alt{background:#1a2a4a;color:#00ccff;border:1px solid #00ccff44;margin-top:6px}
.btn-alt:hover{background:#1a3a6a}
.warn{background:#1c1400;border:1px solid #ff960033;border-radius:8px;padding:11px;color:#ffa500;font-size:.78rem;margin-bottom:12px}
#status{margin-top:12px;padding:10px;border-radius:8px;font-size:.83rem;display:none}
.ok{background:#0a2a0a;border:1px solid #00ff0033;color:#00ff88}
.err{background:#2a0a0a;border:1px solid #ff003333;color:#ff6666}
</style></head><body><div class="card">
<h1>&#128273; NetMirror Token Injector</h1>
<p class="sub">verify.php is blocked by Cloudflare on server. Use your phone browser to get a fresh session token.</p>
<div class="warn">&#9888; Open this page on your PHONE browser (same Jio WiFi: http://${SERVER_IP}:3000/gettoken)</div>

<div class="section">
<div class="label">&#128247; Option A — Auto Fetch (Try This First)</div>
<p style="font-size:.8rem;color:#aaa;margin-bottom:8px">Click the button — your browser will contact net52.cc directly and send the token here automatically.</p>
<button class="btn" onclick="autoFetch()">&#9889; Auto-Get Token from net52.cc</button>
<div id="status"></div>
</div>

<div class="section">
<div class="label">&#9997; Option B — Manual Paste</div>
<p style="font-size:.8rem;color:#aaa;margin-bottom:4px">1. Open Chrome on your phone and visit: <code>https://net52.cc</code></p>
<p style="font-size:.8rem;color:#aaa;margin-bottom:4px">2. In the address bar type: <code>javascript:alert(document.cookie)</code></p>
<p style="font-size:.8rem;color:#aaa;margin-bottom:8px">3. Copy everything after <code>t_hash_t=</code> up to the <code>;</code> and paste below:</p>
<form method="POST" action="/api/netmirror/inject">
<textarea name="token" placeholder="Paste t_hash_t value here e.g. abc123::def456::1783..::ni::m"></textarea>
<button type="submit" class="btn btn-alt">&#128229; Inject Pasted Token</button>
</form>
</div>
</div>

<script>
async function autoFetch(){
  const st = document.getElementById('status');
  st.style.display='block'; st.className=''; st.textContent='Contacting net52.cc...';
  try {
    // POST to verify.php from browser context (browser can solve CF challenge)
    const uuid = crypto.randomUUID();
    const fd = new FormData();
    fd.append('g-recaptcha-response', uuid);
    const r = await fetch('https://net52.cc/verify.php', {
      method:'POST', body:fd, credentials:'include',
      headers:{'X-Requested-With':'app.netmirror.netmirrornew'}
    });
    st.textContent = 'verify.php status: '+r.status+'. Checking cookie...';
    // Try to read the cookie (only works if same-origin or cookie is accessible)
    const cookieMatch = document.cookie.match(/t_hash_t=([^;]+)/);
    if(cookieMatch){
      const token = decodeURIComponent(cookieMatch[1]);
      st.textContent = 'Got token! Injecting...';
      const inject = await fetch('/api/netmirror/inject', {
        method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({token})
      });
      const d = await inject.json();
      st.className = d.ok ? 'ok' : 'err';
      st.textContent = d.ok ? '✅ '+d.message : '❌ '+d.error;
    } else {
      st.className='err';
      st.textContent='Cookie not accessible (cross-origin). Use Option B (manual paste) instead.';
    }
  } catch(e){
    st.className='err';
    st.textContent='Auto-fetch failed: '+e.message+'. Use Option B (manual paste).';
  }
}
</script>
</body></html>`);
    return;
  }
  // GET with ?token= query param
  import('./providers/netmirror/net52.js').then(({ injectToken }) => {
    injectToken(token).then(r => res.json(r)).catch(e => res.status(500).json({ ok: false, error: e.message }));
  });
});

// ---------- HEARTBEAT MONITORING (Auto-Close) ----------
let lastHeartbeat = Date.now();

app.post("/api/heartbeat", (req, res) => {
  lastHeartbeat = Date.now();
  res.json({ success: true });
});

if (process.argv.includes('--autoclose')) {
  console.log('[Heartbeat] Auto-close monitoring active. Server will terminate if client heartbeat is lost for >60s.');
  // Wait 20 seconds before starting strict heartbeat enforcement to allow app to fully start
  setTimeout(() => {
    setInterval(() => {
      if (Date.now() - lastHeartbeat > 60000) {
        console.log('[Heartbeat] Lost connection to client. Shutting down Node server...');
        process.exit(0);
      }
    }, 10000);
  }, 20000);
}

export default app;