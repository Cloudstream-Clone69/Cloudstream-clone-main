import * as cheerio from 'cheerio';
import { dnsAxios as axios } from '../../services/dnsAxios.js';
import { fetchHTML } from '../common.js';
import { BASE_URL, SEARCH, DETAILS, STREAM } from './selectors.js';

export default { search, load, getStreams };

// ── Dynamic Domain Config ─────────────────────────────────────────────────────
let resolvedBaseUrl = null;
async function getBaseUrl() {
  if (resolvedBaseUrl) return resolvedBaseUrl;
  try {
    const res = await axios.get('https://raw.githubusercontent.com/phisher98/TVVVV/refs/heads/main/domains.json', { timeout: 3000 });
    if (res.data && res.data['4khdhub']) {
      resolvedBaseUrl = res.data['4khdhub'];
      console.log(`[4KHDHub] Resolved base URL from GitHub: ${resolvedBaseUrl}`);
      return resolvedBaseUrl;
    }
  } catch (e) {
    console.error(`[4KHDHub] Failed to fetch domains from GitHub, using fallback:`, e.message);
  }
  resolvedBaseUrl = BASE_URL;
  return resolvedBaseUrl;
}

// ── Link Transformations ────────────────────────────────────────────────────────
async function transformLink(url, referer) {
  // 1. Resolve custom pixel.hubcloud.cx/gpdl.hubcloud.cx/tg redirector pages
  if (url.includes('pixel.hubcloud.cx') || url.includes('gpdl.hubcloud.cx') || url.includes('hubcloud.cx/tg/go')) {
    try {
      const resp = await axios.get(url, {
        headers: { 'User-Agent': UA, 'Referer': referer },
        maxRedirects: 5,
        timeout: 3000,   // Reduced from 6s — fail fast
        validateStatus: () => true
      });
      const finalUrl = resp.request?.res?.responseUrl || resp.request?.responseURL || url;
      if (finalUrl.includes('link=')) {
        const parsed = new URL(finalUrl);
        const streamLink = parsed.searchParams.get('link');
        if (streamLink && streamLink.startsWith('http')) {
          url = streamLink;
          console.log(`[4KHDHub] Resolved redirector direct stream: ${url}`);
        }
      } else if (finalUrl.includes('telegram.me') || finalUrl.includes('t.me')) {
        console.log(`[4KHDHub] Resolved redirector to Telegram: ${finalUrl}`);
        url = finalUrl;
      } else if (finalUrl.includes('googleusercontent.com') || finalUrl.includes('google.com')) {
        url = finalUrl;
        console.log(`[4KHDHub] Resolved redirector to direct Google link: ${url}`);
      }
    } catch (e) {
      console.error(`[4KHDHub] redirector resolution failed:`, e.message);
    }
  }

  // 2. Standard PixelDrain transform (excluding custom redirector)
  const isPixel = (url.includes('pixeldra') || url.includes('pixelserver') || url.includes('pixeldrain')) && !url.includes('pixel.hubcloud.cx');
  if (isPixel && !url.includes('/api/file/')) {
    try {
      const parsedUrl = new URL(url);
      const base = parsedUrl.origin;
      let fileId = parsedUrl.searchParams.get('id');
      if (!fileId) {
        fileId = parsedUrl.pathname.split('/').pop();
      }
      if (fileId) {
        url = `${base}/api/file/${fileId}?download`;
        console.log(`[4KHDHub] Transformed PixelDrain link: ${url}`);
      }
    } catch (_) {}
  }

  // 3. BuzzServer redirect handshake (HX-Redirect / hx-redirect)
  if (url.includes('buzzserver') || url.includes('.buzz')) {
    try {
      const dlUrl = url.endsWith('/download') ? url : `${url}/download`;
      const resp = await axios.get(dlUrl, {
        headers: { 'User-Agent': UA, 'Referer': referer },
        maxRedirects: 5,
        timeout: 3000,   // Reduced from 5s — fail fast
        validateStatus: () => true
      });
      const redirect = resp.headers['hx-redirect'] || resp.headers['HX-Redirect'];
      if (redirect && redirect.startsWith('http')) {
        url = redirect;
        console.log(`[4KHDHub] BuzzServer HX-Redirect: ${url}`);
      }
    } catch (_) {}
  }

  return url;
}

// ── Constants ─────────────────────────────────────────────────────────────────
const UA        = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';
const VIDEO_EXTS = ['mkv', 'mp4', 'avi', 'mov', 'm4v', 'webm', 'm3u8', 'ts'];
const ZIP_EXTS   = ['zip', 'rar', '7z'];

// ── URL helpers ────────────────────────────────────────────────────────────────
function extOf(url) {
  try { return new URL(url).pathname.split('.').pop().toLowerCase().split(/[?#]/)[0]; }
  catch { return ''; }
}
const hasVideoExt = (url) => VIDEO_EXTS.includes(extOf(url));
const hasZipExt   = (url) => ZIP_EXTS.includes(extOf(url));

function isVideoContentType(ct) {
  return ct.includes('video/') ||
         ct.includes('octet-stream') ||
         ct.includes('mpegurl') ||
         ct.includes('x-matroska');
}

/**
 * CDN priority score — lower = prefer (less likely to be Cloudflare-bot-blocked).
 * .buzz = BunnyCDN/plain CDN, direct access, no bot detection.
 * .workers.dev = Cloudflare Workers, bot detection very likely.
 */
function cdnScore(url) {
  try {
    const h = new URL(url).hostname.toLowerCase();
    if (h.includes('googleusercontent') || h.includes('googleapis')) return -1; // Google CDN — highest priority
    if (h.endsWith('.buzz'))        return 0;   // BunnyCDN — usually direct
    if (h.endsWith('.r2.dev'))      return 1;   // CF R2 direct — no bot check
    if (h.includes('pixeldrain'))   return 2;
    if (h.includes('gofile'))       return 3;
    if (h.endsWith('.surf'))        return 4;
    if (h.endsWith('.workers.dev')) return 8;   // CF Workers — bot detection likely
    return 5;
  } catch { return 9; }
}

const MIRRORS = [
  'https://4khdhub.one',
  'https://4khdhub.live',
  'https://4khdhub.guru',
  'https://4khdhub.work',
  'https://4khdhub.org'
];

async function fetchHTMLWithMirrorFallback(urlPath) {
  let baseUrl = await getBaseUrl();
  try {
    const targetUrl = urlPath.startsWith('http') ? urlPath : `${baseUrl}${urlPath}`;
    return await fetchHTML(targetUrl, null, 1, 4000);
  } catch (err) {
    console.warn(`[4KHDHub] Fetch failed for ${baseUrl}, trying mirror fallbacks...`);
    for (const mirror of MIRRORS) {
      if (mirror === baseUrl) continue;
      try {
        const targetUrl = urlPath.startsWith('http') 
          ? urlPath.replace(baseUrl, mirror)
          : `${mirror}${urlPath}`;
        console.log(`[4KHDHub] Trying mirror: ${targetUrl}`);
        const html = await fetchHTML(targetUrl, null, 1, 8000);
        resolvedBaseUrl = mirror;
        return html;
      } catch (_) {}
    }
    throw err;
  }
}

// ── Search ─────────────────────────────────────────────────────────────────────
async function search(query) {
  const baseUrl = await getBaseUrl();
  const html = await fetchHTMLWithMirrorFallback(`/?s=${encodeURIComponent(query)}`);
  const $ = cheerio.load(html);
  const results = [];
  $(SEARCH.item).each((i, el) => {
    const title = $(el).find(SEARCH.title).text().trim();
    const poster = $(el).find(SEARCH.poster).attr('src');
    const url   = $(el).attr('href');
    if (title && url) {
      results.push({
        title,
        poster: poster ? new URL(poster, baseUrl).href : null,
        url: new URL(url, baseUrl).href,
      });
    }
  });
  return results;
}

// ── Load ───────────────────────────────────────────────────────────────────────
/** Parse a size string like "2.1 GB", "850 MB", "4.5gb" into MB for comparison. */
function parseFileSizeMB(sizeStr) {
  if (!sizeStr) return Infinity;
  const s = sizeStr.toLowerCase().trim();
  const m = s.match(/([\d.]+)\s*(gb|mb|kb)?/);
  if (!m) return Infinity;
  const val = parseFloat(m[1]);
  const unit = m[2] || 'mb';
  if (unit === 'gb') return val * 1024;
  if (unit === 'kb') return val / 1024;
  return val; // mb
}

/** Keep only the entry with the smallest file size per quality tier. */
function dedupeByQuality(episodes) {
  const best = new Map(); // quality -> episode entry
  for (const ep of episodes) {
    const q = ep.quality || 'Unknown';
    const sizeMB = parseFileSizeMB(ep.size);
    if (!best.has(q) || sizeMB < parseFileSizeMB(best.get(q).size)) {
      best.set(q, ep);
    }
  }
  // Return in logical quality order
  const order = ['2160p', '4K', '1080p', '720p', '480p', '360p', 'Unknown'];
  return [...best.values()].sort((a, b) => {
    const ai = order.findIndex(o => (a.quality||'').includes(o.replace('p','')) || a.quality === o);
    const bi = order.findIndex(o => (b.quality||'').includes(o.replace('p','')) || b.quality === o);
    return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
  });
}

async function load(url) {
  const baseUrl = await getBaseUrl();
  const html = await fetchHTMLWithMirrorFallback(url);
  const $ = cheerio.load(html);
  const title       = $(DETAILS.title).first().text().trim();
  const poster      = $(DETAILS.poster).attr('content') || $('meta[property="og:image"]').attr('content');
  const description = $(DETAILS.description).attr('content') || '';
  const episodes    = [];

  $(DETAILS.episodeItem).each((i, el) => {
    const epTitle   = $(el).find(DETAILS.episodeTitle).text().trim();
    const epTitleLower = epTitle.toLowerCase();
    // Skip zip packs, complete season folders, or full season dumps
    if (epTitleLower.includes('zip') || epTitleLower.includes('pack') || epTitleLower.includes('complete') || epTitleLower.includes('full season')) {
      return;
    }
    const epNumber  = $(el).find(DETAILS.episodeNumber).text().trim() || `Episode ${i + 1}`;
    const size      = $(el).find(DETAILS.episodeSize).text().trim() || '';
    const qualMatch = epTitle.match(DETAILS.qualityRegex);
    const quality   = qualMatch ? qualMatch[1] : 'Unknown';
    const firstLink = $(el).find(DETAILS.downloadLinks).first();
    const epUrl     = firstLink.attr('href');
    if (epUrl && epUrl.startsWith('http')) {
      const combinedAudioText = `${title} ${epTitle} ${description}`.toLowerCase();
      let audioLabel = 'single audio';
      const hasBoth = (a, b) => combinedAudioText.includes(a) && combinedAudioText.includes(b);
      const multiKeywords = [
        'dual', 'multi', 'dual-audio', 'multi-audio', 'double audio',
        'org', 'dd5.1', 'dts', 'atmos', '5.1', '7.1'
      ];
      let isMulti = multiKeywords.some(kw => combinedAudioText.includes(kw)) ||
                    hasBoth('hindi', 'english') ||
                    hasBoth('hindi', 'tamil') ||
                    hasBoth('hindi', 'telugu') ||
                    hasBoth('english', 'telugu') ||
                    hasBoth('english', 'tamil');
      if (isMulti) {
        audioLabel = 'multi audio';
      }

      let formattedSize = size;
      if (size) {
        formattedSize = `${size} - ${audioLabel}`;
      } else {
        formattedSize = audioLabel;
      }

      episodes.push({ episode: epNumber, quality, size: formattedSize, title: epTitle, url: epUrl });
    }
  });

  // Keep only the smallest-size entry per quality tier to avoid showing duplicate sizes
  if (episodes.length > 0) {
    const deduped = dedupeByQuality(episodes);
    episodes.length = 0;
    episodes.push(...deduped);
  }

  if (episodes.length === 0) {
    $(DETAILS.movieItem).each((i, el) => {
      const headerText = $(el).find(DETAILS.movieQualityLabel).first().text().trim();
      if (!headerText ||
          headerText.toLowerCase().includes('zip') ||
          headerText.toLowerCase().includes('s01')) return;
      const size      = $(el).find(DETAILS.movieSizeSelector).first().text().trim() || '';
      const qualMatch = headerText.match(DETAILS.qualityRegex);
      const quality   = qualMatch ? qualMatch[1] : 'Unknown';
      const firstLink = $(el).find(DETAILS.movieDownloadLinks).first();
      const epUrl     = firstLink.attr('href');
      if (epUrl && epUrl.startsWith('http')) {
        const combinedAudioText = `${title} ${headerText} ${description}`.toLowerCase();
        let audioLabel = 'single audio';
        const hasBoth = (a, b) => combinedAudioText.includes(a) && combinedAudioText.includes(b);
        const multiKeywords = [
          'dual', 'multi', 'dual-audio', 'multi-audio', 'double audio',
          'org', 'dd5.1', 'dts', 'atmos', '5.1', '7.1'
        ];
        let isMulti = multiKeywords.some(kw => combinedAudioText.includes(kw)) ||
                      hasBoth('hindi', 'english') ||
                      hasBoth('hindi', 'tamil') ||
                      hasBoth('hindi', 'telugu') ||
                      hasBoth('english', 'telugu') ||
                      hasBoth('english', 'tamil');
        if (isMulti) {
          audioLabel = 'multi audio';
        }

        let formattedSize = size;
        if (size) {
          formattedSize = `${size} - ${audioLabel}`;
        } else {
          formattedSize = audioLabel;
        }

        episodes.push({ episode: 'Movie', quality, size: formattedSize, title: headerText, url: epUrl });
      }
    });
    // Keep only smallest-size per quality
    if (episodes.length > 0) {
      const deduped = dedupeByQuality(episodes);
      episodes.length = 0;
      episodes.push(...deduped);
    }
  }

  if (episodes.length === 0) {
    $('a.btn').each((i, el) => {
      const href = $(el).attr('href');
      const text = $(el).text().trim();
      if (href && href.startsWith('http')) {
        const combinedAudioText = `${title} ${text} ${description}`.toLowerCase();
        let audioLabel = 'single audio';
        const multiKeywords = [
          'dual', 'multi', 'hindi-english', 'english-hindi', 
          'hindi+english', 'english+hindi', 'dual-audio', 
          'multi-audio', 'hindi + english', 'english + hindi', 
          'hindi+tamil', 'hindi+telugu', 'english + telugu',
          'org', 'dd5.1', 'dts', 'atmos', '5.1', '7.1'
        ];
        for (const kw of multiKeywords) {
          if (combinedAudioText.includes(kw)) {
            audioLabel = 'multi audio';
            break;
          }
        }

        episodes.push({ episode: 'Movie', quality: 'Unknown', size: ` - ${audioLabel}`, title: text, url: href });
      }
    });
  }

  // Apply 4K-only constraint for 4KHDHub (A)
  const filteredEpisodes = episodes.filter(ep => {
    const q = (ep.quality || ep.title || '').toLowerCase();
    return /4k|2160/i.test(q);
  });

  return {
    title,
    poster: poster ? new URL(poster, baseUrl).href : null,
    description,
    episodes: filteredEpisodes,
  };
}

// ── getStreams ──────────────────────────────────────────────────────────────────
async function getStreams(downloadUrl) {
  if (downloadUrl.includes('hubcloud') &&
      (downloadUrl.includes('/drive/') || downloadUrl.includes('/d/'))) {
    return getStreamsFromHubcloud(downloadUrl);
  }
  return getStreamsFromDirect(downloadUrl);
}

// ── CDN link probe ──────────────────────────────────────────────────────────────
/**
 * Probe a single CDN URL using GET + Range: bytes=0-0.
 *
 * Why GET instead of HEAD?
 *   HEAD is useless here because Cloudflare Workers return 200 OK on HEAD even
 *   when they would serve a challenge page on GET. A real GET with Range=0-0
 *   only downloads 1 byte but reveals the actual content-type.
 *
 * Why Range: bytes=0-0?
 *   Limits actual data transfer to ≤1 KB. We destroy the stream immediately
 *   after reading response headers.
 *
 * Returns { streamUrl, referer } if video, null if HTML/blocked/error.
 */
async function probeLink(url, referer) {
  url = await transformLink(url, referer);
  let origin = '';
  try { origin = new URL(referer).origin; } catch (_) {}

  const headers = {
    'User-Agent'         : UA,
    'Accept'             : 'video/*,*/*;q=0.8',
    'Accept-Language'    : 'en-US,en;q=0.9',
    'Accept-Encoding'    : 'gzip, deflate, br',
    'Referer'            : referer,
    'Origin'             : origin,
    'Range'              : 'bytes=0-0',
    // Cloudflare browser-hint headers — helps pass some lightweight bot checks
    'sec-ch-ua'          : '"Google Chrome";v="137", "Chromium";v="137", "Not/A)Brand";v="24"',
    'sec-ch-ua-mobile'   : '?0',
    'sec-ch-ua-platform' : '"Windows"',
    'sec-fetch-dest'     : 'video',
    'sec-fetch-mode'     : 'cors',
    'sec-fetch-site'     : 'cross-site',
    'Connection'         : 'keep-alive',
  };

  try {
    const resp = await axios({
      method         : 'get',
      url,
      headers,
      maxRedirects   : 15,
      timeout        : 2000,   // 2s per probe — fail fast, let race winner emerge quickly
      responseType   : 'stream',
      validateStatus : () => true,     // never throw on status codes
    });

    // Final URL after following all redirects
    const finalUrl = resp.request?.res?.responseUrl ||
                     resp.request?.responseURL       || url;

    const ct = (resp.headers['content-type']          || '').toLowerCase();
    const cd = (resp.headers['content-disposition']   || '').toLowerCase();
    const cr =  resp.headers['content-range']         || '';
    // For 206 responses, content-length = range size (tiny); real size is in content-range
    const totalSize = cr
      ? parseInt(cr.split('/').pop() || '0', 10)
      : parseInt(resp.headers['content-length'] || '0', 10);

    // Immediately stop downloading — we only need the headers
    try { resp.data.destroy(); } catch (_) {}

    // ── Hard reject: Cloudflare challenge / error HTML page ───────────
    if (ct.includes('text/html') || ct.includes('text/plain')) {
      console.warn(`  [4KHDHub] ✗ HTML (CF bot block?) — skipping: ${url.slice(0, 70)}`);
      return null;
    }

    // ── Hard reject: zip archives or compressed files ───────────────
    const hasVideoExtension =
      hasVideoExt(finalUrl)                            ||
      hasVideoExt(url)                                 ||
      VIDEO_EXTS.some(e => cd.includes('.' + e));

    const isZip =
      (hasZipExt(finalUrl) || hasZipExt(url) || ZIP_EXTS.some(e => cd.includes('.' + e))) ||
      ((ct.includes('zip') || ct.includes('rar') || ct.includes('compressed')) && !hasVideoExtension);

    if (isZip) {
      console.warn(`  [4KHDHub] ✗ zip/compressed file — skipping: ${url.slice(0, 70)}`);
      return null;
    }

    // ── Accept: known video content-type OR video extension OR large binary
    const isVideo =
      isVideoContentType(ct)                           ||
      (ct === '' && cr !== '')                         ||   // Range response, no declared ct
      hasVideoExt(finalUrl)                            ||
      hasVideoExt(url)                                 ||
      VIDEO_EXTS.some(e => cd.includes('.' + e))      ||
      totalSize > 1024 * 1024;                              // >1 MB with no text ct = binary/video

    if (resp.status >= 200 && resp.status < 400 && isVideo) {
      const chosen = (finalUrl && finalUrl !== url) ? finalUrl : url;
      const lowerChosen = chosen.toLowerCase();
      // Only accept Google Drive CDN, PixelDrain, and Cloudflare R2 links.
      // Buzz/workers/other CDNs pass the probe (respond with video headers) but
      // are download-only — they require browser auth flows that MPV can't handle.
      // Accepting them causes MPV to hang for 60+ seconds before timing out.
      const isPixel  = lowerChosen.includes('pixeldrain') || lowerChosen.includes('pixelserver') || lowerChosen.includes('pixeldra');
      const isGoogle = lowerChosen.includes('googleusercontent') || lowerChosen.includes('googleapis');
      const isR2     = lowerChosen.includes('r2.cloudflarestorage.com') || lowerChosen.includes('r2.dev');
      if (!isPixel && !isGoogle && !isR2) {
        console.warn(`  [4KHDHub] ✗ Non-streamable CDN (buzz/workers/other) — skipping: ${chosen.slice(0, 80)}`);
        return null;
      }
      console.log(`  [4KHDHub] ✓ ${resp.status} "${ct || 'no-ct'}" totalSize=${totalSize} → ${chosen.slice(0, 80)}`);
      return { streamUrl: chosen, referer };
    }

    console.log(`  [4KHDHub] ✗ status=${resp.status} ct="${ct}" size=${totalSize} → ${url.slice(0, 70)}`);
  } catch (e) {
    // ECONNRESET / timeout are normal for blocked links — don't spam the log
    const msg = e.message || '';
    if (!msg.includes('ECONNRESET') && !msg.includes('timeout') && !msg.includes('aborted')) {
      console.error(`  [4KHDHub] probe error (${url.slice(0, 60)}): ${msg}`);
    } else {
      console.log(`  [4KHDHub] ✗ ${msg.slice(0, 40)} — ${url.slice(0, 60)}`);
    }
  }
  return null;
}

// ── Race helper ─────────────────────────────────────────────────────────────────
/** Resolve with the first non-null result. Reject only if ALL resolve to null. */
function raceFirst(promises) {
  return new Promise((resolve, reject) => {
    if (promises.length === 0) { reject(new Error('[4KHDHub] No CDN links to probe')); return; }
    let settled = 0;
    let won = false;
    promises.forEach(p => {
      Promise.resolve(p)
        .then(r => {
          if (won) return;
          if (r) { won = true; resolve(r); }
          else if (++settled === promises.length)
            reject(new Error('[4KHDHub] All CDN links returned HTML or were blocked'));
        })
        .catch(() => {
          if (won) return;
          if (++settled === promises.length)
            reject(new Error('[4KHDHub] All CDN probes threw errors'));
        });
    });
  });
}

// ── Main resolver: hubcloud.cx → gamerxyt.com → CDN ────────────────────────────
async function getStreamsFromHubcloud(hubcloudUrl) {
  console.log(`[4KHDHub] Resolving hubcloud URL: ${hubcloudUrl}`);

  const baseUrl = await getBaseUrl();
  // ── Step 1: hubcloud.cx page → find the "Generate Download Link" URL ─────
  const hubHtml  = await fetchHTML(hubcloudUrl, baseUrl);
  const $hub     = cheerio.load(hubHtml);
  const generateUrl = $hub(STREAM.generateLink).attr('href');
  if (!generateUrl) throw new Error('[4KHDHub] Generate link not found on hubcloud page');
  console.log(`[4KHDHub] Generate URL: ${generateUrl}`);

  // ── Step 2: Fetch gamerxyt download page ────────────────────────────────
  const pageHtml = await fetchHTML(generateUrl, hubcloudUrl);
  const $page    = cheerio.load(pageHtml);
  const pageStr  = typeof pageHtml === 'string' ? pageHtml : String(pageHtml);

  const seen  = new Set();
  const links = [];

  const addLink = (href) => {
    if (!href || !href.startsWith('http') || hasZipExt(href) || seen.has(href)) return;
    try {
      const host = new URL(href).hostname.toLowerCase();
      if (
        host.includes('google.com') ||
        host.includes('t.me') ||
        host.includes('telegram') ||
        host.includes('tinyurl.com') ||
        host.includes('one.one.one.one') ||
        host.includes('gamerxyt.com') ||
        host.includes('howtodownload') ||
        href.includes('/drive/admin') ||
        href.includes('Unblock-Ban-Site') ||
        host.endsWith('hdhub4u.ms') ||
        host.endsWith('hdhub4u.wtf') ||
        host.endsWith('hdhub4u.ltd') ||
        host.endsWith('4khdhub.one') ||
        host.endsWith('4khdhub.com')
      ) {
        return;
      }
      seen.add(href);
      links.push(href);
    } catch (_) {}
  };

  // Pass 1 — links with explicit video extensions (highest priority)
  $page('a[href]').each((_, el) => {
    const href = $page(el).attr('href') || '';
    if (hasVideoExt(href)) addLink(href);
  });

  // Pass 2 — all other external links (server buttons, etc.)
  $page('a[href]').each((_, el) => addLink($page(el).attr('href') || ''));

  // Pass 3 — scan raw HTML/JS for video URLs not in <a> tags
  const rawMatches = pageStr.match(
    /https?:\/\/[^\s"'<>]+\.(?:mkv|mp4|avi|webm|m3u8)(?:[?#][^\s"'<>]*)?/gi
  ) || [];
  rawMatches.forEach(u => addLink(u));

  if (links.length === 0) throw new Error('[4KHDHub] No CDN links found on download page');

  // ── Step 2.5: Pre-resolve pixel.hubcloud.cx redirectors in parallel ─────────
  // pixel.hubcloud.cx links resolve to Google Drive URLs (score -1) but they
  // score 5 (unknown host) before resolution → end up in Group B, wasting time
  // waiting for Group A (buzz CDNs that get filtered) to fail first.
  // Pre-resolving them in parallel lets Google links surface to Group A immediately.
  const resolvedLinks = await Promise.all(links.map(async (link) => {
    if (link.includes('pixel.hubcloud.cx') || link.includes('gpdl.hubcloud.cx') || link.includes('hubcloud.cx/tg/go')) {
      try {
        const resp = await axios.get(link, {
          headers: { 'User-Agent': UA, 'Referer': generateUrl },
          maxRedirects: 5,
          timeout: 3000,
          validateStatus: () => true
        });
        const finalUrl = resp.request?.res?.responseUrl || resp.request?.responseURL || link;
        if (finalUrl.includes('link=')) {
          const parsed = new URL(finalUrl);
          const streamLink = parsed.searchParams.get('link');
          if (streamLink && streamLink.startsWith('http')) {
            console.log(`[4KHDHub] Pre-resolved pixel redirector → ${streamLink.slice(0, 80)}`);
            return streamLink;
          }
        } else if (finalUrl.includes('googleusercontent.com') || finalUrl.includes('googleapis')) {
          console.log(`[4KHDHub] Pre-resolved pixel redirector → Google: ${finalUrl.slice(0, 80)}`);
          return finalUrl;
        }
      } catch (_) {}
    }
    return link; // unchanged
  }));

  // De-duplicate after resolution (multiple pixel links may resolve to same Google URL)
  const resolvedSeen = new Set();
  const dedupedLinks = resolvedLinks.filter(l => {
    if (resolvedSeen.has(l)) return false;
    resolvedSeen.add(l);
    return true;
  });

  // Re-sort with resolved URLs — Google links now get score -1
  dedupedLinks.sort((a, b) => cdnScore(a) - cdnScore(b));

  console.log(`[4KHDHub] Probing ${dedupedLinks.length} CDN link(s) (best-first, post-resolve):`);
  dedupedLinks.slice(0, 6).forEach((l, i) =>
    console.log(`  ${i + 1}. [score=${cdnScore(l)}] ${l.slice(0, 90)}`));
  if (dedupedLinks.length > 6) console.log(`  ... and ${dedupedLinks.length - 6} more`);

  // ── Step 3: probe in priority tiers to avoid throttled links winning the race ──
  const groupA = dedupedLinks.filter(l => cdnScore(l) <= 1);
  const groupB = dedupedLinks.filter(l => cdnScore(l) > 1 && cdnScore(l) <= 5);
  const groupC = dedupedLinks.filter(l => cdnScore(l) > 5);


  console.log(`[4KHDHub] Tiers: Group A (CDN) = ${groupA.length}, Group B (Hosts) = ${groupB.length}, Group C (Workers) = ${groupC.length}`);

  if (groupA.length > 0) {
    try {
      console.log(`[4KHDHub] Racing Group A high-speed direct CDN links...`);
      const result = await raceFirst(groupA.map(link => probeLink(link, generateUrl)));
      if (result) return result;
    } catch (e) {
      console.log(`[4KHDHub] Group A failed/blocked, trying fallback tiers...`);
    }
  }

  if (groupB.length > 0) {
    try {
      console.log(`[4KHDHub] Racing Group B file-hosts...`);
      const result = await raceFirst(groupB.map(link => probeLink(link, generateUrl)));
      if (result) return result;
    } catch (e) {
      console.log(`[4KHDHub] Group B failed/blocked, trying Group C fallback...`);
    }
  }

  if (groupC.length > 0) {
    console.log(`[4KHDHub] Racing Group C fallback workers...`);
    return raceFirst(groupC.map(link => probeLink(link, generateUrl)));
  }

  throw new Error('[4KHDHub] All CDN links returned HTML or were blocked');
}

// ── Direct URL fallback ─────────────────────────────────────────────────────────
async function getStreamsFromDirect(directUrl) {
  console.log(`[4KHDHub] Resolving direct URL: ${directUrl}`);
  try {
    const baseUrl = await getBaseUrl();
    directUrl = await transformLink(directUrl, baseUrl);
    // Quick probe: is the URL itself a video file?
    const resp = await axios({
      method         : 'get',
      url            : directUrl,
      headers        : { 'User-Agent': UA, 'Range': 'bytes=0-0' },
      maxRedirects   : 10,
      timeout        : 4000,
      responseType   : 'stream',
      validateStatus : () => true,
    });
    const finalUrl = resp.request?.res?.responseUrl || directUrl;
    const ct = (resp.headers['content-type'] || '').toLowerCase();
    try { resp.data.destroy(); } catch (_) {}

    if (!ct.includes('text/html') &&
        (isVideoContentType(ct) || hasVideoExt(finalUrl) || hasVideoExt(directUrl))) {
      return { streamUrl: finalUrl, referer: baseUrl };
    }

    // Parse the page for embedded hubcloud or video links
    const html = await fetchHTML(directUrl, baseUrl, 2, 30000);
    const $ = cheerio.load(html);

    const hubLink = $('a[href*="hubcloud"]').toArray()
      .map(el => $(el).attr('href'))
      .find(h => h && (h.includes('/drive/') || h.includes('/d/')));
    if (hubLink) return getStreamsFromHubcloud(hubLink);

    for (const ext of VIDEO_EXTS) {
      const link = $(`a[href$=".${ext}"]`).first().attr('href');
      if (link) return { streamUrl: new URL(link, directUrl).href, referer: baseUrl };
    }

    if ($(STREAM.generateLink).length) return getStreamsFromHubcloud(directUrl);
  } catch (e) {
    console.error(`[4KHDHub] Direct resolve error: ${e.message}`);
  }
  throw new Error('[4KHDHub] No playable stream found from direct link');
}
