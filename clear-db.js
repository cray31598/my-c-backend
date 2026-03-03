/**
 * Clear all data from the database while keeping table structure.
 * Usage: node clear-db.js
 * Works with both file SQLite and Turso.
 */
import { getDb } from './db.js';

const db = await getDb();
await db.runRaw('DELETE FROM invites');
console.log('[clear-db] All rows deleted from invites. Schema unchanged.');
process.exit(0);
