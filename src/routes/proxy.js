import express from "express";
import { dnsAxios as axios } from "../services/dnsAxios.js";

const router = express.Router();

function abs(base, relative){
    try{
        return new URL(relative, base).href;
    }catch{
        return relative;
    }
}

function _safeUrl(rawUrl) {
  if (!rawUrl) return '';
  try {
    return new URL(rawUrl.toString()).toString();
  } catch (_) {
    return rawUrl;
  }
}

// anidb.app CDN requires Android Dalvik UA to bypass Cloudflare.
// All other CDNs use a standard browser UA.
function getUA(url) {
    try {
        const host = new URL(url).hostname;
        if (host.includes('anidb.app')) {
            return 'Dalvik/2.1.0 (Linux; U; Android 13; Pixel 7 Build/TQ3A.230805.001)';
        }
    } catch {}
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
}

router.get("/hls", async (req,res)=>{

    try{

        const target = _safeUrl(req.query.url || "");
        const referer = req.query.ref || "";
        const cookie  = req.query.cookie || "";
        const headers = {
            Referer: referer,
            Origin: referer ? new URL(referer).origin : "",
            "User-Agent": getUA(target),
            "Accept": "*/*",
        };
        if (cookie) headers["Cookie"] = cookie;

        const response = await axios.get(target,{ headers, timeout: 15000 });

        const text = response.data;

        // ── Master playlist? Rewrite ALL variant URLs through our proxy ──────
        // This lets MPV show quality options (1080p / 720p / 360p) in Quality panel.
        // Old code picked only the best quality — that stripped the user's choice.
        if (text.includes('#EXT-X-STREAM-INF') || text.includes('#EXT-X-I-FRAME-STREAM-INF')) {
            const lines = text.split('\n');
            const rewritten = lines.map(line => {
                const trimmed = line.trim();
                if (!trimmed || trimmed.startsWith('#')) {
                    // Keep comment/tag lines — but rewrite URI= attributes inside them
                    return line.replace(/URI="([^"]+)"/g, (_, uri) => {
                        const absolute = abs(target, uri);
                        return `URI="http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent(absolute)}&ref=${encodeURIComponent(referer)}"`;
                    });
                }
                // Variant URL line — rewrite through proxy
                const absolute = abs(target, trimmed);
                if (absolute.includes('.m3u8')) {
                    return `http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent(absolute)}&ref=${encodeURIComponent(referer)}`;
                }
                return line;
            }).join('\n');
            res.setHeader('Content-Type', 'application/vnd.apple.mpegurl');
            return res.send(rewritten);
        }

        // ── Media playlist: rewrite segment/key URLs ──────────────────────────
        const rewritten = text
            .split("\n")
            .map(line=>{

                const trimmed = line.trim();

                if(!trimmed) return line;

                if(trimmed.startsWith("#")){

                    return line.replace(
                        /URI="([^"]+)"/g,
                        (_,uri)=>{

                            const absolute =
                                abs(target, uri);

                            return `URI="http://127.0.0.1:3000/proxy/segment?url=${encodeURIComponent(absolute)}&ref=${encodeURIComponent(referer)}"`;
                        }
                    );
                }

                const absolute =
                    abs(target, trimmed);

                if (
                    absolute.includes(".m3u8")
                ) {
                    return `http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent(absolute)}&ref=${encodeURIComponent(referer)}`;
                }

                return `http://127.0.0.1:3000/proxy/segment?url=${encodeURIComponent(absolute)}&ref=${encodeURIComponent(referer)}`;

            })
            .join("\n");

        res.setHeader(
            "Content-Type",
            "application/vnd.apple.mpegurl"
        );

        res.send(rewritten);

    }catch(err){

        res.status(500).send(err.message);

    }

});

router.get("/segment", async (req,res)=>{
    const controller = new AbortController();
    req.on('close', () => {
        try { controller.abort(); } catch (_) {}
    });

    let sess = null;
    try{

        const target  = _safeUrl(decodeURIComponent(req.query.url || ''));
        // Session-based cookie (short URL) OR legacy inline cookie (long URL)
        const sessionId = req.query.s || '';
        let referer = decodeURIComponent(req.query.ref || '');
        let cookie  = decodeURIComponent(req.query.cookie || '');
        if (sessionId) {
          sess = _getSession(sessionId);
          if (!sess) {
            console.warn('[Segment] Session expired, aborted, or not found:', sessionId);
            if (!res.headersSent) {
              res.status(410).end('Session expired or aborted');
            }
            return;
          }
          cookie = sess.cookie;
          referer = sess.referer || referer;
          sess.activeControllers.add(controller);
        }
        if (!target) { res.status(400).end('Missing url'); return; }

        // Log segment fetches for debugging HEVC/CDN issues
        const segFile = target.split('/').pop().split('?')[0];
        console.log(`[Segment] Fetching: ${segFile} (cookie=${cookie.length > 0 ? 'YES' : 'NO'})`);

        const response = await axios.get(
            target,
            {
                responseType:"arraybuffer",
                signal: controller.signal,
                headers:{
                    Referer: referer,
                    Origin: referer ? new URL(referer).origin : "",
                    "User-Agent": getUA(target),
                    ...(cookie ? { Cookie: cookie } : {}),
                }
            }
        );

        const ct = response.headers["content-type"] || "application/octet-stream";
        console.log(`[Segment] CDN ${response.status} ${segFile} (${ct}, ${response.data.byteLength} bytes)`);

        let buf = Buffer.from(response.data);

        // Do NOT perform MPEG-TS sync-byte slicing on fragmented MP4 files (fMP4/DASH).
        // Slicing them corrupts container headers, leading to playback failures.
        const fileExt = (segFile.split('.').pop() || '').toLowerCase();
        const boxType = buf.length >= 8 ? buf.slice(4, 8).toString('ascii') : '';
        const isFmp4 = ['m4s', 'mp4', 'm4a', 'm4v'].includes(fileExt) ||
                       ['ftyp', 'styp', 'moof', 'moov', 'mdat'].includes(boxType);

        let tsStart = -1;
        if (!isFmp4) {
            for(
                let i = 0;
                i < buf.length - 376;
                i++
            ){
                if(
                    buf[i] === 0x47 &&
                    buf[i + 188] === 0x47
                ){
                    tsStart = i;
                    break;
                }
            }
        }

        if(tsStart > 0){

            buf = buf.slice(tsStart);

            res.setHeader(
                "Content-Type",
                "video/mp2t"
            );

            return res.send(buf);
        }

        res.setHeader("Content-Type", ct);
        res.setHeader('Access-Control-Allow-Origin', '*');
        res.send(buf);

    }catch(err){
        const target = decodeURIComponent(req.query.url || '?');
        if (err.name === 'AbortError' || err.code === 'ERR_CANCELED' || axios.isCancel(err)) {
            console.log(`[Segment] Request aborted for ${target.split('/').pop()}`);
            if (!res.headersSent) {
                res.status(499).end('Client Closed Request');
            }
            return;
        }
        console.error(`[Segment] ERROR fetching ${target.split('/').pop()}: ${err.message}`);
        if (!res.headersSent) {
            res.status(500).send(err.message);
        }
    }finally{
        if (sess) {
            sess.activeControllers.delete(controller);
        }
    }

});

// ── /proxy/dash — DASH→HLS converter ──────────────────────────────────────────
// Converts a DASH MPD to HLS M3U8 so that MPV (which plays HLS natively) can
// play MovieBox DASH streams.  CloudFront cookies are embedded in every segment
// proxy URL so the CDN never sees MPV directly.
//
// Modes (via ?track= query param):
//   master  (default) — multi-rendition M3U8 referencing video+audio sub-playlists
//   video   — M3U8 for the video AdaptationSet
//   audio   — M3U8 for the audio AdaptationSet

// ── MPD cache — avoids re-fetching the same MPD 3 times per playback ────────
// KEY = url + ':' + first 16 chars of cookie (enough to distinguish different auth tokens
// without storing the full 650-char CloudFront cookie in the key).
// This prevents episode A's cached MPD from being served for episode B (different cookie).
const _mpdCache = new Map();
const _MPD_TTL  = 12 * 60 * 1000; // 12 minutes
function _mpdCacheKey(url, cookie) { return url + '::' + (cookie || '').slice(0, 24); }
function _getCachedSets(url, cookie) { const c = _mpdCache.get(_mpdCacheKey(url, cookie)); return (c && c.expiresAt > Date.now()) ? c.sets : null; }
function _cacheSets(url, cookie, sets) { _mpdCache.set(_mpdCacheKey(url, cookie), { sets, expiresAt: Date.now() + _MPD_TTL }); }

// ── Cookie session store ─────────────────────────────────────────────────────
// Stores CloudFront cookies server-side so segment URLs stay SHORT (~80 chars)
// instead of embedding the full cookie (~1000 chars) in every segment URL.
// Short URLs prevent MPV's HLS parser from failing on oversized M3U8 files.
//
// IMPORTANT: MPV requests the MPD 3-4 times (master + each track sub-playlist).
// We reuse the SAME session for all requests to the same (url, cookie) pair
// within the session TTL, so all segment URLs reference a single valid session.
// Creating a new session on every MPD request caused stale-session crashes.
const _sessions = new Map(); // sessionId → { cookie, referer, cdnBase, expiresAt }
const _urlToSession = new Map(); // cacheKey → sessionId  (reuse session for same stream)
const _SESSION_TTL = 35 * 60 * 1000; // 35 minutes (CF cookies last ~30-60 min)

function _createSession(cookie, referer, cdnBase) {
  const id = Math.random().toString(36).slice(2, 10); // 8 random chars
  _sessions.set(id, { 
    cookie, 
    referer, 
    cdnBase: cdnBase || '', 
    expiresAt: Date.now() + _SESSION_TTL,
    activeControllers: new Set(),
    aborted: false
  });
  // Evict expired sessions to avoid memory growth
  if (_sessions.size > 200) {
    const now = Date.now();
    for (const [k, v] of _sessions) { if (v.expiresAt < now) _sessions.delete(k); }
  }
  return id;
}

/** Get or create a session for (url, cookie) pair — reuses existing valid session. */
function _getOrCreateSession(cookie, referer, cdnBase, url) {
  const key = _mpdCacheKey(url, cookie);
  const existingId = _urlToSession.get(key);
  if (existingId) {
    const s = _sessions.get(existingId);
    if (s && s.expiresAt > Date.now() && !s.aborted) {
      // Refresh TTL on reuse
      s.expiresAt = Date.now() + _SESSION_TTL;
      return existingId;
    }
  }
  // Create fresh session and remember it for this (url, cookie)
  const newId = _createSession(cookie, referer, cdnBase);
  _urlToSession.set(key, newId);
  // Clean up stale url→session mappings
  if (_urlToSession.size > 200) {
    const now = Date.now();
    for (const [k, sid] of _urlToSession) {
      const s = _sessions.get(sid);
      if (!s || s.expiresAt < now) _urlToSession.delete(k);
    }
  }
  return newId;
}

function _getSession(id) {
  const s = _sessions.get(id);
  return (s && s.expiresAt > Date.now() && !s.aborted) ? s : null;
}

// ── Session Abort Routes ──────────────────────────────────────────────────────
router.get('/abort-all', (req, res) => {
  console.log('[Abort] GET /abort-all called. Terminating active segment downloads...');
  let count = 0;
  for (const [id, session] of _sessions.entries()) {
    if (!session.aborted) {
      session.aborted = true;
      count++;
      if (session.activeControllers) {
        for (const controller of session.activeControllers) {
          try { controller.abort(); } catch (_) {}
        }
        session.activeControllers.clear();
      }
    }
  }
  // Also clear the MPD parsed-sets cache so the next MPD request
  // fetches a fresh playlist with the new session ID embedded.
  _mpdCache.clear();
  res.status(200).send(`Aborted ${count} sessions`);
});

router.post('/abort-all', (req, res) => {
  console.log('[Abort] POST /abort-all called. Terminating active segment downloads...');
  let count = 0;
  for (const [id, session] of _sessions.entries()) {
    if (!session.aborted) {
      session.aborted = true;
      count++;
      if (session.activeControllers) {
        for (const controller of session.activeControllers) {
          try { controller.abort(); } catch (_) {}
        }
        session.activeControllers.clear();
      }
    }
  }
  _mpdCache.clear();
  res.status(200).send(`Aborted ${count} sessions`);
});

router.get('/abort/:session', (req, res) => {
  const session = _sessions.get(req.params.session);
  if (session && !session.aborted) {
    session.aborted = true;
    if (session.activeControllers) {
      for (const controller of session.activeControllers) {
        try { controller.abort(); } catch (_) {}
      }
      session.activeControllers.clear();
    }
    console.log(`[Abort] Session aborted: ${req.params.session}`);
    return res.status(200).send(`Aborted session ${req.params.session}`);
  }
  res.status(200).send('Session not active or not found');
});

router.post('/abort/:session', (req, res) => {
  const session = _sessions.get(req.params.session);
  if (session && !session.aborted) {
    session.aborted = true;
    if (session.activeControllers) {
      for (const controller of session.activeControllers) {
        try { controller.abort(); } catch (_) {}
      }
      session.activeControllers.clear();
    }
    console.log(`[Abort] Session aborted: ${req.params.session}`);
    return res.status(200).send(`Aborted session ${req.params.session}`);
  }
  res.status(200).send('Session not active or not found');
});

// ── helpers ──────────────────────────────────────────────────────────────────

/** Parse every <AdaptationSet> block from an MPD string.
 *
 *  Handles two common MPD layouts:
 *   1. SegmentTemplate inside each AdaptationSet  (ep1-style)
 *   2. SegmentTemplate at Period level, inherited by all AdaptationSets  (ep2-style)
 */
function parseDashAdaptationSets(mpd) {
  const sets = [];

  // ── Period-level SegmentTemplate fallback ──────────────────────────────────
  // DASH spec allows <SegmentTemplate> at the <Period> level; all AdaptationSets
  // inherit its initialization/media/timescale/startNumber if they don't define
  // their own.  The <SegmentTimeline> is also often at Period level.
  let periodST = null;
  const periodMatch = mpd.match(/<Period[^>]*>([\s\S]*?)<\/Period>/i);
  if (periodMatch) {
    const periodInner = periodMatch[1];
    // SegmentTemplate may be self-closing or have children (SegmentTimeline)
    const pStFullM = periodInner.match(/<SegmentTemplate([^>]*)>([\s\S]*?)<\/SegmentTemplate>/i)
                  || periodInner.match(/<SegmentTemplate([^>]*)\/?>/i);
    if (pStFullM) {
      const pAttrs   = pStFullM[1] || '';
      const pContent = pStFullM[2] || periodInner; // if no children, search full period

      // Parse Period-level SegmentTimeline
      // Fix: match full <S.../> element first, then extract d and r separately.
      // The old single-pass regex failed to capture r when whitespace preceded it
      // because non-greedy [^>]*? + optional (?:r="...")?  caused the engine to
      // skip the optional group then swallow r in the trailing [^>]*?.
      const pSegments = [];
      const pSRx = /<S\b[^>]*?\/?>/gi;
      let ps;
      while ((ps = pSRx.exec(pContent)) !== null) {
        const sEl = ps[0];
        const dM  = sEl.match(/\bd="(\d+)"/);
        const rM  = sEl.match(/\br="(-?\d+)"/);
        if (!dM) continue;
        const d = parseInt(dM[1]);
        const r = rM ? parseInt(rM[1]) : 0;
        const count = r < 0 ? 1 : r + 1;
        for (let i = 0; i < count; i++) pSegments.push(d);
      }

      periodST = {
        initTmpl:  pAttrs.match(/initialization="([^"]+)"/)?.[1]  || '',
        mediaTmpl: pAttrs.match(/\bmedia="([^"]+)"/)?.[1]          || '',
        timescale: parseInt(pAttrs.match(/timescale="(\d+)"/)?.[1]  || '90000'),
        startNum:  parseInt(pAttrs.match(/startNumber="(\d+)"/)?.[1] || '1'),
        segments:  pSegments,
      };
      if (pSegments.length > 0)
        console.log(`[DASH→HLS] Period-level SegmentTemplate found: ${pSegments.length} segments`);
    }
  }

  // ── Parse each AdaptationSet ────────────────────────────────────────────────
  const rx = /<AdaptationSet([^>]*)>([\s\S]*?)<\/AdaptationSet>/gi;
  let m;
  while ((m = rx.exec(mpd)) !== null) {
    const attrs = m[1];
    const inner = m[2];

    // Detect content type
    const typeAttr  = attrs.match(/contentType="([^"]+)"/)?.[1];
    const mimeType  = inner.match(/mimeType="([^"]+)"/)?.[1] || '';
    const contentType = typeAttr || (mimeType.startsWith('audio') ? 'audio' : 'video');

    // Parse all Representations
    const reprRx = /<Representation([^>]*)>([\s\S]*?)<\/Representation>/gi;
    let rm;
    while ((rm = reprRx.exec(inner)) !== null) {
      const reprAttrs = rm[1];
      const reprInner = rm[2];
      const reprId  = reprAttrs.match(/\bid="([^"]+)"/)?.[1] || '0';
      const bandwidth = parseInt(reprAttrs.match(/bandwidth="(\d+)"/)?.[1] || '0');
      const width   = reprAttrs.match(/\bwidth="(\d+)"/)?.[1];
      const height  = reprAttrs.match(/\bheight="(\d+)"/)?.[1];
      const codecs  = reprAttrs.match(/codecs="([^"]+)"/)?.[1] ||
                      inner.match(/codecs="([^"]+)"/)?.[1] || '';

      // SegmentTemplate — Representation-level first, AdaptationSet level next, Period level fallback
      const stM = reprInner.match(/<SegmentTemplate([^>]*)\/?>/i) ||
                  reprInner.match(/<SegmentTemplate([^>]*)>([\s\S]*?)<\/SegmentTemplate>/i) ||
                  inner.match(/<SegmentTemplate([^>]*)\/?>/i) ||
                  inner.match(/<SegmentTemplate([^>]*)>([\s\S]*?)<\/SegmentTemplate>/i);
      
      const stAttrs = stM?.[1] || '';
      const timescale = parseInt(stAttrs.match(/timescale="(\d+)"/)?.[1]  || '') || periodST?.timescale || 90000;
      const initTmpl  = stAttrs.match(/initialization="([^"]+)"/)?.[1]              || periodST?.initTmpl  || '';
      const mediaTmpl = stAttrs.match(/\bmedia="([^"]+)"/)?.[1]                     || periodST?.mediaTmpl || '';
      const startNum  = parseInt(stAttrs.match(/startNumber="(\d+)"/)?.[1] || '')   || periodST?.startNum  || 1;

      // SegmentTimeline search target: SegmentTimeline inside stM, or reprInner, or inner
      const timelineBlock = stM?.[0]?.match(/<SegmentTimeline[^>]*>([\s\S]*?)<\/SegmentTimeline>/i);
      const searchTarget = timelineBlock ? timelineBlock[1] : (reprInner || inner);

      // SegmentTimeline via <S> elements (ep1-style: variable-duration segments)
      // Fix: match full <S.../> element, then extract d and r with separate patterns.
      // This correctly handles any attribute order and whitespace between attributes.
      const segments = [];
      const sRx = /<S\b[^>]*?\/?>/gi;
      let sm;
      while ((sm = sRx.exec(searchTarget)) !== null) {
        const sEl = sm[0];
        const dM  = sEl.match(/\bd="(\d+)"/);
        const rM  = sEl.match(/\br="(-?\d+)"/);
        if (!dM) continue;
        const d = parseInt(dM[1]);
        const r = rM ? parseInt(rM[1]) : 0;
        const count = r < 0 ? 1 : r + 1;
        for (let i = 0; i < count; i++) segments.push(d);
      }
      let finalSegments = segments.length > 0 ? segments : (periodST?.segments || []);

      // ── Fixed-duration fallback (ep2-style: SegmentTemplate@duration, no <S> elements) ──
      if (finalSegments.length === 0) {
        const stDuration = parseInt(stAttrs.match(/\bduration="(\d+)"/)?.[1] || '0')
                        || parseInt((periodST || {}).duration || '0');
        if (stDuration > 0) {
          const durStr = mpd.match(/mediaPresentationDuration="PT([^"]+)"/)?.[1] || '';
          const h   = parseFloat(durStr.match(/(\d+\.?\d*)H/)?.[1] || '0');
          const min = parseFloat(durStr.match(/(\d+\.?\d*)M/)?.[1] || '0');
          const sec = parseFloat(durStr.match(/(\d+\.?\d*)S/)?.[1] || '0');
          const totalSec = h * 3600 + min * 60 + sec;
          if (totalSec > 0) {
            const segDurSec = stDuration / timescale;
            const numSegs   = Math.ceil(totalSec / segDurSec);
            finalSegments = Array(numSegs).fill(stDuration);
            console.log(`[DASH→HLS] Fixed-duration segments: ${numSegs} × ${segDurSec}s = ${(numSegs * segDurSec).toFixed(1)}s`);
          }
        }
      }

      if (!initTmpl || !mediaTmpl || finalSegments.length === 0) {
        console.warn(`[DASH→HLS] Skipping Representation (${contentType}/${reprId}): init=${initTmpl||'MISSING'} media=${mediaTmpl||'MISSING'} segs=${finalSegments.length}`);
        continue;
      }

      sets.push({ contentType, reprId, bandwidth, width, height, codecs,
                  timescale, initTmpl, mediaTmpl, startNum, segments: finalSegments });
    }
  }
  return sets;
}

/** Build an HLS media playlist using a session ID so URLs stay short */
function buildMediaPlaylist(set, mpdBase, sessionId) {
  const seg = (cdnRelative) => {
    const abs = new URL(cdnRelative, mpdBase).href;
    // Use short session ID instead of embedding the full 1000-char cookie
    return `http://127.0.0.1:3000/proxy/segment?url=${encodeURIComponent(abs)}&s=${sessionId}`;
  };

  const expand = (tmpl, n) => {
    let s = tmpl.replace(/\$RepresentationID\$/g, set.reprId);
    s = s.replace(/\$Number%(\d+)d\$/g, (_, w) => String(n).padStart(parseInt(w), '0'));
    s = s.replace(/\$Number\$/g, String(n));
    return s;
  };

  const maxDur = Math.max(...set.segments) / set.timescale;
  const targetDur = Math.ceil(maxDur);
  const initUrl = seg(expand(set.initTmpl, 0));

  let pl = '#EXTM3U\n';
  pl += '#EXT-X-VERSION:6\n';
  pl += '#EXT-X-PLAYLIST-TYPE:VOD\n';
  pl += `#EXT-X-TARGETDURATION:${targetDur}\n`;
  pl += `#EXT-X-MEDIA-SEQUENCE:${set.startNum}\n`;
  pl += `#EXT-X-MAP:URI="${initUrl}"\n`;

  let segNum = set.startNum;
  for (const d of set.segments) {
    pl += `#EXTINF:${(d / set.timescale).toFixed(3)},\n`;
    pl += seg(expand(set.mediaTmpl, segNum)) + '\n';
    segNum++;
  }
  pl += '#EXT-X-ENDLIST\n';
  return pl;
}

// ── Route ─────────────────────────────────────────────────────────────────────

router.get("/dash", async (req, res) => {
  const url      = _safeUrl(decodeURIComponent(req.query.url    || ''));
  const referer  = decodeURIComponent(req.query.ref    || '');
  const cookie   = decodeURIComponent(req.query.cookie || '');
  const track    = req.query.track || 'master';  // 'master' | 'video' | 'audio'
  if (!url) return res.status(400).end('Missing url parameter');

  try {
    const mpdBase    = url.substring(0, url.lastIndexOf('/') + 1);
    const cookieEnc  = encodeURIComponent(cookie);
    const refEnc     = encodeURIComponent(referer);
    const urlEnc     = encodeURIComponent(url);

    // ── MPD fetch (cache-first, keyed by url+cookie) ───────────────────────────
    // Using cookie as part of the key prevents a different-episode cached MPD
    // from being returned when the user switches sources (different auth token).
    let sets = _getCachedSets(url, cookie);
    if (sets) {
      console.log(`[DASH→HLS] Cache hit: ${url.split('/').slice(-2, -1)[0] || 'mpd'} track=${track}`);
    } else {
      const headers = { 'User-Agent': getUA(url), 'Accept': 'application/dash+xml, */*' };
      if (referer) headers['Referer'] = referer;
      if (cookie)  headers['Cookie']  = cookie;
      const resp = await axios.get(url, { headers, timeout: 20000 });
      const mpd  = typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data);
      sets = parseDashAdaptationSets(mpd);
      _cacheSets(url, cookie, sets);
    }

    const videoSets = sets.filter(s => s.contentType === 'video');
    const audioSets = sets.filter(s => s.contentType === 'audio');

    // Sort video sets by bandwidth descending (highest quality first)
    videoSets.sort((a, b) => b.bandwidth - a.bandwidth);

    if (videoSets.length === 0 && audioSets.length === 0) {
      return res.status(500).send('No AdaptationSets found in MPD');
    }

    res.setHeader('Content-Type', 'application/vnd.apple.mpegurl');
    res.setHeader('Access-Control-Allow-Origin', '*');

    // Reuse the same session for repeated MPV requests to this (url, cookie) pair.
    // Creating a new session per-request caused different sub-playlist responses to
    // embed different session IDs → segment requests with wrong/expired session → 403.
    const mpdBase2  = url.substring(0, url.lastIndexOf('/') + 1);
    const sessionId = _getOrCreateSession(cookie, referer, mpdBase2, url);

    // ── sub-playlist mode ─────────────────────────────────────────────────────
    let targetVideoSet = null;
    if (track === 'video') {
      targetVideoSet = videoSets[0];
    } else if (track.startsWith('video_')) {
      const idx = parseInt(track.split('_')[1], 10);
      targetVideoSet = videoSets[idx];
    }
    if (targetVideoSet) {
      return res.send(buildMediaPlaylist(targetVideoSet, mpdBase, sessionId));
    }

    let targetAudioSet = null;
    if (track === 'audio') {
      targetAudioSet = audioSets[0];
    } else if (track.startsWith('audio_')) {
      const idx = parseInt(track.split('_')[1], 10);
      targetAudioSet = audioSets[idx];
    }
    if (targetAudioSet) {
      return res.send(buildMediaPlaylist(targetAudioSet, mpdBase, sessionId));
    }

    // Fallback: return whatever track is available if requested track was not found
    if (track.startsWith('video') && audioSets.length > 0) {
      return res.send(buildMediaPlaylist(audioSets[0], mpdBase, sessionId));
    }
    if (track.startsWith('audio') && videoSets.length > 0) {
      return res.send(buildMediaPlaylist(videoSets[0], mpdBase, sessionId));
    }

    // ── master playlist: sub-playlist URLs carry query params ──
    const proxyDash = (t) =>
      `http://127.0.0.1:3000/proxy/dash?url=${urlEnc}&ref=${refEnc}&cookie=${cookieEnc}&track=${t}`;

    let master = '#EXTM3U\n#EXT-X-VERSION:6\n';

    // We only need one audio group, using the best audio track
    if (audioSets.length > 0) {
      master += `#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio0",NAME="Audio",DEFAULT=YES,URI="${proxyDash('audio_0')}"\n`;
    }

    // Add each video representation as a variant stream
    videoSets.forEach((vSet, idx) => {
      const bw = vSet.bandwidth;
      const resStr = vSet.width && vSet.height ? `,RESOLUTION=${vSet.width}x${vSet.height}` : '';
      const audioG = audioSets.length > 0 ? ',AUDIO="audio0"' : '';
      
      const codecsList = [];
      if (vSet.codecs) codecsList.push(vSet.codecs);
      if (audioSets[0] && audioSets[0].codecs) codecsList.push(audioSets[0].codecs);
      const codecsStr = codecsList.length > 0 ? `,CODECS="${codecsList.join(',')}"` : '';

      master += `#EXT-X-STREAM-INF:BANDWIDTH=${bw}${resStr}${codecsStr}${audioG}\n`;
      master += proxyDash(`video_${idx}`) + '\n';
    });

    // Fallback if no video sets: just output the audio track as a stream
    if (videoSets.length === 0 && audioSets.length > 0) {
      const bw = audioSets[0].bandwidth;
      const codecsStr = audioSets[0].codecs ? `,CODECS="${audioSets[0].codecs}"` : '';
      master += `#EXT-X-STREAM-INF:BANDWIDTH=${bw}${codecsStr}\n`;
      master += proxyDash('audio_0') + '\n';
    }


    console.log(`[DASH→HLS] Converted: ${sets.length} AdaptationSets, videoVariants=${videoSets.length}, audioVariants=${audioSets.length}`);
    return res.send(master);

  } catch (err) {
    console.error('[DASH→HLS] Error:', err.message);
    res.status(502).send(err.message);
  }
});

// ── /proxy/stream.mpd  (also /proxy/mpd for legacy) ─────────────────────────
// CRITICAL: URL MUST end in .mpd so MPV detects DASH format via file extension.
// /proxy/mpd?... → no extension → MPV treats as generic file → no segments fetched
// /proxy/stream.mpd?... → .mpd extension → MPV uses DASH demuxer → segments fetched ✓
//
// For each <Representation id="X">, expands $RepresentationID$ → X in the
// SegmentTemplate, then makes initialization/media into absolute proxy URLs
// through /proxy/cdn/:session/:file (which injects the CloudFront Cookie).
// MPV only needs to expand $Number%05d$ — safe, it's inside $...$ delimiters.
const _mpdHandler = async (req, res) => {
  const url     = _safeUrl(decodeURIComponent(req.query.url    || ''));
  const referer = decodeURIComponent(req.query.ref    || '');
  const cookie  = decodeURIComponent(req.query.cookie || '');
  if (!url) return res.status(400).end('Missing url');

  try {
    // Fetch MPD from CDN (cache-first, keyed by url+cookie)
    let mpd;
    const cacheKey = _mpdCacheKey(url, cookie) + ':raw';
    const cached   = _mpdCache.get(cacheKey);
    if (cached && cached.expiresAt > Date.now()) {
      mpd = cached.mpd;
      console.log('[MPD-Proxy] Cache hit');
    } else {
      const hdrs = { 'User-Agent': getUA(url), 'Accept': 'application/dash+xml, */*' };
      if (referer) hdrs['Referer'] = referer;
      if (cookie)  hdrs['Cookie']  = cookie;
      const resp = await axios.get(url, { headers: hdrs, timeout: 20000 });
      mpd = typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data);
      _mpdCache.set(cacheKey, { mpd, expiresAt: Date.now() + _MPD_TTL });
    }

    const mpdBase  = url.substring(0, url.lastIndexOf('/') + 1);
    // Reuse session for repeated MPV requests to same (url, cookie) — see _getOrCreateSession comment.
    const session  = _getOrCreateSession(cookie, referer, mpdBase, url);
    const proxyPfx = `http://127.0.0.1:3000/proxy/cdn/${session}/`;

    // For each <Representation id="X">…</Representation> block:
    // • Expand $RepresentationID$ → X in initialization= and media= attributes
    // • Prefix the filename with our proxy base URL (absolute URL)
    // CRITICAL: Replace $Number%05d$ with $Number$ (no format specifier).
    //   Why: FFmpeg URL-decodes %05 → ASCII ENQ (0x05 control char) in the
    //   absolute URL string BEFORE template expansion. ENQ corrupts the token
    //   $Number%05d$ → FFmpeg can't recognize it → no segments fetched.
    //   With $Number$, FFmpeg expands to bare integers (1, 2, 3…).
    //   Our /proxy/cdn/:session/:file route zero-pads the integer back to 5 digits
    //   before forwarding to the CDN (which expects chunk-stream0-00001.m4s).
    const rewritten = mpd.replace(
      /<Representation([^>]*\bid="([^"]+)"[^>]*)>([\s\S]*?)<\/Representation>/gi,
      (fullMatch, reprAttrs, reprId, reprContent) => {
        const rewrittenContent = reprContent
          .replace(/\binitialization="([^"]+)"/gi, (_, v) => {
            const expanded = v.replace(/\$RepresentationID\$/g, reprId);
            return `initialization="${proxyPfx + expanded}"`;
          })
          .replace(/\bmedia="([^"]+)"/gi, (_, v) => {
            // 1. Expand $RepresentationID$
            let expanded = v.replace(/\$RepresentationID\$/g, reprId);
            // 2. Replace $Number%05d$ → $Number$ so no %xx in URL
            expanded = expanded.replace(/\$Number%0*\d*d\$/g, '$Number$');
            return `media="${proxyPfx + expanded}"`;
          });
        return `<Representation${reprAttrs}>${rewrittenContent}</Representation>`;
      }
    );

    res.setHeader('Content-Type', 'application/dash+xml');
    res.setHeader('Access-Control-Allow-Origin', '*');
    console.log(`[MPD-Proxy] Served rewritten MPD (session=${session})`);
    res.send(rewritten);
  } catch (err) {
    console.error('[MPD-Proxy] Error:', err.message);
    res.status(502).send(err.message);
  }
};

// Register on BOTH routes:
// • /stream.mpd  ← primary, URL ends in .mpd → MPV detects DASH via extension ✓
// • /mpd         ← legacy alias (no extension, kept for backward compat)
router.get('/stream.mpd', _mpdHandler);
router.get('/mpd',        _mpdHandler);


// ── /cdn/:session/:file — CDN segment proxy ──────────────────────────────────
// MPV requests: /cdn/{session}/{filename}
// • init: init-stream0.m4s  (no number padding needed)
// • media: chunk-stream0-$Number$.m4s expanded → chunk-stream0-1.m4s (bare int)
//   We zero-pad the number back to 5 digits before forwarding to CDN.
//   CDN expects: chunk-stream0-00001.m4s (zero-padded to 5 digits)
router.get('/cdn/:session/:file', async (req, res) => {
  const controller = new AbortController();
  req.on('close', () => {
    try { controller.abort(); } catch (_) {}
  });

  const session = _getSession(req.params.session);
  if (!session || session.aborted) {
    console.warn('[CDN] Session expired, aborted, or not found:', req.params.session);
    if (!res.headersSent) {
      res.status(410).end('Session expired or aborted');
    }
    return;
  }

  // Register controller
  session.activeControllers.add(controller);

  try {
    const rawFile = req.params.file;

    if (!rawFile) return res.status(400).end('Missing file');

    // Zero-pad segment numbers: chunk-stream0-1.m4s → chunk-stream0-00001.m4s
    // ONLY pads chunk-* files (not init-* files — their trailing digit is a repr ID)
    // Pattern: chunk-{reprId}-{segmentNumber}.m4s
    const file = rawFile.replace(
      /^(chunk-[^-]+-?)(\d+)(\.[a-z0-9]+)$/i,
      (_, prefix, num, ext) => num.length < 5 ? `${prefix}${num.padStart(5, '0')}${ext}` : rawFile
    );

    const cdnBase = session.cdnBase || '';
    const cdnUrl  = cdnBase + file;
    if (!cdnBase) {
      console.warn('[CDN] Session not found or expired:', req.params.session);
      return res.status(403).end('Session expired — reload the stream');
    }

    const reqHeaders = {
      'User-Agent': getUA(cdnUrl),
      'Accept':     '*/*',
    };
    if (session.cookie)  reqHeaders['Cookie']  = session.cookie;
    if (session.referer) reqHeaders['Referer'] = session.referer;
    if (req.headers['range']) reqHeaders['Range'] = req.headers['range'];

    console.log(`[CDN] ${file}`);

    const cdnResp = await axios.get(cdnUrl, {
      headers: reqHeaders, responseType: 'arraybuffer', timeout: 30000,
      signal: controller.signal,
    });

    const ct = cdnResp.headers['content-type'] || 'application/octet-stream';
    const cl = cdnResp.headers['content-length'];
    const cr = cdnResp.headers['content-range'];
    res.setHeader('Content-Type', ct);
    res.setHeader('Access-Control-Allow-Origin', '*');
    if (cl) res.setHeader('Content-Length', cl);
    if (cr) res.setHeader('Content-Range', cr);

    res.status(cdnResp.status === 206 ? 206 : 200).send(Buffer.from(cdnResp.data));
  } catch (err) {
    if (err.name === 'AbortError' || err.code === 'ERR_CANCELED' || axios.isCancel(err)) {
      console.log(`[CDN] Request aborted for ${req.params.file}`);
      if (!res.headersSent) {
        res.status(499).end('Client Closed Request');
      }
      return;
    }
    console.error('[CDN] Error:', err.message);
    if (!res.headersSent) {
      res.status(502).end(err.message);
    }
  } finally {
    session.activeControllers.delete(controller);
  }
});


// ── /proxy/video — streams direct MKV/MP4/WebM with Range request support ─────
// MPV sends byte-range requests for seeking; this proxy forwards them to CDN
router.get(["/video", "/video/:filename"], async (req, res) => {
  const controller = new AbortController();
  req.on('close', () => {
    try { controller.abort(); } catch (_) {}
  });

  const url = _safeUrl(decodeURIComponent(req.query.url || ''));
  const referer = decodeURIComponent(req.query.ref || '');
  console.log(`[Proxy] /video requested. Filename: ${req.params.filename || 'none'}`);
  console.log(`  Target URL: ${url}`);
  console.log(`  Range     : ${req.headers['range'] || 'none'}`);

  if (!url) {
    console.error(`  [Proxy] Error: Missing url parameter`);
    return res.status(400).end('Missing url parameter');
  }

  const reqHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Connection': 'keep-alive',
  };
  if (referer) {
    reqHeaders['Referer'] = referer;
    try { reqHeaders['Origin'] = new URL(referer).origin; } catch {}
  }
  // Forward Range header so MPV can seek
  if (req.headers['range']) {
    reqHeaders['Range'] = req.headers['range'];
  }

  try {
    const upstream = await axios({
      method: 'get',
      url,
      headers: reqHeaders,
      responseType: 'stream',
      validateStatus: () => true,
      maxRedirects: 10,
      timeout: 15000,
      signal: controller.signal,
    });

    // Forward status (206 Partial Content for Range requests)
    res.status(upstream.status);

    // Forward essential headers for MPV to understand the stream
    const fwdHeaders = [
      'content-type', 'content-length', 'content-range',
      'accept-ranges', 'last-modified', 'etag', 'cache-control',
    ];
    for (const h of fwdHeaders) {
      if (upstream.headers[h]) res.setHeader(h, upstream.headers[h]);
    }
    // Always advertise byte-range support
    res.setHeader('Accept-Ranges', 'bytes');
    res.setHeader('Access-Control-Allow-Origin', '*');

    // Stream data and handle client disconnect
    upstream.data.pipe(res);
    req.on('close', () => { try { upstream.data.destroy(); } catch {} });
    req.on('aborted', () => { try { upstream.data.destroy(); } catch {} });

  } catch (err) {
    console.error(`  [Proxy] Upstream error for ${url}: ${err.message}`);
    if (!res.headersSent) res.status(502).end(err.message);
  }
});

export default router;


