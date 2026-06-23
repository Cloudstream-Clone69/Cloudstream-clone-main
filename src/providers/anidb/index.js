// AniDB provider — scrapes anidb.app using Android UA to bypass Cloudflare
// API flow:
//   1. GET /search/suggestions?q={query}           → HTML with <a href="/anime/{slug}-{id}"> links
//   2. GET /api/frontend/anime/{id}/episodes        → JSON { episodes: [{id, number, number2, filler}] }
//   3. GET /api/frontend/episode/{episodeId}/languages → JSON { languages: [{code, name, embed_url}] }
//   4. GET /embed/{token}                           → HTML with JW Player sources containing m3u8 URL

import * as cheerio from 'cheerio';

const BASE_URL = 'https://anidb.app';
const HLS_BASE = 'https://hls.anidb.app';

// Android UA is the key — it bypasses Cloudflare's JS challenge
const ANDROID_UA = 'Dalvik/2.1.0 (Linux; U; Android 13; Pixel 7 Build/TQ3A.230805.001)';
const HEADERS = {
  'User-Agent': ANDROID_UA,
  'Accept': 'application/json, text/html, */*',
  'Accept-Encoding': 'gzip, deflate',
  'Referer': BASE_URL + '/',
};

import { createAxios } from '../../services/dnsAxios.js';

const http = createAxios({
  baseURL: BASE_URL,
  headers: HEADERS,
  timeout: 15000,
  decompress: true,
});

export default { search, load, getStreams };

/**
 * Search for anime by query title.
 * Returns [{title, url, poster}]
 */
async function search(query) {
  const resp = await http.get(`/search/suggestions?q=${encodeURIComponent(query)}`);
  const html = resp.data;
  const $ = cheerio.load(html);
  const results = [];

  $('a[data-search-item]').each((_, el) => {
    const href = $(el).attr('href') || '';
    const title = $(el).find('p.font-medium').text().trim() || $(el).find('p').first().text().trim();
    const poster = $(el).find('img').attr('src') || '';
    if (href && title) {
      results.push({ title, url: href, poster });
    }
  });

  return results;
}

/**
 * Load episode list for an anime — returns Sub and Dub as separate entries.
 * url = "https://anidb.app/anime/{slug}-{animeId}"
 */
async function load(url) {
  // Extract numeric anime ID from URL slug like "sentenced-to-be-a-hero-4701"
  const idMatch = url.match(/-(\d+)(?:\/|$)/);
  if (!idMatch) throw new Error(`Cannot extract anime ID from URL: ${url}`);
  const animeId = idMatch[1];

  // Get anime page for metadata (title, poster)
  const pageResp = await http.get(url);
  const $ = cheerio.load(pageResp.data);
  const title = $('h1').first().text().trim() || $('title').text().split('—')[0].trim();
  const poster = $('meta[property="og:image"]').attr('content') || '';
  const description = $('meta[property="og:description"]').attr('content') || '';

  // Get episode list from JSON API
  const epsResp = await http.get(`/api/frontend/anime/${animeId}/episodes`);
  const epsData = epsResp.data;
  const rawEpisodes = epsData.episodes || [];

  // For each episode, check what languages are available.
  // Return Sub (jpn) and Dub (eng) as separate entries — they each have master.m3u8.
  // We encode the language preference into the URL using a ?lang= param.
  const episodes = [];
  for (const ep of rawEpisodes) {
    const epNum = ep.number;
    const baseUrl = `${BASE_URL}/api/frontend/episode/${ep.id}/languages`;

    // Sub (Japanese) — always available
    episodes.push({
      title: `Episode ${epNum}`,
      url: `${baseUrl}?lang=jpn`,
      episode: String(epNum),
      quality: 'Sub',
      size: '',
    });

    // Dub (English) — added with lang=eng; getStreams will fall back if unavailable
    episodes.push({
      title: `Episode ${epNum} (Dub)`,
      url: `${baseUrl}?lang=eng`,
      episode: String(epNum),
      quality: 'Dub',
      size: '',
    });
  }

  return { title, poster, description, episodes };
}

/**
 * Get stream URL for a specific episode + language.
 * episodeUrl = "https://anidb.app/api/frontend/episode/{id}/languages?lang=jpn"
 *
 * Returns the full master.m3u8 which has 1080p / 720p / 360p quality variants.
 */
async function getStreams(episodeUrl) {
  // Parse language preference from URL param
  const urlObj = new URL(episodeUrl);
  const langPref = urlObj.searchParams.get('lang') || 'jpn';
  const apiUrl = `${urlObj.origin}${urlObj.pathname}`; // strip ?lang= param

  // Fetch languages
  const langsResp = await http.get(apiUrl);
  const langsData = langsResp.data;
  const languages = langsData.languages || [];

  if (languages.length === 0) throw new Error('No languages available for this episode');

  // Find preferred language, fallback to first available
  const preferred = languages.find(l => l.code === langPref)
    || languages.find(l => l.code === 'jpn')
    || languages[0];

  // Fetch embed page → extract HLS master.m3u8
  const embedResp = await http.get(preferred.embed_url);
  const embedHtml = embedResp.data;

  // The master.m3u8 has 1080p, 720p, 360p — use it directly (NOT the sub-playlist)
  const m3u8Match = embedHtml.match(/https:\/\/hls\.anidb\.app\/stream\/[A-Za-z0-9_\-]+\/master\.m3u8/);
  if (!m3u8Match) throw new Error('Could not extract HLS stream URL from embed page');

  const streamUrl = m3u8Match[0];
  const langLabel = langPref === 'eng' ? 'Dub' : 'Sub';

  return {
    streamUrl,
    referer: preferred.embed_url,
    langLabel, // 'Sub' or 'Dub'
    subtitleUrl: '',
  };
}

