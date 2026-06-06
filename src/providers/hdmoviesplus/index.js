import * as cheerio from 'cheerio';
import { fetchHTMLPost, fetchHTML } from '../common.js';
import { BASE_URL, SEARCH, DETAILS, STREAM } from './selectors.js';

export default { search, load, getStreams };

async function search(query) {
  const postData = SEARCH.postData(query);
  const html = await fetchHTMLPost(SEARCH.url, postData, BASE_URL);
  const $ = cheerio.load(html);
  const results = [];

  $(SEARCH.item).each((i, el) => {
    const titleEl = $(el).find(SEARCH.title);
    const title = titleEl.text().trim();
    const poster = $(el).find(SEARCH.poster).attr('src');
    const url = titleEl.attr('href') || $(el).find(SEARCH.link).attr('href');

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
  const poster = $(DETAILS.poster).attr('src') || $('meta[property="og:image"]').attr('content');
  const description = $(DETAILS.description).first().text().trim();

  // Extract IMDB ID for streaming
  const imdbId = $(DETAILS.imdbIdSelector).attr('data-imdb') || '';

  const episodes = [];

  // 1. Streaming player entry
  if (imdbId) {
    episodes.push({
      title: 'Stream',
      quality: 'HLS (adaptive)',
      size: '',
      url: `stream:${imdbId}`,
    });
  }

  // 2. Download links (quality + size)
  $(DETAILS.qualityHeadings).each((i, el) => {
    const quality = $(el).text().trim().replace('P', 'p'); // "480P" -> "480p"
    const linkEl = $(el).next('p').find('a').first();      // first <a> in next <p>
    const href = linkEl.attr('href');
    if (href) {
      const sizeText = linkEl.text().trim();   // "⚡ Download Link 1 - 365MB"
      const sizeMatch = sizeText.match(/(\d+\.?\d*\s*(?:GB|MB|KB))/i);
      const size = sizeMatch ? sizeMatch[1] : '';
      episodes.push({
        title: `Download ${quality}`,
        quality,
        size,
        url: new URL(href, BASE_URL).href,
      });
    }
  });

  return {
    title,
    poster: poster ? new URL(poster, BASE_URL).href : null,
    description,
    episodes,
  };
}

async function getStreams(episodeUrl) {
  if (episodeUrl.startsWith('stream:')) {
    const imdbId = episodeUrl.substring(7);
    // Fetch the iframe page
    const iframeUrl = STREAM.iframeUrl(imdbId);
    const html = await fetchHTML(iframeUrl, BASE_URL);
    // Extract the m3u8 file URL
    const match = html.match(STREAM.fileRegex);
    if (!match) throw new Error('Could not find stream URL in iframe');
    let streamUrl = match[1];
    // Clean up escaped slashes
    streamUrl = streamUrl.replace(/\\\//g, '/');
    // Replace .txt with .m3u8 (optional but cleaner for VLC)
    streamUrl = streamUrl.replace(/\.txt$/i, '.m3u8');
    // Encode $ signs for VLC
    streamUrl = streamUrl.replace(/\$/g, '%24');
    return {
      streamUrl,
      referer: iframeUrl,
    };
  } else {
    // For download links, just return the URL directly
    return {
      streamUrl: episodeUrl,
      referer: BASE_URL,
    };
  }
}
