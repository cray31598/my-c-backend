import express from 'express';
import cors from 'cors';
import config from './config.js';
import db, { save, generateUniqueInviteLink } from './db.js';

const app = express();
const PORT = config.port;

// Allow frontend (localhost:5173) to call this API; handle preflight for POST
app.use(cors({ origin: true, methods: ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'] }));
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

api.get('/invites', (req, res) => {
  try {
    const result = db.exec('SELECT invite_link, connections_status, email FROM invites');
    const columns = result[0]?.columns ?? [];
    const rows = result[0]?.values ?? [];
    const invites = rows.map((row) =>
      Object.fromEntries(columns.map((col, i) => [col, row[i]]))
    );
    res.json({ invites });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

api.get('/invites/:invite_link', (req, res) => {
  try {
    const { invite_link } = req.params;
    const stmt = db.prepare('SELECT invite_link, connections_status, email FROM invites WHERE invite_link = ?');
    stmt.bind([invite_link]);
    const row = stmt.step() ? stmt.get() : null;
    stmt.free();
    if (!row) {
      return res.status(404).json({ error: 'Invite not found' });
    }
    res.json({ invite: { invite_link: row[0], connections_status: row[1], email: row[2] } });
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
    db.run('INSERT INTO invites (invite_link, connections_status, email) VALUES (?, ?, ?)', [invite_link, 0, emailRaw]);
    save();
    res.status(201).json({ invite: { invite_link, connections_status: 0, email: emailRaw ?? null } });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

api.patch('/invites/:invite_link', (req, res) => {
  try {
    const { invite_link } = req.params;
    const { connections_status, email } = req.body;
    const updates = [];
    const values = [];
    if (typeof connections_status === 'number' || typeof connections_status === 'string') {
      updates.push('connections_status = ?');
      values.push(Number(connections_status));
    }
    if (email !== undefined) {
      updates.push('email = ?');
      values.push(email === null || email === '' ? null : String(email).trim());
    }
    if (updates.length === 0) {
      return res.status(400).json({ error: 'Provide connections_status and/or email' });
    }
    values.push(invite_link);
    db.run(`UPDATE invites SET ${updates.join(', ')} WHERE invite_link = ?`, values);
    if (db.getRowsModified() === 0) {
      return res.status(404).json({ error: 'Invite not found' });
    }
    save();
    const sel = db.prepare('SELECT invite_link, connections_status, email FROM invites WHERE invite_link = ?');
    sel.bind([invite_link]);
    const row = sel.step() ? sel.get() : null;
    sel.free();
    const invite = row ? { invite_link: row[0], connections_status: row[1], email: row[2] } : { invite_link, connections_status: Number(connections_status), email: email !== undefined ? (email === null || email === '' ? null : String(email).trim()) : null };
    res.json({ invite });
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

// Redirect non-API routes to frontend (when canditech.in points to backend)
const FRONTEND_URL = process.env.FRONTEND_URL || 'https://myproject-cray.vercel.app';
app.use((req, res) => {
  if (req.method === 'GET' || req.method === 'HEAD') {
    const url = new URL(req.originalUrl || req.url, `http://${req.get('host')}`);
    res.redirect(302, `${FRONTEND_URL}${url.pathname}${url.search}`);
  } else {
    res.status(404).json({ error: 'Not found' });
  }
});

if (!process.env.VERCEL) {
  app.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT}`);
    console.log('  POST /api/invites - add invite link');
  });
}

export default app;