import * as https from 'https';
import * as zlib from 'zlib';

const ANDROID_UA = 'Dalvik/2.1.0 (Linux; U; Android 13; Pixel 7 Build/TQ3A.230805.001)';

function get(url, extraHeaders = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    https.get({
      hostname: u.hostname, path: u.pathname + u.search,
      headers: { 'User-Agent': ANDROID_UA, 'Accept': 'application/json, */*', 'Accept-Encoding': 'gzip', 'Referer': 'https://anidb.app/', ...extraHeaders }
    }, r => {
      const chunks = [];
      r.on('data', c => chunks.push(c));
      r.on('end', () => {
        let data = Buffer.concat(chunks);
        try { data = zlib.gunzipSync(data).toString(); } catch(e) { data = data.toString(); }
        resolve({ status: r.statusCode, ct: r.headers['content-type'] || '', data });
      });
    }).on('error', reject);
  });
}

// The episode ID we found: 55716 (sentenced to be a hero ep 1)
const EP_ID = 55716;

// Step 3: Get languages for episode
console.log('=== LANGUAGES API ===');
const langs = await get(`https://anidb.app/api/frontend/episode/${EP_ID}/languages`);
console.log('Status:', langs.status);
console.log('Languages:', langs.data);

const langsData = JSON.parse(langs.data);
console.log('\nLanguages parsed:', JSON.stringify(langsData, null, 2));

// Step 4: The embed_url should point to the HLS player
// embed_url + ?autoplay=1 → iframe src
// We need to fetch that iframe and extract the m3u8 URL
if (langsData.languages?.length > 0) {
  for (const lang of langsData.languages) {
    console.log(`\n=== EMBED PAGE for lang=${lang.code} ===`);
    console.log('embed_url:', lang.embed_url);
    
    // Try fetching the embed URL
    const embed = await get(lang.embed_url, { 'Referer': 'https://anidb.app/' });
    console.log('Status:', embed.status, 'Size:', embed.data.length);
    
    // Look for m3u8 in the response
    const m3u8Match = embed.data.match(/https:\/\/hls\.anidb\.app[^"'\s<>]+\.m3u8[^"'\s<>]*/);
    console.log('m3u8 match:', m3u8Match?.[0]);
    
    // Look for source tags
    const srcMatch = embed.data.match(/src=['"](https?:\/\/[^'"]+\.m3u8[^'"]*)['"]/);
    console.log('src match:', srcMatch?.[1]);
    
    // Print HTML snippet
    const streamIdx = embed.data.toLowerCase().indexOf('hls');
    if (streamIdx > 0) console.log('HLS area:', embed.data.slice(Math.max(0,streamIdx-200), streamIdx+300));
    else console.log('First 500:', embed.data.slice(0, 500));
  }
}
