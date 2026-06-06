import fs from 'fs';
import path from 'path';

const projectRoot = process.cwd();
const configPath = path.join(projectRoot, 'config.json');

let config = {
  cacheTTL: 300000,
  logLevel: 'info',
  fallbackEnabled: true,            // ← default ON
  fallbackOrder: ['anidao', 'hdmoviesplus', 'fourkhdhub']
};

try {
  if (fs.existsSync(configPath)) {
    const raw = fs.readFileSync(configPath, 'utf8');
    config = { ...config, ...JSON.parse(raw) };
    console.log(`Config loaded from ${configPath}`);
  } else {
    console.warn(`No config.json found, using defaults (fallback ON).`);
  }
} catch (e) {
  console.warn(`Error reading config.json, using defaults (fallback ON): ${e.message}`);
}

export default config;
