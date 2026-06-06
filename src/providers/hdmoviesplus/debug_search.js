import provider from './index.js';
import { fetchHTML } from '../common.js';

const url = 'https://hdmoviesrack.com/index.php?do=search&story=tumbbad';
const html = await fetchHTML(url);
console.log('HTML length:', html.length);
// Save to file for inspection
import fs from 'fs';
fs.writeFileSync('search_result.html', html);
console.log('Saved to search_result.html');
