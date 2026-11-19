-- =====================================================================
-- Task Hunt backend. Paste this whole file into the Supabase SQL editor and press Run.
-- Safe to run again later (it only creates what is missing and refreshes the functions).
-- Sign-in codes are NOT in this file. You set them at the bottom (section 9) after running it.
-- =====================================================================

-- 1. Secrets (sign-in codes). No policies on purpose: the app can never read this table.
create table if not exists public.secrets (name text primary key, value text not null);
alter table public.secrets enable row level security;
revoke all on public.secrets from anon, authenticated;
insert into public.secrets (name, value) values
  ('owner_pin',   'CHANGE-ME-OWNER'),
  ('leader_pin',  'CHANGE-ME-LEADER'),
  ('judge_pin',   'CHANGE-ME-JUDGE'),
  ('player_code', '')
on conflict (name) do nothing;

-- 2. Members: who each phone is (set only by join_game below).
create table if not exists public.members (
  user_id    uuid primary key,
  key        text not null,
  role       text not null check (role in ('player','leader','judge')),
  owner      boolean not null default false,
  name       text not null,
  team_id    text,
  created_at timestamptz not null default now()
);
alter table public.members enable row level security;
revoke all on public.members from anon, authenticated;
grant select on public.members to authenticated;

create table if not exists public.join_attempts (
  user_id uuid not null, ts timestamptz not null default now(), ok boolean not null
);
alter table public.join_attempts enable row level security;
revoke all on public.join_attempts from anon, authenticated;

-- 2b. The one shared table the app syncs through
create sequence if not exists public.rec_v;
grant usage, select on sequence public.rec_v to authenticated;
create table if not exists public.records (
  coll       text    not null,
  id         text    not null,
  data       jsonb   not null default '{}'::jsonb,
  deleted    boolean not null default false,
  v          bigint  not null default 0,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (coll, id)
);
create index if not exists records_v_idx on public.records (v);
-- A team can have only one pending-or-approved proof per task. Rejected ones may be redone.
create unique index if not exists one_proof_per_team_task on public.records ((data->>'teamId'), (data->>'taskId'))
  where coll = 'subs' and not deleted and (data->>'status') in ('pending','approved');


-- 3. Helpers (security definer so policies never recurse into members)
create or replace function public.my_role()  returns text    language sql stable security definer set search_path = public as $$ select role from public.members where user_id = auth.uid() $$;
create or replace function public.my_owner() returns boolean language sql stable security definer set search_path = public as $$ select coalesce((select owner from public.members where user_id = auth.uid()), false) $$;
create or replace function public.my_team()  returns text    language sql stable security definer set search_path = public as $$ select team_id from public.members where user_id = auth.uid() $$;
create or replace function public.my_key()   returns text    language sql stable security definer set search_path = public as $$ select key from public.members where user_id = auth.uid() $$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$ select coalesce((select role in ('leader','judge') from public.members where user_id = auth.uid()), false) $$;
create or replace function public.map_visible() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (data->>'mapVisible')::boolean from public.records where coll = 'settings' and id = 'main'), false)
$$;
-- members_read needs is_staff(), so it is created after the helpers
drop policy if exists members_read on public.members;
create policy members_read on public.members for select to authenticated
  using (user_id = (select auth.uid()) or public.is_staff());

-- 4. (the shared table is created above, in section 2b)
create or replace function public.records_touch() returns trigger language plpgsql as $$
begin
  new.v := nextval('public.rec_v'); new.updated_at := now(); new.updated_by := auth.uid(); return new;
end $$;
drop trigger if exists records_touch on public.records;
create trigger records_touch before insert or update on public.records for each row execute function public.records_touch();
alter table public.records replica identity full;
alter table public.records enable row level security;
revoke all on public.records from anon;
grant select, insert, update on public.records to authenticated;

-- 5. Who may read and write what
create or replace function public.can_read(p_coll text, p_data jsonb) returns boolean language plpgsql stable security definer set search_path = public as $$
declare r text := my_role();
begin
  if r is null then return false; end if;
  return case p_coll
    when 'locs'       then r in ('leader','judge') or (coalesce(p_data->>'teamId','') <> 'leader' and (p_data->>'teamId' = my_team() or map_visible()))
    when 'help'       then r in ('leader','judge') or p_data->>'key' = my_key()
    when 'sfeed'      then r in ('leader','judge') or p_data->>'by' = my_key()   -- own rows only, so a phone can upsert what it wrote
    when 'huntsecret' then r = 'leader'
    else true end;
end $$;

create or replace function public.can_write(p_coll text, p_id text, p_data jsonb) returns boolean language plpgsql stable security definer set search_path = public as $$
declare r text := my_role(); t text := my_team(); k text := my_key();
begin
  if r is null then return false; end if;
  if my_owner() then return p_coll not in ('claims','checkins'); end if;   -- claims go through the claim_* functions only
  if r = 'player' then
    return case p_coll
      when 'subs'  then p_data->>'teamId' = t and coalesce(p_data->>'status','pending') = 'pending'
      when 'locs'  then p_id = k
      when 'help'  then p_data->>'key' = k
      when 'feed'  then true
      when 'sfeed' then true
      when 'bonus' then p_data->>'teamId' = t
      when 'tiers' then p_id = t
      when 'multT' then p_id = t
      when 'acks'  then split_part(p_id, ':', 2) = k
      else false end;
  elsif r = 'judge' then
    return p_coll in ('subs','feed','sfeed','bonus','tiers','acks','settings','multT') or (p_coll = 'locs' and p_id = k);
  else -- leader
    return p_coll in ('feed','sfeed','help','hunts','huntPos','tiers','acks','settings','bonus','multT') or (p_coll in ('locs','leaders') and p_id = k);
  end if;
end $$;

drop policy if exists rec_read   on public.records;
drop policy if exists rec_insert on public.records;
drop policy if exists rec_update on public.records;
create policy rec_read   on public.records for select to authenticated using (public.can_read(coll, data));
create policy rec_insert on public.records for insert to authenticated with check (public.can_write(coll, id, data));
create policy rec_update on public.records for update to authenticated using (public.can_write(coll, id, data)) with check (public.can_write(coll, id, data));

-- 6. Join (this is where the sign-in codes are checked, on the server)
create or replace function public.join_info() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('needs_code', coalesce((select value <> '' from public.secrets where name = 'player_code'), false))
$$;

create or replace function public.join_game(p_role text, p_name text, p_team text, p_pin text, p_key text, p_code text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); fails int; nm text := left(trim(coalesce(p_name,'')), 20);
  norm text := lower(regexp_replace(coalesce(p_pin,''), '[^a-zA-Z0-9]', '', 'g'));
  o text; l text; j text; pc text; role_out text; owner_out boolean := false; granted boolean := false;
  tm text := p_team;
begin
  if uid is null then return jsonb_build_object('ok', false, 'msg', 'Not signed in. Reload the page.'); end if;
  if nm = '' then return jsonb_build_object('ok', false, 'msg', 'Add your name.'); end if;
  select count(*) into fails from join_attempts where user_id = uid and ts > now() - interval '30 seconds' and not join_attempts.ok;
  if fails >= 5 then return jsonb_build_object('ok', false, 'msg', 'Too many tries. Wait 30 seconds.'); end if;
  select value into o  from secrets where name = 'owner_pin';
  select value into l  from secrets where name = 'leader_pin';
  select value into j  from secrets where name = 'judge_pin';
  select value into pc from secrets where name = 'player_code';
  if p_role = 'player' then
    if coalesce(pc,'') <> '' and lower(regexp_replace(coalesce(p_code,''), '[^a-zA-Z0-9]', '', 'g')) <> lower(regexp_replace(pc, '[^a-zA-Z0-9]', '', 'g')) then
      insert into join_attempts (user_id, ok) values (uid, false);
      return jsonb_build_object('ok', false, 'msg', 'That game code is not right.');
    end if;
    role_out := 'player'; granted := true;
    if exists (select 1 from records where coll = 'teams' and not deleted) and not exists (select 1 from records where coll = 'teams' and id = coalesce(p_team,'') and not deleted) then
      return jsonb_build_object('ok', false, 'msg', 'Pick your team.');
    end if;
  elsif p_role = 'leader' and norm <> '' and norm = lower(regexp_replace(o, '[^a-zA-Z0-9]', '', 'g')) then
    role_out := 'leader'; owner_out := true; granted := true; tm := null;
  elsif p_role = 'leader' and trim(coalesce(p_pin,'')) = l then
    role_out := 'leader'; granted := true; tm := null;
  elsif p_role = 'judge' and trim(coalesce(p_pin,'')) = j then
    role_out := 'judge'; granted := true; tm := null;
  end if;
  insert into join_attempts (user_id, ok) values (uid, granted);
  if not granted then return jsonb_build_object('ok', false, 'msg', 'That code is not right.'); end if;
  insert into members (user_id, key, role, owner, name, team_id) values (uid, p_key, role_out, owner_out, nm, tm)
    on conflict (user_id) do update set key = excluded.key, role = excluded.role, owner = excluded.owner, name = excluded.name, team_id = excluded.team_id;
  return jsonb_build_object('ok', true, 'role', role_out, 'owner', owner_out, 'name', nm, 'key', p_key, 'teamId', tm);
end $$;

create or replace function public.whoami() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('ok', true, 'role', role, 'owner', owner, 'name', name, 'key', key, 'teamId', team_id) from public.members where user_id = auth.uid()), jsonb_build_object('ok', false))
$$;

-- Used by the owner's "Check the game server" button
create or replace function public.setup_status() returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.my_owner() then jsonb_build_object('ok', true,
      'default_codes', exists (select 1 from public.secrets where name in ('owner_pin','leader_pin','judge_pin') and value like 'CHANGE-ME%'),
      'players', (select count(*) from public.members where role = 'player'),
      'staff',   (select count(*) from public.members where role <> 'player'))
    else jsonb_build_object('ok', false) end
$$;

create or replace function public.server_now() returns bigint language sql stable as $$ select (extract(epoch from clock_timestamp()) * 1000)::bigint $$;

-- 7. Claims that must be fair across phones (one winner order, secret codes)
-- Is the game running right now? Decided from the clock, so it stays right even if nobody's phone has pushed "started" or "ended" yet.
create or replace function public.game_running(gm jsonb, now_ms bigint) returns boolean language sql immutable as $$
  select case coalesce(gm->'game'->>'state','')
    when 'running'  then coalesce((gm->'game'->>'endsAt')::numeric, 0) > now_ms
    when 'starting' then coalesce((gm->'game'->>'goAt')::numeric, 0) <= now_ms and coalesce((gm->'game'->>'goAt')::numeric, 0) + coalesce((gm->'game'->>'dur')::numeric, 0) > now_ms
    else false end
$$;
create or replace function public.claim_ping(p_ping text) returns jsonb language plpgsql security definer set search_path = public as $$
declare t text := my_team(); pg records%rowtype; rk int; now_ms bigint := server_now(); gm jsonb;
begin
  if my_role() <> 'player' then return jsonb_build_object('ok', false, 'msg', 'Only players can check in.'); end if;
  select * into pg from records where coll = 'pings' and id = p_ping and not deleted for update;
  if not found then return jsonb_build_object('ok', false, 'msg', 'That ping is gone.'); end if;
  select data into gm from records where coll = 'settings' and id = 'main';
  if not game_running(gm, now_ms) then return jsonb_build_object('ok', false, 'msg', 'The game is not running.'); end if;
  if (pg.data->>'deadline')::numeric < now_ms then return jsonb_build_object('ok', false, 'msg', 'This ping has ended.'); end if;
  if (pg.data->>'target') <> 'all' and (pg.data->>'target') <> t then return jsonb_build_object('ok', false, 'msg', 'This ping is not for your team.'); end if;
  if exists (select 1 from records where coll = 'checkins' and id = p_ping || ':' || t and not deleted) then
    return jsonb_build_object('ok', false, 'msg', 'Your team already checked in.');
  end if;
  select count(*) into rk from records where coll = 'checkins' and id like p_ping || ':%' and not deleted;
  if rk >= jsonb_array_length(pg.data->'places') then return jsonb_build_object('ok', false, 'msg', 'All the reward places are taken.'); end if;
  insert into records (coll, id, data) values ('checkins', p_ping || ':' || t, jsonb_build_object('pingId', p_ping, 'teamId', t, 'rank', rk, 'ts', now_ms));
  return jsonb_build_object('ok', true, 'rank', rk, 'ts', now_ms);
end $$;

create or replace function public.claim_hunt(p_hunt text, p_code text) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t text := my_team(); h records%rowtype; sec records%rowtype; gm jsonb; now_ms bigint := server_now();
  codes jsonb; ci int; len int; tr jsonb; used boolean; nclaims int; nteams int; done boolean := false;
  lname text; tshort text; code_in text := trim(coalesce(p_code,''));
begin
  if my_role() <> 'player' then return jsonb_build_object('ok', false, 'msg', 'Only players can claim.'); end if;
  select * into h   from records where coll = 'hunts'      and id = p_hunt and not deleted for update;
  select * into sec from records where coll = 'huntsecret' and id = p_hunt for update;
  select data into gm from records where coll = 'settings' and id = 'main';
  if h.id is null or sec.id is null or h.data->>'state' <> 'live' or not game_running(gm, now_ms) then
    return jsonb_build_object('ok', false, 'msg', 'This hunt is not live right now.');
  end if;
  if exists (select 1 from records where coll = 'claims' and id = p_hunt || ':' || t and not deleted) then
    return jsonb_build_object('ok', false, 'msg', 'Your team already found them.');
  end if;
  codes := sec.data->'codes'; len := jsonb_array_length(codes); ci := coalesce((sec.data->>'ci')::int, 0);
  tr := coalesce(sec.data->'tries'->t, '{"n":0,"lock":0}'::jsonb);
  if (tr->>'lock')::bigint > now_ms then
    return jsonb_build_object('ok', false, 'msg', 'Too many tries. Wait ' || ceil(((tr->>'lock')::bigint - now_ms) / 1000.0)::int || ' seconds.');
  end if;
  if code_in <> (codes->>least(ci, len - 1)) then
    select exists (select 1 from jsonb_array_elements_text(codes) with ordinality e(v, i) where i <= ci and v = code_in) into used;
    tr := jsonb_set(tr, '{n}', to_jsonb((tr->>'n')::int + 1));
    if (tr->>'n')::int >= 3 then tr := jsonb_build_object('n', 0, 'lock', now_ms + 60000); end if;
    update records set data = jsonb_set(data, array['tries', t], tr, true) where coll = 'huntsecret' and id = p_hunt;
    return jsonb_build_object('ok', false, 'msg', case when (tr->>'lock')::bigint > now_ms then 'Wrong again. Locked for 1 minute.' when used then 'That code was already used by another team. Find them for their new code.' else 'That is not the right code.' end);
  end if;
  insert into records (coll, id, data) values ('claims', p_hunt || ':' || t, jsonb_build_object('huntId', p_hunt, 'teamId', t, 'ts', now_ms));
  select count(*) into nclaims from records where coll = 'claims' and id like p_hunt || ':%' and not deleted;
  select count(*) into nteams  from records where coll = 'teams' and not deleted;
  done := (ci + 1 >= len) or (nteams > 0 and nclaims >= nteams);
  update records set data = jsonb_set(jsonb_set(data, '{ci}', to_jsonb(ci + 1)), array['tries', t], '{"n":0,"lock":0}'::jsonb, true) where coll = 'huntsecret' and id = p_hunt;
  if done then update records set data = data || jsonb_build_object('state', 'done', 'doneAt', now_ms) where coll = 'hunts' and id = p_hunt; end if;
  lname := h.data->>'leaderName';
  select data->>'short' into tshort from records where coll = 'teams' and id = t;
  insert into records (coll, id, data) values ('sfeed', 'hunt:' || p_hunt || ':' || t,
    jsonb_build_object('ts', now_ms, 'aud', jsonb_build_array('key:' || (h.data->>'leaderKey')), 'snd', 'ok',
      'text', case when done then 'Every team has found you. The hunt is over. Thank you!' else coalesce(tshort, 'A team') || ' found you. Your next code is ' || (codes->>least(ci + 1, len - 1)) || '.' end));
  return jsonb_build_object('ok', true, 'rank', nclaims, 'done', done, 'ts', now_ms, 'leaderName', lname);
end $$;

-- 8. Live updates, privileges, storage
grant execute on all functions in schema public to authenticated;
revoke execute on function public.join_game(text,text,text,text,text,text) from anon;
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'records') then
    alter publication supabase_realtime add table public.records;
  end if;
end $$;
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit) values ('proofs', 'proofs', false, 26214400) on conflict (id) do nothing;
    drop policy if exists proofs_insert on storage.objects;
    drop policy if exists proofs_read on storage.objects;
    create policy proofs_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'proofs' and public.my_role() is not null and ((storage.foldername(name))[1] = public.my_team() or public.is_staff()));
    create policy proofs_read on storage.objects for select to authenticated
      using (bucket_id = 'proofs' and public.my_role() is not null and (public.is_staff() or (storage.foldername(name))[1] = public.my_team()));
  end if;
end $$;

-- 9. SET YOUR SIGN-IN CODES (run these lines yourself after step 1; change the values, keep the quotes)
--   update public.secrets set value = 'YOUR-OWNER-CODE'  where name = 'owner_pin';
--   update public.secrets set value = 'YOUR-LEADER-CODE' where name = 'leader_pin';
--   update public.secrets set value = 'YOUR-JUDGE-CODE'  where name = 'judge_pin';
--   -- optional: kids must type this game code to join as a player (leave empty for no code)
--   update public.secrets set value = 'tahoe27' where name = 'player_code';
--
-- AFTER THE TRIP: wipe everything
--   truncate public.records, public.members, public.join_attempts;
--   delete from storage.objects where bucket_id = 'proofs';
