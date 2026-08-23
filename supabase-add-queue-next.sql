-- ============================================================
-- เพิ่มตาราง wh_queue_next สำหรับฟีเจอร์ "อัปโหลดคิวรถล่วงหน้า" ในหน้า LG
-- รันสคริปต์นี้ครั้งเดียวใน Supabase SQL Editor ของ project จริง
--
-- เก็บคิวรถของวันทำงานถัดไปที่ LG อัปโหลดล่วงหน้าไว้ต่างหากจาก wh_queue
-- (คิวของวันทำงานปัจจุบัน) เพื่อไม่ให้กระทบคิวของวันนี้เลย
-- เมื่อข้ามรอบวันทำงาน (close_work_day() ใน supabase-auto-close-10am.sql
-- หรือปุ่ม "ล้างวันใหม่" — handleReset ใน App.jsx) ข้อมูลในตารางนี้จะถูกย้าย
-- เข้า wh_queue ให้กลายเป็นคิวรถวันปัจจุบันโดยอัตโนมัติ แล้วตารางนี้จะถูกล้างว่าง
-- ============================================================

create table if not exists wh_queue_next (
  id   text primary key,
  data jsonb
);

alter table wh_queue_next enable row level security;
drop policy if exists "allow all" on wh_queue_next;
create policy "allow all" on wh_queue_next for all using (true) with check (true);
