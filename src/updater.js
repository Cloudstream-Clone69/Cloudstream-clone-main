import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
// Project root is one level up (since updater.js lives in src/)
const PROJECT_ROOT = path.resolve(__dirname, '..');

const REPO_RAW = 'https://raw.githubusercontent.com/Cloudstream-Clone69/Cloudstream-clone/main';

async function fetchJSON(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${res.statusText}`);
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch (e) {
    throw new Error(`Invalid JSON: ${text.substring(0, 100)}`);
  }
}

export async function checkForUpdates() {
  console.log('Checking for provider updates...');
  const manifestUrl = `${REPO_RAW}/providers.json`;
  const manifest = await fetchJSON(manifestUrl);
  const updates = [];

  for (const [name, remoteVersion] of Object.entries(manifest.providers)) {
    const localVersionFile = path.join(PROJECT_ROOT, 'src', 'providers', name, 'version.json');
    try {
      const localData = JSON.parse(await fs.readFile(localVersionFile, 'utf8'));
      if (localData.version !== remoteVersion) {
        updates.push({ name, remoteVersion, localVersion: localData.version });
      }
    } catch {
      // provider not installed, skip
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
      const res = await fetch(`${REPO_RAW}/src/providers/common.js`);
      if (!res.ok) throw new Error(`Failed to download common.js`);
      const content = await res.text();
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
        const res = await fetch(`${REPO_RAW}/src/providers/${provider}/${file}`);
        if (!res.ok) throw new Error(`Failed to download ${file} for ${provider}`);
        const content = await res.text();
        const targetPath = path.join(PROJECT_ROOT, 'src', 'providers', provider, file);
        await fs.writeFile(targetPath, content);
      }
    }
    console.log(`Updated ${update.name} to ${update.remoteVersion}`);
  }
}
