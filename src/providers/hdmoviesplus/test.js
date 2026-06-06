import provider from './index.js';

(async () => {
  try {
    const results = await provider.search('tumbbad');
    console.log('First 3 results:');
    console.log(results.slice(0, 3));
  } catch (err) {
    console.error('Test failed:', err.message);
  }
})();
