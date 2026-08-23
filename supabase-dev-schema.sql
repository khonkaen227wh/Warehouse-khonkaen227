-- ============================================================
-- Warehouse Phraputthabath — Dev Schema Setup
-- รันใน Supabase SQL Editor ของ dev project
--
-- หมายเหตุ: แอปเก็บข้อมูลทั้งหมดในรูป id + data (jsonb) เพียง 4 ตาราง
-- ไม่มีตารางแยกคอลัมน์ราย field (trucks/qc_records/loading_records แบบเก่า
-- ไม่ได้ใช้งานจริงแล้ว ตัดออกจากไฟล์นี้)
--
-- รูปสินค้า/อุณหภูมิไม่ได้เก็บใน Supabase Storage — อัปโหลดไป Cloudflare R2
-- ผ่าน src/lib/r2.js แทน ต้องตั้งค่า VITE_R2_* แยกชุดสำหรับ dev ใน Vercel
-- (Environment: Preview) ไม่ใช้ตัวเดียวกับ production
-- ============================================================

-- ─── wh_queue ──────────────────────────────────────────────
-- คิวรถจาก LG (ตารางคิวที่ LG อัปโหลด)
create table if not exists wh_queue (
  id   text primary key,
  data jsonb
);

alter table wh_queue enable row level security;
drop policy if exists "allow all" on wh_queue;
create policy "allow all" on wh_queue for all using (true) with check (true);

-- ─── wh_queue_next ─────────────────────────────────────────
-- คิวรถของวันทำงานถัดไปที่ LG อัปโหลดล่วงหน้า (แท็ป "อัปโหลดล่วงหน้า" ในหน้า LG)
-- แยกจาก wh_queue โดยสมบูรณ์ — ไม่กระทบคิวของวันทำงานปัจจุบัน
-- ถูกย้ายเข้า wh_queue อัตโนมัติแล้วล้างว่าง ตอนข้ามรอบวันทำงาน (close_work_day()
-- ใน supabase-auto-close-10am.sql หรือปุ่ม "ล้างวันใหม่" — handleReset ใน App.jsx)
create table if not exists wh_queue_next (
  id   text primary key,
  data jsonb
);

alter table wh_queue_next enable row level security;
drop policy if exists "allow all" on wh_queue_next;
create policy "allow all" on wh_queue_next for all using (true) with check (true);

-- ─── wh_trucks ─────────────────────────────────────────────
-- รถแต่ละคัน หนึ่งแถวต่อคัน — data.qcLanes / data.loadLanes / data.sampleLanes
-- เก็บแยกกันคนละ field ในก้อน JSON เดียวกัน ไม่ชนกัน:
--   data.qcLanes.<lane_id>     = { done, temp, photos[], doneAt }   — QC ตรวจอุณหภูมิรถ
--   data.loadLanes.<lane_id>   = { done, waiting, photos[], note, doneAt, waitingAt } — Checker (ลานโหลดจริง)
--   data.sampleLanes.<lane_id> = { done, photos[], doneAt }         — ลานโหลด: สุ่มตรวจอุณหภูมิสินค้า (ไม่มี temp, แนบรูปอย่างเดียว)
-- lane_id คือหนึ่งใน: lane_parts | lane_head | lane_pork
create table if not exists wh_trucks (
  id   text primary key,
  data jsonb
);

alter table wh_trucks enable row level security;
drop policy if exists "allow all" on wh_trucks;
create policy "allow all" on wh_trucks for all using (true) with check (true);

-- ─── wh_master ─────────────────────────────────────────────
-- ไฟล์ Master ลานโหลด (id = 'master') และไฟล์ Detail Loading รายแหล่ง (id = 'detail_<source_id>')
create table if not exists wh_master (
  id   text primary key,
  data jsonb
);

alter table wh_master enable row level security;
drop policy if exists "allow all" on wh_master;
create policy "allow all" on wh_master for all using (true) with check (true);

-- ─── wh_archive ────────────────────────────────────────────
-- สแนปช็อตคิว/รถรายวัน เก็บไว้ดู log ย้อนหลัง (Loading Log / QC Log / Log การตรวจอุณหภูมิสินค้า)
create table if not exists wh_archive (
  archive_date date primary key,
  queue        jsonb,
  trucks       jsonb
);

alter table wh_archive enable row level security;
drop policy if exists "allow all" on wh_archive;
create policy "allow all" on wh_archive for all using (true) with check (true);

-- ─── wh_basket_returns ─────────────────────────────────────
-- log การคืนตะกร้า/ตะขอ หนึ่งแถวต่อการคืนหนึ่งครั้ง — สะสมตลอดไป
-- ไม่ถูกล้างตอนกดปิดงาน (handleReset) ต่างจาก wh_queue/wh_trucks
-- data = { plate, yellowBig, yellowSmall, gray, hooks, returnedAt }
-- หน้า "ข้อมูลยอดตะกร้า/ตะขอ" เทียบยอดนี้กับยอดที่ออกไปสะสมทุกวัน (ทุก wh_archive.trucks
-- รวมคิววันนี้ที่ยังไม่ปิดงาน) เพื่อคำนวณว่าแต่ละทะเบียนยังค้างคืนเท่าไร
create table if not exists wh_basket_returns (
  id   text primary key,
  data jsonb
);

alter table wh_basket_returns enable row level security;
drop policy if exists "allow all" on wh_basket_returns;
create policy "allow all" on wh_basket_returns for all using (true) with check (true);

-- ─── wh_master_upload_log ──────────────────────────────────
-- log ทุกครั้งที่มีการอัปโหลด/เปลี่ยนไฟล์ Master ลานโหลด หนึ่งแถวต่อครั้ง — สะสมตลอดไป
-- data = { fileName, uploadedAt, matched, total }
-- แสดงในหน้า "อัพโหลด Master" เป็นประวัติการอัพโหลด
create table if not exists wh_master_upload_log (
  id   text primary key,
  data jsonb
);

alter table wh_master_upload_log enable row level security;
drop policy if exists "allow all" on wh_master_upload_log;
create policy "allow all" on wh_master_upload_log for all using (true) with check (true);

-- ─── wh_settings ───────────────────────────────────────────
-- ค่า config ที่เคย hardcode ไว้ในโค้ด (cutoff hour, threshold ต่างๆ) ดูรายละเอียด
-- key ที่รองรับใน supabase-add-settings.sql / src/lib/settings.js
create table if not exists wh_settings (
  id    text primary key,
  value jsonb
);

alter table wh_settings enable row level security;
drop policy if exists "allow all" on wh_settings;
create policy "allow all" on wh_settings for all using (true) with check (true);

-- ─── wh_lane_aliases ───────────────────────────────────────
-- ชื่อเรียกลานแบบอื่นๆ ที่พบในไฟล์ Master นอกเหนือจาก default ในโค้ด
-- id = alias text, data = { laneKey }
create table if not exists wh_lane_aliases (
  id   text primary key,
  data jsonb
);

alter table wh_lane_aliases enable row level security;
drop policy if exists "allow all" on wh_lane_aliases;
create policy "allow all" on wh_lane_aliases for all using (true) with check (true);

-- ─── wh_waiting_reasons ────────────────────────────────────
-- รายการเหตุผล "รอสินค้าอะไร" (fallback เมื่อไฟล์ Master ไม่มีชื่อสินค้า match)
-- data = { label, sortOrder }
create table if not exists wh_waiting_reasons (
  id   text primary key,
  data jsonb
);

alter table wh_waiting_reasons enable row level security;
drop policy if exists "allow all" on wh_waiting_reasons;
create policy "allow all" on wh_waiting_reasons for all using (true) with check (true);

-- ─── wh_basket_types ───────────────────────────────────────
-- ประเภทตะกร้า/ตะขอ เสริม/override 4 ตัว default ในโค้ด (yellowBig/yellowSmall/gray/hooks)
-- id = key คงที่, data = { label, countsInTotal, sortOrder }
create table if not exists wh_basket_types (
  id   text primary key,
  data jsonb
);

alter table wh_basket_types enable row level security;
drop policy if exists "allow all" on wh_basket_types;
create policy "allow all" on wh_basket_types for all using (true) with check (true);

-- ─── wh_detail_sources ─────────────────────────────────────
-- ช่องทาง PO เสริม/override 3 ช่องทาง default ในโค้ด (wet_market/modern_trade/others)
-- id = รหัสช่องทางคงที่, data = { label, emoji, color, bg, plateCol, productCodeCol, groupFlagCol, matchKeywords }
create table if not exists wh_detail_sources (
  id   text primary key,
  data jsonb
);

alter table wh_detail_sources enable row level security;
drop policy if exists "allow all" on wh_detail_sources;
create policy "allow all" on wh_detail_sources for all using (true) with check (true);
