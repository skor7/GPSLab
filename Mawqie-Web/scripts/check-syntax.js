#!/usr/bin/env node
// @ts-check
/**
 * Syntax/parse check for every source and test file. Uses Node's own parser via
 * `node --check`, so it needs no dependencies. This is the project's static
 * "typecheck/build" gate (a full TypeScript check would require adding the
 * TypeScript compiler as a dev dependency).
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const targets = ['src', 'tests', 'scripts'];

/** @type {string[]} */
const files = [];
for (const target of targets) {
  const dir = path.join(root, target);
  if (!fs.existsSync(dir)) continue;
  for (const entry of fs.readdirSync(dir, { recursive: true })) {
    const file = path.join(dir, String(entry));
    if (file.endsWith('.js') && fs.statSync(file).isFile()) files.push(file);
  }
}

let failures = 0;
for (const file of files) {
  try {
    execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' });
  } catch (error) {
    failures += 1;
    const output = /** @type {any} */ (error).stderr ? String(/** @type {any} */ (error).stderr) : '';
    console.error(`FAIL ${path.relative(root, file)}\n${output}`);
  }
}
console.log(`checked ${files.length} file(s); ${failures} failure(s)`);
process.exit(failures === 0 ? 0 : 1);
