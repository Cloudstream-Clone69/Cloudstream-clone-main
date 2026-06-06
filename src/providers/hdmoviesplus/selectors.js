export const BASE_URL = 'https://hdmoviesrack.com';

export const SEARCH = {
  url: `${BASE_URL}/index.php?do=search`,
  postData: (query) => `do=search&subaction=search&story=${encodeURIComponent(query)}`,
  item: 'article.item',
  title: 'div.data h3 a',
  poster: 'div.poster img',
  link: 'div.poster a',
};

export const DETAILS = {
  title: 'div.sheader .data h1',
  poster: 'div.sheader .poster img',
  description: 'div#info div.ftext',
  imdbIdSelector: 'li#player-option-1',   // data-imdb attribute
  // Download links extraction (qualities in h3, then p a)
  qualityHeadings: 'div.wp-content h3',    // <h3>480P</h3>
};

export const STREAM = {
  // The iframe page pattern
  iframeUrl: (imdbId) => `https://gemma416okl.com/play/${imdbId}`,
  // Regex to extract the file URL from the p3 object
  fileRegex: /file":"([^"]+)"/,
};
