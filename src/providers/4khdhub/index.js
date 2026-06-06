import * as cheerio from 'cheerio';
import { fetchHTML, resolveFinalUrl } from '../common.js';
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
    if (href && (text.includes('fsl') || text.includes('server') || text.includes('download'))) {
      serverLinks.push(href);
    }
  });

  if (serverLinks.length === 0) throw new Error('No server links found on generate page');

  // Known direct‑stream domains – order matters, first match wins
  const directDomains = [
    'hub.diskcdn.buzz',       // fastest for One Piece
    'hub.mandalorian.buzz',
    'hub.homelander.buzz',
    'pixel.hubcloud.cx',
    'pixeldrain.dev',
    'cdn.fukggl.buzz',
  ];

  for (const serverLink of serverLinks) {
    console.log(`  Checking: ${serverLink}`);
    const urlObj = new URL(serverLink);
    if (directDomains.includes(urlObj.hostname)) {
      console.log(`    Direct stream domain, returning immediately.`);
      return { streamUrl: serverLink, referer: generateUrl };
    }
    // Otherwise, try to resolve the final URL
    try {
      const finalUrl = await resolveFinalUrl(serverLink, generateUrl);
      console.log(`    Resolved: ${finalUrl}`);
      const videoExts = ['mkv', 'mp4', 'avi', 'mov', 'm4v', 'webm', 'm3u8', 'ts'];
      if (videoExts.some(ext => finalUrl.toLowerCase().endsWith('.' + ext))) {
        return { streamUrl: finalUrl, referer: generateUrl };
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
