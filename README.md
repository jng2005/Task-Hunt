# Task Hunt

Campus scavenger-hunt game for the Winter Retreat 2027 (Zephyr Point, Lake Tahoe, Jan 22-24).

Current state: v1.0 candidate. A single `index.html` app with two modes:

- **Practice mode** (default, and always on at `#demo`): runs on one phone with simulated data. Nothing to set up.
- **Live mode**: phones share one game through a free Supabase project. Follow `SETUP_BACKEND.md`, then put the project URL and publishable key in `config.js`.

Files: `index.html` (the app), `config.js` (server address), `supabase/schema.sql` (database, sign-in checks, who-can-see-what rules), `SETUP_BACKEND.md` (click-by-click setup), `manifest.webmanifest` + `sw.js` + icons (installable app).
