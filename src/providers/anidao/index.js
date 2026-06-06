import * as cheerio from 'cheerio';
import { fetchHTML } from '../common.js';
import { BASE_URL, SEARCH, DETAILS, STREAM } from './selectors.js';

export default { search, load, getStreams };

async function search(query) {
  const html = await fetchHTML(SEARCH.url(query));
  const $ = cheerio.load(html);
  const results = [];

  $(SEARCH.item).each((i, el) => {
    const titleLink = $(el).find(SEARCH.title);
    const title = titleLink.text().trim();
    const url = titleLink.attr('href');
    const poster = $(el).find(SEARCH.poster).attr('src');

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
  $(DETAILS.episodeRow).each((i, el) => {
    const link = $(el).find(DETAILS.episodeLink);
    const epTitle = link.text().trim();
    const epUrl = link.attr('href');
    if (epUrl && epUrl !== '#') {
      episodes.push({
        title: epTitle,
        url: new URL(epUrl, BASE_URL).href,
      });
    }
  });

  // Sort episodes by the number extracted from the title (e.g., "Episode 1" -> 1)
  const getEpisodeNumber = (title) => {
    const match = title.match(/Episode\s+(\d+)/i);
    return match ? parseInt(match[1], 10) : Infinity;
  };
  episodes.sort((a, b) => getEpisodeNumber(a.title) - getEpisodeNumber(b.title));

  return {
    title,
    poster: poster ? new URL(poster, BASE_URL).href : null,
    description,
    episodes,
  };
}

async function getStreams(episodeUrl) {
  const html = await fetchHTML(episodeUrl, BASE_URL);
  const $ = cheerio.load(html);

  let iframeSrc = $(STREAM.iframe).attr('src');
  if (!iframeSrc) {
    throw new Error('No iframe found on episode page');
  }
  iframeSrc = new URL(iframeSrc, episodeUrl).href;

  const iframeHtml = await fetchHTML(iframeSrc, episodeUrl);
  const $$ = cheerio.load(iframeHtml);

  let streamUrl = $$(STREAM.source).attr('src');
  if (!streamUrl) {
    const match = iframeHtml.match(STREAM.m3u8Regex);
    if (match) streamUrl = match[0];
  }

  if (!streamUrl) {
    throw new Error('Could not extract stream URL from iframe');
  }

  streamUrl = new URL(streamUrl, iframeSrc).href;

  return {
    streamUrl,
    referer: iframeSrc,
  };
}
