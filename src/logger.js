import fs from 'fs';
import path from 'path';

const logFile = path.join(process.cwd(), 'app.log');

function timestamp() {
  return new Date().toISOString();
}

export function info(msg) {
  const line = `[${timestamp()}] INFO: ${msg}`;
  console.log(line);
  fs.appendFileSync(logFile, line + '\n');
}

export function warn(msg) {
  const line = `[${timestamp()}] WARN: ${msg}`;
  console.warn(line);
  fs.appendFileSync(logFile, line + '\n');
}

export function error(msg) {
  const line = `[${timestamp()}] ERROR: ${msg}`;
  console.error(line);
  fs.appendFileSync(logFile, line + '\n');
}
