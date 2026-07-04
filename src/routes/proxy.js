import express from "express";
import rawAxios from "axios";
import { createDecipheriv } from "crypto";
import { dnsAxios as axios, getSlowMode, createStreamAxios, createDirectAxios, createDirectStreamAxios } from "../services/dnsAxios.js";

const streamAxios = createStreamAxios();
const directAxios = createDirectAxios();
const directStreamAxios = createDirectStreamAxios();

async function fetchWithWarpFallback(url, options) {
  try {
    return await streamAxios.get(url, options);
  } catch (err) {
    const errStr = (err.message || String(err)).toLowerCase();
    const isProxyError = err.code === 'ECONNREFUSED' ||
                         errStr.includes('socks') ||
                         errStr.includes('proxy') ||
                         errStr.includes('connectionrefused') ||
                         errStr.includes('hostunreachable');
    if (isProxyError) {
      console.warn(`[Proxy] WARP SOCKS5 proxy failed or refused connection (${err.message || err}). Falling back to direct connection for: ${url}`);
      return await directStreamAxios.get(url, options);
    }
    throw err;
  }
}


const router = express.Router();

// ── CENC Decryption Helpers (server-side decrypt for Cricify DASH streams) ─────
// Reads a big-endian 32-bit unsigned integer from a Buffer
const _ru32 = (b, o) => (b[o] * 0x1000000 + (b[o+1] << 16) + (b[o+2] << 8) + b[o+3]) >>> 0;
const _ru16 = (b, o) => ((b[o] << 8) | b[o+1]) >>> 0;
const _wu32 = (b, o, v) => { b[o]=(v>>>24)&0xFF; b[o+1]=(v>>>16)&0xFF; b[o+2]=(v>>>8)&0xFF; b[o+3]=v&0xFF; };

// Parse consecutive MP4 boxes within a byte range, return [{type,s,e}]
function _parseBoxList(buf, start, end) {
  const r = [];
  let p = start;
  while (p + 8 <= end) {
    const sz = _ru32(buf, p);
    if (sz < 8 || p + sz > end) break;
    r.push({ type: buf.slice(p+4, p+8).toString('ascii'), s: p, e: p+sz });
    p += sz;
  }
  return r;
}

// Find first box of given type within a byte range (non-recursive)
function _findBox(buf, start, end, type) {
  let p = start;
  while (p + 8 <= end) {
    const sz = _ru32(buf, p);
    if (sz < 8) break;
    if (buf.slice(p+4, p+8).toString('ascii') === type) return { s: p, e: p+sz };
    p += sz;
  }
  return null;
}

/**
 * Patch CENC init segment: convert encv→avc1 / enca→mp4a, strip sinf box.
 * The encrypted sample entry wraps the real codec box; we unwrap it so
 * the player treats the content as clear (unencrypted) media.
 */
function _patchInitSegment(inputBuf) {
  const buf = Buffer.from(inputBuf);

  function scan(s, e) {
    let p = s;
    while (p + 8 <= e) {
      const sz = _ru32(buf, p);
      if (sz < 8 || p + sz > e) break;
      const t = buf.slice(p+4, p+8).toString('ascii');
      if (t === 'encv' || t === 'enca') {
        _patchEncBox(buf, p, p+sz, t);
      } else if (['moov','trak','mdia','minf','stbl','stsd'].includes(t)) {
        scan(p+8, p+sz); // recurse into container boxes
      }
      p += sz;
    }
  }
  scan(0, buf.length);
  return buf;
}

function _patchEncBox(buf, boxStart, boxEnd, type) {
  // Rename outer box: encv→avc1 or enca→mp4a
  buf.write(type === 'encv' ? 'avc1' : 'mp4a', boxStart + 4, 4, 'ascii');

  // After the 8-byte box header, there's a fixed-size sample entry header:
  //   Video (encv): 78 bytes  (6 reserved + 2 ref + 70 visual_entry_fields)
  //   Audio (enca): 28 bytes  (6 reserved + 2 ref + 8 reserved + 2 ch + 2 sz + 2 + 2 + 4)
  const hdrSize = type === 'encv' ? 78 : 28;
  const innerStart = boxStart + 8 + hdrSize;

  // Find inner codec box and sinf within the encv/enca
  let iCodecStart = -1, iCodecEnd = -1;
  let sinfStart = -1, sinfEnd = -1;
  let p = innerStart;
  while (p + 8 <= boxEnd) {
    const sz = _ru32(buf, p);
    if (sz < 8) break;
    const t = buf.slice(p+4, p+8).toString('ascii');
    if (['avc1','hvc1','hev1','mp4a','Opus','ac-3'].includes(t)) {
      iCodecStart = p; iCodecEnd = p + sz;
    } else if (t === 'sinf') {
      sinfStart = p; sinfEnd = p + sz;
    }
    p += sz;
  }

  // Extract inner codec box CONTENT (skip its 8-byte header) → these are avcC/esds/etc.
  if (iCodecStart >= 0) {
    const innerContent = Buffer.from(buf.slice(iCodecStart + 8, iCodecEnd));
    // Write inner codec content directly at innerStart, overwriting old inner box header
    innerContent.copy(buf, innerStart);

    // Pad remaining space (old inner box beyond content) with a 'free' box
    const remStart = innerStart + innerContent.length;
    const remEnd = sinfStart >= 0 ? sinfStart : boxEnd;
    if (remEnd >= remStart + 8) {
      _wu32(buf, remStart, remEnd - remStart);
      buf.write('free', remStart + 4, 4, 'ascii');
      buf.fill(0, remStart + 8, remEnd);
    } else if (remEnd > remStart) {
      buf.fill(0, remStart, remEnd);
    }
  }

  // Neutralize sinf: rename to 'free' and zero content
  if (sinfStart >= 0) {
    buf.write('free', sinfStart + 4, 4, 'ascii');
    buf.fill(0, sinfStart + 8, sinfEnd);
  }
}

/**
 * Decrypt a CENC-encrypted fMP4 media segment (moof+mdat).
 * Uses AES-128-CTR with per-sample IVs from the SENC box.
 * Supports both subsample (video NAL) and full-sample (audio) encryption.
 */
function _decryptCencSegment(inputBuf, keyHex) {
  if (!keyHex || keyHex.length !== 32) return inputBuf; // invalid key
  let key;
  try { key = Buffer.from(keyHex, 'hex'); } catch (_) { return inputBuf; }

  const buf = Buffer.from(inputBuf);
  const topBoxes = _parseBoxList(buf, 0, buf.length);

  for (let i = 0; i < topBoxes.length; i++) {
    const moof = topBoxes[i];
    if (moof.type !== 'moof') continue;

    // Find mdat immediately following this moof
    let mdat = null;
    for (let j = i+1; j < topBoxes.length; j++) {
      if (topBoxes[j].type === 'mdat') { mdat = topBoxes[j]; break; }
    }
    if (!mdat) continue;

    // Navigate: moof → traf → senc (IVs) and trun (sample sizes)
    const traf = _findBox(buf, moof.s+8, moof.e, 'traf');
    if (!traf) continue;
    const senc = _findBox(buf, traf.s+8, traf.e, 'senc');
    if (!senc) continue; // no per-sample encryption info → skip

    // Parse SENC: version(1) flags(3) sample_count(4)
    const sData = senc.s + 8;
    const sFlags = _ru32(buf, sData) & 0xFFFFFF;
    const sCount = _ru32(buf, sData + 4);
    const useSubs = (sFlags & 0x2) !== 0;
    let sp = sData + 8;

    // Parse trun for per-sample sizes
    const trun = _findBox(buf, traf.s+8, traf.e, 'trun');
    const sampleSizes = [];
    if (trun) {
      const tData = trun.s + 8;
      const tFlags = _ru32(buf, tData) & 0xFFFFFF;
      const tCount = _ru32(buf, tData + 4);
      let tp = tData + 8;
      if (tFlags & 0x1) tp += 4;   // data_offset
      if (tFlags & 0x4) tp += 4;   // first_sample_flags
      for (let s = 0; s < tCount; s++) {
        let sz = 0;
        if (tFlags & 0x100) tp += 4; // sample_duration
        if (tFlags & 0x200) { sz = _ru32(buf, tp); tp += 4; } // sample_size
        if (tFlags & 0x400) tp += 4; // sample_flags
        if (tFlags & 0x800) tp += 4; // composition_time_offset
        sampleSizes.push(sz);
      }
    }

    // Parse samples from SENC (CENC = 8-byte IVs padded to 16 with zeros)
    const samples = [];
    for (let s = 0; s < sCount; s++) {
      if (sp + 8 > senc.e) break;
      const iv = Buffer.alloc(16, 0);
      buf.copy(iv, 0, sp, sp + 8);
      sp += 8;
      let subs = null;
      if (useSubs) {
        const nSubs = _ru16(buf, sp); sp += 2;
        subs = [];
        for (let j = 0; j < nSubs && sp + 6 <= senc.e; j++) {
          subs.push({ clear: _ru16(buf, sp), enc: _ru32(buf, sp+2) });
          sp += 6;
        }
      }
      samples.push({ iv, subs, size: sampleSizes[s] || 0 });
    }

    // Decrypt encrypted bytes in mdat
    let mdatPos = mdat.s + 8;
    for (const sample of samples) {
      if (sample.subs && sample.subs.length > 0) {
        try {
          const dec = createDecipheriv('aes-128-ctr', key, sample.iv);
          for (const sub of sample.subs) {
            mdatPos += sub.clear;
            if (sub.enc > 0 && mdatPos + sub.enc <= buf.length) {
              const decryptedChunk = dec.update(buf.subarray(mdatPos, mdatPos + sub.enc));
              decryptedChunk.copy(buf, mdatPos);
            }
            mdatPos += sub.enc;
          }
        } catch (_) {}
      } else if (sample.size > 0 && mdatPos + sample.size <= buf.length) {
        try {
          const dec = createDecipheriv('aes-128-ctr', key, sample.iv);
          const decryptedChunk = dec.update(buf.subarray(mdatPos, mdatPos + sample.size));
          decryptedChunk.copy(buf, mdatPos);
        } catch (_) {}
        mdatPos += sample.size;
      }
    }
  }
  return buf;
}

function abs(base, relative){
    try{
        let res = new URL(relative, base);
        if (!res.search) {
            const baseObj = new URL(base);
            if (baseObj.search) {
                res.search = baseObj.search;
            }
        }
        return res.href;
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

// NOTE: woff2 disguise was tested but reverted — CDN nodes return 400 Bad Request
// for .woff2 extensions. The browser network tab showed .woff2 on a specific CDN
// node that happened to support it, but most nodes only accept .m4s.
function _disguiseSegUrl(url) {
  return url; // no rewrite — keep original .m4s extension
}

// ── CDN Node Health Tracker ───────────────────────────────────────────────────
// Tracks 502/5xx failures per CDN IP. After 3 consecutive failures,
// the node is marked dead for 5 minutes and segment requests are re-routed
// to the Cloudflare CDN fallback domain.
// This prevents MPV from seeing enough 502s to treat the stream as ended
// (the "7 second video" / "stream ends randomly" bug).
const _cdnFailures = new Map(); // hostname → { count, lastFail }
const CDN_FAIL_THRESHOLD = 3;     // failures before marking as dead
const CDN_DEAD_TTL = 5 * 60 * 1000; // 5 minutes before re-trying dead node

function _isCdnNodeDead(hostname) {
  const entry = _cdnFailures.get(hostname);
  if (!entry) return false;
  if (Date.now() - entry.lastFail > CDN_DEAD_TTL) {
    _cdnFailures.delete(hostname);
    return false;
  }
  return entry.count >= CDN_FAIL_THRESHOLD;
}

function _recordCdnFailure(hostname) {
  const entry = _cdnFailures.get(hostname) || { count: 0, lastFail: 0 };
  entry.count++;
  entry.lastFail = Date.now();
  _cdnFailures.set(hostname, entry);
  if (entry.count === CDN_FAIL_THRESHOLD) {
    console.warn(`[CDN] Node ${hostname} marked as dead after ${CDN_FAIL_THRESHOLD} failures. Will use CF fallback.`);
  }
}

function _recordCdnSuccess(hostname) {
  if (_cdnFailures.has(hostname)) _cdnFailures.delete(hostname);
}

// Build a Cloudflare fallback URL from a dead direct-IP CDN URL.
// Direct IP:  http://185.x.x.x/v4/TOKEN/TS/s93/VIDEO_ID/seg-N-f1-v1.m4s
// CF fallback: https://CF_DOMAIN/v4/s93/VIDEO_ID/seg-N-f1-v1.m4s
// CF_DOMAIN is looked up from the referer or stored session.
function _buildCfFallback(url) {
  try {
    const parsed = new URL(url);
    // Only applies to direct-IP hubstream CDN URLs
    if (!parsed.hostname.match(/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/)) return null;
    if (!parsed.pathname.includes('/v4/')) return null;
    // Path: /v4/TOKEN/TIMESTAMP/s93/VIDEO_ID/seg-N-...
    // We need to extract: /s93/VIDEO_ID/seg-N-...
    const pathParts = parsed.pathname.split('/');
    // Find the index of 's93' or similar segment identifier
    const s93Idx = pathParts.findIndex(p => p === 's93' || p === 'djx' || p === 'djt');
    if (s93Idx < 0) return null;
    let segPath = pathParts.slice(s93Idx).join('/');
    
    // Cloudflare CDN disguises HLS media as web font assets to bypass ISP blocks.
    // Rewrite standard extensions (.mp4/.m4s) to bypass extensions (.woff/.woff2).
    if (segPath.endsWith('.mp4')) {
      segPath = segPath.replace(/\.mp4$/, '.woff');
    } else if (segPath.endsWith('.m4s')) {
      segPath = segPath.replace(/\.m4s$/, '.woff2');
    }

    // Use a known working CF domain
    const cfDomain = _cfDomain || 's3ae.luminaryvision.shop';
    return `https://${cfDomain}/v4/${segPath}`;
  } catch (_) { return null; }
}

// Remember the last CF domain seen from hubstream API responses
let _cfDomain = '';

// Call this when the provider resolves a CF URL to remember the domain
function _rememberCfDomain(cfUrl) {
  try {
    const h = new URL(cfUrl).hostname;
    if (h.includes('.')) _cfDomain = h;
  } catch (_) {}
}


// ── Inject Hubstream Chrome Headers ──────────────────────────────────────────
// CDN edge nodes return 502 Bad Gateway if we pass the raw IP in the Host header
// or miss the sec-ch-ua/sec-fetch headers, which triggers bot detection.
// Mimicking Chrome's exact headers completely bypasses this.
function _injectHubstreamHeaders(url, headers) {
  try {
    if (url.includes('/v4/')) {
      const parsed = new URL(url);
      if (parsed.hostname.match(/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/)) {
        headers['Host'] = 'hubstream.art';
      }
      headers['sec-ch-ua'] = '"Google Chrome";v="120", "Chromium";v="120", "Not)A;Brand";v="24"';
      headers['sec-ch-ua-mobile'] = '?0';
      headers['sec-ch-ua-platform'] = '"Windows"';
      headers['sec-fetch-dest'] = 'empty';
      headers['sec-fetch-mode'] = 'cors';
      headers['sec-fetch-site'] = 'cross-site';
      headers['Accept-Language'] = 'en-US,en;q=0.9';
    }
  } catch (_) {}
}

// ── Inject Netmirror Headers ──────────────────────────────────────────────────
// Netmirror CDN/media servers aggressively throttle or block requests
// that do not send the app's specific headers ('ott', 'X-Requested-With',
// and NetmirrorNewTV User-Agent). Injecting these fixes playback speed issues.
function _injectNetmirrorHeaders(url, headers, forcedOtt) {
  try {
    const parsed = new URL(url);
    const host = parsed.hostname.toLowerCase();
    if (host.includes('imgcdn.kim') || host.includes('freecdn') || host.includes('subscdn.top') || host.includes('nm-cdn')) {
      let ott = forcedOtt || 'nf';
      if (!forcedOtt) {
        if (parsed.pathname.includes('/pv/') || url.includes('/pv/')) {
          ott = 'pv';
        } else if (parsed.pathname.includes('/hs/') || url.includes('/hs/')) {
          ott = 'hs';
        } else if (parsed.pathname.includes('/nf/') || url.includes('/nf/')) {
          ott = 'nf';
        }
      }
      headers['ott'] = ott;
      headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:136.0) Gecko/20100101 Firefox/136.0 /OS.GatuNewTV v1.0';
      headers['X-Requested-With'] = 'NetmirrorNewTV v1.0';
      headers['Referer'] = 'https://net52.cc/';
      headers['Origin'] = 'https://net52.cc';
    }
  } catch (_) {}
}

// Enforce a sliding window of exactly maxSegments (e.g. 15) on live HLS media playlists.
// Adjusts the MEDIA-SEQUENCE tag monotonically so the player's timeline shifts back smoothly.
function _enforceHlsSlidingWindow(text, maxSegments = 15) {
  if (text.includes('#EXT-X-ENDLIST')) return text; // VOD - don't touch
  if (!text.includes('#EXTINF')) return text;

  const lines = text.split('\n');
  const headers = [];
  const segments = [];
  let currentSeg = [];
  let foundFirstSeg = false;

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    if (!foundFirstSeg) {
      if (trimmed.startsWith('#EXTINF') || trimmed.startsWith('#EXT-X-DISCONTINUITY') || trimmed.startsWith('#EXT-X-KEY')) {
        foundFirstSeg = true;
        currentSeg.push(line);
      } else {
        headers.push(line);
      }
    } else {
      currentSeg.push(line);
      if (!trimmed.startsWith('#')) {
        segments.push(currentSeg);
        currentSeg = [];
      }
    }
  }

  if (currentSeg.length > 0) {
    const hasUrl = currentSeg.some(l => l.trim() && !l.trim().startsWith('#'));
    if (hasUrl) segments.push(currentSeg);
    else headers.push(...currentSeg);
  }

  if (segments.length <= maxSegments) {
    const cleanedHeaders = headers.filter(l => !l.includes('#EXT-X-PLAYLIST-TYPE'));
    return [...cleanedHeaders, ...segments.flat(), ''].join('\n');
  }

  const K = segments.length - maxSegments;
  const useSegments = segments.slice(K);

  // Parse and update media sequence
  let mediaSeq = 0;
  let mediaSeqIndex = -1;
  for (let i = 0; i < headers.length; i++) {
    const m = headers[i].match(/#EXT-X-MEDIA-SEQUENCE:(\d+)/i);
    if (m) {
      mediaSeq = parseInt(m[1], 10);
      mediaSeqIndex = i;
      break;
    }
  }

  const newMediaSeq = mediaSeq + K;
  const finalHeaders = [];
  for (let i = 0; i < headers.length; i++) {
    const line = headers[i];
    if (line.includes('#EXT-X-PLAYLIST-TYPE')) continue;
    if (i === mediaSeqIndex) {
      finalHeaders.push(`#EXT-X-MEDIA-SEQUENCE:${newMediaSeq}`);
    } else {
      finalHeaders.push(line);
    }
  }
  if (mediaSeqIndex === -1) {
    finalHeaders.push(`#EXT-X-MEDIA-SEQUENCE:${newMediaSeq}`);
  }

  return [...finalHeaders, ...useSegments.flat(), ''].join('\n');
}

router.get("/hls", async (req,res)=>{

    try{

        const target = _safeUrl(req.query.url || "");
        console.log(`[HLS] Requesting: ${target.split('/').pop().split('?')[0]} (${target.includes('?in=') ? 'authenticated' : 'NO_AUTH'})`);
        const referer = req.query.ref || "";
        const cookie  = req.query.cookie || "";
        const queryOtt = req.query.ott || "";
        
        let ott = queryOtt;
        if (!ott) {
            if (target.includes('/pv/') || target.includes('/hls/pv/')) ott = 'pv';
            else if (target.includes('/hs/') || target.includes('/hls/hs/')) ott = 'hs';
            else if (target.includes('/nf/') || target.includes('/hls/nf/')) ott = 'nf';
        }

        let normalizedReferer = referer;
        if (normalizedReferer.includes('megaplay.buzz') || normalizedReferer.includes('megaplay')) {
            normalizedReferer = 'https://megaplay.buzz/';
        }

        const queryUa = req.query.ua || "";
        const queryOrigin = req.query.origin || "";
        let customUa = queryUa || getUA(target);
        let customRef = normalizedReferer;
        let customOrigin = queryOrigin || (normalizedReferer ? new URL(normalizedReferer).origin : "");

        if (target.includes('toffeelive.com')) {
          customUa = "Toffee (Linux;Android 14)";
        } else if (target.includes('tapmadlive') || target.includes('akamaized')) {
          customRef = "https://www.tapmad.com/";
          customOrigin = "https://www.tapmad.com";
          customUa = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
        }

        const headers = {
            Referer: customRef,
            Origin: customOrigin,
            "User-Agent": customUa,
            "Accept": "*/*",
        };
        if (cookie) headers["Cookie"] = cookie;
        _injectHubstreamHeaders(target, headers);
        _injectNetmirrorHeaders(target, headers, ott);

        const response = await fetchWithWarpFallback(target,{ headers });
        const text = typeof response.data === 'string' ? response.data : '';

        if (!text.includes('#EXTM3U') && !text.includes('#EXT-X-')) {
          return res.status(400).send('Invalid M3U playlist response from origin');
        }

        const uaSuffix = queryUa ? `&ua=${encodeURIComponent(queryUa)}` : '';
        const originSuffix = queryOrigin ? `&origin=${encodeURIComponent(queryOrigin)}` : '';
        const sportsSuffix = req.query.sports ? `&sports=${req.query.sports}` : '';

        // ── Master playlist? Rewrite ALL variant URLs through our proxy ──────
        if (text.includes('#EXT-X-STREAM-INF') || text.includes('#EXT-X-I-FRAME-STREAM-INF')) {
            const lines = text.split('\n');

            // Find query parameters from variant URL lines (e.g. ?in=...)
            let queryParams = '';
            for (const line of lines) {
                const trimmed = line.trim();
                if (trimmed && !trimmed.startsWith('#')) {
                    const idx = trimmed.indexOf('?');
                    if (idx !== -1) {
                        queryParams = trimmed.substring(idx);
                        break;
                    }
                }
            }

            const cookieSuffix = cookie ? `&cookie=${encodeURIComponent(cookie)}` : '';
            const rewritten = lines.map(line => {
                const trimmed = line.trim();
                if (!trimmed || trimmed.startsWith('#')) {
                    // Keep comment/tag lines — but rewrite URI= attributes inside them
                    return line.replace(/URI="([^"]+)"/g, (_, uri) => {
                        let absolute = abs(target, uri);
                        if (queryParams && !absolute.includes('?')) {
                            absolute += queryParams;
                        }
                        return `URI="http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent(absolute)}&ref=${encodeURIComponent(referer)}${cookieSuffix}&ott=${ott}${uaSuffix}${originSuffix}${sportsSuffix}"`;
                    });
                }
                // Variant URL line — rewrite through proxy
                const absolute = abs(target, trimmed);
                return `http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent(absolute)}&ref=${encodeURIComponent(referer)}${cookieSuffix}&ott=${ott}${uaSuffix}${originSuffix}${sportsSuffix}`;
            }).join('\n');

            // ── English audio forced default ──────────────────────────────────────
            // If the master has multiple TYPE=AUDIO entries (e.g. Netmirror has 30+
            // language tracks), find the English one and set DEFAULT=YES on it while
            // setting DEFAULT=NO on all others. MPV uses DEFAULT=YES to auto-select audio.
            let finalPlaylist = rewritten;
            if (rewritten.includes('TYPE=AUDIO')) {
                const audioLines = rewritten.split('\n').filter(l => l.includes('#EXT-X-MEDIA') && l.includes('TYPE=AUDIO'));
                if (audioLines.length > 1) {
                    // Find the English track index
                    const isEnglish = (l) => {
                        const langMatch = l.match(/LANGUAGE="([^"]+)"/i);
                        const nameMatch = l.match(/NAME="([^"]+)"/i);
                        const lang = (langMatch?.[1] || '').toLowerCase();
                        const name = (nameMatch?.[1] || '').toLowerCase();
                        return lang === 'en' || lang === 'eng' || lang.startsWith('en') ||
                               name.includes('english') || name === 'en';
                    };
                    const defaultIdx = audioLines.findIndex(isEnglish);
                    const targetIdx = defaultIdx >= 0 ? defaultIdx : 0; // fallback: first track

                    // Rewrite DEFAULT/AUTOSELECT attributes for all audio lines
                    finalPlaylist = rewritten.split('\n').map(line => {
                        if (!line.includes('#EXT-X-MEDIA') || !line.includes('TYPE=AUDIO')) return line;
                        const isTarget = line === audioLines[targetIdx];
                        return line
                            .replace(/DEFAULT=(YES|NO)/gi, `DEFAULT=${isTarget ? 'YES' : 'NO'}`)
                            .replace(/AUTOSELECT=(YES|NO)/gi, `AUTOSELECT=${isTarget ? 'YES' : 'NO'}`);
                    }).join('\n');
                    console.log(`[HLS] Audio default forced to track ${targetIdx} (${defaultIdx >= 0 ? 'English found' : 'fallback to first'})`);
                }
            }

            res.setHeader('Content-Type', 'application/vnd.apple.mpegurl');
            return res.send(finalPlaylist);
        }

        // ── Media playlist: rewrite segment/key URLs ──────────────────────────
        const cookieSuffix = cookie ? `&cookie=${encodeURIComponent(cookie)}` : '';
        const rewritten = text
            .split("\n")
            .map(line=>{

                const trimmed = line.trim();

                if(!trimmed) return line;

                if(trimmed.startsWith("#")){

                    return line.replace(
                        /URI="([^"]+)"/g,
                        (_,uri)=>{

                            const absolute = abs(target, uri);
                            const segUrl   = _disguiseSegUrl(absolute);

                            return `URI="http://127.0.0.1:3000/proxy/segment?url=${encodeURIComponent(segUrl)}&ref=${encodeURIComponent(referer)}${cookieSuffix}&ott=${ott}${uaSuffix}${originSuffix}${sportsSuffix}"`;
                        }
                    );
                }

                const absolute = abs(target, trimmed);

                if (absolute.includes(".m3u8")) {
                    return `http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent(absolute)}&ref=${encodeURIComponent(referer)}${cookieSuffix}&ott=${ott}${uaSuffix}${originSuffix}${sportsSuffix}`;
                }

                const segUrl = _disguiseSegUrl(absolute);
                return `http://127.0.0.1:3000/proxy/segment?url=${encodeURIComponent(segUrl)}&ref=${encodeURIComponent(referer)}${cookieSuffix}&ott=${ott}${uaSuffix}${originSuffix}${sportsSuffix}`;

            })
            .join("\n");

        res.setHeader(
            "Content-Type",
            "application/vnd.apple.mpegurl"
        );

        let finalPlaylist = rewritten;
        if (req.query.sports === '1') {
            finalPlaylist = _enforceHlsSlidingWindow(rewritten, 15);
        }
        res.send(finalPlaylist);

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
        const queryOtt = req.query.ott || '';
        let sessionUa = '';
        let sessionOrigin = '';
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
          sessionUa = sess.ua || '';
          sessionOrigin = sess.origin || '';
          sess.activeControllers.add(controller);
        }
        if (!target) { res.status(400).end('Missing url'); return; }

        // Log segment fetches for debugging HEVC/CDN issues
        const segFile = target.split('/').pop().split('?')[0];
        console.log(`[Segment] Fetching: ${segFile} (cookie=${cookie.length > 0 ? 'YES' : 'NO'})`);

        const fileExt = (segFile.split('.').pop() || '').toLowerCase();
        // woff2/woff = hubstream CDN disguises .m4s segments as web-font files
        // to bypass Jio DPI. Treat them identically to fMP4 segments.
        const isFmp4 = ['m4s', 'mp4', 'm4a', 'm4v', 'woff', 'woff2'].includes(fileExt);

        const queryUa = req.query.ua || sessionUa || "";
        const queryOrigin = req.query.origin || sessionOrigin || "";
        let normalizedReferer = referer;
        if (normalizedReferer.includes('megaplay.buzz') || normalizedReferer.includes('megaplay')) {
            normalizedReferer = 'https://megaplay.buzz/';
        }

        const headers = {
            Referer: normalizedReferer,
            Origin: queryOrigin || (normalizedReferer ? new URL(normalizedReferer).origin : ""),
            "User-Agent": queryUa || getUA(target),
            ...(cookie ? { Cookie: cookie } : {}),
        };
        if (req.headers['range']) {
            headers['Range'] = req.headers['range'];
        }
        _injectHubstreamHeaders(target, headers);
        _injectNetmirrorHeaders(target, headers, queryOtt);

        let response;
        let attempt = 0;
        // 8 retries × 100ms flat delay = ~2 second max retry budget.
        // This ensures the proxy almost always returns 200 to MPV instead of 502.
        // Why: MPV's HLS demuxer treats repeated 5xx responses as end-of-stream
        // and stops playback entirely ("randomly ends video" bug).
        // The 15s cache readahead limit already prevents audio from running away,
        // so high retry counts no longer cause the audio-only loop.
        const maxAttempts = 8;

        // CDN dead-node check: if the CDN IP has been returning 502s, immediately
        // try the CF fallback instead of hammering the dead node.
        let actualTarget = target;
        try {
            const targetHost = new URL(target).hostname;
            if (_isCdnNodeDead(targetHost)) {
                const cfUrl = _buildCfFallback(target);
                if (cfUrl) {
                    console.warn(`[CDN] Skipping dead node ${targetHost}, using CF fallback for ${segFile}`);
                    actualTarget = cfUrl;
                    delete headers['Host'];
                    delete headers['host'];
                }
            }
        } catch (_) {}

        while (attempt < maxAttempts) {
            attempt++;
            try {
                response = await fetchWithWarpFallback(
                    actualTarget,
                    {
                        responseType: "stream",
                        signal: controller.signal,
                        headers
                    }
                );

                if (response.status >= 500 && attempt < maxAttempts) {
                    console.warn(`[Segment] CDN returned ${response.status} for ${segFile}, retrying (attempt ${attempt}/${maxAttempts})...`);
                    try { _recordCdnFailure(new URL(actualTarget).hostname); } catch (_) {}
                    // After 3 failures, switch to CF fallback
                    if (attempt >= CDN_FAIL_THRESHOLD) {
                        const cfUrl = _buildCfFallback(target);
                        if (cfUrl && cfUrl !== actualTarget) {
                            console.warn(`[CDN] Switching to CF fallback for ${segFile}: ${cfUrl}`);
                            actualTarget = cfUrl;
                            delete headers['Host'];
                            delete headers['host'];
                        }
                    }
                    await new Promise(r => setTimeout(r, 100));
                    continue;
                }
                try { _recordCdnSuccess(new URL(actualTarget).hostname); } catch (_) {}
                break;
            } catch (err) {
                if (err.name === 'AbortError' || err.code === 'ERR_CANCELED' || rawAxios.isCancel(err)) {
                    throw err;
                }
                console.error(`[Segment] Fetch attempt ${attempt} failed for ${segFile}: ${err.message}`);
                if (attempt >= maxAttempts) {
                    throw err;
                }
                if (attempt >= CDN_FAIL_THRESHOLD) {
                    const cfUrl = _buildCfFallback(target);
                    if (cfUrl && cfUrl !== actualTarget) {
                        console.warn(`[CDN] Switching to CF fallback for ${segFile} on error: ${cfUrl}`);
                        actualTarget = cfUrl;
                        delete headers['Host'];
                        delete headers['host'];
                    }
                }
                await new Promise(r => setTimeout(r, 100));
            }
        }

        const ct = response.headers["content-type"] || "application/octet-stream";
        const cr = response.headers["content-range"];
        const ext = (segFile.split('.').pop() || '').toLowerCase();

        res.setHeader('Access-Control-Allow-Origin', '*');
        if (cr) res.setHeader('Content-Range', cr);

        // Fast path for standard video/audio segments (ts, m4s, mp4, m4a, woff2)
        // Bypasses chunk-by-chunk manual buffer parsing for max throughput.
        // For CENC-encrypted segments (session.decryptionKey set), we must buffer
        // the whole segment first, decrypt, then send.
        if (['ts', 'm4s', 'mp4', 'm4a', 'm4v', 'woff', 'woff2', 'jpg', 'jpeg'].includes(ext)) {
          const mime = (ext === 'ts' || ext === 'jpg' || ext === 'jpeg') ? 'video/mp2t' : (ext === 'm4s' || ext === 'mp4' ? 'video/mp4' : ct);
          res.setHeader("Content-Type", mime);
          res.status(response.status === 206 ? 206 : response.status);

          // If this session has a CENC ClearKey, buffer + decrypt before sending
          const decKey = sess?.decryptionKey;
          if (decKey && ['mp4', 'm4s', 'm4a', 'm4v'].includes(ext)) {
            const chunks = [];
            await new Promise((resolve, reject) => {
              response.data.on('data', c => chunks.push(c));
              response.data.on('end', resolve);
              response.data.on('error', reject);
            });
            let rawBuf = Buffer.concat(chunks);
            // Detect segment type by looking for moov/moof/ftyp/styp boxes
            const firstBox = rawBuf.length >= 8 ? rawBuf.slice(4, 8).toString('ascii') : '';
            const hasInit = ['ftyp','styp','moov'].includes(firstBox);
            const hasMedia = rawBuf.indexOf('moof') >= 0; // coarse check
            try {
              if (hasInit) {
                rawBuf = _patchInitSegment(rawBuf);
                console.log(`[CENC] Patched init segment: ${segFile}`);
              }
              if (hasMedia || (!hasInit && rawBuf.length > 0)) {
                rawBuf = _decryptCencSegment(rawBuf, decKey);
              }
            } catch (decErr) {
              console.warn(`[CENC] Decryption error for ${segFile}:`, decErr.message);
            }
            res.setHeader('Content-Length', rawBuf.length);
            res.end(rawBuf);
            return;
          }

          // No decryption needed — fast pipe
          await new Promise((resolve, reject) => {
            response.data.pipe(res);
            response.data.on('end', resolve);
            response.data.on('error', reject);
          });
          return;
        }

        await new Promise((resolve, reject) => {
            let isFirstChunk = true;
            let contentType = ct;

            response.data.on('data', (chunk) => {
                try {
                    if (isFirstChunk) {
                        isFirstChunk = false;
                        
                        let boxType = '';
                        try {
                            if (chunk.length >= 8) {
                                boxType = chunk.slice(4, 8).toString('ascii').replace(/[^\x20-\x7e]/g, '');
                            }
                        } catch (_) {}

                        const isFmp4Fallback = ['m4s', 'mp4', 'm4a', 'm4v', 'woff', 'woff2', 'vtt', 'srt'].includes(ext) ||
                                               ['ftyp', 'styp', 'moof', 'moov', 'mdat'].includes(boxType);

                        let tsStart = -1;
                        if (!isFmp4Fallback) {
                            for (let i = 0; i < chunk.length - 376; i++) {
                                if (chunk[i] === 0x47 && chunk[i + 188] === 0x47) {
                                    tsStart = i;
                                    break;
                                }
                            }
                        }

                        let buf = chunk;
                        if (tsStart > 0) {
                            buf = chunk.slice(tsStart);
                        }

                        if (buf.length > 0) {
                            if (buf[0] === 0x47) {
                                contentType = "video/mp2t";
                            } else if (['ftyp', 'moof', 'moov', 'mdat'].includes(boxType)) {
                                contentType = "video/mp4";
                            } else if (['image/jpeg', 'image/png', 'image/webp', 'text/javascript', 'application/javascript', 'text/plain'].includes(ct)) {
                                contentType = "application/octet-stream";
                            }
                        }
                        res.setHeader("Content-Type", contentType);
                        
                        res.status(response.status === 206 ? 206 : response.status);
                        res.write(buf);
                    } else {
                        res.write(chunk);
                    }
                } catch (e) {
                    reject(e);
                }
            });

            response.data.on('end', () => {
                res.end();
                resolve();
            });

            response.data.on('error', (err) => {
                reject(err);
            });
        });


    }catch(err){
        const target = decodeURIComponent(req.query.url || '?');
        if (err.name === 'AbortError' || err.code === 'ERR_CANCELED' || rawAxios.isCancel(err)) {
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
const _MPD_TTL      = 12 * 60 * 1000; // 12 minutes (VOD / cached streams)
const _MPD_TTL_LIVE =          2000;  // 2 seconds  (live DASH — one segment duration)
function _mpdCacheKey(url, cookie) { return url + '::' + (cookie || '').slice(0, 24); }
function _getCachedSets(url, cookie) { const c = _mpdCache.get(_mpdCacheKey(url, cookie)); return (c && c.expiresAt > Date.now()) ? c : null; }
function _cacheSets(url, cookie, sets, isLive = false) { _mpdCache.set(_mpdCacheKey(url, cookie), { sets, isLive, expiresAt: Date.now() + (isLive ? _MPD_TTL_LIVE : _MPD_TTL) }); }

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

function _createSession(cookie, referer, cdnBase, ua, origin) {
  const id = Math.random().toString(36).slice(2, 10); // 8 random chars
  _sessions.set(id, { 
    cookie, 
    referer, 
    cdnBase: cdnBase || '', 
    ua: ua || '',
    origin: origin || '',
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
function _getOrCreateSession(cookie, referer, cdnBase, url, ua, origin) {
  const key = _mpdCacheKey(url, cookie);
  const existingId = _urlToSession.get(key);
  if (existingId) {
    const s = _sessions.get(existingId);
    if (s && s.expiresAt > Date.now() && !s.aborted) {
      // Refresh TTL on reuse
      s.expiresAt = Date.now() + _SESSION_TTL;
      if (ua) s.ua = ua;
      if (origin) s.origin = origin;
      return existingId;
    }
  }
  // Create fresh session and remember it for this (url, cookie)
  const newId = _createSession(cookie, referer, cdnBase, ua, origin);
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
  console.log('[Abort] GET /abort-all called. Cancelling in-flight segment downloads (sessions kept alive)...');
  let count = 0;
  for (const [id, session] of _sessions.entries()) {
    if (session.activeControllers && session.activeControllers.size > 0) {
      count++;
      for (const controller of session.activeControllers) {
        try { controller.abort(); } catch (_) {}
      }
      session.activeControllers.clear();
      // Reset aborted flag so future segment requests succeed
      session.aborted = false;
    }
  }
  // NOTE: Do NOT clear _mpdCache here — clearing it causes the player to
  // re-fetch MPD and get a new session ID embedded in sub-playlists, which
  // means old segment URLs (with the previous session ID) return 410 errors.
  res.status(200).send(`Cancelled downloads for ${count} sessions`);
});

router.post('/abort-all', (req, res) => {
  console.log('[Abort] POST /abort-all called. Cancelling in-flight segment downloads (sessions kept alive)...');
  let count = 0;
  for (const [id, session] of _sessions.entries()) {
    if (session.activeControllers && session.activeControllers.size > 0) {
      count++;
      for (const controller of session.activeControllers) {
        try { controller.abort(); } catch (_) {}
      }
      session.activeControllers.clear();
      session.aborted = false;
    }
  }
  res.status(200).send(`Cancelled downloads for ${count} sessions`);
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
    // Also check codecs: some MPDs label audio tracks as mimeType="video/mp4" with audio codecs
    const typeAttr  = attrs.match(/contentType="([^"]+)"/)?.[1];
    const mimeType  = inner.match(/mimeType="([^"]+)"/)?.[1] ||
                      attrs.match(/mimeType="([^"]+)"/)?.[1] || '';
    const codecStr  = inner.match(/codecs="([^"]+)"/)?.[1] || '';
    const isAudioCodec = /^(mp4a|ac-3|ec-3|opus|flac|dtsc|dtsh|dtse)/i.test(codecStr.trim());
    const contentType = typeAttr || (mimeType.startsWith('audio') ? 'audio' : (isAudioCodec ? 'audio' : 'video'));

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

/**
 * Build an HLS media playlist using a session ID so URLs stay short.
 * For live streams (isLive=true) only the most recent LIVE_WINDOW segments
 * are included as a sliding window (no EXT-X-PLAYLIST-TYPE — correct for live).
 * Tracks the highest MEDIA-SEQUENCE per session+track to prevent backward jumps
 * when the MPD segment count fluctuates between refreshes.
 */
const LIVE_WINDOW = 15; // 15 segments sliding window (~60-90 seconds) for live streams

function buildMediaPlaylist(set, mpdBase, sessionId, isLive = false, track = 'unknown') {
  const seg = (cdnRelative) => {
    const abs = new URL(cdnRelative, mpdBase).href;
    return `http://127.0.0.1:3000/proxy/segment?url=${encodeURIComponent(abs)}&s=${sessionId}`;
  };

  const expand = (tmpl, n) => {
    let s = tmpl.replace(/\$RepresentationID\$/g, set.reprId);
    s = s.replace(/\$Number%(\d+)d\$/g, (_, w) => String(n).padStart(parseInt(w), '0'));
    s = s.replace(/\$Number\$/g, String(n));
    return s;
  };

  const allSegs = set.segments;

  let useSegs, startSeqNum;

  if (isLive && allSegs.length > 0) {
    // Compute the ideal window: last LIVE_WINDOW segments from the MPD
    const windowSize = Math.min(LIVE_WINDOW, allSegs.length);
    const lastSegNum  = set.startNum + allSegs.length - 1;    // highest segment number in MPD
    const idealStart  = lastSegNum - windowSize + 1;          // first seg of ideal window

    // Monotonic guarantee: never let MEDIA-SEQUENCE go backward.
    // Store the highest startSeqNum we've ever sent for this session+track.
    const sess     = _sessions.get(sessionId);
    const seqKey   = `seq_${track}`;
    const prevSeq  = sess?.[seqKey] ?? idealStart;            // default: ideal on first call
    startSeqNum    = Math.max(idealStart, prevSeq);           // only advance

    // Cap: can't skip past the last segment
    startSeqNum = Math.min(startSeqNum, lastSegNum);

    // Compute which segments to include
    const skipCount = startSeqNum - set.startNum;
    const count     = Math.min(windowSize, allSegs.length - skipCount);
    useSegs = count > 0 ? allSegs.slice(skipCount, skipCount + count) : allSegs.slice(-windowSize);

    // Update the stored sequence (only advance)
    if (sess) sess[seqKey] = startSeqNum;
  } else {
    // VOD: full playlist
    useSegs     = allSegs;
    startSeqNum = set.startNum;
  }

  if (useSegs.length === 0) useSegs = allSegs.slice(-LIVE_WINDOW);

  const maxDur    = Math.max(...useSegs) / set.timescale;
  const targetDur = Math.ceil(maxDur);
  const initUrl   = seg(expand(set.initTmpl, 0));

  let pl = '#EXTM3U\n';
  pl += '#EXT-X-VERSION:6\n';
  // Live: NO #EXT-X-PLAYLIST-TYPE (sliding window, player keeps polling for new segs)
  // VOD: explicit VOD type
  if (!isLive) pl += '#EXT-X-PLAYLIST-TYPE:VOD\n';
  pl += `#EXT-X-TARGETDURATION:${targetDur}\n`;
  pl += `#EXT-X-MEDIA-SEQUENCE:${startSeqNum}\n`;
  pl += `#EXT-X-MAP:URI="${initUrl}"\n`;

  let segNum = startSeqNum;
  for (const d of useSegs) {
    pl += `#EXTINF:${(d / set.timescale).toFixed(3)},\n`;
    pl += seg(expand(set.mediaTmpl, segNum)) + '\n';
    segNum++;
  }
  if (!isLive) {
    pl += '#EXT-X-ENDLIST\n';
  }
  return pl;
}

// ── Route ─────────────────────────────────────────────────────────────────────

router.get("/dash", async (req, res) => {
  const url      = _safeUrl(decodeURIComponent(req.query.url    || ''));
  const referer  = decodeURIComponent(req.query.ref    || '');
  const cookie   = decodeURIComponent(req.query.cookie || '');
  const track    = req.query.track || 'master';  // 'master' | 'video' | 'audio'
  const queryUa     = req.query.ua || '';
  const queryOrigin = req.query.origin || '';
  const querySports = req.query.sports || '';
  // ClearKey decryption key (32-char hex = 16 bytes) for CENC-encrypted DASH streams
  const queryKey    = req.query.key || '';
  if (!url) return res.status(400).end('Missing url parameter');

  try {
    const mpdBase    = url.substring(0, url.lastIndexOf('/') + 1);
    const cookieEnc  = encodeURIComponent(cookie);
    const refEnc     = encodeURIComponent(referer);
    const urlEnc     = encodeURIComponent(url);

    // ── MPD fetch (cache-first, keyed by url+cookie) ───────────────────────────
    const cachedEntry = _getCachedSets(url, cookie);
    let sets = null;
    let isLiveMpd = false;
    let mpdRaw = null;

    if (cachedEntry) {
      sets = cachedEntry.sets;
      isLiveMpd = cachedEntry.isLive;
      console.log(`[DASH→HLS] Cache hit: ${url.split('/').slice(-2, -1)[0] || 'mpd'} track=${track} (isLive=${isLiveMpd})`);
    } else {
      const headers = { 
        'User-Agent': queryUa || getUA(url), 
        'Accept': 'application/dash+xml, */*',
        ...(queryOrigin ? { 'Origin': queryOrigin } : {})
      };
      if (referer) headers['Referer'] = referer;
      if (cookie)  headers['Cookie']  = cookie;
      const resp = await fetchWithWarpFallback(url, { headers, timeout: 20000 });
      mpdRaw = typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data);
      sets = parseDashAdaptationSets(mpdRaw);
      isLiveMpd = /type\s*=\s*"dynamic"/i.test(mpdRaw) || !/mediaPresentationDuration/i.test(mpdRaw);
      _cacheSets(url, cookie, sets, isLiveMpd);
    }


    let videoSets = sets.filter(s => s.contentType === 'video');
    const audioSets = sets.filter(s => s.contentType === 'audio');

    // Sort video sets by bandwidth descending (highest quality first)
    videoSets.sort((a, b) => b.bandwidth - a.bandwidth);

    // LIMIT to top 5 quality variants to prevent the player from probing all
    // 55 qualities simultaneously (which overloads the connection and causes abort-all)
    const MAX_VIDEO_VARIANTS = 5;
    if (videoSets.length > MAX_VIDEO_VARIANTS) {
      console.log(`[DASH→HLS] Selecting ${MAX_VIDEO_VARIANTS} representative video variants from ${videoSets.length} total`);
      const selected = [];
      const len = videoSets.length;
      for (let i = 0; i < MAX_VIDEO_VARIANTS; i++) {
        const idx = Math.floor(i * (len - 1) / (MAX_VIDEO_VARIANTS - 1));
        selected.push(videoSets[idx]);
      }
      videoSets = selected;
    }

    if (videoSets.length === 0 && audioSets.length === 0) {
      return res.status(500).send('No AdaptationSets found in MPD');
    }

    res.setHeader('Content-Type', 'application/vnd.apple.mpegurl');
    res.setHeader('Access-Control-Allow-Origin', '*');

    // Reuse the same session for repeated MPV requests to this (url, cookie) pair.
    const mpdBase2  = url.substring(0, url.lastIndexOf('/') + 1);
    const sessionId = _getOrCreateSession(cookie, referer, mpdBase2, url, queryUa, queryOrigin);
    // Store isLive flag and decryption key on session
    const sess2 = _sessions.get(sessionId);
    if (sess2) {
      sess2.isLive = sess2.isLive ?? isLiveMpd;
      // Store the ClearKey only if not already set (first request wins)
      if (!sess2.decryptionKey && queryKey && queryKey.length === 32) {
        sess2.decryptionKey = queryKey;
        console.log(`[DASH→HLS] Stored ClearKey for session ${sessionId} (key=${queryKey.slice(0,8)}...)`);
      }
    }

    // Use the stored isLive flag (covers cached cases where mpdRaw is null)
    const isLive = _sessions.get(sessionId)?.isLive ?? isLiveMpd;

    // ── sub-playlist mode ─────────────────────────────────────────────────────
    let targetVideoSet = null;
    if (track === 'video') {
      targetVideoSet = videoSets[0];
    } else if (track.startsWith('video_')) {
      const idx = parseInt(track.split('_')[1], 10);
      targetVideoSet = videoSets[idx];
    }
    if (targetVideoSet) {
      return res.send(buildMediaPlaylist(targetVideoSet, mpdBase, sessionId, isLive, track));
    }

    let targetAudioSet = null;
    if (track === 'audio') {
      targetAudioSet = audioSets[0];
    } else if (track.startsWith('audio_')) {
      const idx = parseInt(track.split('_')[1], 10);
      targetAudioSet = audioSets[idx];
    }
    if (targetAudioSet) {
      return res.send(buildMediaPlaylist(targetAudioSet, mpdBase, sessionId, isLive, track));
    }

    // Fallback: return whatever track is available if requested track was not found
    if (track.startsWith('video') && audioSets.length > 0) {
      return res.send(buildMediaPlaylist(audioSets[0], mpdBase, sessionId, isLive, track));
    }
    if (track.startsWith('audio') && videoSets.length > 0) {
      return res.send(buildMediaPlaylist(videoSets[0], mpdBase, sessionId, isLive, track));
    }

    // ── master playlist: sub-playlist URLs carry query params ──
    const uaEnc  = queryUa  ? `&ua=${encodeURIComponent(queryUa)}`   : '';
    const origEnc = queryOrigin ? `&origin=${encodeURIComponent(queryOrigin)}` : '';
    const keyEnc  = queryKey ? `&key=${encodeURIComponent(queryKey)}` : '';
    const sportsEnc = querySports ? `&sports=${encodeURIComponent(querySports)}` : '';
    const proxyDash = (t) =>
      `http://127.0.0.1:3000/proxy/dash?url=${urlEnc}&ref=${refEnc}&cookie=${cookieEnc}&track=${t}${uaEnc}${origEnc}${keyEnc}${sportsEnc}`;

    let master = '#EXTM3U\n#EXT-X-VERSION:6\n';

    // We only need one audio group, using the best audio track
    if (audioSets.length > 0) {
      master += `#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio0",NAME="Audio",DEFAULT=YES,URI="${proxyDash('audio_0')}"\n`;
    }

    // Add each video representation as a variant stream (capped to MAX_VIDEO_VARIANTS)
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

    let cdnResp;
    let attempt = 0;
    const maxAttempts = 6;
    while (attempt < maxAttempts) {
      attempt++;
      try {
        cdnResp = await axios.get(cdnUrl, {
          headers: reqHeaders, responseType: 'stream', timeout: 30000,
          signal: controller.signal,
        });

        if (cdnResp.status >= 500 && attempt < maxAttempts) {
          console.warn(`[CDN] Server returned ${cdnResp.status} for ${file}, retrying (attempt ${attempt}/${maxAttempts})...`);
          try { cdnResp.data.destroy(); } catch (_) {}
          await new Promise(r => setTimeout(r, 150 * attempt));
          continue;
        }
        break;
      } catch (err) {
        if (err.name === 'AbortError' || err.code === 'ERR_CANCELED' || rawAxios.isCancel(err)) {
          throw err;
        }
        console.error(`[CDN] Fetch attempt ${attempt} failed for ${file}: ${err.message}`);
        if (attempt >= maxAttempts) {
          throw err;
        }
        await new Promise(r => setTimeout(r, 150 * attempt));
      }
    }

    const ct = cdnResp.headers['content-type'] || 'application/octet-stream';
    const cl = cdnResp.headers['content-length'];
    const cr = cdnResp.headers['content-range'];
    res.setHeader('Content-Type', ct);
    res.setHeader('Access-Control-Allow-Origin', '*');
    if (cl) res.setHeader('Content-Length', cl);
    if (cr) res.setHeader('Content-Range', cr);

    res.status(cdnResp.status === 206 ? 206 : 200);
    cdnResp.data.pipe(res);
    req.on('close', () => { try { cdnResp.data.destroy(); } catch {} });
    req.on('aborted', () => { try { cdnResp.data.destroy(); } catch {} });
  } catch (err) {
    if (err.name === 'AbortError' || err.code === 'ERR_CANCELED' || rawAxios.isCancel(err)) {
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

  const url = _safeUrl(req.query.url || '');
  const referer = req.query.ref || '';
  console.log(`[Proxy] /video requested. Filename: ${req.params.filename || 'none'}`);
  console.log(`  Target URL: ${url}`);
  console.log(`  Range     : ${req.headers['range'] || 'none'}`);

  if (!url) {
    console.error(`  [Proxy] Error: Missing url parameter`);
    return res.status(400).end('Missing url parameter');
  }

  const reqHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36',
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Accept-Encoding': 'identity',
    'Connection': 'keep-alive',
    'sec-ch-ua': '"Google Chrome";v="137", "Chromium";v="137", "Not/A)Brand";v="24"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Windows"',
    'sec-fetch-dest': 'video',
    'sec-fetch-mode': 'cors',
    'sec-fetch-site': 'cross-site',
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
    const upstream = await directStreamAxios({
      method: 'get',
      url,
      headers: reqHeaders,
      responseType: 'stream',
      validateStatus: () => true,
      maxRedirects: 10,
      signal: controller.signal,
    });

    // Check if upstream returned HTML (indicating a Cloudflare block/bot challenge or redirect to login)
    const ct = (upstream.headers['content-type'] || '').toLowerCase();
    if (ct.includes('text/html') || ct.includes('text/plain') || ct.includes('application/xhtml+xml')) {
      console.error(`  [Proxy] Error: Upstream returned text/HTML content-type (${ct}) instead of video. (Likely Cloudflare/bot block)`);
      try { upstream.data.destroy(); } catch (_) {}
      return res.status(403).send('Bot protection active or invalid stream format.');
    }

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

// ── /proxy/master.m3u8 — decodes a base64 master playlist and serves it ──────────
router.get('/master.m3u8', (req, res) => {
  try {
    const base64Playlist = (req.query.playlist || '').replace(/\s/g, '+');
    if (!base64Playlist) {
      return res.status(400).send('Missing playlist parameter');
    }
    const decoded = Buffer.from(base64Playlist, 'base64').toString('utf-8');
    res.setHeader('Content-Type', 'application/vnd.apple.mpegurl');
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.send(decoded);
  } catch (err) {
    res.status(500).send(err.message);
  }
});

export { _rememberCfDomain };
export default router;


