# Connect the game server (about 15 minutes)

Until you do this, Task Hunt runs on one phone only (practice mode). After this, every phone shares one live game.
You need: a free Supabase account, and edit access to this GitHub repo. No credit card.

## 1. Make the project
1. Go to **supabase.com** and sign up (GitHub login is easiest).
2. Click **New project**.
3. Name: `task-hunt`. Database password: click **Generate a password** and save it somewhere (you will not need it again for this setup).
4. Region: **West US (North California)**. Plan: **Free**. Click **Create new project** and wait about 2 minutes.

## 2. Load the game's database
1. Left menu: **SQL Editor** → **New query**.
2. Open `supabase/schema.sql` in this repo, copy everything, paste it into the editor.
3. Click **Run**. You should see "Success. No rows returned". (Notices are fine. A red error is not: send it to me.)

## 3. Turn on anonymous sign-in
Phones do not use email. The server gives each phone a private id, and your codes decide who is a leader or judge.
1. Left menu: **Authentication** → **Sign In / Providers** (older dashboards: Settings).
2. Turn **Allow anonymous sign-ins** ON. Click **Save**.

## 4. Set your own sign-in codes
The codes that are in the old prototype (7603, 1232, 6842) are public in this repo's history. Do not reuse them.
1. **SQL Editor** → **New query**. Paste this, change the quoted values, **Run**:
```sql
update public.secrets set value = 'PICK-OWNER-CODE'  where name = 'owner_pin';   -- only you
update public.secrets set value = 'PICK-LEADER-CODE' where name = 'leader_pin';  -- leaders
update public.secrets set value = 'PICK-JUDGE-CODE'  where name = 'judge_pin';   -- judges
update public.secrets set value = ''                 where name = 'player_code'; -- optional: kids must type this to join; '' means no code
```
2. Letters and numbers both work. The owner code ignores capital letters, dashes and spaces.

## 5. Connect the app
1. Supabase left menu: **Project Settings** → **API Keys** (older dashboards: **API**).
2. Copy the **Project URL** (looks like `https://abcdxyz.supabase.co`) and the **publishable** key (starts `sb_publishable_`; older projects call it the `anon` key).
   Never copy the **secret** or `service_role` key into the app.
3. On GitHub, open `config.js`, click the pencil, paste the two values between the quotes, and **Commit changes**.
4. Wait about a minute for the site to update, then reload it on your phone.

## 6. Check it
1. On your phone open the site, choose **Leader**, type your name and your owner code.
2. Open the **Game** tab and tap **Run check** on the Game server card. Every line should be green.
   Red lines say what to fix. The most common ones are in the table below.
3. Join from a second phone as a player. Start the game from your phone. Both should change within a few seconds.

## If something is red
| Message | Fix |
|---|---|
| The server does not know this phone | Tap your name (top right) → leave, then join again. |
| Still the CHANGE-ME placeholders | Do step 4. |
| Could not read setup status | Run the newest `schema.sql` again (it is safe to re-run). |
| Can store photos: failed | Step 2 did not finish. Re-run `schema.sql`, then check **Storage** shows a private bucket named `proofs`. |
| Reaches the server: failed | The URL or key in `config.js` has a typo or an extra space. |

## What to know before the trip
- **The free plan pauses a project after about a week with no visits.** Open the app a couple of days before Jan 22. If it paused, click **Restore** in Supabase.
- **Your phone starts and ends the game.** Players still claim pings and hunts correctly if your phone drops, because the server checks the clock itself. Reopen the app to push the final scoreboard.
- **Updates arrive every 2 to 3 seconds** (every 8 seconds when a phone's screen is off). Alerts that wake a locked phone need push notifications, which are not built yet.
- **Photos and videos are private.** Only the team that sent them and staff can open them, through links that expire after an hour.
- **Players can open the browser tools and try to cheat.** The server blocks the big things (changing tasks, scoring for another team, reading hunt codes or other teams' locations). It cannot verify GPS, so a determined kid could fake a check-in. Judges and leaders are the backstop.

## After the trip: wipe everything
1. **SQL Editor**, run: `truncate public.records, public.members, public.join_attempts;`
2. **Storage** → `proofs` → select all → **Delete**.
3. Or delete the whole project: **Project Settings** → **General** → **Delete project**.
