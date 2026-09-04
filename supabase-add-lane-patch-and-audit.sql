-- ============================================================
-- Lane-level atomic patch + full audit trail for wh_trucks / wh_queue
--
-- ปัญหาที่พบ: หน้า QC / ตรวจอุณหภูมิสินค้า (RandomSampleCheck) / ลานโหลด (LoadingYard)
-- และหน้า Admin ทุกจุดที่แก้ qcLanes/sampleLanes/loadLanes ทำแบบเดียวกันหมดคือ
-- อ่าน object เดิมทั้งก้อนจาก state ฝั่ง client (เช่น sel.qcLanes) มา spread แล้วแก้แค่
-- lane เดียว จากนั้นส่ง object ทั้งก้อนกลับไปเป็น patch ผ่าน wh_trucks_patch
-- (data = data || p_patch เป็น shallow merge แค่ระดับ top-level key)
--
-- ผลคือถ้ามีอุปกรณ์ 2 ตัวบันทึกคนละ lane ของรถคันเดียวกันใกล้ๆ กัน (เช่น QC ลาน parts
-- กับ QC ลาน head), ฝั่งที่บันทึกทีหลังจะเอา snapshot เก่าของ qcLanes (ที่ยังไม่มีข้อมูล
-- ลานแรก) มาทับทั้งก้อน ทำให้ lane แรกที่เพิ่งบันทึกไปหายเงียบๆ — เป็นบั๊กคลาสเดียวกับที่
-- wh_trucks_patch เคยแก้ไว้ระดับ top-level แต่ยังไม่ครอบคลุมระดับ lane ข้างใน qcLanes/
-- sampleLanes/loadLanes
--
-- แก้โดย: wh_trucks_patch_lane merge เฉพาะ lane ที่ระบุ ที่ระดับ DB โดยตรง (atomic)
-- ไม่ต้องอาศัย snapshot จาก client เลย จึงชนกันไม่ได้ไม่ว่า client จะข้อมูลเก่าแค่ไหน
--
-- Run this once in the Supabase SQL editor (dev + prod).
-- ============================================================

-- ─── wh_trucks_patch_lane ──────────────────────────────────────────────────
-- Merge (หรือแทนที่ทั้ง lane ถ้า p_replace = true) เข้า data.<p_field>.<p_lane>
-- แบบ atomic ใน UPDATE เดียว — p_field ต้องเป็น qcLanes | sampleLanes | loadLanes
create or replace function wh_trucks_patch_lane(
  p_id text,
  p_field text,
  p_lane text,
  p_value jsonb,
  p_replace boolean default false
)
returns jsonb
language plpgsql
as $$
declare
  result jsonb;
begin
  if p_field not in ('qcLanes', 'sampleLanes', 'loadLanes') then
    raise exception 'wh_trucks_patch_lane: invalid field %', p_field;
  end if;

  update wh_trucks
  set data = jsonb_set(
    coalesce(data, '{}'::jsonb),
    array[p_field],
    coalesce(data->p_field, '{}'::jsonb) || jsonb_build_object(
      p_lane,
      case when p_replace then p_value
           else coalesce(data->p_field->p_lane, '{}'::jsonb) || p_value
      end
    ),
    true
  )
  where id = p_id
  returning data into result;

  if result is null then
    raise exception 'wh_trucks_patch_lane: no truck with id %', p_id;
  end if;

  return result;
end;
$$;

-- ─── wh_trucks_history / wh_queue_history ──────────────────────────────────
-- ตาราง audit log บันทึกทุกการเปลี่ยนแปลงของ wh_trucks และ wh_queue แบบ before/after
-- ไม่ว่าจะเขียนผ่านช่องทางไหน (upsert ตรงๆ, wh_trucks_patch, wh_trucks_patch_lane)
-- เพื่อให้ตรวจสอบย้อนหลังได้ว่าข้อมูลรถ/คิว ณ เวลาใดเป็นอย่างไร และใครทับใครตอนไหน
create table if not exists wh_trucks_history (
  id         bigint generated always as identity primary key,
  truck_id   text not null,
  action     text not null, -- INSERT | UPDATE | DELETE
  old_data   jsonb,
  new_data   jsonb,
  changed_at timestamptz not null default now()
);
create index if not exists wh_trucks_history_truck_id_idx on wh_trucks_history (truck_id, changed_at desc);

alter table wh_trucks_history enable row level security;
drop policy if exists "allow all" on wh_trucks_history;
create policy "allow all" on wh_trucks_history for all using (true) with check (true);

create table if not exists wh_queue_history (
  id         bigint generated always as identity primary key,
  queue_id   text not null,
  action     text not null, -- INSERT | UPDATE | DELETE
  old_data   jsonb,
  new_data   jsonb,
  changed_at timestamptz not null default now()
);
create index if not exists wh_queue_history_queue_id_idx on wh_queue_history (queue_id, changed_at desc);

alter table wh_queue_history enable row level security;
drop policy if exists "allow all" on wh_queue_history;
create policy "allow all" on wh_queue_history for all using (true) with check (true);

create or replace function wh_trucks_audit() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    insert into wh_trucks_history (truck_id, action, old_data, new_data) values (new.id, 'INSERT', null, new.data);
    return new;
  elsif tg_op = 'UPDATE' then
    insert into wh_trucks_history (truck_id, action, old_data, new_data) values (new.id, 'UPDATE', old.data, new.data);
    return new;
  elsif tg_op = 'DELETE' then
    insert into wh_trucks_history (truck_id, action, old_data, new_data) values (old.id, 'DELETE', old.data, null);
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_wh_trucks_audit on wh_trucks;
create trigger trg_wh_trucks_audit
after insert or update or delete on wh_trucks
for each row execute function wh_trucks_audit();

create or replace function wh_queue_audit() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    insert into wh_queue_history (queue_id, action, old_data, new_data) values (new.id, 'INSERT', null, new.data);
    return new;
  elsif tg_op = 'UPDATE' then
    insert into wh_queue_history (queue_id, action, old_data, new_data) values (new.id, 'UPDATE', old.data, new.data);
    return new;
  elsif tg_op = 'DELETE' then
    insert into wh_queue_history (queue_id, action, old_data, new_data) values (old.id, 'DELETE', old.data, null);
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_wh_queue_audit on wh_queue;
create trigger trg_wh_queue_audit
after insert or update or delete on wh_queue
for each row execute function wh_queue_audit();
