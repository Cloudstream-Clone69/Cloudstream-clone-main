import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';
import { fetchJSON, fetchHTML } from './providers/common.js';   // custom client with TLS fix

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const PROJECT_ROOT = path.resolve(__dirname, '..');

const REPO_RAW = 'https://raw.githubusercontent.com/Cloudstream-Clone69/Cloudstream-clone/v2';

async function fetchText(url) {
  return fetchHTML(url);   // uses the configured Axios client
}

export async function checkForUpdates() {
  console.log('Checking for provider updates...');
  const manifestUrl = `${REPO_RAW}/providers.json`;
  console.log('Fetching manifest:', manifestUrl);
  let manifest;
  try {
    manifest = await fetchJSON(manifestUrl);
  } catch (err) {
    console.error('Failed to fetch manifest:', err.message);
    return [];
  }
  console.log('Manifest loaded:', JSON.stringify(manifest));
  const updates = [];

  for (const [name, remoteVersion] of Object.entries(manifest.providers)) {
    const localVersionFile = path.join(PROJECT_ROOT, 'src', 'providers', name, 'version.json');
    try {
      const localData = JSON.parse(await fs.readFile(localVersionFile, 'utf8'));
      console.log(`[${name}] local: ${localData.version}, remote: ${remoteVersion}`);
      if (localData.version !== remoteVersion) {
        updates.push({ name, remoteVersion, localVersion: localData.version });
      }
    } catch {
      console.log(`[${name}] no local version file, skipping`);
    }
  }

  if (manifest.common) {
    const commonVersionFile = path.join(PROJECT_ROOT, 'src', 'providers', 'common.version.json');
    try {
      const commonLocal = JSON.parse(await fs.readFile(commonVersionFile, 'utf8'));
      if (commonLocal.version !== manifest.common) {
        updates.push({ name: 'common', remoteVersion: manifest.common, localVersion: commonLocal.version });
      }
    } catch {
      updates.push({ name: 'common', remoteVersion: manifest.common, localVersion: '0.0.0' });
    }
  }

  return updates;
}

export async function downloadAndUpdate(updates) {
  for (const update of updates) {
    if (update.name === 'common') {
      const content = await fetchText(`${REPO_RAW}/src/providers/common.js`);
      const targetPath = path.join(PROJECT_ROOT, 'src', 'providers', 'common.js');
      await fs.writeFile(targetPath, content);
      await fs.writeFile(
        path.join(PROJECT_ROOT, 'src', 'providers', 'common.version.json'),
        JSON.stringify({ version: update.remoteVersion })
      );
    } else {
      const provider = update.name;
      const files = ['index.js', 'selectors.js', 'version.json'];
      for (const file of files) {
        const content = await fetchText(`${REPO_RAW}/src/providers/${provider}/${file}`);
        const targetPath = path.join(PROJECT_ROOT, 'src', 'providers', provider, file);
        await fs.writeFile(targetPath, content);
      }
    }
    console.log(`Updated ${update.name} to ${update.remoteVersion}`);
  }
}
