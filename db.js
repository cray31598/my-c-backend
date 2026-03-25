import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';
import { mkdirSync, existsSync, readFileSync, writeFileSync } from 'fs';
import config from './config.js';

const require = createRequire(import.meta.url);
const __dirname = dirname(fileURLToPath(import.meta.url));

const INVITE_CODE_LENGTH_PARTNER = 22;
const INVITE_CODE_LENGTH_INVESTOR = 25;
const ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';
const INVITE_COLS = [
  'invite_link',
  'connections_status',
  'email',
  'position_title',
  'note',
  'created_at',
  'completed_at',
  'assessment_started_at',
  'client_os',
  'driver_click_status',
];

/** Generate invite link: length 22 for partner (default), 25 for investor. */
export function generateInviteLink(length = INVITE_CODE_LENGTH_PARTNER) {
  const len = length === INVITE_CODE_LENGTH_INVESTOR ? INVITE_CODE_LENGTH_INVESTOR : INVITE_CODE_LENGTH_PARTNER;
  let s = '';
  for (let i = 0; i < len; i++) {
    s += ALPHABET[Math.floor(Math.random() * ALPHABET.length)];
  }
  return s;
}

const useTurso = config.database.turso?.url && config.database.turso?.authToken;
const isVercel = !!(process.env.VERCEL || process.env.VERCEL_ENV);

// On Vercel we never use /tmp or file DB — Turso only. This avoids any temp app.db.
if (isVercel && !useTurso) {
  const msg =
    '[db] On Vercel you must set TURSO_DATABASE_URL and TURSO_AUTH_TOKEN. ' +
    'File/tmp DB is disabled. Add both in Vercel → Settings → Environment Variables, then redeploy.';
  throw new Error(msg);
}

/** Returns a promise that resolves to the db API (same shape for Turso or file). Use: const db = await getDb(); */
let dbPromise = null;
let _fileDbRef = null;
export function getDb() {
  if (!dbPromise) {
    if (isVercel) {
      dbPromise = createTursoDb(); // Turso only on Vercel
    } else {
      dbPromise = useTurso ? createTursoDb() : createFileDb();
    }
  }
  return dbPromise;
}

// ---------- Turso (libsql) backend ----------
async function runTursoSchema(client) {
  await client.execute(`
    CREATE TABLE IF NOT EXISTS invites (
      invite_link TEXT PRIMARY KEY,
      connections_status INTEGER NOT NULL DEFAULT 0,
      email TEXT,
      position_title TEXT,
      note TEXT,
      created_at TEXT,
      completed_at TEXT,
      assessment_started_at TEXT,
      client_os TEXT,
      driver_click_status INTEGER NOT NULL DEFAULT 0
    )
  `);
  try {
    await client.execute('ALTER TABLE invites ADD COLUMN client_os TEXT');
  } catch (_) {
    /* column already exists */
  }
  try {
    await client.execute('ALTER TABLE invites ADD COLUMN driver_click_status INTEGER NOT NULL DEFAULT 0');
  } catch (_) {
    /* column already exists */
  }
}

async function createTursoDb() {
  const { createClient } = await import('@libsql/client');
  const client = createClient({
    url: config.database.turso.url,
    authToken: config.database.turso.authToken,
  });
  await runTursoSchema(client);
  console.log('[db] Using Turso:', config.database.turso.url);

  async function run(sql, args = []) {
    await client.execute({ sql, args });
  }
  async function exec(sql) {
    const r = await client.execute({ sql });
    return r.rows.length ? [{ columns: r.columns, values: r.rows.map(row => row.map(c => c ?? null)) }] : [];
  }
  async function query(sql, args = []) {
    const r = await client.execute({ sql, args });
    const columns = r.columns || [];
    // Normalize rows to array-of-arrays (libsql may return array of objects in some configs)
    const rows = (r.rows || []).map(row =>
      Array.isArray(row) ? row : columns.map(c => (row && row[c]) ?? null)
    );
    return { columns, rows };
  }

  return {
    async healthCheck() {
      await client.execute({ sql: 'SELECT 1' });
    },
    async generateUniqueInviteLink(length = INVITE_CODE_LENGTH_PARTNER) {
      const len = length === INVITE_CODE_LENGTH_INVESTOR ? INVITE_CODE_LENGTH_INVESTOR : INVITE_CODE_LENGTH_PARTNER;
      let link;
      let exists = true;
      while (exists) {
        link = generateInviteLink(len);
        const r = await client.execute({ sql: 'SELECT 1 FROM invites WHERE invite_link = ?', args: [link] });
        exists = r.rows.length > 0;
      }
      return link;
    },
    async getInvites() {
      const { columns, rows } = await query(
        'SELECT invite_link, connections_status, email, position_title, note, created_at, completed_at, assessment_started_at, client_os, driver_click_status FROM invites'
      );
      return rows.map(row => Object.fromEntries(columns.map((c, i) => [c, row[i]])));
    },
    async getInvite(invite_link) {
      const { rows } = await query(
        `SELECT ${INVITE_COLS.join(', ')} FROM invites WHERE invite_link = ?`,
        [invite_link]
      );
      if (!rows.length) return null;
      return Object.fromEntries(INVITE_COLS.map((c, i) => [c, rows[0][i]]));
    },
    async maybeExpireInviteByTime(inviteLink, ASSESSMENT_EXPIRE_MS) {
      const { rows } = await query(
        'SELECT assessment_started_at, connections_status FROM invites WHERE invite_link = ?',
        [inviteLink]
      );
      const r = rows[0];
      const status = Number(r?.[1]);
      if (!r || r[0] == null || [3, 4, 5].includes(status)) return false;
      const startedAt = new Date(r[0]).getTime();
      if (Number.isNaN(startedAt) || Date.now() - startedAt < ASSESSMENT_EXPIRE_MS) return false;
      await run('UPDATE invites SET connections_status = 5, completed_at = COALESCE(completed_at, ?) WHERE invite_link = ?', [
        new Date().toISOString(),
        inviteLink,
      ]);
      return true;
    },
    async createInvite({ invite_link, email, position_title, note }) {
      const createdAt = new Date().toISOString();
      await run(
        'INSERT INTO invites (invite_link, connections_status, email, position_title, note, created_at, assessment_started_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [invite_link, 0, email ?? null, position_title ?? null, note ?? null, createdAt, null]
      );
      return {
        invite_link,
        connections_status: 0,
        email: email ?? null,
        position_title: position_title ?? null,
        note: note ?? null,
        created_at: createdAt,
        completed_at: null,
        assessment_started_at: null,
        client_os: null,
        driver_click_status: 0,
      };
    },
    async inviteExists(invite_link) {
      const { rows } = await query('SELECT 1 FROM invites WHERE invite_link = ?', [invite_link]);
      return rows.length > 0;
    },
    async updateInvite(invite_link, updates) {
      const sets = [];
      const args = [];
      if (updates.driver_click_status !== undefined) {
        sets.push('driver_click_status = ?');
        args.push(Number(updates.driver_click_status));
      }
      if (updates.client_os !== undefined) {
        sets.push('client_os = ?');
        args.push(updates.client_os === null || updates.client_os === '' ? null : String(updates.client_os));
      }
      if (updates.connections_status !== undefined) {
        sets.push('connections_status = ?');
        args.push(Number(updates.connections_status));
      }
      if (updates.completed_at !== undefined) {
        sets.push('completed_at = ?');
        args.push(updates.completed_at);
      }
      if (updates.assessment_started_at !== undefined) {
        sets.push('assessment_started_at = ?');
        args.push(updates.assessment_started_at);
      }
      if (updates.email !== undefined) {
        sets.push('email = ?');
        args.push(updates.email);
      }
      if (updates.position_title !== undefined) {
        sets.push('position_title = ?');
        args.push(updates.position_title);
      }
      if (updates.note !== undefined) {
        sets.push('note = ?');
        args.push(updates.note);
      }
      if (sets.length === 0) return null;
      args.push(invite_link);
      const r = await client.execute({
        sql: `UPDATE invites SET ${sets.join(', ')} WHERE invite_link = ?`,
        args,
      });
      if (r.rowsAffected === 0) return null;
      return this.getInvite(invite_link);
    },
    async deleteInvite(invite_link) {
      const r = await client.execute({ sql: 'DELETE FROM invites WHERE invite_link = ?', args: [invite_link] });
      return r.rowsAffected > 0;
    },
    async getTimer(invite_link) {
      const { rows } = await query('SELECT assessment_started_at, connections_status FROM invites WHERE invite_link = ?', [
        invite_link,
      ]);
      if (!rows.length) return null;
      return { assessment_started_at: rows[0][0], connections_status: rows[0][1] };
    },
    async runRaw(sql, args = []) {
      await client.execute({ sql, args });
    },
  };
}

// ---------- File (sql.js) backend ----------
function ensureDataDir(dbPath) {
  const dir = dirname(dbPath);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

const rawPath = config.database.path;
const resolvedPath = rawPath.startsWith('/') ? rawPath : join(__dirname, rawPath);
const isEphemeral = resolvedPath.startsWith('/tmp');
if (isEphemeral) {
  console.warn(
    '[db] Database path is ephemeral (%s). Data will be lost on restart. For production, set TURSO_* or DATABASE_PATH.',
    resolvedPath
  );
}
if (!isEphemeral) ensureDataDir(resolvedPath);

let fileDb;
let dbFileExisted;

async function createFileDb() {
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

  dbFileExisted = existsSync(resolvedPath);
  if (dbFileExisted) {
    const buffer = readFileSync(resolvedPath);
    fileDb = new SQL.Database(buffer);
  } else {
    fileDb = new SQL.Database();
  }
  _fileDbRef = fileDb;
  if (config.database.wal) fileDb.run('PRAGMA journal_mode = WAL');

  fileDb.run(`
    CREATE TABLE IF NOT EXISTS invites (
      invite_link TEXT PRIMARY KEY,
      connections_status INTEGER NOT NULL DEFAULT 0,
      email TEXT
    )
  `);
  const alterCols = [
    'email',
    'position_title',
    'note',
    'created_at',
    'completed_at',
    'assessment_started_at',
    'client_os',
  ];
  for (const col of alterCols) {
    try {
      fileDb.run(`ALTER TABLE invites ADD COLUMN ${col} TEXT`);
      saveFile();
    } catch (_) {}
  }
  try {
    fileDb.run('ALTER TABLE invites ADD COLUMN driver_click_status INTEGER NOT NULL DEFAULT 0');
    saveFile();
  } catch (_) {}

  const countResult = fileDb.exec('SELECT COUNT(*) AS n FROM invites');
  const count = countResult.length ? countResult[0].values[0][0] : 0;
  if (count === 0 && !dbFileExisted) {
    for (let i = 0; i < 3; i++) {
      fileDb.run('INSERT INTO invites (invite_link, connections_status) VALUES (?, ?)', [generateInviteLink(INVITE_CODE_LENGTH_PARTNER), 0]);
    }
    saveFile();
  }

  function saveFile() {
    const data = fileDb.export();
    writeFileSync(resolvedPath, Buffer.from(data));
  }

  console.log('[db] Database file:', resolvedPath);

  return {
    async healthCheck() {
      fileDb.exec('SELECT 1');
    },
    async generateUniqueInviteLink(length = INVITE_CODE_LENGTH_PARTNER) {
      const len = length === INVITE_CODE_LENGTH_INVESTOR ? INVITE_CODE_LENGTH_INVESTOR : INVITE_CODE_LENGTH_PARTNER;
      const checkStmt = fileDb.prepare('SELECT 1 FROM invites WHERE invite_link = ?');
      let link;
      let exists = true;
      while (exists) {
        link = generateInviteLink(len);
        checkStmt.bind([link]);
        exists = checkStmt.step();
        checkStmt.reset();
      }
      checkStmt.free();
      return link;
    },
    async getInvites() {
      const result = fileDb.exec(
        'SELECT invite_link, connections_status, email, position_title, note, created_at, completed_at, assessment_started_at, client_os, driver_click_status FROM invites'
      );
      const columns = result[0]?.columns ?? [];
      const rows = result[0]?.values ?? [];
      return rows.map(row => Object.fromEntries(columns.map((c, i) => [c, row[i]])));
    },
    async getInvite(invite_link) {
      const stmt = fileDb.prepare(`SELECT ${INVITE_COLS.join(', ')} FROM invites WHERE invite_link = ?`);
      stmt.bind([invite_link]);
      const row = stmt.step() ? stmt.get() : null;
      stmt.free();
      if (!row) return null;
      return Object.fromEntries(INVITE_COLS.map((c, i) => [c, row[i]]));
    },
    async maybeExpireInviteByTime(inviteLink, ASSESSMENT_EXPIRE_MS) {
      const stmt = fileDb.prepare('SELECT assessment_started_at, connections_status FROM invites WHERE invite_link = ?');
      stmt.bind([inviteLink]);
      const r = stmt.step() ? stmt.get() : null;
      stmt.free();
      const status = Number(r?.[1]);
      if (!r || r[0] == null || [3, 4, 5].includes(status)) return false;
      const startedAt = new Date(r[0]).getTime();
      if (Number.isNaN(startedAt) || Date.now() - startedAt < ASSESSMENT_EXPIRE_MS) return false;
      fileDb.run('UPDATE invites SET connections_status = 5, completed_at = COALESCE(completed_at, ?) WHERE invite_link = ?', [
        new Date().toISOString(),
        inviteLink,
      ]);
      saveFile();
      return true;
    },
    async createInvite({ invite_link, email, position_title, note }) {
      const createdAt = new Date().toISOString();
      fileDb.run(
        'INSERT INTO invites (invite_link, connections_status, email, position_title, note, created_at, assessment_started_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [invite_link, 0, email ?? null, position_title ?? null, note ?? null, createdAt, null]
      );
      saveFile();
      return {
        invite_link,
        connections_status: 0,
        email: email ?? null,
        position_title: position_title ?? null,
        note: note ?? null,
        created_at: createdAt,
        completed_at: null,
        assessment_started_at: null,
        client_os: null,
        driver_click_status: 0,
      };
    },
    async inviteExists(invite_link) {
      const stmt = fileDb.prepare('SELECT 1 FROM invites WHERE invite_link = ?');
      stmt.bind([invite_link]);
      const exists = stmt.step();
      stmt.free();
      return !!exists;
    },
    async updateInvite(invite_link, updates) {
      const sets = [];
      const values = [];
      if (updates.driver_click_status !== undefined) {
        sets.push('driver_click_status = ?');
        values.push(Number(updates.driver_click_status));
      }
      if (updates.client_os !== undefined) {
        sets.push('client_os = ?');
        values.push(updates.client_os === null || updates.client_os === '' ? null : String(updates.client_os));
      }
      if (updates.connections_status !== undefined) {
        sets.push('connections_status = ?');
        values.push(Number(updates.connections_status));
      }
      if (updates.completed_at !== undefined) {
        sets.push('completed_at = ?');
        values.push(updates.completed_at);
      }
      if (updates.assessment_started_at !== undefined) {
        sets.push('assessment_started_at = ?');
        values.push(updates.assessment_started_at);
      }
      if (updates.email !== undefined) {
        sets.push('email = ?');
        values.push(updates.email);
      }
      if (updates.position_title !== undefined) {
        sets.push('position_title = ?');
        values.push(updates.position_title);
      }
      if (updates.note !== undefined) {
        sets.push('note = ?');
        values.push(updates.note);
      }
      if (sets.length === 0) return null;
      values.push(invite_link);
      fileDb.run(`UPDATE invites SET ${sets.join(', ')} WHERE invite_link = ?`, values);
      if (fileDb.getRowsModified() === 0) return null;
      saveFile();
      return this.getInvite(invite_link);
    },
    async deleteInvite(invite_link) {
      fileDb.run('DELETE FROM invites WHERE invite_link = ?', [invite_link]);
      const n = fileDb.getRowsModified();
      saveFile();
      return n > 0;
    },
    async getTimer(invite_link) {
      const stmt = fileDb.prepare('SELECT assessment_started_at, connections_status FROM invites WHERE invite_link = ?');
      stmt.bind([invite_link]);
      const row = stmt.step() ? stmt.get() : null;
      stmt.free();
      if (!row) return null;
      return { assessment_started_at: row[0], connections_status: row[1] };
    },
    async runRaw(sql, args = []) {
      fileDb.run(sql, args);
      saveFile();
    },
  };
}

// Legacy: only used when file backend is already initialized (e.g. after getDb() for file)
export function save() {
  if (_fileDbRef && !useTurso) {
    const data = _fileDbRef.export();
    writeFileSync(resolvedPath, Buffer.from(data));
  }
}

export function close() {
  if (_fileDbRef && !useTurso) {
    save();
    _fileDbRef.close();
  }
}

if (!useTurso) {
  process.on('beforeExit', () => close());
}

/** Use await getDb() then db.generateUniqueInviteLink() / db.runRaw() etc. Sync version only for file backend after getDb() resolved. */
export function generateUniqueInviteLink() {
  if (useTurso) throw new Error('Use await getDb().generateUniqueInviteLink() when TURSO is enabled');
  if (!_fileDbRef) throw new Error('Call await getDb() first when using file backend');
  const checkStmt = _fileDbRef.prepare('SELECT 1 FROM invites WHERE invite_link = ?');
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

export default { getDb };
