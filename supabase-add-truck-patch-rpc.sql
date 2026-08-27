-- Atomic partial update for wh_trucks.data.
--
-- Problem: handleUpdate() used to read its own cached copy of a truck, spread the
-- patch onto it in JS, then upsert the WHOLE `data` object back. If two actions on
-- the same truck land close together from different devices (e.g. QC recording a
-- temperature check while Picking prints the pickup slip), whichever write reaches
-- the DB last silently overwrites the other's change — because it was built from a
-- client-side snapshot that predates the first write. No error, nothing visible to
-- either operator; the field the first write set just disappears.
--
-- Fix: merge the patch into `data` inside a single UPDATE statement, so the merge
-- happens atomically in Postgres against whatever is currently stored — not against
-- a possibly-stale client copy. This is a SHALLOW (top-level key) merge, matching
-- how the app already treats nested objects like qcLanes/loadLanes as "replace this
-- whole key" (callers pre-build the full nested object before calling onUpdate, e.g.
-- src/App.jsx resetQC/resetLoad rely on being able to wholesale-replace `qcLanes`).
-- A recursive deep merge would silently no-op those resets, so this intentionally
-- stays shallow — it only closes the race between writes to *different* top-level
-- fields, which is the concrete case that was observed (QC temp check vs. picking
-- print on the same truck landing at nearly the same moment).
--
-- Run this once in the Supabase SQL editor.

create or replace function wh_trucks_patch(p_id text, p_patch jsonb)
returns jsonb
language plpgsql
as $$
declare
  result jsonb;
begin
  update wh_trucks
  set data = data || p_patch
  where id = p_id
  returning data into result;

  if result is null then
    raise exception 'wh_trucks_patch: no truck with id %', p_id;
  end if;

  return result;
end;
$$;
