# Step-by-step: Use Turso as your backend database

Use this when you want **persistent** data on Vercel (or any host). Your app already supports Turso; you only need to create a database, get a token, and set environment variables.

---

## 1. Create a Turso account (if you don’t have one)

1. Go to [https://turso.tech](https://turso.tech).
2. Sign up (e.g. with GitHub or email).
3. You’re on the **Free** tier by default (no card required).

---

## 2. Create a database

1. In the Turso dashboard, click **“Create Database”**.
2. Choose a **name** (e.g. `master` or `criteriacorp-db`).
3. Pick a **region** close to your users (e.g. `aws-us-east-2`).
4. Click **Create**.
5. Open the new database and go to the **Overview** tab.

You already have a database named **master**; you can use that.

---

## 3. Get the database URL

1. In the database **Overview** page, find the **Connect** section.
2. Copy the **Database URL**, e.g.:
   ```text
   libsql://master-cray31598.aws-us-east-2.turso.io
   ```
3. Keep this for the next step (env var `TURSO_DATABASE_URL`).

---

## 4. Create an auth token

1. In the same **Connect** section, click **“+ Create Token”**.
2. Give it a name (e.g. `backend` or `vercel`).
3. Choose **Full access** (read + write).
4. (Optional) Set an expiration or leave it as “Never”.
5. Click **Create** and **copy the token** (you won’t see it again).
6. This value is your **`TURSO_AUTH_TOKEN`**.

---

## 5. Set environment variables

### Local development

1. In the **backend** folder, copy the example env file:
   ```bash
   cp .env.example .env
   ```
2. Edit **`.env`** and set:
   ```env
   TURSO_DATABASE_URL=libsql://master-cray31598.aws-us-east-2.turso.io
   TURSO_AUTH_TOKEN=eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJhIjoicnciLCJpYXQiOjE3NzI1NTIwNzcsImlkIjoiMDE5Y2I0NGQtYzkwMS03NTNlLWJkZjMtMjg5NWNjOTZmOTEwIiwicmlkIjoiMjQ5NWRhOWItODhiNS00OTdhLWI3NTItNGU4NTQxOWRjNDNjIn0.dNN4aactW5gvSmAky_DMQJEV-myJMhs0L1rIiXAXWFv33_Lc34dmAHEtnDhsH2_PQUOkCgTNrbZewzZr7H5dBA
   ```
3. Restart the backend (`npm run dev` or `node index.js`).
4. You should see in the logs: `[db] Using Turso: libsql://...`

### Vercel (production)

1. Open your project on [vercel.com](https://vercel.com) → **Settings** → **Environment Variables**.
2. Add:
   - **Name:** `TURSO_DATABASE_URL`  
     **Value:** your Database URL (e.g. `libsql://master-cray31598.aws-us-east-2.turso.io`).
3. Add:
   - **Name:** `TURSO_AUTH_TOKEN`  
     **Value:** the token you created in step 4.
4. Redeploy the project so the new variables are used.

---

## 6. Run the app

- **Local:** From the backend folder run `npm run dev` or `node index.js`. If Turso env vars are set, the app uses Turso; otherwise it uses the local file `./data/app.db`.
- **Vercel:** After saving the env vars and redeploying, API routes will use Turso and data will persist across deploys and cold starts.

---

## Summary

| Step | What you do |
|------|------------------|
| 1 | Sign up at turso.tech |
| 2 | Create a database (or use existing “master”) |
| 3 | Copy **Database URL** from Connect section |
| 4 | Click “+ Create Token”, copy the token |
| 5 | Set `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` (locally in `.env`, on Vercel in project Settings) |
| 6 | Restart / redeploy and use the app |

No code changes are required: the backend automatically uses Turso when both `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` are set.
