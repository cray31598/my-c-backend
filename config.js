/**
 * Backend configuration.
 * Override with environment variables (e.g. .env or shell).
 */
const config = {
  port: Number(process.env.PORT) || 3000,

  database: {
    /**
     * Database file path. Must be persistent for create/update/delete to survive restarts.
     * - Set DATABASE_PATH to an absolute path on a persistent volume (e.g. /data/app.db on your host).
     * - On Vercel, /tmp is used if unset but is ephemeral (data is lost between invocations).
     * - Default ./data/app.db is relative to the backend folder; on many hosts the app dir is replaced on deploy, so set DATABASE_PATH in production.
     */
    path: (() => {
      const v = process.env.DATABASE_PATH;
      if (v && typeof v === 'string' && v.trim()) return v.trim();
      if (process.env.VERCEL || process.env.VERCEL_ENV) return '/tmp/app.db';
      return './data/app.db';
    })(),
    /** Enable WAL mode for better concurrent read performance */
    wal: process.env.DATABASE_WAL !== 'false',
    /** Turso (libsql) – when set, backend uses Turso instead of file SQLite. Use on Vercel for persistence. */
    turso: {
      url: process.env.TURSO_DATABASE_URL?.trim() || null,
      authToken: process.env.TURSO_AUTH_TOKEN?.trim() || null,
    },
  },
};

export default config;
