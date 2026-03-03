import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';
import { mkdirSync, existsSync, readFileSync, writeFileSync } from 'fs';
import config from './config.js';

const require = createRequire(import.meta.url);
const __dirname = dirname(fileURLToPath(import.meta.url));

function ensureDataDir(dbPath) {
  const dir = dirname(dbPath);
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
}

const rawPath = config.database.path;
const resolvedPath = rawPath.startsWith('/') ? rawPath : join(__dirname, rawPath);
if (!resolvedPath.startsWith('/tmp')) {
  ensureDataDir(resolvedPath);
}

const sqlJsModule = await import('sql.js');
const initSqlJs = sqlJsModule.default;
const SQL = await initSqlJs({
  locateFile: (file) => {
    try {
      return require.resolve(`sql.js/dist/${file}`);
    } catch {
      const local = join(__dirname, 'node_modules', 'sql.js', 'dist', file);
      if (existsSync(local)) return local;
      return `https://sql.js.org/dist/${file}`;
    }
  },
});

let db;
if (existsSync(resolvedPath)) {
  const buffer = readFileSync(resolvedPath);
  db = new SQL.Database(buffer);
} else {
  db = new SQL.Database();
}

if (config.database.wal) {
  db.run('PRAGMA journal_mode = WAL');
}

const INVITE_CODE_LENGTH = 22;
const ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';

export function generateInviteLink() {
  let s = '';
  for (let i = 0; i < INVITE_CODE_LENGTH; i++) {
    s += ALPHABET[Math.floor(Math.random() * ALPHABET.length)];
  }
  return s;
}

/** Generate a random invite link that does not exist in the database, then return it. */
export function generateUniqueInviteLink() {
  const checkStmt = db.prepare('SELECT 1 FROM invites WHERE invite_link = ?');
  let link;
  let exists = true;
  while (exists) {
    link = generateInviteLink();
    checkStmt.bind([link]);
    exists = checkStmt.step();
    checkStmt.reset();
  }
  checkStmt.free();
  return link;
}

db.run(`
  CREATE TABLE IF NOT EXISTS invites (
    invite_link TEXT PRIMARY KEY,
    connections_status INTEGER NOT NULL DEFAULT 0,
    email TEXT
  )
`);

// Add email column if table existed without it (existing DBs)
try {
  db.run('ALTER TABLE invites ADD COLUMN email TEXT');
  save();
} catch (_) {
  // Column already exists
}

// Add position_title column if missing (existing DBs)
try {
  db.run('ALTER TABLE invites ADD COLUMN position_title TEXT');
  save();
} catch (_) {
  // Column already exists
}

// Add note column if missing (existing DBs)
try {
  db.run('ALTER TABLE invites ADD COLUMN note TEXT');
  save();
} catch (_) {
  // Column already exists
}

// Add created_at and completed_at columns (ISO 8601 text)
try {
  db.run('ALTER TABLE invites ADD COLUMN created_at TEXT');
  save();
} catch (_) {}
try {
  db.run('ALTER TABLE invites ADD COLUMN completed_at TEXT');
  save();
} catch (_) {}

// When candidate starts assessment (connections_status set to 1)
try {
  db.run('ALTER TABLE invites ADD COLUMN assessment_started_at TEXT');
  save();
} catch (_) {}

const countResult = db.exec('SELECT COUNT(*) AS n FROM invites');
const count = countResult.length ? countResult[0].values[0][0] : 0;
if (count === 0) {
  for (let i = 0; i < 3; i++) {
    db.run('INSERT INTO invites (invite_link, connections_status) VALUES (?, ?)', [generateInviteLink(), 0]);
  }
  save();
}

export function save() {
  const data = db.export();
  writeFileSync(resolvedPath, Buffer.from(data));
}

export function close() {
  save();
  db.close();
}

process.on('beforeExit', () => close());

export default db;
