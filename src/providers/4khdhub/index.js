import * as cheerio from 'cheerio';
import { fetchHTML, resolveFinalUrl, headRequest } from '../common.js';
import { BASE_URL, SEARCH, DETAILS, STREAM } from './selectors.js';

export default { search, load, getStreams };

async function search(query) {
  const html = await fetchHTML(SEARCH.url(query));
  const $ = cheerio.load(html);
  const results = [];
  $(SEARCH.item).each((i, el) => {
    const title = $(el).find(SEARCH.title).text().trim();
    const poster = $(el).find(SEARCH.poster).attr('src');
    const url = $(el).attr('href');
    if (title && url) {
      results.push({
        title,
        poster: poster ? new URL(poster, BASE_URL).href : null,
        url: new URL(url, BASE_URL).href,
      });
    }
  });
  return results;
}

async function load(url) {
  const html = await fetchHTML(url, BASE_URL);
  const $ = cheerio.load(html);
  const title = $(DETAILS.title).first().text().trim();
  const poster = $(DETAILS.poster).attr('content') || $('meta[property="og:image"]').attr('content');
  const description = $(DETAILS.description).attr('content') || '';
  const episodes = [];

  $(DETAILS.episodeItem).each((i, el) => {
    const epTitle = $(el).find(DETAILS.episodeTitle).text().trim();
    const epNumber = $(el).find(DETAILS.episodeNumber).text().trim() || `Episode ${i+1}`;
    const size = $(el).find(DETAILS.episodeSize).text().trim() || '';
    const qualMatch = epTitle.match(DETAILS.qualityRegex);
    const quality = qualMatch ? qualMatch[1] : 'Unknown';
    const firstLink = $(el).find(DETAILS.downloadLinks).first();
    const epUrl = firstLink.attr('href');
    if (epUrl && epUrl.startsWith('http')) {
      episodes.push({
        episode: epNumber,
        quality,
        size,
        title: epTitle,
        url: epUrl,
      });
    }
  });

  if (episodes.length === 0) {
    $(DETAILS.movieItem).each((i, el) => {
      const headerText = $(el).find(DETAILS.movieQualityLabel).first().text().trim();
      if (!headerText || headerText.toLowerCase().includes('zip') || headerText.toLowerCase().includes('s01')) return;
      const sizeEl = $(el).find(DETAILS.movieSizeSelector).first();
      const size = sizeEl.text().trim() || '';
      const qualMatch = headerText.match(DETAILS.qualityRegex);
      const quality = qualMatch ? qualMatch[1] : 'Unknown';
      const firstLink = $(el).find(DETAILS.movieDownloadLinks).first();
      const epUrl = firstLink.attr('href');
      if (epUrl && epUrl.startsWith('http')) {
        episodes.push({
          episode: 'Movie',
          quality,
          size,
          title: headerText,
          url: epUrl,
        });
      }
    });
  }

  if (episodes.length === 0) {
    $('a.btn').each((i, el) => {
      const href = $(el).attr('href');
      const text = $(el).text().trim();
      if (href && href.startsWith('http')) {
        episodes.push({
          episode: 'Movie',
          quality: 'Unknown',
          size: '',
          title: text,
          url: href,
        });
      }
    });
  }

  return {
    title,
    poster: poster ? new URL(poster, BASE_URL).href : null,
    description,
    episodes,
  };
}

async function getStreams(downloadUrl) {
  if (downloadUrl.includes('hubcloud.foo')) {
    return getStreamsFromHubcloud(downloadUrl);
  }
  return getStreamsFromDirect(downloadUrl);
}

async function getStreamsFromHubcloud(hubcloudUrl) {
  const html = await fetchHTML(hubcloudUrl, BASE_URL);
  const $ = cheerio.load(html);
  const generateUrl = $(STREAM.generateLink).attr('href');
  if (!generateUrl) throw new Error('Generate download link not found');

  const finalHtml = await fetchHTML(generateUrl, hubcloudUrl);
  const $$ = cheerio.load(finalHtml);

  const serverLinks = [];
  $$('a').each((i, el) => {
    const text = $$(el).text().toLowerCase();
    const href = $$(el).attr('href');
    if (href && (text.includes('fsl') || text.includes('server') || text.includes('download') || text.includes('stream'))) {
      serverLinks.push(href);
    }
  });

  // Also grab ALL links from the page as fallback
  if (serverLinks.length === 0) {
    $$('a[href^="http"]').each((i, el) => {
      const href = $$(el).attr('href');
      if (href) serverLinks.push(href);
    });
  }

  if (serverLinks.length === 0) throw new Error('No server links found on generate page');

  // These domains serve DIRECT video files (MPV can play them)
  const directDomains = [
    'hub.diskcdn.buzz',
    'hub.mandalorian.buzz',
    'hub.homelander.buzz',
    'hub.buvps.buzz',
    'pixeldrain.dev',
    'cdn.fukggl.buzz',
  ];

  // Direct domains matched by pattern (CDN hostnames that serve video files)
  const isDirectCdn = (hostname) =>
    directDomains.includes(hostname) ||
    hostname.endsWith('.r2.dev') ||       // Cloudflare R2 storage
    hostname.endsWith('.workers.dev') ||  // Cloudflare Workers CDN
    hostname.endsWith('.herokucdn.workers.dev') ||
    hostname.endsWith('.buzz') ||         // All .buzz CDN domains
    hostname.endsWith('.surf');           // All .surf CDN domains

  // pixel.hubcloud.cx is a PLAYER PAGE — we must fetch it and extract the real video URL
  const playerPageDomains = [
    'pixel.hubcloud.cx',
  ];

  const videoExts = ['mkv', 'mp4', 'avi', 'mov', 'm4v', 'webm', 'm3u8', 'ts'];

  const isZipFile = (urlStr) => {
    try {
      const pathname = new URL(urlStr).pathname;
      return /\.(zip|rar|7z)$/i.test(pathname);
    } catch (_) {
      return false;
    }
  };

  // Sort server links: prioritize direct CDN links first, and deprioritize ZIP/RAR files to the end
  const sortedServerLinks = [...serverLinks].sort((a, b) => {
    const aIsZip = isZipFile(a);
    const bIsZip = isZipFile(b);
    if (aIsZip && !bIsZip) return 1;
    if (!aIsZip && bIsZip) return -1;

    let aIsDirect = false;
    let bIsDirect = false;
    try { aIsDirect = isDirectCdn(new URL(a).hostname); } catch (_) {}
    try { bIsDirect = isDirectCdn(new URL(b).hostname); } catch (_) {}
    if (aIsDirect && !bIsDirect) return -1;
    if (!aIsDirect && bIsDirect) return 1;
    return 0;
  });

  for (const serverLink of sortedServerLinks) {
    console.log(`  Checking: ${serverLink}`);
    let urlObj;
    try { urlObj = new URL(serverLink); } catch { continue; }

    // Direct CDN domain → route through our proxy (avoids ISP IP-level blocking)
    if (isDirectCdn(urlObj.hostname)) {
      console.log(`    Direct CDN via proxy: ${serverLink}`);
      // Pre-validate CDN link to ensure it's not a 404 or 403
      const check = await headRequest(serverLink, generateUrl, 5000);
      if (!check) {
        console.log(`      [Validation] Direct CDN link failed (404/403/timeout) -> skipping`);
        continue;
      }
      console.log(`      [Validation] Direct CDN link OK`);
      return { streamUrl: serverLink, referer: generateUrl };
    }

    // Player page → fetch it and extract the real video URL
    if (playerPageDomains.includes(urlObj.hostname)) {
      console.log(`    Player page, extracting real URL from: ${serverLink}`);
      try {
        // First try: resolve final URL and check if there's a 'link' parameter
        const finalUrl = await resolveFinalUrl(serverLink, generateUrl);
        try {
          const parsed = new URL(finalUrl);
          const extractedLink = parsed.searchParams.get('link');
          if (extractedLink) {
            console.log(`    Extracted link parameter from redirect: ${extractedLink}`);
            const check = await headRequest(extractedLink, null, 5000);
            if (check) {
              console.log(`      [Validation] Extracted link OK`);
              return { streamUrl: extractedLink, referer: finalUrl };
            } else {
              console.log(`      [Validation] Extracted link failed (404/403/timeout) -> skipping`);
            }
          }
        } catch (_) {}

        const playerHtml = await fetchHTML(serverLink, generateUrl);
        const $p = cheerio.load(playerHtml);

        // Look for video source tags
        const videoSrc = $p('video source').attr('src') ||
                         $p('video').attr('src') ||
                         $p('source').attr('src');
        if (videoSrc) {
          const resolved = new URL(videoSrc, serverLink).href;
          console.log(`    Extracted video src: ${resolved}`);
          const check = await headRequest(resolved, serverLink, 5000);
          if (check) {
            return { streamUrl: resolved, referer: serverLink };
          } else {
            console.log(`      [Validation] Extracted video src failed -> skipping`);
          }
        }

        // Look for direct video file links in page
        let found = null;
        $p('a[href]').each((i, el) => {
          const href = $p(el).attr('href') || '';
          if (videoExts.some(e => href.toLowerCase().includes('.' + e))) {
            found = href.startsWith('http') ? href : new URL(href, serverLink).href;
          }
        });
        if (found) {
          console.log(`    Extracted link: ${found}`);
          const check = await headRequest(found, serverLink, 5000);
          if (check) {
            return { streamUrl: found, referer: serverLink };
          } else {
            console.log(`      [Validation] Extracted link failed -> skipping`);
          }
        }

        // Parse JS for video URLs — common pattern: file:"URL" or src:"URL"
        const scripts = [];
        $p('script').each((i, el) => scripts.push($p(el).html() || ''));
        const allJs = scripts.join('\n');

        // Match common video URL patterns in JS
        const patterns = [
          /["']file["']\s*:\s*["'](https?:\/\/[^"']+\.(?:mkv|mp4|m3u8|webm|avi))["']/i,
          /["']src["']\s*:\s*["'](https?:\/\/[^"']+\.(?:mkv|mp4|m3u8|webm|avi))["']/i,
          /source\s*:\s*["'](https?:\/\/[^"']+\.(?:mkv|mp4|m3u8|webm|avi))["']/i,
          /(https?:\/\/[^"'\s<>]+\.(?:mkv|mp4|webm|m3u8)(?:\?[^"'\s<>]*)?)/i,
        ];
        for (const pat of patterns) {
          const m = allJs.match(pat);
          if (m && m[1]) {
            console.log(`    JS-extracted URL: ${m[1]}`);
            const check = await headRequest(m[1], serverLink, 5000);
            if (check) {
              return { streamUrl: m[1], referer: serverLink };
            } else {
              console.log(`      [Validation] JS-extracted link failed -> skipping`);
            }
          }
        }

        console.log(`    Could not extract video URL from player page`);
      } catch (e) {
        console.error(`    Error fetching player page: ${e.message}`);
      }
      continue; // try next server link
    }

    // Unknown domain — try to resolve final URL
    try {
      const finalUrl = await resolveFinalUrl(serverLink, generateUrl);
      console.log(`    Resolved: ${finalUrl}`);
      const headers = await headRequest(finalUrl, generateUrl, 5000);
      if (headers) {
        const contentType = (headers['content-type'] || '').toLowerCase();
        const contentLength = parseInt(headers['content-length'] || '0', 10);
        const contentDisp = (headers['content-disposition'] || '').toLowerCase();

        const hasVideoExt = videoExts.some(ext => finalUrl.toLowerCase().includes('.' + ext)) ||
                            videoExts.some(ext => contentDisp.includes('.' + ext));

        const isMedia = contentType.startsWith('video/') ||
                        contentType.includes('mpegurl') ||
                        contentType.includes('dash+xml') ||
                        (contentType === 'application/octet-stream' && contentLength > 10 * 1024 * 1024);

        if (hasVideoExt || isMedia) {
          console.log(`      [Validation] Resolved stream URL OK (Media/Extension match)`);
          return { streamUrl: finalUrl, referer: generateUrl };
        }
      }
    } catch (e) {
      console.error(`    Error: ${e.message}`);
    }
  }

  throw new Error('No playable stream found');
}

async function getStreamsFromDirect(directUrl) {
  console.log(`  Direct link, resolving...`);
  const videoExts = ['mkv', 'mp4', 'avi', 'mov', 'm4v', 'webm', 'm3u8', 'ts'];
  try {
    const finalUrl = await resolveFinalUrl(directUrl, BASE_URL);
    if (videoExts.some(ext => finalUrl.toLowerCase().endsWith('.' + ext))) {
      return { streamUrl: finalUrl, referer: BASE_URL };
    }
    const html = await fetchHTML(directUrl, BASE_URL, 2, 30000);
    const $ = cheerio.load(html);

    // If it's a detail/intermediate page link, extract the HubCloud download link and resolve it
    const hubcloudLink = $('a[href*="hubcloud"]').first().attr('href');
    if (hubcloudLink) {
      console.log(`  Found HubCloud link on page: ${hubcloudLink}`);
      return getStreamsFromHubcloud(hubcloudLink);
    }

    for (const ext of videoExts) {
      const link = $(`a[href$=".${ext}"]`).first().attr('href');
      if (link) {
        return { streamUrl: new URL(link, directUrl).href, referer: BASE_URL };
      }
    }
    if ($(STREAM.generateLink).length) {
      return getStreamsFromHubcloud(directUrl);
    }
  } catch (e) {
    console.error(`  Direct error: ${e.message}`);
  }
  throw new Error('No playable stream found from direct link');
}
