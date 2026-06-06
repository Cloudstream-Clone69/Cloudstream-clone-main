export const BASE_URL = 'https://www.anidao.to';

export const SEARCH = {
  url: (query) => `${BASE_URL}/search?q=${encodeURIComponent(query)}`,
  item: 'article.an-anime-card',
  title: 'h2.an-anime-card__title a',
  poster: 'a.an-anime-card__image img',
};

export const DETAILS = {
  title: 'h1',
  poster: 'meta[property="og:image"]',
  description: 'meta[property="og:description"]',
  episodeRow: 'article.an-episode-row',
  episodeLink: 'h3.an-episode-row__title a',
};

export const STREAM = {
  // The iframe that contains the video player
  iframe: 'iframe',
  // Regex to extract .m3u8 URL from the iframe page
  m3u8Regex: /(https?:\/\/[^"'\s]+\.m3u8[^"'\s]*)/i,
};
