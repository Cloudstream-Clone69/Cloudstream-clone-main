import provider from './index.js';

(async () => {
  try {
    // Search
    const results = await provider.search('one piece');
    console.log('First result:', results[0].title);

    // Load
    const details = await provider.load(results[0].url);
    console.log('Episodes:', details.episodes.length);

    // Get stream for first episode
    if (details.episodes.length > 0) {
      const stream = await provider.getStreams(details.episodes[0].url);
      console.log('Stream URL:', stream.streamUrl);
      console.log('Referer:', stream.referer);
      console.log('Success! Copy the stream URL and test in VLC.');
    }
  } catch (err) {
    console.error('Error:', err.message);
  }
})();
