export const BASE_URL = 'https://4khdhub.link';

export const SEARCH = {
  url: (query) => `${BASE_URL}/?s=${encodeURIComponent(query)}`,
  item: 'a.movie-card',
  title: 'h3.movie-card-title',
  poster: 'img',
};

export const DETAILS = {
  title: 'h1',
  poster: 'meta[property="og:image"]',
  description: 'meta[property="og:description"]',
  
  // Series episode selectors
  episodeContainer: 'div.episode-downloads',
  episodeItem: 'div.episode-download-item',
  episodeTitle: 'div.episode-file-title',
  episodeNumber: 'div.episode-file-info span.badge-psa',
  episodeSize: 'div.episode-file-info span.badge-size',
  downloadLinks: 'div.episode-links a.btn',
  qualityRegex: /(\d{3,4}p)/i,

  // Movie quality selectors (same container as series zip but used for individual qualities)
  movieItem: 'div.download-item',                     // individual quality block
  movieQualityLabel: 'div.download-header .flex-1',   // contains text like "Top Gun: Maverick (2160p...)"
  movieSizeSelector: 'span.badge[style*="background-color: #ea580c"]', // file size badge
  movieDownloadLinks: 'div.grid.grid-cols-2 a.btn'    // download buttons inside the item
};

export const STREAM = {
  generateLink: 'a#download[href*="gamerxyt.com"]',
  mkvLink: 'a[href$=".mkv"]',
};
