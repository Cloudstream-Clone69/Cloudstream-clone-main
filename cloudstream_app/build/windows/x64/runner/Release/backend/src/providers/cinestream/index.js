import { dnsAxios as axios, createDirectAxios } from '../../services/dnsAxios.js';
import crypto from 'crypto';
import https from 'https';

const directAxios = createDirectAxios();

async function fetchOpenSubtitlesHelper(tmdbId, type, season, episode) {
  if (!tmdbId) return [];

  // Step 1: Resolve IMDb ID from TMDB ID
  let imdbId;
  try {
    const extUrl = type === 'movie'
      ? `https://api.tmdb.org/3/movie/${tmdbId}/external_ids`
      : `https://api.tmdb.org/3/tv/${tmdbId}/external_ids`;
    const extRes = await axios.get(extUrl, {
      headers: {
        Authorization: `Bearer ${TMDB_BEARER}`,
        accept: 'application/json'
      }
    });
    imdbId = extRes.data.imdb_id;
    if (imdbId && imdbId.startsWith('tt')) {
      imdbId = imdbId.replace('tt', '');
    }
  } catch (e) {
    console.error('[OpenSubtitles] Failed to fetch IMDb ID from TMDB:', e.message);
    return [];
  }

  if (!imdbId) {
    console.warn('[OpenSubtitles] No IMDb ID found for TMDB ID:', tmdbId);
    return [];
  }

  // Step 2: Query XML-RPC API
  try {
    console.log(`[OpenSubtitles] Querying for IMDb ID: ${imdbId} (season=${season}, episode=${episode})`);
    
    // LogIn request
    const loginXml = `<?xml version="1.0" encoding="utf-8"?>
<methodCall>
  <methodName>LogIn</methodName>
  <params>
    <param><value><string></string></value></param>
    <param><value><string></string></value></param>
    <param><value><string>en</string></value></param>
    <param><value><string>VLSub 0.9.13</string></value></param>
  </params>
</methodCall>`;

    const loginRes = await postXmlRpc('/xml-rpc', loginXml);
    const tokenMatch = loginRes.match(/<string>([^<]{20,})<\/string>/);
    if (!tokenMatch) {
      console.warn('[OpenSubtitles] Failed to parse XML-RPC token');
      return [];
    }
    const token = tokenMatch[1];

    // SearchSubtitles request
    const isTv = type === 'series' || type === 'tv';
    const searchXml = `<?xml version="1.0" encoding="utf-8"?>
<methodCall>
  <methodName>SearchSubtitles</methodName>
  <params>
    <param><value><string>${token}</string></value></param>
    <param>
      <value>
        <array>
          <data>
            <value>
              <struct>
                <member>
                  <name>sublanguageid</name>
                  <value><string>eng</string></value>
                </member>
                <member>
                  <name>imdbid</name>
                  <value><string>${imdbId}</string></value>
                </member>
                ${isTv && season && episode ? `
                <member>
                  <name>season</name>
                  <value><int>${season}</int></value>
                </member>
                <member>
                  <name>episode</name>
                  <value><int>${episode}</int></value>
                </member>
                ` : ''}
              </struct>
            </value>
          </data>
        </array>
      </value>
    </param>
  </params>
</methodCall>`;

    const searchRes = await postXmlRpc('/xml-rpc', searchXml);
    
    // Parse results
    const results = parseXmlRpcStructs(searchRes);
    const subtitles = results
      .filter(r => r.SubDownloadLink && r.LanguageName)
      .map(r => {
        // Clean language name: strip the word "external" if present
        let lang = r.LanguageName || 'English';
        lang = lang.replace(/\(external\)/gi, '')
                   .replace(/\[external\]/gi, '')
                   .replace(/external/gi, '')
                   .trim();
        if (lang.length > 1) {
          lang = lang[0].toUpperCase() + lang.substring(1);
        }
        
        const proxyUrl = `http://127.0.0.1:3000/subtitles/download?url=${encodeURIComponent(r.SubDownloadLink)}`;
        return {
          url: proxyUrl,
          lang: lang,
          code: r.ISO639 || 'en'
        };
      });

    console.log(`[OpenSubtitles] Found ${subtitles.length} fallback subtitles`);
    return subtitles;
  } catch (err) {
    console.error('[OpenSubtitles] Error querying XML-RPC:', err.message);
    return [];
  }
}

function postXmlRpc(path, body) {
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: 'api.opensubtitles.org',
      port: 443,
      path: path,
      method: 'POST',
      headers: {
        'Content-Type': 'text/xml',
        'User-Agent': 'VLSub 0.9.13',
        'Content-Length': Buffer.byteLength(body)
      }
    }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => resolve(data));
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function parseXmlRpcStructs(xml) {
  const structs = [];
  const structRegex = /<struct>([\s\S]*?)<\/struct>/g;
  let match;
  while ((match = structRegex.exec(xml)) !== null) {
    const structXml = match[1];
    const obj = {};
    const memberRegex = /<member>\s*<name>([^<]+)<\/name>\s*<value>\s*<(?:string|double|int)>([^<]*?)<\/(?:string|double|int)>\s*<\/value>\s*<\/member>/g;
    let m;
    while ((m = memberRegex.exec(structXml)) !== null) {
      obj[m[1]] = m[2];
    }
    if (Object.keys(obj).length > 0) {
      structs.push(obj);
    }
  }
  return structs;
}

function _matchTitle(postTitle, targetTitle) {
  const cleanPost = postTitle.toLowerCase().replace(/[^a-z0-9\s]/g, ' ');
  const cleanTarget = targetTitle.toLowerCase().replace(/[^a-z0-9\s]/g, ' ');
  
  // Remove season/episode/year markers from cleanPost
  const postWithoutMeta = cleanPost
    .replace(/\b(season|series|episode|complete|hindi|dual|multi|english|hevc|web|dl|hdr|dovi|bluray|x264|x265|dd5|1|720p|1080p|2160p|4k)\b/g, '')
    .replace(/\b(s\d+|e\d+|\d{4})\b/g, '')
    .trim();

  const postWords = postWithoutMeta.split(/\s+/).filter(Boolean);
  const targetWords = cleanTarget.split(/\s+/).filter(Boolean);
  
  if (targetWords.length === 0) return false;
  
  const hasAllTargetWords = targetWords.every(word => postWords.includes(word));
  if (!hasAllTargetWords) return false;

  const extraWords = postWords.filter(w => !targetWords.includes(w));
  if (extraWords.length > 1) {
    return false;
  }
  
  return true;
}

function _matchEpisode(ep, v, pad) {
  const targetSlug = `s${pad(v.season)}e${pad(v.episode)}`;
  const targetShortSlug = `s${v.season}e${v.episode}`;
  const text = (ep.episode + ' ' + ep.title).toLowerCase();
  
  if (text.includes(targetSlug) || text.includes(targetShortSlug)) {
    return true;
  }
  
  if (ep.season && parseInt(ep.season) === v.season && ep.episode && parseInt(ep.episode) === v.episode) {
    return true;
  }
  
  const hasSeason = text.includes(`season ${v.season}`) || text.includes(`s${pad(v.season)}`) || text.includes(`s${v.season}`);
  const hasEpisode = text.includes(`episode ${v.episode}`) || text.includes(`e${pad(v.episode)}`) || text.includes(`e${v.episode}`) || text.includes(`ep ${v.episode}`) || text.includes(`ep. ${v.episode}`);
  
  return hasSeason && hasEpisode;
}

function _isPostSeries(post) {
  const url = (post.url || '').toLowerCase();
  const title = (post.title || '').toLowerCase();
  return url.includes('series-') || url.includes('season-') || title.includes('(series)') || title.includes('season') || title.includes('s0') || title.includes('s1') || title.includes('s2');
}

const TMDB_BEARER = 'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJhYjY1OWFlMjQwYmM5ZGZmMTJhYWFiZjI2ZDdjZDVmMCIsIm5iZiI6MTc4MDQxNzkwMi4yNDk5OTk4LCJzdWIiOiI2YTFmMDU2ZTg4ZDU2ZDA5ZDgyNTBmYTgiLCJzY29wZXMiOlsiYXBpX3JlYWQiXSwidmVyc2lvbiI6MX0.BaaZkYd0cK84S-P2vujy5qUYYc2MM3BUkrosxG5dOZM';

export default { search, load, getStreams };

async function search(query) {
  try {
    const movieUrl = `https://v3-cinemeta.strem.io/catalog/movie/top/search=${encodeURIComponent(query)}.json`;
    const seriesUrl = `https://v3-cinemeta.strem.io/catalog/series/top/search=${encodeURIComponent(query)}.json`;

    const [movieRes, seriesRes] = await Promise.all([
      directAxios.get(movieUrl).catch(() => ({ data: { metas: [] } })),
      directAxios.get(seriesUrl).catch(() => ({ data: { metas: [] } }))
    ]);

    const movies = movieRes.data?.metas || [];
    const series = seriesRes.data?.metas || [];
    const merged = [...movies, ...series];

    return merged.map(item => ({
      title: item.name || '',
      poster: item.poster || `https://images.metahub.space/poster/medium/${item.id}/img`,
      url: JSON.stringify({ id: item.id, type: item.type })
    }));
  } catch (e) {
    console.error('[CineStream] Search error:', e.message);
    return [];
  }
}

async function checkNetmirror(title, ottCode) {
  const nfmirrorAPI = 'https://tv.imgcdn.kim/newtv';
  const headers = {
    'ott': ottCode,
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:136.0) Gecko/20100101 Firefox/136.0 /OS.GatuNewTV v1.0',
    'X-Requested-With': 'NetmirrorNewTV v1.0'
  };
  try {
    const searchUrl = `${nfmirrorAPI}/search.php?s=${encodeURIComponent(title)}`;
    const res = await directAxios.get(searchUrl, { headers, timeout: 5000 });
    const results = res.data?.searchResult || [];
    const cleanTitle = title.toLowerCase().trim();
    return results.some(r => r.t.toLowerCase().trim() === cleanTitle);
  } catch (_) {
    return false;
  }
}

async function load(url, options = {}) {
  let { id, tmdbId, type } = JSON.parse(url);

  if (!id && tmdbId) {
    try {
      const extUrl = type === 'movie'
        ? `https://api.tmdb.org/3/movie/${tmdbId}/external_ids`
        : `https://api.tmdb.org/3/tv/${tmdbId}/external_ids`;
      const extRes = await axios.get(extUrl, {
        headers: {
          Authorization: `Bearer ${TMDB_BEARER}`,
          accept: 'application/json'
        }
      });
      id = extRes.data.imdb_id;
      console.log(`[CineStream] Resolved IMDb ID ${id} from TMDB ID ${tmdbId}`);
    } catch (e) {
      console.error('[CineStream] Failed to fetch IMDb ID from TMDB ID:', e.message);
    }
  }

  if (!id) {
    throw new Error('No valid IMDb ID found to resolve metadata.');
  }

  const detailUrl = `https://v3-cinemeta.strem.io/meta/${type}/${id}.json`;
  const res = await directAxios.get(detailUrl);
  const meta = res.data.meta || {};
  if (!tmdbId) {
    tmdbId = meta.moviedb_id;
  }

  if (!tmdbId && id.startsWith('tt')) {
    try {
      const findUrl = `https://api.tmdb.org/3/find/${id}?external_source=imdb_id`;
      const findRes = await axios.get(findUrl, {
        headers: {
          Authorization: `Bearer ${TMDB_BEARER}`,
          accept: 'application/json'
        }
      });
      const results = findRes.data;
      if (type === 'movie' && results.movie_results?.length > 0) {
        tmdbId = results.movie_results[0].id;
      } else if (type === 'series' && results.tv_results?.length > 0) {
        tmdbId = results.tv_results[0].id;
      }
    } catch (e) {
      console.error('[CineStream] Failed to fetch TMDB ID from IMDb ID:', e.message);
    }
  }

  const title = meta.name || '';
  const description = meta.description || '';
  const poster = meta.poster || `https://images.metahub.space/poster/medium/${id}/img`;
  const year = meta.year ? (meta.year.match(/\d+/)?.[0] || '') : '';

  const hasNetflix = false;
  const hasPrime = false;
  const hasHotstar = false;

  const episodes = [];
  if (type === 'movie') {
    // Standard always-available providers
    episodes.push({
      episode: 'Movie',
      quality: 'Multi',
      size: '',
      title: 'VidSrc (Zxc)',
      url: JSON.stringify({ id, tmdbId, type: 'movie', year, title, source: 'vidsrc' })
    });
    // Only vidsrc is remaining
  } else if (type === 'series' && meta.videos) {
    const pad = (n) => n.toString().padStart(2, '0');

    meta.videos.forEach(v => {
      if (v.season === 0) return;

      episodes.push({
        episode: v.episode.toString(),
        season: v.season.toString(),
        quality: 'Multi',
        size: '',
        title: `VidSrc (Zxc) - S${v.season}E${v.episode}`,
        url: JSON.stringify({ id, tmdbId, type: 'series', season: v.season, episode: v.episode, year, title, source: 'vidsrc' })
      });
      // Only vidsrc is remaining
    });
  }
  
  // Query 4KHDHub inside CineStream to avoid parallel processing on the client
  try {
    const isMovie = type === 'movie';
    const isSeriesEpisode = type === 'series' && options.season && options.episode;
    
    if (isMovie || isSeriesEpisode) {
      console.log(`[CineStream] Automatically fetching 4KHDHub links inside load (type=${type}, season=${options.season}, episode=${options.episode})`);
      const fourKHDHubProvider = (await import('../4khdhub/index.js')).default;
      const searchResults = await fourKHDHubProvider.search(title);
      
      const cleanTitle = title.toLowerCase().replace(/[^\w\s]/g, '').replace(/\s+/g, ' ').trim();
      let best = null;
      let bestScore = -1;
      
      for (const r of searchResults) {
        const rTitle = r.title.toLowerCase().replace(/[^\w\s]/g, '').replace(/\s+/g, ' ').trim();
        let score = 0;
        if (rTitle === cleanTitle) score = 200;
        else if (rTitle.includes(cleanTitle)) score = 80;
        if (score > bestScore) {
          bestScore = score;
          best = r;
        }
      }
      
      if (best && bestScore >= 40) {
        const details = await fourKHDHubProvider.load(best.url);
        if (details && details.episodes) {
          const parseSizeToMb = (sizeStr) => {
            if (!sizeStr) return 999999;
            const match = sizeStr.match(/(\d+(?:\.\d+)?)\s*(GB|MB)/i);
            if (!match) return 999999;
            const val = parseFloat(match[1]);
            const unit = match[2].toUpperCase();
            if (unit === 'GB') return val * 1024;
            return val;
          };

          const qualityGroups = {};
          
          details.episodes.forEach(ep => {
            const isMovieMatch = isMovie && ep.episode === 'Movie';
            const isSeriesMatch = isSeriesEpisode && 
              (ep.episode.toString() === options.episode.toString() ||
               ep.episode.toString().toLowerCase().replace('episode', '').trim() === options.episode.toString());
               
            if (isMovieMatch || isSeriesMatch) {
              const qBadge = (ep.quality || 'Unknown').toLowerCase().trim();
              
              // Only allow 4K (2160) from 4KHDHub (A)
              const is4k = /4k|2160/i.test(qBadge);
              if (!is4k) {
                return; // SKIP 1080p, 720p, 480p, etc. from 4KHDHub (A)
              }

              const sizeInMb = parseSizeToMb(ep.size);
              if (!qualityGroups[qBadge] || sizeInMb < qualityGroups[qBadge].sizeInMb) {
                qualityGroups[qBadge] = { ep, sizeInMb };
              }
            }
          });
          
          Object.values(qualityGroups).forEach(group => {
            const ep = group.ep;
            episodes.push({
              episode: isMovie ? 'Movie' : options.episode.toString(),
              season: isMovie ? undefined : options.season.toString(),
              quality: ep.quality,
              size: ep.size,
              title: `4KHDHub — ${ep.title}`,
              url: JSON.stringify({
                source: '4khdhub',
                server: ep.url,
                title: ep.title,
                quality: ep.quality,
                size: ep.size
              })
            });
          });
        }
      }
    }
  } catch (err) {
    console.error('[CineStream] Failed to load 4khdhub links inside load:', err.message);
  }

  // ── Inject Netmirror (Netflix/Prime/Hotstar) prioritized at the top ─────────
  try {
    const isMovie = type === 'movie';
    const isSeriesEpisode = type === 'series' && options.season && options.episode;
    
    if (isMovie || isSeriesEpisode) {
      console.log(`[CineStream] Querying Netmirror (Otts) inside load...`);
      const netmirror = await import('../netmirror/index.js');
      
      const otts = [
        { name: 'Netflix Mirror', code: 'nf' },
        { name: 'Prime Video Mirror', code: 'pv' },
        { name: 'Disney+/Hotstar Mirror', code: 'hs' }
      ];

      const netmirrorResults = await Promise.all(otts.map(async (ott) => {
        try {
          const searchResults = await netmirror.search(title, ott.code);
          const cleanTitle = title.toLowerCase().replace(/[^\w\s]/g, '').replace(/\s+/g, ' ').trim();
          let best = null;
          let bestScore = -1;
          
          for (const r of searchResults) {
            const rTitle = r.title.toLowerCase().replace(/[^\w\s]/g, '').replace(/\s+/g, ' ').trim();
            let score = 0;
            if (rTitle === cleanTitle) score = 200;
            else if (rTitle.includes(cleanTitle)) score = 80;
            if (score > bestScore) {
              bestScore = score;
              best = r;
            }
          }
          
          // Require near-exact title match (>=150) to avoid false OTT positives
          if (best && bestScore >= 150) {
            const details = await netmirror.load(best.url, ott.code);
            if (details && details.episodes && details.episodes.length > 0) {
              try {
                const firstEpUrl = JSON.parse(details.episodes[0].url);
                if (firstEpUrl.tmdbId && tmdbId && parseInt(firstEpUrl.tmdbId, 10) !== parseInt(tmdbId, 10)) {
                  console.log(`[CineStream] Netmirror ${ott.name} TMDB ID mismatch (got ${firstEpUrl.tmdbId}, expected ${tmdbId}). Skipping.`);
                  return null;
                }
              } catch (_) {}
            }
            if (details && details.episodes) {
              const matchedEp = details.episodes.find(ep => {
                if (isMovie) return true;
                return parseInt(ep.season, 10) === parseInt(options.season, 10) && 
                       parseInt(ep.episode, 10) === parseInt(options.episode, 10);
              });
              if (matchedEp) {
                const epTitle = isMovie 
                  ? `${ott.name} — ${title}`
                  : `${ott.name} — ${title} - S${options.season}E${options.episode}`;
                return {
                  episode: isMovie ? 'Movie' : options.episode.toString(),
                  season: isMovie ? undefined : options.season.toString(),
                  quality: 'Multi',
                  size: '',
                  title: epTitle,
                  url: JSON.stringify({
                    source: 'netmirror',
                    ott: ott.code,
                    server: matchedEp.url,
                    title: title
                  })
                };
              }
            }
          }
        } catch (err) {
          console.warn(`[CineStream] Failed Netmirror (${ott.name}) sub-query:`, err.message);
        }
        return null;
      }));

      const validNetmirror = netmirrorResults.filter(Boolean);

      // Separate current episodes (which has 4KHDHub + VidSrc)
      const eps4k_A = [];
      const eps1080p_A = [];
      const others = [];

      episodes.forEach(ep => {
        try {
          const u = JSON.parse(ep.url);
          if (u.source === '4khdhub') {
            const q = (ep.quality || '').toLowerCase();
            if (/4k|2160/i.test(q)) {
              eps4k_A.push(ep);
            } else if (/1080/i.test(q)) {
              eps1080p_A.push(ep);
            }
            // Skip 720p, 480p, etc. from A (already handled in details iteration, but double-safe here)
          } else {
            others.push(ep);
          }
        } catch {
          others.push(ep);
        }
      });

      // Split the remaining B sources (VidSrc and any others)
      const epsVidSrc = others.filter(ep => {
        try { return JSON.parse(ep.url).source === 'vidsrc'; } catch { return false; }
      });
      const epsRest_B = others.filter(ep => {
        try { return JSON.parse(ep.url).source !== 'vidsrc'; } catch { return true; }
      });

      // Clear the episodes list and push strictly by quality priority:
      // 1) 4K: A > B (eps4k_A first, then B 4K if any)
      // 2) 1080p: A > B (eps1080p_A first, then validNetmirror streaming, then rest B 1080p if any)
      // 3) 720p and below: B only (Rest B, VidSrc)
      episodes.length = 0;
      episodes.push(
        ...eps4k_A,
        ...eps1080p_A,
        ...validNetmirror,
        ...epsRest_B,
        ...epsVidSrc
      );

      console.log(`[CineStream] Priority sorted: ${eps4k_A.length} 4K (A), ${eps1080p_A.length} 1080p (A), ${validNetmirror.length} Netmirror (B), ${epsRest_B.length + epsVidSrc.length} other (B).`);
    }
  } catch (err) {
    console.error('[CineStream] Netmirror auto-injection failed:', err.message);
  }

  return {
    title,
    poster,
    description,
    episodes
  };
}

async function resolveVidlinkHelper(id, tmdbId, type, season, episode) {
  const vidHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36',
    'Accept': '*/*',
    'Origin': 'https://vidlink.pro',
    'Referer': 'https://vidlink.pro/'
  };

  let streamUrl = '';
  let subtitles = [];
  let vidlinkServers = [];

  // Method 1: Try the encrypted API endpoint (fast path)
  try {
    const encUrl = `https://enc-dec.app/api/enc-vidlink?text=${tmdbId || id}`;
    const encRes = await directAxios.get(encUrl, { timeout: 8000 });
    if (encRes.data.status === 200) {
      const encrypted = encRes.data.result;
      const vidlinkUrl = type === 'movie'
        ? `https://vidlink.pro/api/b/movie/${encrypted}`
        : `https://vidlink.pro/api/b/tv/${encrypted}/${season}/${episode}`;
      const res = await axios.get(vidlinkUrl, { headers: vidHeaders, timeout: 10000 });
      if (res.data.stream && typeof res.data.stream === 'object') {
        if (res.data.stream.playlist) {
          streamUrl = res.data.stream.playlist;
        } else if (res.data.stream.qualities) {
          const q = res.data.stream.qualities;
          streamUrl = q['1080']?.url || q['720']?.url || q['480']?.url || q['360']?.url || '';
          
          // Map all available qualities
          Object.entries(q).forEach(([k, val]) => {
            if (val && val.url) {
              const label = k === '1080' ? '1080p' : k === '720' ? '720p' : k === '480' ? '480p' : k === '360' ? '360p' : `${k}p`;
              let filename = `stream_${label}.mp4`;
              try {
                const urlPath = new URL(val.url).pathname;
                const matches = urlPath.match(/\/([^\/]+\.(?:mkv|mp4|webm|avi|mov|ts|m4v))$/i);
                if (matches) {
                  filename = matches[1];
                }
              } catch (_) {}
              
              vidlinkServers.push({
                label,
                url: val.url,
                proxyUrl: `http://127.0.0.1:3000/proxy/video/${encodeURIComponent(filename)}?url=${encodeURIComponent(val.url)}&ref=${encodeURIComponent('https://vidlink.pro/')}`
              });
            }
          });
        }
      } else {
        streamUrl = res.data.stream || res.data.url || '';
      }
      if (res.data.subtitles && Array.isArray(res.data.subtitles)) {
        subtitles = res.data.subtitles;
      }
    }
  } catch (e) {
    console.warn(`[CineStream] Vidlink encrypted API failed: ${e.message}`);
  }

  // Method 2: Scrape the embed page for the stream JSON
  if (!streamUrl) {
    try {
      const embedUrl = type === 'movie'
        ? `https://vidlink.pro/movie/${tmdbId || id}`
        : `https://vidlink.pro/tv/${tmdbId || id}/${season}/${episode}`;
      const embedRes = await axios.get(embedUrl, { headers: vidHeaders, timeout: 12000 });
      const jsonMatch = embedRes.data.match(/__NEXT_DATA__[\s\S]*?<\/script>/) ||
                        embedRes.data.match(/window\.__data\s*=\s*({[\s\S]*?});/);
      if (jsonMatch) {
        const parsed = JSON.parse(jsonMatch[1]);
        const pl = parsed?.props?.pageProps?.stream?.playlist ||
                   parsed?.stream?.playlist || '';
        if (pl) streamUrl = pl;

        const subs = parsed?.props?.pageProps?.stream?.subtitles ||
                     parsed?.stream?.subtitles || [];
        if (subs && subs.length > 0) subtitles = subs;
      }
      // Fallback: look for m3u8 URL in the HTML
      if (!streamUrl) {
        const m3u8Match = embedRes.data.match(/(https?:\/\/[^"'\s]+\.m3u8[^"'\s]*)/);
        if (m3u8Match) streamUrl = m3u8Match[1];
      }
    } catch (e2) {
      console.warn(`[CineStream] Vidlink embed scrape failed: ${e2.message}`);
    }
  }

  if (!streamUrl && vidlinkServers.length === 0) {
    throw new Error('No stream URL found from Vidlink.');
  }

  // If no main streamUrl but qualities list exists, use best quality as fallback
  if (!streamUrl && vidlinkServers.length > 0) {
    // sort to find highest
    const ORDER = ['1080p', '720p', '480p', '360p'];
    vidlinkServers.sort((a,b) => ORDER.indexOf(a.label) - ORDER.indexOf(b.label));
    streamUrl = vidlinkServers[0].url;
  }

  let q = '1080p';
  if (vidlinkServers.length > 0) {
    const match = vidlinkServers.find(s => s.url === streamUrl);
    if (match) q = match.label;
  }

  if (subtitles.length === 0) {
    try {
      subtitles = await fetchOpenSubtitlesHelper(tmdbId || id, type, season, episode);
    } catch (err) {
      console.warn(`[CineStream] Vidlink OpenSubtitles fallback failed: ${err.message}`);
    }
  }

  return {
    streamUrl,
    referer: 'https://vidlink.pro/',
    subtitles,
    vidlinkServers,
    quality: q,
    headers: vidHeaders
  };
}

async function getStreams(watchUrl) {
  const { id, tmdbId, type, season, episode, year, title, source, server, ott, size, quality } = JSON.parse(watchUrl);
  console.log(`[CineStream] Resolving ${source} stream for tmdbId=${tmdbId || id}`);

  if (source === 'vidlink') {
    return await resolveVidlinkHelper(id, tmdbId, type, season, episode);

  } else if (source === 'netmirror') {
    const netmirror = await import('../netmirror/index.js');
    if (server && server.startsWith('{')) {
      console.log(`[CineStream] Resolving high-speed Netmirror (${ott}) link...`);
      return await netmirror.getStreams(server, ott);
    } else {
      console.log(`[CineStream] Resolving fallback Netmirror (${ott}) link by title: "${title}"...`);
      const searchResults = await netmirror.search(title, ott);
      const cleanTitle = title.toLowerCase().replace(/[^\w\s]/g, '').replace(/\s+/g, ' ').trim();
      let best = null;
      let bestScore = -1;
      for (const r of searchResults) {
        const rTitle = r.title.toLowerCase().replace(/[^\w\s]/g, '').replace(/\s+/g, ' ').trim();
        let score = 0;
        if (rTitle === cleanTitle) score = 200;
        else if (rTitle.includes(cleanTitle)) score = 80;
        if (score > bestScore) {
          bestScore = score;
          best = r;
        }
      }
      if (!best || bestScore < 40) {
        throw new Error(`Media not found on Netmirror for "${title}"`);
      }
      const details = await netmirror.load(best.url, ott);
      if (details && details.episodes && details.episodes.length > 0) {
        try {
          const firstEpUrl = JSON.parse(details.episodes[0].url);
          if (firstEpUrl.tmdbId && tmdbId && parseInt(firstEpUrl.tmdbId, 10) !== parseInt(tmdbId, 10)) {
            throw new Error(`TMDB ID mismatch on Netmirror fallback (got ${firstEpUrl.tmdbId}, expected ${tmdbId})`);
          }
        } catch (_) {}
      }
      const matchedEp = details.episodes.find(ep => {
        if (type === 'movie') return true;
        return ep.season.toString() === season.toString() && ep.episode.toString() === episode.toString();
      });
      if (!matchedEp) {
        throw new Error(`Episode not found on Netmirror`);
      }
      return await netmirror.getStreams(matchedEp.url, ott);
    }
  } else if (source === 'videasy') {
    console.log(`[CineStream] Resolving Videasy stream for tmdbId=${tmdbId}`);
    const videasyAPI = 'https://api.videasy.to';
    const servers = [
      'myflixerzupcloud', '1movies', 'downloader2', 'primewire',
      'm4uhd', 'hdmovie', 'cdn', 'primesrcme', 'visioncine',
      'overflix', 'superflix', 'cuevana', 'lamovie', 'mb-flix'
    ];

    const headers = {
      'Accept': '*/*',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36',
      'Origin': 'https://player.videasy.to',
      'Referer': 'https://player.videasy.to/'
    };

    const encTitle = encodeURIComponent(encodeURIComponent(title));

    const checkServer = async (serverName) => {
      try {
        const url = type === 'movie'
          ? `${videasyAPI}/${serverName}/sources-with-title?title=${encTitle}&mediaType=movie&year=${year}&tmdbId=${tmdbId}&imdbId=${id}`
          : `${videasyAPI}/${serverName}/sources-with-title?title=${encTitle}&mediaType=tv&year=${year}&tmdbId=${tmdbId}&episodeId=${episode}&seasonId=${season}&imdbId=${id}`;

        console.log(`[CineStream] Videasy: trying server ${serverName} (parallel)`);
        const encRes = await axios.get(url, { headers, timeout: 5000 });
        if (!encRes.data) return null;

        const decRes = await directAxios.post('https://enc-dec.app/api/dec-videasy', {
          text: encRes.data,
          id: tmdbId
        });

        if (decRes.data.status === 200 && decRes.data.result) {
          const sources = decRes.data.result.sources || [];
          const subtitles = decRes.data.result.subtitles || [];
          if (sources.length > 0) {
            const stream = sources[0];
            console.log(`[CineStream] Videasy: server ${serverName} succeeded!`);
            return {
              streamUrl: stream.url,
              referer: 'https://player.videasy.to/',
              subtitles,
              headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36',
                'Referer': 'https://player.videasy.to/'
              }
            };
          }
        }
      } catch (err) {
        // fail silently
      }
      return null;
    };

    const promises = servers.map(srv => checkServer(srv));

    const result = await new Promise((resolve, reject) => {
      let completed = 0;
      let resolved = false;

      promises.forEach(p => {
        Promise.resolve(p).then(res => {
          if (resolved) return;
          if (res) {
            resolved = true;
            resolve(res);
          } else {
            completed++;
            if (completed === promises.length) {
              reject(new Error('No stream found on any Videasy servers.'));
            }
          }
        }).catch(() => {
          if (resolved) return;
          completed++;
          if (completed === promises.length) {
            reject(new Error('No stream found on any Videasy servers.'));
          }
        });
      });
    });

    return result;

  } else if (source === 'vidfast') {
    try {
      console.log(`[CineStream] Resolving Vidfast stream for tmdbId=${tmdbId}`);
      const vidfastProApi = 'https://vidfast.io';
      const url = type === 'movie'
        ? `${vidfastProApi}/movie/${tmdbId}/`
        : `${vidfastProApi}/tv/${tmdbId}/${season}/${episode}/`;

      const headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36',
        'Referer': `${vidfastProApi}/`,
        'X-Requested-With': 'XMLHttpRequest'
      };

      const response = await axios.get(url, { headers, timeout: 15000 });
      const html = response.data.toString();

      const match = html.match(/\\"en\\":\\"(.*?)\\"/);
      if (!match) {
        throw new Error('Failed to find encoded text in Vidfast response.');
      }
      const encodedText = match[1];

      // Decryption prep from enc-dec.app
      const decApiUrl = `https://enc-dec.app/api/enc-vidfast?text=${encodeURIComponent(encodedText)}`;
      const decApiRes = await directAxios.get(decApiUrl, { timeout: 8000 });
      if (decApiRes.data.status !== 200) {
        throw new Error(`Vidfast decryption prep failed: ${decApiRes.data.error || 'unknown'}`);
      }

      const { servers: serversUrl, stream: streamBaseUrl, token } = decApiRes.data.result;
      headers['X-CSRF-Token'] = token;

      const serversEncrypted = await axios.post(serversUrl, {}, { headers, timeout: 8000 });
      if (!serversEncrypted.data) {
        throw new Error('Vidfast servers POST returned empty response.');
      }

      const decRes = await directAxios.post('https://enc-dec.app/api/dec-vidfast', {
        text: serversEncrypted.data
      }, { timeout: 8000 });
      if (decRes.data.status !== 200 || !decRes.data.result) {
        throw new Error(`Vidfast servers list decryption failed: ${decRes.data.error || 'unknown'}`);
      }

      const serversList = decRes.data.result;

      console.log(`[CineStream] Resolving ${serversList.length} Vidfast servers in parallel...`);
      const promises = serversList.map(async (serverObj) => {
        const serverHash = serverObj.data;
        if (!serverHash) return null;

        const finalStreamUrl = `${streamBaseUrl}/${serverHash}`;
        try {
          const streamDataEncrypted = await axios.post(finalStreamUrl, {}, { headers, timeout: 5000 });
          if (!streamDataEncrypted.data) return null;

          const streamDataRes = await directAxios.post('https://enc-dec.app/api/dec-vidfast', {
            text: streamDataEncrypted.data
          });
          if (streamDataRes.data.status === 200 && streamDataRes.data.result) {
            const fileUrl = streamDataRes.data.result.url;
            if (fileUrl) {
              return {
                name: serverObj.name,
                desc: serverObj.description || '',
                url: fileUrl,
                subtitles: streamDataRes.data.result.subtitles || []
              };
            }
          }
        } catch (err) {
          console.warn(`[CineStream] Vidfast parallel check: server ${serverObj.name} failed: ${err.message}`);
        }
        return null;
      });

      const results = await Promise.all(promises);
      const resolved = results.filter(Boolean);

      if (resolved.length === 0) {
        throw new Error('No stream found on Vidfast.');
      }

      const getQualityLabel = (item) => {
        const name = item.name.toLowerCase();
        const desc = (item.desc || '').toLowerCase();
        if (name === 'vfast' || desc.includes('4k')) return '4K';
        if (name === 'vedge' || desc.includes('1080')) return '1080p';
        if (name === 'mega') return '1080p';
        if (name === 'cobra' || name === 'charlie' || name === 'bravo') return '720p';
        if (name === 'max' || name === 'beta') return '480p';
        if (name === 'vodka') return '360p';
        return item.name; // fallback: use server name
      };

      const getQualityScore = (item) => {
        const lbl = getQualityLabel(item);
        if (lbl === '4K')   return 5;
        if (lbl === '1080p') return 4;
        if (lbl === '720p')  return 3;
        if (lbl === '480p')  return 2;
        if (lbl === '360p')  return 1;
        return 0;
      };

      // Sort highest quality first (4K Ã¢â€ â€™ 1080p Ã¢â€ â€™ 720p Ã¢â€ â€™ 480p)
      resolved.sort((a, b) => getQualityScore(b) - getQualityScore(a));

      const bestStream = resolved[0];
      const proxiedUrl = `http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent(bestStream.url)}&ref=${encodeURIComponent('https://vidfast.io/')}`;
      console.log(`[CineStream] Selected best Vidfast server: ${bestStream.name} (${bestStream.desc || 'no desc'})`);

      // Build all-servers map for unified quality picker
      const seenLabels = new Set();
      const vidfastServers = resolved
        .map(s => {
          const label = getQualityLabel(s);
          if (seenLabels.has(label)) return null; // deduplicate same quality
          seenLabels.add(label);
          return {
            label,
            server: s.name,
            url: s.url,
            proxyUrl: `http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent(s.url)}&ref=${encodeURIComponent('https://vidfast.io/')}`,
          };
        })
        .filter(Boolean);

      // De-duplicate and merge subtitles from all resolved servers
      let allSubtitles = [];
      const subUrls = new Set();
      resolved.forEach(stream => {
        if (stream.subtitles && Array.isArray(stream.subtitles)) {
          stream.subtitles.forEach(sub => {
            const file = sub.file || sub.url || '';
            if (file && !subUrls.has(file)) {
              subUrls.add(file);
              allSubtitles.push(sub);
            }
          });
        }
      });

      if (allSubtitles.length === 0) {
        try {
          allSubtitles = await fetchOpenSubtitlesHelper(tmdbId || id, type, season, episode);
        } catch (err) {
          console.warn(`[CineStream] Vidfast OpenSubtitles fallback failed: ${err.message}`);
        }
      }

      return {
        streamUrl: proxiedUrl,           // best stream (backward compat with existing app)
        referer: 'https://vidfast.io/',
        subtitles: allSubtitles,
        vidfastServers,                  // ALL servers with quality labels for unified picker
        quality: getQualityLabel(bestStream),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36',
          Referer: 'https://vidfast.io/',
          ...headers
        }
      };
    } catch (err) {
      console.warn(`[CineStream] Vidfast stream resolution failed: ${err.message}. Falling back to Vidlink...`);
      return await resolveVidlinkHelper(id, tmdbId, type, season, episode);
    }

  } else if (source === '4khdhub') {
    console.log(`[CineStream] Resolving 4khdhub stream from movie/episode URL: ${server}`);
    const fourKHDHubProvider = (await import('../4khdhub/index.js')).default;
    return await fourKHDHubProvider.getStreams(server);
  } else if (source === 'vegamovies') {
    console.log(`[CineStream] Resolving Vegamovies stream from URL: ${server}`);
    const vegaProvider = (await import('../vegamovies/index.js')).default;
    return await vegaProvider.getStreams(server);
  } else if (source === 'bollyflix') {
    console.log(`[CineStream] Resolving Bollyflix stream from URL: ${server}`);
    const bollyProvider = (await import('../bollyflix/index.js')).default;
    return await bollyProvider.getStreams(server);
  } else if (source === 'moviesdrive') {
    console.log(`[CineStream] Resolving MoviesDrive stream from URL: ${server} (size=${size}, quality=${quality})`);
    const mdProvider = (await import('../moviesdrive/index.js')).default;
    return await mdProvider.getStreams(server, size, quality);
  } else if (source === 'vidsrc') {
    const MAX_RETRIES = 4;
    let lastErr;
    for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
      try {
        console.log(`[CineStream] Resolving VidSrc stream for tmdbId=${tmdbId}... (attempt ${attempt}/${MAX_RETRIES})`);

        const rawAxios = axios;

      // ── Confirmed from HAR: active domain is daedalus.zxcstream.xyz ──────────────
      // ── 1. Dynamically resolve active VidSrc subdomain ────────────────────
      let baseUrl = 'https://daedalus.zxcstream.xyz'; // Default fallback
      try {
        const redirectTestUrl = type === 'series'
          ? `https://zxcstream.xyz/player/tv/${tmdbId}/${season}/${episode}/en`
          : `https://zxcstream.xyz/player/movie/${tmdbId}`;
        console.log(`[CineStream] VidSrc: Dynamically resolving active subdomain from https://zxcstream.xyz...`);
        const testRes = await rawAxios.get(redirectTestUrl, {
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36',
            'Referer': 'https://vidsrc.sbs/',
          },
          timeout: 5000,
        });
        const finalUrl = testRes.request?.res?.responseUrl || testRes.config?.url;
        if (finalUrl) {
          const parsed = new URL(finalUrl);
          baseUrl = parsed.origin;
          console.log(`[CineStream] VidSrc: Successfully resolved active domain: ${baseUrl}`);
        }
      } catch (err) {
        console.warn(`[CineStream] VidSrc: Domain resolution failed, using fallback: ${baseUrl}. Error: ${err.message}`);
      }

      const playerUrl = type === 'movie'
        ? `${baseUrl}/player/movie/${tmdbId}`
        : `${baseUrl}/player/tv/${tmdbId}/${season}/${episode}/en`;

      // ── Exact headers from HAR (no cf_clearance cookie needed) ────────────
      const headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36',
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'en-US,en;q=0.9,ru;q=0.8,hi;q=0.7',
        'Accept-Encoding': 'gzip, deflate, br, zstd',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
        'Origin': baseUrl,
        'Referer': playerUrl,
        'sec-ch-ua': '"Google Chrome";v="149", "Chromium";v="149", "Not)A;Brand";v="24"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"Windows"',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-origin',
        'sec-fetch-storage-access': 'active',
        'Priority': 'u=1, i',
      };

      // ── 1. Fetch TMDB metadata ─────────────────────────────────────────────
      const tmdbMetaUrl = type === 'movie'
        ? `https://api.tmdb.org/3/movie/${tmdbId}?append_to_response=external_ids`
        : `https://api.tmdb.org/3/tv/${tmdbId}?append_to_response=external_ids`;

      const tmdbRes = await axios.get(tmdbMetaUrl, {
        headers: { Authorization: `Bearer ${TMDB_BEARER}`, accept: 'application/json' }
      });
      const meta = tmdbRes.data || {};
      const title = meta.title || meta.name || '';
      const releaseDate = meta.release_date || meta.first_air_date || '';
      const year = releaseDate ? releaseDate.substring(0, 4) : '';
      const imdbId = meta.imdb_id || meta.external_ids?.imdb_id || '';

      // ── 2. Get token ───────────────────────────────────────────────────────
      const timestamp = Date.now();
      const rSalt = "3435443433";
      const hash = crypto.createHash('sha512').update(`${timestamp}:${rSalt}:${tmdbId}`).digest('hex').slice(0, 64);

      console.log(`[CineStream] VidSrc: Requesting token from ${baseUrl}...`);
      const tokenRes = await rawAxios.post(`${baseUrl}/backend/token`, {
        rgrwsdsdfgwrwrwwr: tmdbId.toString(),
        xfgdfgdsffgrwgrwyjhkjt: hash,
        rdghhdghhfssft: timestamp
      }, { headers, timeout: 10000 });

      if (tokenRes.status !== 200 || !tokenRes.data?.ZDDVHJFGHYRHG) {
        throw new Error(`Token fetch failed: Status ${tokenRes.status}`);
      }

      const token = tokenRes.data.ZDDVHJFGHYRHG;
      const serverTs = tokenRes.data.rdghhdghhfssft;
      console.log(`[CineStream] VidSrc: Token obtained ✅`);

      // ── 3. Build common icarus params ──────────────────────────────────────
      const buildIcarusParams = (extraParams = {}) => {
        const p = new URLSearchParams({
          rgrwsdsdfgwrwrwwr: tmdbId.toString(),
          b: (type === 'series') ? 'tv' : type,
          rdghhdghhfssft: serverTs.toString(),
          ZDDVHJFGHYRHG: token,
          xfgdfgdsffgrwgrwyjhkjt: hash,
          TUKTHFSSFGDGHJS: title,
          '53653TRFG647GF': year,
          date: releaseDate,
          '564745ygtuy5yi75yuy': imdbId,
          ...extraParams,
        });
        if (type === 'tv' || type === 'series') {
          p.append('adkljfhdahfladhfjahfjlahfhfljkadfdf', season.toString());
          p.append('546745ygy46ytfgty', episode.toString());
        }
        return p;
      };

      // ── 4. Fetch English (default) stream links (Icarus with Berkas fallback) ──────
      let linksRes;
      let usedServer = 'icarus';
      try {
        const icarusUrl = `${baseUrl}/backend_/servers/icarus?${buildIcarusParams()}`;
        console.log(`[CineStream] VidSrc: Fetching stream links from Icarus...`);
        linksRes = await rawAxios.get(icarusUrl, { headers, timeout: 10000 });
        if (!linksRes.data?.success || !Array.isArray(linksRes.data.links) || linksRes.data.links.length === 0) {
          throw new Error('No links on Icarus');
        }
      } catch (icarusErr) {
        console.log(`[CineStream] VidSrc: Icarus server failed or has no links. Falling back to Berkas...`);
        const berkasUrl = `${baseUrl}/backend_/servers/berkas?${buildIcarusParams()}`;
        linksRes = await rawAxios.get(berkasUrl, { headers, timeout: 10000 });
        usedServer = 'berkas';
      }

      if (!linksRes.data?.success || !Array.isArray(linksRes.data.links) || linksRes.data.links.length === 0) {
        throw new Error(`Both Icarus and Berkas failed: ${JSON.stringify(linksRes.data).substring(0, 100)}`);
      }

      // Map Berkas integer codes (4, 3, 2, 1) to actual resolution numbers (1080, 720, 480, 360)
      if (usedServer === 'berkas') {
        linksRes.data.links.forEach(lnk => {
          if (lnk.resolution === 4) lnk.resolution = 1080;
          else if (lnk.resolution === 3) lnk.resolution = 720;
          else if (lnk.resolution === 2) lnk.resolution = 480;
          else if (lnk.resolution === 1) lnk.resolution = 360;
        });
      }

      // Sort highest resolution first
      const links = linksRes.data.links.sort((a, b) => (b.resolution || 0) - (a.resolution || 0));
      const bestLink = links[0];

      // ── 5. Map subtitles from VidSrc API response ─────────────────────────
      // VidSrc has split subtitles into a separate endpoint /backend_/subtitle.
      // We query this endpoint using the same parameters.
      let rawSubs = [];
      try {
        const subtitleUrl = `${baseUrl}/backend_/subtitle?${buildIcarusParams()}`;
        console.log(`[CineStream] VidSrc: Fetching subtitles from ${subtitleUrl}...`);
        const subRes = await rawAxios.get(subtitleUrl, { headers, timeout: 5000 });
        if (subRes.data && Array.isArray(subRes.data.subtitles)) {
          rawSubs = subRes.data.subtitles;
          console.log(`[CineStream] VidSrc: Successfully fetched ${rawSubs.length} subtitles from /backend_/subtitle`);
        }
      } catch (subErr) {
        console.warn(`[CineStream] VidSrc: Failed to fetch subtitles from /backend_/subtitle: ${subErr.message}`);
      }

      if (rawSubs.length === 0) {
        rawSubs = Array.isArray(linksRes.data.subtitles) ? linksRes.data.subtitles : [];
      }

      let subtitles = rawSubs
        .filter(s => s && (s.file || s.url))
        .map(s => ({
          url: s.file || s.url || '',
          lang: s.display || s.lang || s.label || 'Unknown',
          code: s.id || s.code || (s.display ? s.display.substring(0, 2).toLowerCase() : 'en'),
        }))
        .filter(s => s.url.startsWith('http'));

      if (subtitles.length === 0) {
        try {
          console.log(`[CineStream] VidSrc: No subtitles found in API response. Fetching OpenSubtitles fallback...`);
          const openSubs = await fetchOpenSubtitlesHelper(tmdbId || id, type, season, episode);
          if (Array.isArray(openSubs) && openSubs.length > 0) {
            subtitles = openSubs.map(s => ({
              url: s.url,
              lang: s.lang,
              code: s.code,
            }));
            console.log(`[CineStream] VidSrc: Successfully loaded ${subtitles.length} subtitles from OpenSubtitles`);
          }
        } catch (osErr) {
          console.warn(`[CineStream] VidSrc: OpenSubtitles fallback failed: ${osErr.message}`);
        }
      }
      if (subtitles.length > 0) {
        console.log(`[CineStream] VidSrc: ${subtitles.length} subtitle(s): ${subtitles.map(s => s.lang).join(', ')}`);
      }

      // ── 6. Build per-quality proxy entries (English) ──────────────────────
      const vidfastServers = links.map(lnk => {
        const isHls = lnk.link.includes('.m3u8') || lnk.type === 'hls';
        const proxyPath = isHls ? 'hls' : 'video/stream.mp4';
        return {
          label: lnk.resolution ? `${lnk.resolution}p` : '1080p',
          server: 'Zxc',
          url: lnk.link,
          proxyUrl: `http://127.0.0.1:3000/proxy/${proxyPath}?url=${encodeURIComponent(lnk.link)}&ref=${encodeURIComponent(baseUrl + '/')}&ua=${encodeURIComponent(headers['User-Agent'] || '')}`,
        };
      });

      // ── 7. Fetch dub language streams ──────────────────────────────────────
      // HAR confirms: dubs have type=0, original=false
      // Example: Hindi(hi,type=0), Arabic(ar,type=0), Russian(ru,type=0), French(fr,type=0)
      const originalLanguage = meta.original_language || '';
      console.log('[CineStream] raw dubs:', JSON.stringify(linksRes.data.dubs));
      const dubList = (linksRes.data.dubs || []).filter(d => 
        d.type === 0 && !d.original && d.lang !== originalLanguage && (d.lang === 'hi' || d.name.toLowerCase().includes('hindi'))
      );
      console.log(`[CineStream] VidSrc: Found ${dubList.length} dub languages (excluding original language "${originalLanguage}"): ${dubList.map(d => d.name).join(', ')}`);

      console.log(`[CineStream] VidSrc: Resolving ${dubList.length} dubs in parallel...`);
      const dubPromises = dubList.map(async (dub) => {
        try {
          const dubParams = buildIcarusParams({ dubCode: dub.lang, dubType: dub.type.toString() });
          const dubRes = await rawAxios.get(`${baseUrl}/backend_/servers/icarus?${dubParams}`, { headers, timeout: 6000 });
          if (dubRes.data?.success && Array.isArray(dubRes.data.links) && dubRes.data.links.length > 0) {
            dubRes.data.links.sort((a, b) => (b.resolution || 0) - (a.resolution || 0));
            const list = [];
            for (const lnk of dubRes.data.links) {
              const isHls = lnk.link.includes('.m3u8') || lnk.type === 'hls';
              const proxyPath = isHls ? 'hls' : 'video/stream.mp4';
              list.push({
                label: lnk.resolution ? `${lnk.resolution}p` : '1080p',
                server: `Zxc [${dub.name}]`,
                url: lnk.link,
                proxyUrl: `http://127.0.0.1:3000/proxy/${proxyPath}?url=${encodeURIComponent(lnk.link)}&ref=${encodeURIComponent(baseUrl + '/')}&ua=${encodeURIComponent(headers['User-Agent'] || '')}`,
                lang: dub.lang,
                langName: dub.name,
              });
            }
            console.log(`[CineStream] VidSrc: ${dub.name} dub âœ… â€” ${list.length} quality links`);
            return list;
          }
        } catch (dubErr) {
          console.warn(`[CineStream] VidSrc: ${dub.name} dub failed: ${dubErr.message}`);
        }
        return [];
      });

      const dubResults = await Promise.all(dubPromises);
      const dubServers = dubResults.flat();

      const allServers = [...vidfastServers, ...dubServers];
      const bestProxyUrl = `http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent(bestLink.link)}&ref=${encodeURIComponent(baseUrl + '/')}`;

      console.log(`[CineStream] VidSrc âœ… ${bestLink.resolution || '?'}p | ${allServers.length} quality+dub entries | ${subtitles.length} subtitles`);

      return {
        streamUrl: bestProxyUrl,
        referer: baseUrl + '/',
        subtitles,
        vidfastServers: allServers,
        quality: bestLink.resolution ? `${bestLink.resolution}p` : '1080p',
        headers: {
          'User-Agent': headers['User-Agent'],
          'Referer': baseUrl + '/',
        }
      };

      } catch (err) {
        lastErr = err;
        const isRetryable = err.code === 'ECONNRESET' || err.code === 'ECONNREFUSED'
          || err.code === 'ETIMEDOUT' || err.code === 'ENOTFOUND'
          || (err.response && err.response.status >= 500);
        if (isRetryable && attempt < MAX_RETRIES) {
          console.warn(`[CineStream] VidSrc attempt ${attempt} failed (${err.message}), retrying in 1s...`);
          await new Promise(r => setTimeout(r, 1000));
        } else {
          console.warn(`[CineStream] VidSrc stream resolution failed after ${attempt} attempt(s): ${err.message}`);
          throw err;
        }
      }
    }
    throw lastErr;
  }

  throw new Error(`Unsupported source: ${source}`);
}
