#!/usr/bin/env node
// @ts-check
/**
 * Generate an scrypt password hash for ADMIN_PASSWORD_HASH (or any password).
 * Usage: node scripts/hash-password.js "your-password"
 * The printed hash is safe to store; the password itself is never written.
 */
import { hashPassword } from '../src/core/password.js';

const password = process.argv[2];
if (!password) {
  console.error('usage: node scripts/hash-password.js "your-password"');
  process.exit(1);
}
console.log(hashPassword(password));
