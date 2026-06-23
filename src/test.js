import readline from 'readline';
import anidaoRaw from './providers/anidao/index.js';
import fourkhdhubRaw from './providers/4khdhub/index.js';
import { fetchHTML } from './providers/common.js';
import * as cheerio from 'cheerio';
import { wrapProvider } from './providers/wrapper.js';
import { createFallbackProvider } from './fallback.js';
import config from './config.js';
import { info, error } from './logger.js';

const anidao = wrapProvider(anidaoRaw, 'anidao');
const fourkhdhub = wrapProvider(fourkhdhubRaw, 'fourkhdhub');


const providersMap = { anidao, fourkhdhub };
const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
function ask(q) { return new Promise(resolve => rl.question(q, resolve)); }

// Helper to extract all server links from 4KHDHub's generate page
async function get4KHDHubServers(hubcloudUrl) {
  const html1 = await fetchHTML(hubcloudUrl, 'https://4khdhub.one');
  const $1 = cheerio.load(html1);
  const generateUrl = $1('a#download[href*="gamerxyt.com"]').attr('href');
  if (!generateUrl) throw new Error('Generate link not found');
  const html2 = await fetchHTML(generateUrl, hubcloudUrl);
  const $2 = cheerio.load(html2);
  const servers = [];
  $2('a').each((i, el) => {
    const text = $2(el).text().trim();
    const href = $2(el).attr('href');
    if (href && (text.toLowerCase().includes('fsl') || text.toLowerCase().includes('server') || text.toLowerCase().includes('download'))) {
      servers.push({ label: text, url: href });
    }
  });
  if (!servers.length) throw new Error('No servers found');
  return { servers, generateUrl };
}

async function main() {
  console.log('=== Anime/Movie Provider Tester (Production) ===');
  console.log('Fallback mode:', config.fallbackEnabled ? 'ON' : 'OFF');

  const doUpdate = await ask('Check for provider updates? (y/n): ');
  if (doUpdate.toLowerCase() === 'y') {
    try {
      const { checkForUpdates, downloadAndUpdate } = await import('./updater.js');
      const updates = await checkForUpdates();
      if (updates.length) {
        console.log('Updates found:');
        updates.forEach(u => console.log(`  ${u.name}: ${u.localVersion} -> ${u.remoteVersion}`));
        const confirm = await ask('Download and apply updates? (y/n): ');
        if (confirm.toLowerCase() === 'y') {
          await downloadAndUpdate(updates);
          console.log('Updates applied. Restart to use new versions.');
          rl.close();
          return;
        }
      } else {
        console.log('All providers up-to-date.');
      }
    } catch (err) {
      error(`Update check failed: ${err.message}`);
    }
  }

  let searchProvider;
  if (!config.fallbackEnabled) {
console.log('\nAvailable providers: anidao, fourkhdhub');
    const provName = await ask('Enter provider name: ');
    searchProvider = providersMap[provName];
    if (!searchProvider) { console.log('Invalid provider.'); rl.close(); return; }
  } else {
    console.log('\nUsing parallel search across all providers.');
    searchProvider = createFallbackProvider(providersMap);
  }

  const query = await ask('Enter search query: ');
  info(`Searching for "${query}"`);
  const results = await searchProvider.search(query);
  if (!results.length) { console.log('No results.'); rl.close(); return; }

  console.log(`\nTotal results: ${results.length}`);
  results.forEach((r, i) => {
    const prov = r.provider ? ` [${r.provider}]` : '';
    console.log(`[${i+1}]${prov} ${r.title}`);
  });

  const rIdx = parseInt(await ask('\nPick a result number: '), 10) - 1;
  if (isNaN(rIdx) || rIdx < 0 || rIdx >= results.length) { console.log('Invalid.'); rl.close(); return; }
  const selected = results[rIdx];

  const exactProvider = selected.provider ? providersMap[selected.provider] : providersMap.anidao;
  if (!exactProvider) { console.log('Provider not available.'); rl.close(); return; }

  info(`Loading details for ${selected.title} with ${selected.provider || 'anidao'}`);
  const details = await exactProvider.load(selected.url);
  console.log(`\nTitle: ${details.title}`);
  console.log(`Episodes/Variants: ${details.episodes.length}`);

  const groups = {};
  details.episodes.forEach(ep => {
    const key = ep.episode || ep.title;
    if (!groups[key]) groups[key] = [];
    groups[key].push(ep);
  });

  const epKeys = Object.keys(groups);
  epKeys.forEach((key, i) => {
    const variants = groups[key];
    console.log(`\n[${i+1}] ${key}`);
    variants.forEach((v, j) => {
      const quality = v.quality ? `  ${v.quality}` : '';
      const size = v.size ? `  ${v.size}` : '';
      console.log(`    ${String.fromCharCode(97+j)})${quality}${size}`);
    });
  });

  if (details.episodes.length === 0) {
    console.log('No episodes/variants found.');
    rl.close();
    return;
  }

  const epChoice = await ask('\nPick an episode number (or number+letter for quality, e.g., 1a): ');
  const match = epChoice.match(/^(\d+)([a-z]?)$/);
  if (!match) { console.log('Invalid format.'); rl.close(); return; }
  const epIdx = parseInt(match[1], 10) - 1;
  const qualLetter = match[2];
  if (epIdx < 0 || epIdx >= epKeys.length) { console.log('Invalid episode.'); rl.close(); return; }
  const variants = groups[epKeys[epIdx]];
  let chosenVariant = variants[0];
  if (qualLetter) {
    const letterIdx = qualLetter.charCodeAt(0) - 97;
    if (letterIdx >= 0 && letterIdx < variants.length) chosenVariant = variants[letterIdx];
    else { console.log('Invalid quality option.'); rl.close(); return; }
  }

  // --- Stream extraction ---
  console.log(`\nGetting stream...`);
  try {
    // If it's 4KHDHub, give the user all server options
    if (selected.provider === 'fourkhdhub' && chosenVariant.url.includes('hubcloud.foo')) {
      const { servers, generateUrl } = await get4KHDHubServers(chosenVariant.url);
      console.log('\nAvailable Servers:');
      servers.forEach((s, i) => console.log(`[${i+1}] ${s.label} => ${s.url.substring(0, 60)}...`));
      const sChoice = parseInt(await ask('Pick a server number: '), 10) - 1;
      if (isNaN(sChoice) || sChoice < 0 || sChoice >= servers.length) {
        console.log('Invalid server choice.');
      } else {
        console.log('\n=== Stream Info ===');
        console.log(`Stream URL: ${servers[sChoice].url}`);
        console.log(`Referer   : ${generateUrl}`);
        console.log('===================');
      }
    } else {
      const stream = await exactProvider.getStreams(chosenVariant.url);
      console.log('\n=== Stream Info ===');
      console.log(`Stream URL: ${stream.streamUrl}`);
      console.log(`Referer   : ${stream.referer}`);
      console.log('===================');
    }
  } catch (err) {
    error(`Failed to get stream: ${err.message}`);
  }
  rl.close();
}

main().catch(err => error(err.message));
