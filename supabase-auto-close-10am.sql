-- ============================================================
-- Auto-close work day — ผูกกับ wh_settings.work_day_cutoff_hour โดยตรง
-- รันสคริปต์นี้ครั้งเดียวใน Supabase SQL Editor ของ project จริง
-- (ต้องรันด้วยสิทธิ์ owner/admin — anon key ของแอปทำแบบนี้ไม่ได้)
--
-- ⚠️ ไฟล์นี้เคยตั้ง cron ให้รันตายตัวตอน 10:00 Bangkok (job ชื่อ close-work-day-10am)
-- ซึ่งไม่รู้จักถ้า admin ไปเปลี่ยนเวลาตัดรอบในหน้า Admin (SystemSettings) เวอร์ชันนี้
-- เปลี่ยนมาให้ cron รันทุกชั่วโมง แล้วให้ฟังก์ชันเองเช็คจาก wh_settings ว่าถึงชั่วโมง
-- ตัดรอบหรือยัง — เปลี่ยนเวลาตัดรอบในแอปเมื่อไหร่ cron ก็ตามทันที ไม่ต้องมารัน SQL ใหม่
-- ถ้าเคยรันไฟล์นี้เวอร์ชันเก่าไปแล้ว ต้องรันไฟล์นี้ทั้งไฟล์ซ้ำอีกครั้งเพื่ออัปเดต
-- ฟังก์ชัน/schedule ที่ผูกกับ cron job อยู่แล้ว (รันซ้ำได้ปลอดภัย)
--
-- ทำสิ่งเดียวกับปุ่ม "ล้างวันใหม่" ใน Dashboard (handleReset ใน App.jsx) และเพิ่ม
-- ขั้นตอนดึงคิวรถล่วงหน้าที่ LG อัปโหลดไว้ (wh_queue_next) มาใช้เป็นคิวรถวันปัจจุบัน:
--   1. archive แถวปัจจุบันของ wh_queue + wh_trucks ไปที่ wh_archive
--   2. ลบ wh_queue และ wh_trucks ให้ว่างสำหรับรอบใหม่
--   3. ย้ายข้อมูลจาก wh_queue_next (ถ้ามี) เข้า wh_queue แล้วล้าง wh_queue_next ให้ว่าง
-- ปุ่ม "ล้างวันใหม่" ในแอปยังใช้งานได้ตามปกติ (เผื่อกดปิดงานนอกรอบ/เร็วกว่าเวลาตัดรอบ)
-- และตอนนี้ทำขั้นตอนที่ 3 เหมือนกันแล้ว (ดู handleReset ใน App.jsx)
-- ============================================================

-- 1) เปิด extension pg_cron (ถ้ายังไม่เปิด)
--    ถ้ารันแล้ว error เรื่องสิทธิ์ ให้ไปเปิดผ่าน
--    Dashboard → Database → Extensions → ค้นหา "pg_cron" → Enable
create extension if not exists pg_cron;

-- 2) ฟังก์ชันปิดงาน — คำนวณ archive_date = "เมื่อวาน" ของเวลา Bangkok เสมอ
--    (งานนี้รันตอนถึงชั่วโมงตัดรอบพอดี ซึ่งตรงกับจุดเริ่มต้นของวันทำงานใหม่ตาม cycleDateStr()
--    ใน App.jsx — ข้อมูลที่กำลังจะ archive ตอนนี้คือของวันทำงานที่เพิ่งปิดไป (เมื่อวาน) เสมอ
--    จึงลบ 1 วันตรง ๆ ไม่ต้อง port logic ก่อน/หลัง cutoff แบบ cycleDateStr มาใช้ตรงนี้)
create or replace function close_work_day() returns void as $$
declare
  v_archive_date date := (now() at time zone 'Asia/Bangkok')::date - 1;
  v_queue        jsonb;
  v_trucks       jsonb;
begin
  select coalesce(jsonb_agg(data order by (data->>'seq')::numeric nulls last), '[]'::jsonb)
    into v_queue
    from wh_queue;

  select coalesce(jsonb_agg(data), '[]'::jsonb)
    into v_trucks
    from wh_trucks;

  insert into wh_archive (archive_date, queue, trucks)
  values (v_archive_date, v_queue, v_trucks)
  on conflict (archive_date) do update
    set queue  = excluded.queue,
        trucks = excluded.trucks;

  delete from wh_queue;
  delete from wh_trucks;

  -- ดึงคิวรถล่วงหน้าที่ LG อัปโหลดไว้ (ถ้ามี) มาใช้เป็นคิวรถวันปัจจุบันทันที
  insert into wh_queue (id, data)
  select id, data from wh_queue_next;

  delete from wh_queue_next;
end;
$$ language plpgsql security definer;

-- 3) ฟังก์ชันเช็คทุกชั่วโมงว่าถึงเวลาตัดรอบตาม wh_settings.work_day_cutoff_hour หรือยัง
--    - ยังไม่ถึงชั่วโมงตัดรอบ → ไม่ทำอะไร
--    - ถึงชั่วโมงตัดรอบแล้ว แต่ archive ของวันนี้มีอยู่แล้ว (เช่นกดปุ่ม "ล้างวันใหม่" ไปก่อนแล้ว)
--      → ไม่ทำอะไร กันปิดงานซ้ำ/ย้าย wh_queue_next ซ้ำ
--    - ถึงชั่วโมงตัดรอบและยังไม่ได้ปิดงาน → เรียก close_work_day()
create or replace function maybe_close_work_day() returns void as $$
declare
  v_cutoff_hour  int;
  v_now_bkk      timestamp := now() at time zone 'Asia/Bangkok';
  v_archive_date date := v_now_bkk::date - 1;
begin
  select (value #>> '{}')::int into v_cutoff_hour
    from wh_settings where id = 'work_day_cutoff_hour';
  if v_cutoff_hour is null then
    v_cutoff_hour := 10; -- ค่า default เดียวกับ settings.js ถ้ายังไม่มีแถวตั้งค่านี้
  end if;

  if extract(hour from v_now_bkk)::int <> v_cutoff_hour then
    return;
  end if;

  if exists (select 1 from wh_archive where archive_date = v_archive_date) then
    return;
  end if;

  perform close_work_day();
end;
$$ language plpgsql security definer;

-- 4) ตั้งเวลา — รันทุกชั่วโมงที่นาที 5 (Asia/Bangkok = UTC+7 ไม่มี DST จึงไม่ขยับ)
--    ตัวฟังก์ชันเองเช็คว่าตรงชั่วโมงตัดรอบปัจจุบันหรือไม่ ไม่ใช่ schedule ตายตัวแบบเดิม
--    รันซ้ำได้ปลอดภัย: ถ้ามี job ชื่อนี้อยู่แล้ว cron.schedule จะอัปเดตให้ ไม่สร้างซ้ำ
do $$
begin
  perform cron.unschedule('close-work-day-10am'); -- เอา job เวอร์ชันเก่า (เวลาตายตัว) ออกถ้ามี
exception when others then
  null;
end $$;

select cron.schedule(
  'close-work-day-hourly',
  '5 * * * *',
  $$ select maybe_close_work_day(); $$
);

-- ============================================================
-- ตรวจสอบหลังรัน
-- ============================================================
-- ดูว่า job ถูกตั้งไว้จริง (ต้องเห็น close-work-day-hourly และไม่มี close-work-day-10am แล้ว):
--   select * from cron.job;
-- ดู log การรันแต่ละครั้ง (เช็คตอนหลังผ่านชั่วโมงตัดรอบว่า status = 'succeeded'):
--   select * from cron.job_run_details order by start_time desc limit 5;
--
-- ⚠️ ห้ามรัน `select close_work_day();` ทดสอบตรง ๆ ในเวลาทำงานจริง
--   เพราะมันจะ archive + ลบ wh_queue/wh_trucks + ย้าย wh_queue_next ทันทีเหมือนกดปุ่ม "ล้างวันใหม่" จริง
--
-- ยกเลิก automation (ถ้าต้องการ):
--   select cron.unschedule('close-work-day-hourly');
-- ============================================================
