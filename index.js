import express from 'express';
import cors from 'cors';
import config from './config.js';
import db, { save, generateUniqueInviteLink } from './db.js';

const app = express();
const PORT = config.port;

// CORS: allow frontend from local dev (any host:5173) and production
const allowedOrigins = [
  'https://canditech.in',
  'https://www.canditech.in',
  'http://localhost:5173',
  /^http:\/\/192\.168\.\d+\.\d+:5173$/,   // local network
  /^http:\/\/198\.18\.\d+\.\d+:5173$/,   // VPN/virtual network dev
  /^http:\/\/localhost(:\d+)?$/,
];
app.use(cors({
  origin: (origin, cb) => {
    if (!origin) return cb(null, true);
    if (allowedOrigins.some(o => typeof o === 'string' ? o === origin : o.test(origin))) return cb(null, true);
    return cb(null, true);
  },
  methods: ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization'],
}));
app.use(express.json());

app.get('/health', (req, res) => {
  try {
    db.exec('SELECT 1');
    res.json({ status: 'ok', database: 'connected' });
  } catch (err) {
    res.status(503).json({ status: 'error', database: 'disconnected' });
  }
});

// All /api routes on a router so POST is guaranteed to match
const api = express.Router();

api.get('/example', (req, res) => {
  res.json({ message: 'Hello from backend' });
});

api.get('/invites/generate', (req, res) => {
  try {
    const invite_link = generateUniqueInviteLink();
    res.json({ invite_link });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

const ASSESSMENT_EXPIRE_MS = 30 * 60 * 1000; // 30 minutes

function inviteRowToObject(columns, row) {
  return Object.fromEntries(columns.map((col, i) => [col, row[i]]));
}

/** connections_status: 0=not started, 1=started, 2=camera fixed, 3=completed. If started and 30 mins passed, set to 3. */
function maybeExpireInviteByTime(inviteLink) {
  const stmt = db.prepare('SELECT assessment_started_at, connections_status FROM invites WHERE invite_link = ?');
  stmt.bind([inviteLink]);
  const r = stmt.step() ? stmt.get() : null;
  stmt.free();
  if (!r || r[0] == null || Number(r[1]) === 3) return false;
  const startedAt = new Date(r[0]).getTime();
  if (Number.isNaN(startedAt) || Date.now() - startedAt < ASSESSMENT_EXPIRE_MS) return false;
  db.run('UPDATE invites SET connections_status = 3, completed_at = COALESCE(completed_at, ?) WHERE invite_link = ?', [new Date().toISOString(), inviteLink]);
  save();
  return true;
}

api.get('/invites', (req, res) => {
  try {
    const result = db.exec('SELECT invite_link, connections_status, email, position_title, note, created_at, completed_at, assessment_started_at FROM invites');
    const columns = result[0]?.columns ?? [];
    const rows = result[0]?.values ?? [];
    const invites = rows.map((row) => {
      const link = row[columns.indexOf('invite_link')];
      if (maybeExpireInviteByTime(link)) {
        const re = db.prepare('SELECT invite_link, connections_status, email, position_title, note, created_at, completed_at, assessment_started_at FROM invites WHERE invite_link = ?');
        re.bind([link]);
        const newRow = re.step() ? re.get() : null;
        re.free();
        return newRow ? inviteRowToObject(columns, newRow) : inviteRowToObject(columns, row);
      }
      return inviteRowToObject(columns, row);
    });
    res.json({ invites });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

api.get('/invites/:invite_link', (req, res) => {
  try {
    const { invite_link } = req.params;
    maybeExpireInviteByTime(invite_link);
    const stmt = db.prepare('SELECT invite_link, connections_status, email, position_title, note, created_at, completed_at, assessment_started_at FROM invites WHERE invite_link = ?');
    stmt.bind([invite_link]);
    const row = stmt.step() ? stmt.get() : null;
    stmt.free();
    if (!row) {
      return res.status(404).json({ error: 'Invite not found' });
    }
    res.json({
      invite: {
        invite_link: row[0], connections_status: row[1], email: row[2], position_title: row[3], note: row[4],
        created_at: row[5], completed_at: row[6], assessment_started_at: row[7] ?? null,
      },
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Real-time assessment timer: remaining seconds from assessment_started_at (frontend only displays this).
api.get('/invites/:invite_link/timer', (req, res) => {
  try {
    const { invite_link } = req.params;
    maybeExpireInviteByTime(invite_link);
    const stmt = db.prepare('SELECT assessment_started_at, connections_status FROM invites WHERE invite_link = ?');
    stmt.bind([invite_link]);
    const row = stmt.step() ? stmt.get() : null;
    stmt.free();
    if (!row) {
      return res.status(404).json({ error: 'Invite not found' });
    }
    const startedAt = row[0] ? new Date(row[0]).getTime() : null;
    const expired = Number(row[1]) === 3;
    const now = Date.now();
    let seconds_remaining = 0;
    if (!expired && startedAt && !Number.isNaN(startedAt)) {
      const elapsedMs = now - startedAt;
      seconds_remaining = Math.max(0, Math.floor((ASSESSMENT_EXPIRE_MS - elapsedMs) / 1000));
    }
    res.json({
      seconds_remaining,
      server_time: new Date(now).toISOString(),
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

api.post('/invites', (req, res) => {
  console.log('POST /api/invites received');
  try {
    let invite_link;
    if (req.body?.invite_link && typeof req.body.invite_link === 'string') {
      invite_link = req.body.invite_link.trim();
      if (!invite_link) {
        return res.status(400).json({ error: 'invite_link cannot be empty' });
      }
      const check = db.prepare('SELECT 1 FROM invites WHERE invite_link = ?');
      check.bind([invite_link]);
      const exists = check.step();
      check.free();
      if (exists) {
        return res.status(409).json({ error: 'Invite link already exists in DB' });
      }
    } else {
      invite_link = generateUniqueInviteLink();
    }
    const emailRaw = req.body?.email != null ? String(req.body.email).trim() || null : null;
    const positionTitleRaw = req.body?.position_title != null ? String(req.body.position_title).trim() || null : null;
    const noteRaw = req.body?.note != null ? String(req.body.note).trim() || null : null;
    const createdAt = new Date().toISOString();
    db.run('INSERT INTO invites (invite_link, connections_status, email, position_title, note, created_at, assessment_started_at) VALUES (?, ?, ?, ?, ?, ?, ?)', [invite_link, 0, emailRaw, positionTitleRaw, noteRaw, createdAt, null]);
    save();
    res.status(201).json({
      invite: { invite_link, connections_status: 0, email: emailRaw ?? null, position_title: positionTitleRaw ?? null, note: noteRaw ?? null, created_at: createdAt, completed_at: null, assessment_started_at: null },
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

api.patch('/invites/:invite_link', (req, res) => {
  try {
    const { invite_link } = req.params;
    const { connections_status, email, position_title, note, assessment_started_at } = req.body;
    const updates = [];
    const values = [];
    if (typeof connections_status === 'number' || typeof connections_status === 'string') {
      updates.push('connections_status = ?');
      values.push(Number(connections_status));
      if (Number(connections_status) === 3) {
        updates.push('completed_at = COALESCE(completed_at, ?)');
        values.push(new Date().toISOString());
      }
      // When starting assessment (connections_status = 1), set assessment_started_at to now if not provided
      if (Number(connections_status) === 1 && assessment_started_at === undefined) {
        updates.push('assessment_started_at = ?');
        values.push(new Date().toISOString());
      }
    }
    if (email !== undefined) {
      updates.push('email = ?');
      values.push(email === null || email === '' ? null : String(email).trim());
    }
    if (position_title !== undefined) {
      updates.push('position_title = ?');
      values.push(position_title === null || position_title === '' ? null : String(position_title).trim());
    }
    if (note !== undefined) {
      updates.push('note = ?');
      values.push(note === null || note === '' ? null : String(note).trim());
    }
    if (assessment_started_at !== undefined) {
      updates.push('assessment_started_at = ?');
      values.push(assessment_started_at === null || assessment_started_at === '' ? null : String(assessment_started_at).trim());
    }
    if (updates.length === 0) {
      return res.status(400).json({ error: 'Provide at least one field to update' });
    }
    values.push(invite_link);
    db.run(`UPDATE invites SET ${updates.join(', ')} WHERE invite_link = ?`, values);
    if (db.getRowsModified() === 0) {
      return res.status(404).json({ error: 'Invite not found' });
    }
    save();
    const cols = ['invite_link', 'connections_status', 'email', 'position_title', 'note', 'created_at', 'completed_at', 'assessment_started_at'];
    const sel = db.prepare(`SELECT ${cols.join(', ')} FROM invites WHERE invite_link = ?`);
    sel.bind([invite_link]);
    const row = sel.step() ? sel.get() : null;
    sel.free();
    const invite = row ? Object.fromEntries(cols.map((c, i) => [c, row[i]])) : null;
    res.json({ invite: invite || { invite_link, ...req.body } });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

api.delete('/invites/:invite_link', (req, res) => {
  try {
    const { invite_link } = req.params;
    db.run('DELETE FROM invites WHERE invite_link = ?', [invite_link]);
    if (db.getRowsModified() === 0) {
      return res.status(404).json({ error: 'Invite not found' });
    }
    save();
    res.status(204).send();
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.use('/api', api);

if (!process.env.VERCEL) {
  app.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT}`);
    console.log('  POST /api/invites - add invite link');
  });
}

export default app;