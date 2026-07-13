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

// ---------- AUTO‑UPDATE ----------
import { checkForUpdates, downloadAndUpdate } from "../src/updater.js";   // adjust path if needed
import { dnsAxios as sfAxios } from "./services/dnsAxios.js";
import { fetchHTML } from "./providers/common.js";

const app = express();

app.use(cors());
app.use(express.json());

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
    const hdrs = { "user-agent": UA, "referer": REF, "x-requested-with": "app.netmirror.netmirrornew", "cookie": cookie };

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
      const sources = rawSources.map(s => ({
        label: s.label || "Auto",
        proxy: `http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent("https://net52.cc"+s.file)}&ref=${refEnc}&cookie=${hlsCookie}&ott=${ott}&ua=${uaEnc}`,
      }));
      const subtitles = (raw.tracks || []).map(t => ({ label: t.label || t.lang, url: "https:" + (t.file || t.url || "") }));

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
  const { tmdbId, type = "movie", season = "1", episode = "1", net52Id, ott = "pv" } = req.query;
  const UA  = "Mozilla/5.0 (Linux; Android 13; Pixel 5 Build/TQ3A.230901.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/149.0.7827.91 Safari/537.36 /OS.Gatu v3.0";
  const REF = "https://net52.cc/mobile/home?app=1";

  // ── 1. Get M-token from GitHub config ────────────────────────────────────
  let M_TOKEN = "";
  try {
    const cfg = await ax.get(
      "https://raw.githubusercontent.com/Cloudstream-Clone69/Cloudstream-clone-main/main/app_status.json",
      { timeout: 6000 }
    );
    M_TOKEN = cfg.data?.netmirror?.m_token || "";
  } catch (_) {}
  if (!M_TOKEN) return res.status(503).json({ error: "Token unavailable" });

  const cookie = `t_hash_t=${encodeURIComponent(M_TOKEN)}; ott=${ott}; hd=on;`;
  const hdrs = { "user-agent": UA, "referer": REF, "x-requested-with": "app.netmirror.netmirrornew", "cookie": cookie };
  const ts = Math.floor(Date.now() / 1000);
  const ottCfg = { pv: { search: "/mobile/pv/search.php", playlist: "/mobile/pv/playlist.php", episodes: "newtv/episodes.php" },
                   nf: { search: "/mobile/search.php",    playlist: "/mobile/playlist.php",    episodes: "newtv/episodes.php" },
                   hs: { search: "/mobile/hs/search.php", playlist: "/mobile/hs/playlist.php", episodes: "newtv/episodes.php" } };
  const o = ottCfg[ott] || ottCfg.pv;

  // ── 2. TMDB lookup for title ─────────────────────────────────────────────
  let title = "", year = "", poster = "";
  if (tmdbId) {
    try {
      const tmdbType = type === "tv" ? "tv" : "movie";
      const tmdbRes = await ax.get(`https://api.themoviedb.org/3/${tmdbType}/${tmdbId}?api_key=5b6b234ccb72c4e8b1cfe26c69302b6f`, { timeout: 6000 });
      title  = tmdbRes.data.title || tmdbRes.data.name || "";
      year   = (tmdbRes.data.release_date || tmdbRes.data.first_air_date || "").substring(0, 4);
      poster = tmdbRes.data.poster_path ? "https://image.tmdb.org/t/p/w500" + tmdbRes.data.poster_path : "";
    } catch (_) {}
  }

  // ── 3. Search net52 ──────────────────────────────────────────────────────
  let contentId = net52Id || "";
  let contentTitle = title;
  let searchResults = [];
  if (!contentId && title) {
    try {
      const sRes = await ax.get(`https://net52.cc${o.search}?s=${encodeURIComponent(title)}&t=${ts}`, { headers: hdrs, timeout: 10000 });
      searchResults = sRes.data?.searchResult || [];
      // Try to match by year or pick first result
      const match = searchResults.find(r => r.y?.includes(year)) || searchResults[0];
      if (match) { contentId = match.id; contentTitle = match.t; }
    } catch (_) {}
  }
  if (!contentId) return res.json({ error: "Content not found on NetMirror", searchResults, title, year });

  // ── 4. For TV: list episodes, find episode ID ────────────────────────────
  let episodes = [], episodeId = contentId;
  if (type === "tv") {
    try {
      const tvHdrs = { "X-Requested-With": "NetmirrorNewTV v1.0", "User-Agent": "Mozilla/5.0 /OS.GatuNewTV v1.0", "ott": ott };
      const epRes = await ax.get(`https://tv.imgcdn.kim/${o.episodes}?id=${contentId}&page=1`, { headers: tvHdrs, timeout: 10000 });
      episodes = epRes.data?.episodes || [];
      const ep = episodes.find(e => String(e.ep) === String(episode));
      if (ep) episodeId = ep.id;
    } catch (_) {}
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
    const pRes = await ax.get(`https://net52.cc${o.playlist}?id=${episodeId}&t=${encodeURIComponent(contentTitle)}&tm=${ts}`, { headers: hdrs, timeout: 12000 });
    const raw = pRes.data?.[0] || {};
    const rawSources = raw.sources || [];
    const tracks = raw.tracks || [];

    const hlsCookie = encodeURIComponent(`t_hash_t=${encodeURIComponent(M_TOKEN)}; ott=${ott}; hd=on;`);
    const refEnc   = encodeURIComponent(REF);
    const uaEnc    = encodeURIComponent(UA);

    sources = rawSources.map(s => {
      const m3u8 = "https://net52.cc" + s.file;
      const proxy = `http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent(m3u8)}&ref=${refEnc}&cookie=${hlsCookie}&ott=${ott}&ua=${uaEnc}`;
      return { label: s.label || "Auto", proxy, direct: m3u8 };
    });
    subtitles = tracks.map(t => ({ label: t.label || t.lang, url: "https:" + (t.file || t.url || "") }));
  } catch (e) {
    return res.status(500).json({ error: "Playlist fetch failed: " + e.message });
  }

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