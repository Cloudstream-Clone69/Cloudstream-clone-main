import provider from './index.js';

(async () => {
  try {
    const results = await provider.search('spider-noir');
    if (results.length === 0) return console.log('No results');
    const first = results[0];
    console.log('Loading details for:', first.title);
    const details = await provider.load(first.url);
    console.log('Title:', details.title);
    console.log('Episodes count:', details.episodes.length);
    if (details.episodes.length > 0) {
      console.log('First episode:', details.episodes[0]);
      console.log('Getting stream for first episode...');
      const stream = await provider.getStreams(details.episodes[0].url);
      console.log('Stream URL:', stream.streamUrl);
      console.log('Referer:', stream.referer);
      console.log('Success! Open the stream URL in VLC or browser.');
    }
  } catch (err) {
    console.error('Test failed:', err.message);
  }
})();
