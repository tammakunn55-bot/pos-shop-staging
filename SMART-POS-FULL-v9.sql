-- =====================================================================
-- SMART-POS: ชุด SQL รวมไฟล์เดียว (v2 + patch 003 + patch 004)
-- ใช้กับฐานข้อมูลใหม่ หรือรันทับฐานที่ติดตั้ง v2 แล้ว
-- รันทั้งไฟล์ในครั้งเดียว ครอบด้วย transaction: ถ้าผิดพลาดจุดใดจะ rollback ทั้งหมด
-- ต้องเปิด extension pg_cron ก่อน เพื่อให้เปิด/ปิดร้านอัตโนมัติทำงาน (ไม่เปิดก็รันได้ แต่จะไม่มีการเปิด/ปิดอัตโนมัติ)
-- =====================================================================

begin;


-- ######## ชุดติดตั้งหลัก (v2) ########
-- =====================================================================
-- Smart POS  —  SMART-POS-SETUP-v2.sql   (ฐานข้อมูลใหม่ / Supabase PostgreSQL 15+)
-- ใช้คู่กับ index.html ที่แพตช์แล้ว (smartpos-v2)
--
-- วิธีใช้: Supabase > SQL Editor > วางทั้งไฟล์ > Run  (รันซ้ำได้ ไม่ลบข้อมูลร้าน)
-- แนวคิดหลัก
--   1) ตัวเลขที่เป็นเงิน/สต็อก/หนี้ เปลี่ยนได้ผ่านฟังก์ชัน (RPC) เท่านั้น — เครื่องเขียนตารางตรงไม่ได้
--   2) ทุกอย่างต้องเป็น "พนักงานที่ active ใน app_users" ถึงจะอ่าน/เขียนได้ (คนสมัคร Auth เฉยๆ ไม่ผ่าน)
--   3) ledger/audit แก้ไขหรือลบย้อนหลังไม่ได้
--   4) ต้นทุนขาย (COGS) ถูกบันทึกในรายการบิล ณ วันที่ขาย
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) ตาราง
-- ---------------------------------------------------------------------
create table if not exists public.shop_settings (
  id uuid primary key default gen_random_uuid(),
  shop_name text not null default '', phone text, tax_id text, address text,
  vat_registered boolean not null default false,
  vat_rate numeric not null default 7,
  updated_at timestamptz not null default now()
);

create table if not exists public.app_users (
  id uuid primary key,
  auth_user_id uuid unique,
  name text not null,
  pin text not null,
  role text not null default 'CASHIER',
  permissions jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.categories (
  id uuid primary key, name text not null, icon text default '📁', color text default '#4F46E5',
  display_order integer default 0, created_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key, sku text unique, name text not null, image_url text,
  min_stock_alert numeric not null default 5, is_active boolean not null default true,
  group_name text, display_order integer default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.product_categories (
  product_id uuid not null references public.products(id) on delete cascade,
  category_id uuid not null references public.categories(id) on delete cascade,
  primary key (product_id, category_id)
);

create table if not exists public.product_variants (
  id uuid primary key,
  product_id uuid not null references public.products(id) on delete cascade,
  variant_name text not null default 'ปกติ',
  barcode text unique, sku text unique, image_url text,
  price numeric not null default 0 check (price >= 0),
  cost_price numeric not null default 0 check (cost_price >= 0),
  stock_quantity numeric not null default 0,          -- เปลี่ยนผ่าน RPC เท่านั้น
  stock_seeded boolean not null default false,        -- ตั้งยอดยกมาแล้วหรือยัง
  min_stock numeric not null default 5,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.product_fractions (
  id uuid primary key,
  variant_id uuid not null references public.product_variants(id) on delete cascade,
  fraction_name text not null,
  quantity_ratio numeric not null default 1 check (quantity_ratio > 0),  -- กี่หน่วยย่อย = 1 หน่วยสต็อก
  price numeric not null default 0 check (price >= 0),
  barcode text unique
);

create table if not exists public.customers (
  id uuid primary key, name text not null, phone text, address text not null default '',
  credit_limit numeric not null default 50000 check (credit_limit >= 0),
  debt numeric not null default 0 check (debt >= 0),   -- ยอดหนี้ค้าง: เปลี่ยนผ่าน RPC เท่านั้น
  debt_seeded boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.customer_ledger (    -- บัญชีลูกหนี้รายตัว (+ เพิ่มหนี้ / - ลดหนี้)
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id),
  entry_type text not null,                            -- OPENING, SALE, RETURN, PAYMENT
  amount numeric not null, balance_after numeric not null,
  ref_type text, ref_id text,
  created_at timestamptz not null default now(), created_by uuid references public.app_users(id)
);

create table if not exists public.suppliers (
  id uuid primary key, name text not null, phone text, address text not null default '',
  is_active boolean not null default true, created_at timestamptz not null default now()
);

create table if not exists public.shifts (
  id uuid primary key,
  opened_at timestamptz not null default now(), closed_at timestamptz,
  opening_cash numeric not null default 0 check (opening_cash >= 0),
  closing_cash numeric, expected_cash numeric, cash_variance numeric, close_note text,
  status text not null default 'OPEN' check (status in ('OPEN','CLOSED')),
  opened_by uuid references public.app_users(id), closed_by uuid references public.app_users(id)
);

create table if not exists public.bills (
  id uuid primary key default gen_random_uuid(),
  bill_number text not null unique,
  customer_id uuid references public.customers(id),
  user_id uuid references public.app_users(id),
  shift_id uuid references public.shifts(id),
  subtotal numeric not null default 0,
  discount_amount numeric not null default 0,
  tax_amount numeric not null default 0,
  rounding_amount numeric not null default 0,         -- เศษปัดระหว่างยอดที่ระบบคำนวณกับยอดที่เก็บจริง
  total numeric not null default 0,
  cogs_total numeric not null default 0,              -- ต้นทุนขายรวม ณ วันขาย
  payment_method text not null default 'CASH',
  status text not null default 'PAID' check (status in ('PAID','CREDIT','CANCELLED')),
  tax_mode text not null default 'NONE' check (tax_mode in ('NONE','INCLUDED','EXCLUDED')),
  client_ref text unique,
  created_at timestamptz not null default now()       -- = เวลาขายจริงที่เครื่องส่งมา (ไม่ใช่เวลาซิงค์)
);

create table if not exists public.bill_items (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null references public.bills(id) on delete cascade,
  product_id uuid references public.products(id),
  variant_id uuid references public.product_variants(id),
  fraction_id uuid references public.product_fractions(id),
  item_name text not null,
  quantity numeric not null check (quantity > 0),
  unit_price numeric not null check (unit_price >= 0),
  list_price numeric,                                 -- ราคาตามระบบ ณ วันขาย (ไว้ตรวจการแก้ราคา)
  line_total numeric not null,
  line_cost numeric not null default 0,               -- ต้นทุนรวมของรายการ ณ วันขาย
  stock_quantity_delta numeric not null default 0,
  returned_qty numeric not null default 0 check (returned_qty >= 0)
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null references public.bills(id) on delete cascade,
  method text not null, amount numeric not null, reference text,   -- ติดลบ = คืนเงินนอกลิ้นชัก
  created_at timestamptz not null default now()
);

create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  variant_id uuid not null references public.product_variants(id),
  change_qty numeric not null, reason text not null,
  ref_type text, ref_id uuid, op_ref text,
  created_at timestamptz not null default now(), created_by uuid references public.app_users(id)
);
create unique index if not exists uq_inventory_op_ref on public.inventory_movements(op_ref) where op_ref is not null;

create table if not exists public.cash_ledger (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid references public.shifts(id),
  type text not null,
  income numeric not null default 0 check (income >= 0),
  expense numeric not null default 0 check (expense >= 0),
  description text, ref_id text, payment_method text default 'CASH',
  created_at timestamptz not null default now(), created_by uuid references public.app_users(id)
);

create table if not exists public.customer_payments (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id),
  amount numeric not null check (amount > 0),
  shift_id uuid references public.shifts(id),
  payment_method text not null default 'CASH', reference text,
  op_ref text unique,
  created_at timestamptz not null default now(), received_by uuid references public.app_users(id)
);

create table if not exists public.returns (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null references public.bills(id),
  return_ref text unique,
  shift_id uuid references public.shifts(id),
  total numeric not null default 0, cogs_total numeric not null default 0,
  refund_method text, full_return boolean not null default false,
  created_at timestamptz not null default now(), created_by uuid references public.app_users(id)
);

create table if not exists public.return_items (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.returns(id) on delete cascade,
  bill_item_id uuid references public.bill_items(id),
  variant_id uuid references public.product_variants(id),
  fraction_id uuid references public.product_fractions(id),
  quantity numeric not null, unit_price numeric not null,
  line_total numeric not null default 0, line_cost numeric not null default 0,
  stock_quantity_delta numeric not null default 0
);

create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  client_ref text unique, supplier_id uuid references public.suppliers(id),
  doc_ref text, terms integer default 30,
  received_at timestamptz not null default now(),
  total numeric not null default 0, status text not null default 'RECEIVED',
  created_at timestamptz not null default now(), created_by uuid references public.app_users(id)
);

create table if not exists public.purchase_order_items (
  id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  product_id uuid references public.products(id), variant_id uuid references public.product_variants(id),
  quantity numeric not null, unit_cost numeric not null default 0, line_total numeric not null default 0
);

create table if not exists public.accounts_payable (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid references public.suppliers(id),
  purchase_order_id uuid references public.purchase_orders(id),
  doc_ref text, amount numeric not null default 0 check (amount >= 0),
  credit_terms integer default 30,
  status text not null default 'OPEN' check (status in ('OPEN','PAID')),
  created_at timestamptz not null default now(), paid_at timestamptz
);
create unique index if not exists uq_ap_po on public.accounts_payable(purchase_order_id) where purchase_order_id is not null;

create table if not exists public.supplier_payments (    -- หลักฐานการจ่ายเจ้าหนี้ (สร้างอัตโนมัติเมื่อ AP เป็น PAID)
  id uuid primary key default gen_random_uuid(),
  ap_id uuid not null unique references public.accounts_payable(id),
  supplier_id uuid references public.suppliers(id),
  amount numeric not null, paid_at timestamptz not null default now(),
  paid_by uuid references public.app_users(id), note text
);

create table if not exists public.income_expenses (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid references public.shifts(id), type text not null,
  amount numeric not null default 0, description text,
  created_at timestamptz not null default now(), created_by uuid references public.app_users(id)
);

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references public.app_users(id), actor_name text,
  action text not null, entity_type text, entity_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_variants_product on public.product_variants(product_id);
create index if not exists idx_inventory_variant_time on public.inventory_movements(variant_id, created_at desc);
create index if not exists idx_bills_created on public.bills(created_at desc);
create index if not exists idx_bills_customer on public.bills(customer_id, created_at desc);
create index if not exists idx_bills_shift on public.bills(shift_id);
create index if not exists idx_bill_items_bill on public.bill_items(bill_id);
create index if not exists idx_cash_ledger_shift on public.cash_ledger(shift_id, created_at);
create index if not exists idx_customer_ledger on public.customer_ledger(customer_id, created_at);
create index if not exists idx_returns_bill on public.returns(bill_id);
create index if not exists idx_po_supplier on public.purchase_orders(supplier_id, created_at desc);

insert into public.shop_settings(shop_name) select '' where not exists (select 1 from public.shop_settings);

-- ---------------------------------------------------------------------
-- 2) ฟังก์ชันช่วย (ตรวจสิทธิ์)
-- ---------------------------------------------------------------------
create or replace function public.pos_current_app_user_id() returns uuid
language sql stable security definer set search_path = public, auth as $$
  select id from public.app_users where auth_user_id = auth.uid() and is_active limit 1
$$;

create or replace function public.pos_current_role() returns text
language sql stable security definer set search_path = public, auth as $$
  select role from public.app_users where auth_user_id = auth.uid() and is_active limit 1
$$;

create or replace function public.pos_is_staff() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (select 1 from public.app_users where auth_user_id = auth.uid() and is_active)
$$;

create or replace function public.pos_is_manager() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (select 1 from public.app_users where auth_user_id = auth.uid() and is_active and role in ('OWNER','MANAGER'))
$$;

create or replace function public.pos_require_staff() returns uuid
language plpgsql stable security definer set search_path = public, auth as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'ต้องเข้าสู่ระบบก่อน'; end if;
  select id into v from public.app_users where auth_user_id = auth.uid() and is_active;
  if v is null then raise exception 'บัญชีนี้ไม่ได้รับสิทธิ์ใช้งานระบบ POS'; end if;
  return v;
end $$;

create or replace function public.pos_audit(p_action text, p_type text, p_id text, p_details jsonb) returns void
language sql security definer set search_path = public, auth as $$
  insert into public.audit_logs(actor_user_id, actor_name, action, entity_type, entity_id, details)
  select u.id, u.name, p_action, p_type, p_id, coalesce(p_details, '{}'::jsonb)
  from (select id, name from public.app_users where auth_user_id = auth.uid() and is_active limit 1) u
$$;

create or replace function public.pos_schema_version() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('version','smartpos-v2','stock_table','inventory_movements','contract','index.html patched v2')
$$;

-- ---------------------------------------------------------------------
-- 3) Trigger ป้องกันข้อมูล (บังคับเฉพาะคำสั่งที่มาจากเครื่องผู้ใช้ role=authenticated;
--    ฟังก์ชัน RPC รันด้วยเจ้าของฐานข้อมูลจึงไม่ถูกจำกัด)
-- ---------------------------------------------------------------------
create or replace function public.trg_touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists touch_products on public.products;
create trigger touch_products before update on public.products for each row execute function public.trg_touch_updated_at();

create or replace function public.trg_guard_app_users() returns trigger language plpgsql as $$
declare v_role text;
begin
  if current_user <> 'authenticated' then return new; end if;
  v_role := public.pos_current_role();
  if tg_op = 'INSERT' then
    if new.role = 'OWNER' and v_role is distinct from 'OWNER' then raise exception 'เฉพาะ OWNER เท่านั้นที่สร้าง OWNER ได้'; end if;
    new.auth_user_id := null;
  else
    new.auth_user_id := old.auth_user_id;
    if (old.role = 'OWNER' or new.role = 'OWNER') and v_role is distinct from 'OWNER' then raise exception 'เฉพาะ OWNER เท่านั้นที่แก้ไขบัญชี OWNER ได้'; end if;
    if old.role = 'OWNER' and (new.role <> 'OWNER' or new.is_active = false) then raise exception 'ห้ามลดสิทธิ์หรือปิดบัญชี OWNER'; end if;
  end if;
  return new;
end $$;
drop trigger if exists guard_app_users on public.app_users;
create trigger guard_app_users before insert or update on public.app_users for each row execute function public.trg_guard_app_users();

create or replace function public.trg_guard_shifts() returns trigger language plpgsql as $$
begin
  if current_user <> 'authenticated' then return new; end if;
  if tg_op = 'INSERT' then
    if new.opened_by is null or not exists (select 1 from public.app_users u where u.id = new.opened_by and u.is_active) then
      new.opened_by := public.pos_current_app_user_id();
    end if;
    new.expected_cash := null; new.cash_variance := null; new.closed_by := null; new.close_note := null;
    return new;
  end if;
  -- UPDATE จากเครื่อง: ห้ามเปลี่ยนอะไรเลย (ปิดกะต้องผ่าน close_shift เท่านั้น)
  return old;
end $$;
drop trigger if exists guard_shifts on public.shifts;
create trigger guard_shifts before insert or update on public.shifts for each row execute function public.trg_guard_shifts();

create or replace function public.trg_guard_cash_ledger() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if current_user = 'authenticated' then raise exception 'ห้ามลบรายการเงินสด'; end if;
    return old;
  end if;
  if current_user <> 'authenticated' then return new; end if;
  if tg_op = 'UPDATE' then return old; end if;            -- แก้ย้อนหลังไม่ได้ (upsert ซ้ำจึงไม่เปลี่ยนอะไร)
  if exists (select 1 from public.cash_ledger where id = new.id) then return new; end if;   -- ส่งซ้ำ: ไปทางเส้น update (ไม่เปลี่ยน)
  if new.income < 0 or new.expense < 0 or (new.income > 0 and new.expense > 0) then raise exception 'ยอดเงินสดไม่ถูกต้อง'; end if;
  if new.shift_id is not null and exists (select 1 from public.shifts where id = new.shift_id and status = 'CLOSED') then
    insert into public.audit_logs(action, entity_type, entity_id, details)
    values ('REJECTED_CASH_MOVEMENT_CLOSED_SHIFT', 'cash_ledger', new.id::text, jsonb_build_object('shift_id', new.shift_id, 'income', new.income, 'expense', new.expense, 'type', new.type));
    return null;                                           -- ข้ามแถว (ไม่ให้ทั้ง batch ล้ม) แต่บันทึกไว้ใน audit
  end if;
  new.created_by := public.pos_current_app_user_id();
  return new;
end $$;
drop trigger if exists guard_cash_ledger on public.cash_ledger;
create trigger guard_cash_ledger before insert or update or delete on public.cash_ledger for each row execute function public.trg_guard_cash_ledger();

create or replace function public.trg_guard_accounts_payable() returns trigger language plpgsql as $$
begin
  if current_user <> 'authenticated' then return new; end if;
  new.amount := old.amount; new.supplier_id := old.supplier_id; new.doc_ref := old.doc_ref;
  new.credit_terms := old.credit_terms; new.created_at := old.created_at;
  new.purchase_order_id := coalesce(old.purchase_order_id, new.purchase_order_id);
  if old.status = 'PAID' then new.status := 'PAID'; new.paid_at := old.paid_at; end if;
  if new.status = 'PAID' and old.status <> 'PAID' then new.paid_at := coalesce(new.paid_at, now()); end if;
  return new;
end $$;
drop trigger if exists guard_ap on public.accounts_payable;
create trigger guard_ap before update on public.accounts_payable for each row execute function public.trg_guard_accounts_payable();

create or replace function public.trg_ap_paid_record() returns trigger language plpgsql security definer set search_path = public, auth as $$
begin
  if new.status = 'PAID' and (tg_op = 'INSERT' or old.status <> 'PAID') then
    insert into public.supplier_payments(ap_id, supplier_id, amount, paid_at, paid_by)
    values (new.id, new.supplier_id, new.amount, coalesce(new.paid_at, now()), public.pos_current_app_user_id())
    on conflict (ap_id) do nothing;
  end if;
  return null;
end $$;
drop trigger if exists ap_paid_record on public.accounts_payable;
create trigger ap_paid_record after insert or update on public.accounts_payable for each row execute function public.trg_ap_paid_record();

create or replace function public.trg_audit_immutable() returns trigger language plpgsql as $$
begin raise exception 'audit_logs แก้ไขหรือลบไม่ได้'; end $$;
drop trigger if exists audit_immutable on public.audit_logs;
create trigger audit_immutable before update or delete on public.audit_logs for each row execute function public.trg_audit_immutable();

create or replace function public.trg_audit_actor() returns trigger language plpgsql as $$
begin
  if current_user = 'authenticated' then new.actor_user_id := coalesce(public.pos_current_app_user_id(), null); end if;
  return new;
end $$;
drop trigger if exists audit_actor on public.audit_logs;
create trigger audit_actor before insert on public.audit_logs for each row execute function public.trg_audit_actor();

-- ---------------------------------------------------------------------
-- 4) View ที่หน้าแอปเรียกใช้ + รายงานบัญชี
-- ---------------------------------------------------------------------
create or replace view public.product_variants_view with (security_invoker = true) as
  select v.* from public.product_variants v;

create or replace view public.v_daily_sales with (security_invoker = true) as
with s as (
  select (created_at at time zone 'Asia/Bangkok')::date as d,
         count(*) as bills, sum(subtotal) as gross, sum(discount_amount) as discounts,
         sum(total) as net_sales, sum(cogs_total) as cogs
  from public.bills group by 1),
r as (
  select (created_at at time zone 'Asia/Bangkok')::date as d,
         sum(total) as refunds, sum(cogs_total) as returned_cogs
  from public.returns group by 1)
select coalesce(s.d, r.d) as day,
       coalesce(s.bills,0) as bills, coalesce(s.gross,0) as gross_sales, coalesce(s.discounts,0) as discounts,
       coalesce(s.net_sales,0) as net_sales, coalesce(r.refunds,0) as refunds,
       coalesce(s.net_sales,0) - coalesce(r.refunds,0) as net_after_returns,
       coalesce(s.cogs,0) - coalesce(r.returned_cogs,0) as cogs,
       coalesce(s.net_sales,0) - coalesce(r.refunds,0) - (coalesce(s.cogs,0) - coalesce(r.returned_cogs,0)) as gross_profit
from s full join r on s.d = r.d;

create or replace view public.v_customer_ar with (security_invoker = true) as
select c.id as customer_id, c.name, c.phone, c.credit_limit, c.debt,
       (select max(created_at) from public.customer_ledger l where l.customer_id = c.id and l.entry_type = 'PAYMENT') as last_payment_at,
       (select min(created_at) from public.bills b where b.customer_id = c.id and b.status = 'CREDIT') as oldest_credit_bill_at
from public.customers c where c.debt > 0;

create or replace view public.v_ap_open with (security_invoker = true) as
select a.id, a.doc_ref, s.name as supplier, a.amount, a.credit_terms, a.created_at,
       (a.created_at + make_interval(days => coalesce(a.credit_terms,30)))::date as due_date
from public.accounts_payable a left join public.suppliers s on s.id = a.supplier_id where a.status = 'OPEN';

create or replace view public.v_stock_valuation with (security_invoker = true) as
select v.id as variant_id, p.name as product, v.variant_name, v.stock_quantity, v.cost_price,
       round(v.stock_quantity * v.cost_price, 2) as stock_value
from public.product_variants v join public.products p on p.id = v.product_id where v.is_active;

create or replace view public.v_shift_summary with (security_invoker = true) as
select sh.id as shift_id, sh.opened_at, sh.closed_at, sh.status, sh.opening_cash,
       coalesce(sum(cl.income),0) as cash_in, coalesce(sum(cl.expense),0) as cash_out,
       sh.opening_cash + coalesce(sum(cl.income),0) - coalesce(sum(cl.expense),0) as expected_now,
       sh.closing_cash, sh.expected_cash, sh.cash_variance, sh.close_note
from public.shifts sh left join public.cash_ledger cl on cl.shift_id = sh.id group by sh.id;

-- ---------------------------------------------------------------------
-- 5) RPC (ทุกฟังก์ชันตรวจว่าเป็นพนักงาน active ก่อน)
-- ---------------------------------------------------------------------
create or replace function public.bootstrap_first_owner(p_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'ต้องเข้าสู่ระบบ Supabase ก่อน'; end if;
  perform pg_advisory_xact_lock(hashtext('smartpos_bootstrap_owner'));
  select id into v_id from public.app_users where auth_user_id = auth.uid() and is_active;
  if v_id is not null then return jsonb_build_object('id', v_id, 'already_linked', true); end if;
  if exists (select 1 from public.app_users where role = 'OWNER') then raise exception 'มี OWNER อยู่แล้ว'; end if;
  if coalesce(trim(p_name), '') = '' or coalesce(p_pin, '') = '' then raise exception 'ต้องระบุชื่อและ PIN'; end if;
  insert into public.app_users(id, auth_user_id, name, pin, role, permissions, is_active)
  values (gen_random_uuid(), auth.uid(), trim(p_name), p_pin, 'OWNER', '["ALL"]'::jsonb, true) returning id into v_id;
  insert into public.audit_logs(actor_user_id, actor_name, action, entity_type, entity_id, details)
  values (v_id, trim(p_name), 'BOOTSTRAP_OWNER', 'app_users', v_id::text, '{}'::jsonb);
  return jsonb_build_object('id', v_id, 'already_linked', false);
end $$;

-- OWNER ผูกบัญชี Supabase อีกบัญชีเข้ากับพนักงาน (เช่น ผู้จัดการ หรือเครื่องหน้าร้านแยก)
create or replace function public.owner_link_auth_user(p_auth_user_id uuid, p_name text, p_role text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid;
begin
  if public.pos_current_role() is distinct from 'OWNER' then raise exception 'เฉพาะ OWNER เท่านั้น'; end if;
  if upper(coalesce(p_role,'')) not in ('MANAGER','CASHIER') then raise exception 'role ต้องเป็น MANAGER หรือ CASHIER'; end if;
  if not exists (select 1 from auth.users where id = p_auth_user_id) then raise exception 'ไม่พบผู้ใช้ใน Supabase Auth'; end if;
  insert into public.app_users(id, auth_user_id, name, pin, role, permissions, is_active)
  values (gen_random_uuid(), p_auth_user_id, trim(p_name), coalesce(nullif(p_pin,''), 'unset'), upper(p_role), '[]'::jsonb, true)
  on conflict (auth_user_id) do update set name = excluded.name, role = excluded.role, is_active = true
  returning id into v_id;
  perform public.pos_audit('LINK_AUTH_USER', 'app_users', v_id::text, jsonb_build_object('role', upper(p_role)));
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.seed_variant_stock(p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; v_id uuid; v_stock numeric; v_count int := 0; v_user uuid;
begin
  v_user := public.pos_require_staff();
  for x in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_id := (x->>'variant_id')::uuid; v_stock := greatest(coalesce((x->>'stock')::numeric, 0), 0);
    update public.product_variants set stock_quantity = v_stock, stock_seeded = true
    where id = v_id and not stock_seeded;
    if found then
      insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, ref_id, created_by)
      values (v_id, v_stock, 'ยอดยกมา', 'SEED', v_id, v_user);
      v_count := v_count + 1;
    elsif not exists (select 1 from public.product_variants where id = v_id) then
      raise exception 'ไม่พบรุ่นสินค้า % บนเซิร์ฟเวอร์ (ซิงค์สินค้าก่อน)', v_id;
    end if;
  end loop;
  return jsonb_build_object('seeded', v_count);
end $$;

create or replace function public.seed_customer_debt(p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; v_id uuid; v_debt numeric; v_count int := 0; v_user uuid;
begin
  v_user := public.pos_require_staff();
  for x in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_id := (x->>'customer_id')::uuid; v_debt := greatest(coalesce((x->>'debt')::numeric, 0), 0);
    update public.customers set debt = round(v_debt, 2), debt_seeded = true where id = v_id and not debt_seeded;
    if found then
      if v_debt > 0 then
        insert into public.customer_ledger(customer_id, entry_type, amount, balance_after, ref_type, created_by)
        values (v_id, 'OPENING', round(v_debt, 2), round(v_debt, 2), 'SEED', v_user);
      end if;
      v_count := v_count + 1;
    elsif not exists (select 1 from public.customers where id = v_id) then
      raise exception 'ไม่พบลูกค้า % บนเซิร์ฟเวอร์', v_id;
    end if;
  end loop;
  return jsonb_build_object('seeded', v_count);
end $$;

create or replace function public.adjust_stock(p_variant_id uuid, p_mode text, p_value numeric, p_reason text, p_op_ref text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_old numeric; v_new numeric; v_delta numeric; v_user uuid;
begin
  v_user := public.pos_require_staff();
  if p_value is null then raise exception 'ต้องระบุจำนวน'; end if;
  if p_op_ref is not null and exists (select 1 from public.inventory_movements where op_ref = p_op_ref) then
    return jsonb_build_object('duplicate', true);
  end if;
  select stock_quantity into v_old from public.product_variants where id = p_variant_id for update;
  if not found then raise exception 'ไม่พบรุ่นสินค้า'; end if;
  if upper(p_mode) = 'SET' then v_new := p_value;
  elsif upper(p_mode) = 'ADD' then v_new := v_old + p_value;
  elsif upper(p_mode) = 'SUBTRACT' then v_new := v_old - p_value;
  else raise exception 'p_mode ต้องเป็น SET, ADD หรือ SUBTRACT'; end if;
  if v_new < 0 then raise exception 'สต็อกต้องไม่ติดลบ'; end if;
  v_delta := v_new - v_old;
  update public.product_variants set stock_quantity = v_new, stock_seeded = true where id = p_variant_id;
  insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, op_ref, created_by)
  values (p_variant_id, v_delta, coalesce(nullif(p_reason, ''), 'ปรับสต็อก'), 'ADJUST', p_op_ref, v_user);
  perform public.pos_audit('ADJUST_STOCK', 'product_variants', p_variant_id::text,
    jsonb_build_object('old', v_old, 'new', v_new, 'reason', p_reason));
  return jsonb_build_object('variant_id', p_variant_id, 'old_stock', v_old, 'stock_quantity', v_new, 'change_qty', v_delta);
end $$;

create or replace function public.create_sale(
  p_bill_number text, p_customer_id uuid, p_user_id uuid, p_shift_id uuid,
  p_discount_amount numeric, p_tax_amount numeric, p_payment_method text, p_items jsonb,
  p_allow_negative boolean, p_tax_mode text, p_expected_total numeric default null,
  p_created_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid; v_user uuid; v_method text; v_is_credit boolean; v_bill_id uuid; v_exist record;
  x jsonb; v_subtotal numeric := 0; v_discount numeric; v_tax numeric; v_tax_mode text;
  v_calc numeric; v_total numeric; v_round numeric := 0; v_tol numeric; v_cogs numeric := 0;
  v_qty numeric; v_price numeric; v_variant uuid; v_fraction uuid; v_product uuid; v_name text;
  v_ratio numeric; v_stock_qty numeric; v_stock numeric; v_cost numeric; v_list numeric; v_line_cost numeric;
  v_debt numeric; v_limit numeric; v_new_debt numeric; v_created timestamptz; v_shift_status text; v_n int;
begin
  v_actor := public.pos_require_staff();
  if coalesce(trim(p_bill_number), '') = '' then raise exception 'ต้องระบุเลขบิล'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'ไม่มีรายการสินค้า'; end if;

  select id into v_user from public.app_users where id = p_user_id and is_active;
  v_user := coalesce(v_user, v_actor);

  v_method := upper(trim(coalesce(p_payment_method, 'CASH')));
  v_method := case v_method when 'เงินสด' then 'CASH' when 'เครดิต' then 'CREDIT' when 'ON_CREDIT' then 'CREDIT'
                            when 'โอน' then 'TRANSFER' when 'โอนเงิน' then 'TRANSFER' else v_method end;
  v_is_credit := (v_method = 'CREDIT');

  -- กันบิลซ้ำ: เลขเดียวกัน + รายการเท่ากัน = ส่งซ้ำ; เลขเดียวกันแต่ต่างกัน = เลขบิลชนกัน (แจ้ง error ไม่ทิ้งเงียบ)
  select id, total into v_exist from public.bills where bill_number = p_bill_number;
  if found then
    select count(*) into v_n from public.bill_items where bill_id = v_exist.id;
    if v_n <> jsonb_array_length(p_items) or abs(v_exist.total - coalesce(p_expected_total, v_exist.total)) > 0.05 then
      raise exception 'เลขบิล % ซ้ำกับบิลอื่นที่มีรายการต่างกัน (เครื่องออกเลขบิลชนกัน)', p_bill_number;
    end if;
    return jsonb_build_object('bill_id', v_exist.id, 'total', v_exist.total, 'duplicate', true);
  end if;

  v_created := case when p_created_at is null or p_created_at > now() + interval '10 minutes'
                      or p_created_at < now() - interval '400 days' then now() else p_created_at end;

  if p_shift_id is not null then
    select status into v_shift_status from public.shifts where id = p_shift_id;
    if not found then raise exception 'ไม่พบกะ %', p_shift_id; end if;
    if v_shift_status <> 'OPEN' then raise exception 'กะนี้ปิดแล้ว ไม่สามารถบันทึกบิล % เข้ากะนี้ได้', p_bill_number; end if;
  end if;

  -- ล็อกรุ่นสินค้าตามลำดับ id กัน deadlock เมื่อขายพร้อมกันหลายเครื่อง
  perform 1 from public.product_variants
  where id in (select nullif(e->>'variant_id', '')::uuid from jsonb_array_elements(p_items) e where nullif(e->>'variant_id', '') is not null)
  order by id for update;

  for x in select value from jsonb_array_elements(p_items) loop
    v_qty := coalesce((x->>'quantity')::numeric, 0); v_price := coalesce((x->>'unit_price')::numeric, 0);
    if v_qty <= 0 or v_price < 0 then raise exception 'จำนวนหรือราคาสินค้าไม่ถูกต้อง'; end if;
    v_subtotal := v_subtotal + round(v_qty * v_price, 2);
  end loop;

  v_discount := least(greatest(coalesce(p_discount_amount, 0), 0), v_subtotal);
  v_tax_mode := upper(coalesce(nullif(p_tax_mode, ''), 'NONE'));
  if v_tax_mode not in ('NONE', 'INCLUDED', 'EXCLUDED') then raise exception 'tax_mode ไม่ถูกต้อง: %', p_tax_mode; end if;
  v_tax := case when v_tax_mode = 'NONE' then 0 else greatest(coalesce(p_tax_amount, 0), 0) end;
  v_calc := round(v_subtotal - v_discount + case when v_tax_mode = 'EXCLUDED' then v_tax else 0 end, 2);
  v_total := v_calc;
  v_tol := greatest(0.02, 0.01 * jsonb_array_length(p_items));
  if p_expected_total is not null then
    if abs(v_calc - p_expected_total) > v_tol then
      raise exception 'ยอดบิลไม่ตรง: เซิร์ฟเวอร์คำนวณได้ %, หน้า POS ส่ง %', v_calc, p_expected_total;
    end if;
    v_total := round(p_expected_total, 2);            -- ยอดที่เก็บเงินจริง; ส่วนต่างเก็บเป็นเศษปัด
    v_round := round(v_total - v_calc, 2);
  end if;

  if v_is_credit then
    if p_customer_id is null then raise exception 'ขายเชื่อต้องระบุลูกค้า'; end if;
    select debt, credit_limit into v_debt, v_limit from public.customers where id = p_customer_id and is_active for update;
    if not found then raise exception 'ไม่พบลูกค้า'; end if;
    if v_debt + v_total > v_limit then raise exception 'ยอดหนี้เกินวงเงินลูกค้า (หนี้ % + บิล % > วงเงิน %)', v_debt, v_total, v_limit; end if;
  elsif p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'ไม่พบลูกค้า';
  end if;

  insert into public.bills(bill_number, customer_id, user_id, shift_id, subtotal, discount_amount, tax_amount, rounding_amount,
                           total, payment_method, status, tax_mode, created_at)
  values (p_bill_number, p_customer_id, v_user, p_shift_id, v_subtotal, v_discount, v_tax, v_round,
          v_total, v_method, case when v_is_credit then 'CREDIT' else 'PAID' end, v_tax_mode, v_created)
  returning id into v_bill_id;

  for x in select value from jsonb_array_elements(p_items) loop
    v_product := nullif(x->>'product_id', '')::uuid; v_variant := nullif(x->>'variant_id', '')::uuid;
    v_fraction := nullif(x->>'fraction_id', '')::uuid;
    v_qty := (x->>'quantity')::numeric; v_price := (x->>'unit_price')::numeric;
    v_name := coalesce(nullif(x->>'item_name', ''), 'สินค้า');
    v_stock_qty := v_qty; v_line_cost := 0; v_list := null;
    if v_variant is not null then
      select stock_quantity, cost_price, price into v_stock, v_cost, v_list from public.product_variants where id = v_variant;
      if not found then raise exception 'ไม่พบรุ่นสินค้า %', v_variant; end if;
      if v_fraction is not null then
        select quantity_ratio, price into v_ratio, v_list from public.product_fractions where id = v_fraction and variant_id = v_variant;
        if not found then raise exception 'ไม่พบหน่วยย่อยสินค้า %', v_fraction; end if;
        v_stock_qty := v_qty / v_ratio;
      end if;
      if not coalesce(p_allow_negative, false) and v_stock < v_stock_qty then
        raise exception 'สต็อกไม่พอสำหรับ % (เหลือ %)', v_name, v_stock;
      end if;
      update public.product_variants set stock_quantity = stock_quantity - v_stock_qty where id = v_variant;
      insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, ref_id, created_at, created_by)
      values (v_variant, -v_stock_qty, 'ขายสินค้า', 'SALE', v_bill_id, v_created, v_user);
      v_line_cost := round(v_cost * v_stock_qty, 4);
    end if;
    insert into public.bill_items(bill_id, product_id, variant_id, fraction_id, item_name, quantity, unit_price, list_price,
                                  line_total, line_cost, stock_quantity_delta)
    values (v_bill_id, v_product, v_variant, v_fraction, v_name, v_qty, v_price, v_list,
            round(v_qty * v_price, 2), v_line_cost, case when v_variant is not null then v_stock_qty else 0 end);
    v_cogs := v_cogs + v_line_cost;
  end loop;
  update public.bills set cogs_total = round(v_cogs, 2) where id = v_bill_id;

  if v_is_credit then
    update public.customers set debt = debt + v_total where id = p_customer_id returning debt into v_new_debt;
    insert into public.customer_ledger(customer_id, entry_type, amount, balance_after, ref_type, ref_id, created_at, created_by)
    values (p_customer_id, 'SALE', v_total, v_new_debt, 'BILL', v_bill_id::text, v_created, v_user);
  else
    insert into public.payments(bill_id, method, amount, created_at) values (v_bill_id, v_method, v_total, v_created);
    if v_method = 'CASH' then
      insert into public.cash_ledger(shift_id, type, income, description, ref_id, payment_method, created_at, created_by)
      values (p_shift_id, 'SALE', v_total, 'รับเงินขายสินค้า ' || p_bill_number, v_bill_id::text, 'CASH', v_created, v_user);
    end if;
  end if;

  perform public.pos_audit('CREATE_SALE', 'bills', v_bill_id::text,
    jsonb_build_object('bill_number', p_bill_number, 'total', v_total, 'method', v_method, 'items', jsonb_array_length(p_items), 'cashier', v_user));
  return jsonb_build_object('bill_id', v_bill_id, 'bill_number', p_bill_number, 'subtotal', v_subtotal, 'total', v_total, 'stock_updated', true);
end $$;

create or replace function public.process_return(p_bill_id uuid, p_items jsonb, p_full_return boolean,
  p_return_ref text default null, p_shift_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid; v_bill record; v_return_id uuid; v_dup record; x jsonb; bi record;
  v_ratio numeric; v_need numeric; v_take numeric; v_req_qty numeric; v_req_price numeric;
  v_variant uuid; v_fraction uuid; v_refund numeric := 0; v_line_refund numeric; v_cogs numeric := 0;
  v_line_cost numeric; v_stock_back numeric; v_shift_status text; v_debt numeric; v_debt_cut numeric := 0;
  v_cash_out numeric := 0; v_all_returned boolean; v_prev numeric; v_new_debt numeric; v_method text;
begin
  v_actor := public.pos_require_staff();
  if p_return_ref is not null then
    select id, total into v_dup from public.returns where return_ref = p_return_ref;
    if found then return jsonb_build_object('return_id', v_dup.id, 'total', v_dup.total, 'duplicate', true); end if;
  end if;
  select * into v_bill from public.bills where id = p_bill_id for update;
  if not found then raise exception 'ไม่พบบิลต้นทาง'; end if;
  if v_bill.status = 'CANCELLED' then raise exception 'บิลนี้ถูกคืน/ยกเลิกครบแล้ว'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'ไม่มีรายการคืนสินค้า'; end if;
  if p_shift_id is not null then
    select status into v_shift_status from public.shifts where id = p_shift_id;
    if not found then raise exception 'ไม่พบกะ'; end if;
    if v_shift_status <> 'OPEN' then raise exception 'กะปิดแล้ว ไม่สามารถบันทึกการคืนเงินเข้ากะนี้ได้'; end if;
  end if;

  -- สัดส่วนส่วนลดของบิล: คืนสินค้าได้เงินเท่าที่ลูกค้าจ่ายจริงต่อชิ้น (ไม่เชื่อราคาที่เครื่องส่งมา)
  v_ratio := case when v_bill.subtotal > 0 then (v_bill.subtotal - v_bill.discount_amount) / v_bill.subtotal else 1 end;
  v_method := upper(v_bill.payment_method);

  insert into public.returns(bill_id, return_ref, shift_id, total, full_return, refund_method, created_by)
  values (p_bill_id, p_return_ref, p_shift_id, 0, false, v_method, v_actor) returning id into v_return_id;

  for x in select value from jsonb_array_elements(p_items) loop
    v_variant := nullif(x->>'variant_id', '')::uuid; v_fraction := nullif(x->>'fraction_id', '')::uuid;
    v_req_qty := coalesce((x->>'quantity')::numeric, 0); v_req_price := coalesce((x->>'unit_price')::numeric, 0);
    if v_req_qty <= 0 then raise exception 'จำนวนคืนต้องมากกว่า 0'; end if;
    v_need := v_req_qty;
    for bi in
      select * from public.bill_items
      where bill_id = p_bill_id and quantity - returned_qty > 0.000001
        and ((v_variant is not null and variant_id = v_variant and fraction_id is not distinct from v_fraction)
          or (v_variant is null and variant_id is null))
      order by id for update
    loop
      exit when v_need <= 0.000001;
      v_take := least(v_need, bi.quantity - bi.returned_qty);
      v_line_refund := round(v_take * bi.unit_price * v_ratio, 2);
      v_stock_back := case when bi.quantity > 0 then bi.stock_quantity_delta * v_take / bi.quantity else 0 end;
      v_line_cost := case when bi.quantity > 0 then round(bi.line_cost * v_take / bi.quantity, 4) else 0 end;
      update public.bill_items set returned_qty = returned_qty + v_take where id = bi.id;
      if bi.variant_id is not null and v_stock_back <> 0 then
        update public.product_variants set stock_quantity = stock_quantity + v_stock_back where id = bi.variant_id;
        insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, ref_id, created_by)
        values (bi.variant_id, v_stock_back, 'คืนสินค้า', 'RETURN', v_return_id, v_actor);
      end if;
      insert into public.return_items(return_id, bill_item_id, variant_id, fraction_id, quantity, unit_price, line_total, line_cost, stock_quantity_delta)
      values (v_return_id, bi.id, bi.variant_id, bi.fraction_id, v_take, round(bi.unit_price * v_ratio, 4), v_line_refund, v_line_cost, v_stock_back);
      v_refund := v_refund + v_line_refund; v_cogs := v_cogs + v_line_cost; v_need := v_need - v_take;
    end loop;
    if v_need > 0.000001 then raise exception 'จำนวนคืนเกินจำนวนที่ขาย'; end if;
  end loop;

  select not exists (select 1 from public.bill_items where bill_id = p_bill_id and quantity - returned_qty > 0.000001) into v_all_returned;
  if v_all_returned then      -- คืนครบทั้งบิล: ปิดเศษสตางค์ให้รวมเท่ากับยอดบิลพอดี
    select coalesce(sum(total), 0) into v_prev from public.returns where bill_id = p_bill_id and id <> v_return_id;
    v_refund := round(v_bill.total - v_prev, 2);
  end if;
  if v_refund < 0 then v_refund := 0; end if;

  if v_method = 'CREDIT' then            -- บิลเชื่อ: ลดหนี้ก่อน ส่วนที่เกินหนี้ (ลูกค้าจ่ายไปแล้ว) คืนเป็นเงินสด
    select debt into v_debt from public.customers where id = v_bill.customer_id for update;
    v_debt_cut := least(v_refund, coalesce(v_debt, 0));
    if v_debt_cut > 0 then
      update public.customers set debt = debt - v_debt_cut where id = v_bill.customer_id returning debt into v_new_debt;
      insert into public.customer_ledger(customer_id, entry_type, amount, balance_after, ref_type, ref_id, created_by)
      values (v_bill.customer_id, 'RETURN', -v_debt_cut, v_new_debt, 'RETURN', v_return_id::text, v_actor);
    end if;
    v_cash_out := v_refund - v_debt_cut;
  elsif v_method = 'CASH' then
    v_cash_out := v_refund;
  elsif v_refund > 0 then                -- โอน/QR/บัตร: คืนนอกลิ้นชัก ไม่กระทบเงินสดในกะ
    insert into public.payments(bill_id, method, amount, reference) values (p_bill_id, v_method, -v_refund, 'REFUND ' || v_return_id::text);
  end if;
  if v_cash_out > 0 then
    insert into public.cash_ledger(shift_id, type, expense, description, ref_id, payment_method, created_by)
    values (p_shift_id, 'RETURN', v_cash_out, 'คืนเงินลูกค้า บิล ' || v_bill.bill_number, v_return_id::text, 'CASH', v_actor);
  end if;

  update public.returns set total = v_refund, cogs_total = round(v_cogs, 2), full_return = (v_all_returned or coalesce(p_full_return, false))
  where id = v_return_id;
  if v_all_returned then update public.bills set status = 'CANCELLED' where id = p_bill_id; end if;

  perform public.pos_audit('PROCESS_RETURN', 'returns', v_return_id::text,
    jsonb_build_object('bill_number', v_bill.bill_number, 'total', v_refund, 'debt_reduced', v_debt_cut, 'cash_out', v_cash_out));
  return jsonb_build_object('return_id', v_return_id, 'total', v_refund, 'debt_reduced', v_debt_cut, 'cash_refunded', v_cash_out, 'stock_restored', true);
end $$;

create or replace function public.receive_customer_payment(p_customer_id uuid, p_amount numeric, p_shift_id uuid,
  p_op_ref text default null, p_payment_method text default 'CASH', p_reference text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor uuid; v_id uuid; v_debt numeric; v_new_debt numeric; v_method text; v_status text;
begin
  v_actor := public.pos_require_staff();
  if p_amount is null or p_amount <= 0 then raise exception 'ยอดรับชำระต้องมากกว่า 0'; end if;
  if p_op_ref is not null then
    select id into v_id from public.customer_payments where op_ref = p_op_ref;
    if v_id is not null then return jsonb_build_object('payment_id', v_id, 'duplicate', true); end if;
  end if;
  v_method := upper(trim(coalesce(p_payment_method, 'CASH')));
  if v_method = 'เงินสด' then v_method := 'CASH'; end if;
  select debt into v_debt from public.customers where id = p_customer_id for update;
  if not found then raise exception 'ไม่พบลูกค้า'; end if;
  if round(p_amount, 2) > round(v_debt, 2) then raise exception 'ยอดรับชำระ % เกินยอดหนี้ค้าง %', p_amount, v_debt; end if;
  if v_method = 'CASH' and p_shift_id is not null then
    select status into v_status from public.shifts where id = p_shift_id;
    if not found then raise exception 'ไม่พบกะ'; end if;
    if v_status <> 'OPEN' then raise exception 'กะปิดแล้ว ไม่สามารถบันทึกรับเงินสดเข้ากะนี้ได้'; end if;
  end if;
  insert into public.customer_payments(customer_id, amount, shift_id, payment_method, reference, op_ref, received_by)
  values (p_customer_id, round(p_amount, 2), p_shift_id, v_method, p_reference, p_op_ref, v_actor) returning id into v_id;
  update public.customers set debt = debt - round(p_amount, 2) where id = p_customer_id returning debt into v_new_debt;
  insert into public.customer_ledger(customer_id, entry_type, amount, balance_after, ref_type, ref_id, created_by)
  values (p_customer_id, 'PAYMENT', -round(p_amount, 2), v_new_debt, 'PAYMENT', v_id::text, v_actor);
  if v_method = 'CASH' then
    insert into public.cash_ledger(shift_id, type, income, description, ref_id, payment_method, created_by)
    values (p_shift_id, 'CUSTOMER_PAYMENT', round(p_amount, 2), 'รับชำระหนี้ลูกค้า', v_id::text, 'CASH', v_actor);
  end if;
  perform public.pos_audit('CUSTOMER_PAYMENT', 'customer_payments', v_id::text,
    jsonb_build_object('customer_id', p_customer_id, 'amount', p_amount, 'method', v_method));
  return jsonb_build_object('payment_id', v_id, 'customer_id', p_customer_id, 'amount', p_amount, 'balance', v_new_debt);
end $$;

create or replace function public.receive_goods(p_client_ref text, p_supplier_id uuid, p_doc_ref text, p_terms integer,
  p_received_at timestamptz, p_items jsonb, p_ap_id uuid default null, p_pay_now boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor uuid; x jsonb; v_po uuid; v_ap uuid; v_variant uuid; v_product uuid; v_qty numeric; v_cost numeric; v_total numeric := 0;
begin
  v_actor := public.pos_require_staff();
  if p_client_ref is not null then
    select id into v_po from public.purchase_orders where client_ref = p_client_ref;
    if v_po is not null then
      select id into v_ap from public.accounts_payable where purchase_order_id = v_po;
      return jsonb_build_object('po_id', v_po, 'ap_id', v_ap, 'duplicate', true);
    end if;
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'ไม่มีรายการรับสินค้า'; end if;
  if p_supplier_id is not null and not exists (select 1 from public.suppliers where id = p_supplier_id) then raise exception 'ไม่พบผู้ขาย'; end if;

  insert into public.purchase_orders(client_ref, supplier_id, doc_ref, terms, received_at, created_by)
  values (p_client_ref, p_supplier_id, p_doc_ref, coalesce(p_terms, 30), coalesce(p_received_at, now()), v_actor) returning id into v_po;

  for x in select value from jsonb_array_elements(p_items) loop
    v_product := nullif(x->>'product_id', '')::uuid; v_variant := nullif(x->>'variant_id', '')::uuid;
    v_qty := coalesce((x->>'quantity')::numeric, 0); v_cost := coalesce((x->>'unit_cost')::numeric, 0);
    if v_qty <= 0 or v_cost < 0 then raise exception 'จำนวนหรือทุนรับสินค้าไม่ถูกต้อง'; end if;
    if v_variant is null then raise exception 'รายการรับสินค้าต้องระบุ variant_id'; end if;
    -- ต้นทุนถัวเฉลี่ยถ่วงน้ำหนัก (สูตรเดียวกับหน้าแอป): (สต็อกเดิม x ทุนเดิม + รับใหม่ x ทุนใหม่) / (สต็อกเดิม + รับใหม่)
    update public.product_variants set
      cost_price = case when v_cost <= 0 then cost_price
                        when stock_quantity > 0 then round((stock_quantity * cost_price + v_qty * v_cost) / (stock_quantity + v_qty), 2)
                        else v_cost end,
      stock_quantity = stock_quantity + v_qty
    where id = v_variant;
    if not found then raise exception 'ไม่พบรุ่นสินค้า %', v_variant; end if;
    insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, ref_id, created_by)
    values (v_variant, v_qty, 'รับสินค้าเข้าสต็อก', 'PURCHASE', v_po, v_actor);
    insert into public.purchase_order_items(purchase_order_id, product_id, variant_id, quantity, unit_cost, line_total)
    values (v_po, v_product, v_variant, v_qty, v_cost, round(v_qty * v_cost, 2));
    v_total := v_total + round(v_qty * v_cost, 2);
  end loop;
  update public.purchase_orders set total = v_total where id = v_po;

  insert into public.accounts_payable(id, supplier_id, purchase_order_id, doc_ref, amount, credit_terms, status, paid_at)
  values (coalesce(p_ap_id, gen_random_uuid()), p_supplier_id, v_po, p_doc_ref, v_total, coalesce(p_terms, 30),
          case when p_pay_now then 'PAID' else 'OPEN' end, case when p_pay_now then now() end)
  on conflict (id) do update set purchase_order_id = excluded.purchase_order_id, supplier_id = excluded.supplier_id,
    doc_ref = excluded.doc_ref, amount = excluded.amount, credit_terms = excluded.credit_terms
  returning id into v_ap;

  perform public.pos_audit('RECEIVE_GOODS', 'purchase_orders', v_po::text, jsonb_build_object('total', v_total, 'items', jsonb_array_length(p_items)));
  return jsonb_build_object('po_id', v_po, 'ap_id', v_ap, 'total', v_total);
end $$;

create or replace function public.close_shift(p_shift_id uuid, p_actual_cash numeric, p_close_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor uuid; v_opening numeric; v_in numeric; v_out numeric; v_expected numeric; v_var numeric;
begin
  v_actor := public.pos_require_staff();
  if p_actual_cash is null or p_actual_cash < 0 then raise exception 'ยอดเงินสดนับจริงไม่ถูกต้อง'; end if;
  select opening_cash into v_opening from public.shifts where id = p_shift_id and status = 'OPEN' for update;
  if not found then raise exception 'ไม่พบกะที่เปิดอยู่'; end if;
  select coalesce(sum(income), 0), coalesce(sum(expense), 0) into v_in, v_out from public.cash_ledger where shift_id = p_shift_id;
  v_expected := round(v_opening + v_in - v_out, 2);
  v_var := round(p_actual_cash - v_expected, 2);
  if v_var <> 0 and nullif(trim(coalesce(p_close_note, '')), '') is null then raise exception 'ยอดเงินสดไม่ตรง (ต่าง %) ต้องระบุสาเหตุ', v_var; end if;
  update public.shifts set status = 'CLOSED', closed_at = now(), closing_cash = round(p_actual_cash, 2), expected_cash = v_expected,
    cash_variance = v_var, close_note = p_close_note, closed_by = v_actor where id = p_shift_id;
  perform public.pos_audit('CLOSE_SHIFT', 'shifts', p_shift_id::text,
    jsonb_build_object('opening_cash', v_opening, 'cash_in', v_in, 'cash_out', v_out, 'expected_cash', v_expected,
                       'actual_cash', p_actual_cash, 'variance', v_var, 'note', p_close_note));
  return jsonb_build_object('shift_id', p_shift_id, 'opening_cash', v_opening, 'cash_in', v_in, 'cash_out', v_out,
                            'expected_cash', v_expected, 'actual_cash', p_actual_cash, 'variance', v_var, 'status', 'CLOSED');
end $$;

create or replace function public.delete_entity(p_kind text, p_id uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_table text; v_count int := 0; v_debt numeric;
begin
  perform public.pos_require_staff();
  v_table := case lower(p_kind) when 'product' then 'products' when 'customer' then 'customers'
                                when 'supplier' then 'suppliers' when 'category' then 'categories' else null end;
  if v_table is null then raise exception 'ไม่รองรับการลบชนิดข้อมูล %', p_kind; end if;
  if v_table = 'products' then
    update public.products set is_active = false where id = p_id;
    get diagnostics v_count = row_count;
    update public.product_variants set is_active = false where product_id = p_id;
  elsif v_table = 'customers' then
    select debt into v_debt from public.customers where id = p_id;
    if not found then raise exception 'ไม่พบลูกค้า'; end if;
    if v_debt > 0 then raise exception 'ลูกค้ายังมียอดหนี้ค้าง % บาท ลบไม่ได้ (รับชำระให้ครบก่อน)', v_debt; end if;
    update public.customers set is_active = false where id = p_id;
    get diagnostics v_count = row_count;
  elsif v_table = 'suppliers' then
    update public.suppliers set is_active = false where id = p_id;
    get diagnostics v_count = row_count;
  else
    delete from public.categories where id = p_id;
    get diagnostics v_count = row_count;
  end if;
  if v_count = 0 then raise exception 'ไม่พบข้อมูลที่จะลบ'; end if;
  perform public.pos_audit('DELETE_ENTITY', v_table, p_id::text, jsonb_build_object('note', p_note));
  return jsonb_build_object('kind', v_table, 'id', p_id, 'affected', v_count);
end $$;

-- ---------------------------------------------------------------------
-- 6) สิทธิ์ (GRANT) และ RLS
-- ---------------------------------------------------------------------
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
grant usage on schema public to authenticated;

-- อ่านได้ (ผ่าน RLS ต่อ)
grant select on all tables in schema public to authenticated;

-- เขียนตรงได้เฉพาะคอลัมน์ที่จำเป็น (ยอดสต็อก/หนี้/ปิดกะ ห้ามเขียนตรง)
grant insert (id,name,icon,color,display_order), update (id,name,icon,color,display_order) on public.categories to authenticated;
grant insert (id,sku,name,image_url,min_stock_alert,is_active,group_name,display_order), update (id,sku,name,image_url,min_stock_alert,is_active,group_name,display_order) on public.products to authenticated;
grant insert (product_id,category_id), update (product_id,category_id) on public.product_categories to authenticated;
grant delete on public.product_categories to authenticated;
grant delete on public.products to authenticated;
grant insert (id,product_id,variant_name,barcode,sku,image_url,price,cost_price,min_stock,is_active), update (id,product_id,variant_name,barcode,sku,image_url,price,cost_price,min_stock,is_active) on public.product_variants to authenticated;
grant insert (id,variant_id,fraction_name,quantity_ratio,price,barcode), update (id,variant_id,fraction_name,quantity_ratio,price,barcode) on public.product_fractions to authenticated;
grant insert (id,name,phone,address,credit_limit,is_active), update (id,name,phone,address,credit_limit,is_active) on public.customers to authenticated;
grant insert (id,name,phone,address,is_active), update (id,name,phone,address,is_active) on public.suppliers to authenticated;
grant insert (id,opened_at,closed_at,opening_cash,closing_cash,status,opened_by), update (id,opened_at,closed_at,opening_cash,closing_cash,status,opened_by) on public.shifts to authenticated;
grant insert (id,shift_id,type,income,expense,description,ref_id,created_at,payment_method), update (id,shift_id,type,income,expense,description,ref_id,created_at,payment_method) on public.cash_ledger to authenticated;
grant insert (id,supplier_id,purchase_order_id,doc_ref,amount,credit_terms,status,created_at,paid_at), update (id,supplier_id,purchase_order_id,doc_ref,amount,credit_terms,status,created_at,paid_at) on public.accounts_payable to authenticated;
grant insert (id,name,pin,role,permissions,is_active), update (id,name,pin,role,permissions,is_active) on public.app_users to authenticated;
grant insert (id,actor_user_id,actor_name,action,entity_type,entity_id,details,created_at) on public.audit_logs to authenticated;
grant insert (id,shop_name,phone,tax_id,address,vat_registered,vat_rate,updated_at), update (id,shop_name,phone,tax_id,address,vat_registered,vat_rate,updated_at) on public.shop_settings to authenticated;

-- ฟังก์ชันที่เรียกจากหน้าแอป / ใช้ใน policy
grant execute on function public.pos_current_app_user_id(), public.pos_current_role(), public.pos_is_staff(), public.pos_is_manager(), public.pos_schema_version() to authenticated;
grant execute on function public.bootstrap_first_owner(text,text) to authenticated;
grant execute on function public.owner_link_auth_user(uuid,text,text,text) to authenticated;
grant execute on function public.seed_variant_stock(jsonb) to authenticated;
grant execute on function public.seed_customer_debt(jsonb) to authenticated;
grant execute on function public.adjust_stock(uuid,text,numeric,text,text) to authenticated;
grant execute on function public.create_sale(text,uuid,uuid,uuid,numeric,numeric,text,jsonb,boolean,text,numeric,timestamptz) to authenticated;
grant execute on function public.process_return(uuid,jsonb,boolean,text,uuid) to authenticated;
grant execute on function public.receive_customer_payment(uuid,numeric,uuid,text,text,text) to authenticated;
grant execute on function public.receive_goods(text,uuid,text,integer,timestamptz,jsonb,uuid,boolean) to authenticated;
grant execute on function public.close_shift(uuid,numeric,text) to authenticated;
grant execute on function public.delete_entity(text,uuid,text) to authenticated;

-- RLS
do $$
declare t text;
begin
  foreach t in array array['shop_settings','app_users','categories','products','product_categories','product_variants','product_fractions',
    'customers','customer_ledger','suppliers','shifts','bills','bill_items','payments','inventory_movements','cash_ledger',
    'customer_payments','returns','return_items','purchase_orders','purchase_order_items','accounts_payable','supplier_payments',
    'income_expenses','audit_logs'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;

  -- อ่าน: พนักงาน active ทุกคน (ยกเว้น app_users / audit_logs ที่จำกัดกว่า)
  foreach t in array array['shop_settings','categories','products','product_categories','product_variants','product_fractions',
    'customers','customer_ledger','suppliers','shifts','bills','bill_items','payments','inventory_movements','cash_ledger',
    'customer_payments','returns','return_items','purchase_orders','purchase_order_items','accounts_payable','supplier_payments','income_expenses'] loop
    execute format('drop policy if exists staff_select on public.%I', t);
    execute format('create policy staff_select on public.%I for select to authenticated using ((select public.pos_is_staff()))', t);
  end loop;

  -- เขียนตรง: ตารางแคตตาล็อก/ลูกค้า/ผู้ขาย/กะ/เจ้าหนี้ (คอลัมน์ถูกจำกัดด้วย GRANT + trigger แล้ว)
  foreach t in array array['categories','products','product_categories','product_variants','product_fractions','customers','suppliers','shifts','accounts_payable'] loop
    execute format('drop policy if exists staff_insert on public.%I', t);
    execute format('create policy staff_insert on public.%I for insert to authenticated with check ((select public.pos_is_staff()))', t);
    execute format('drop policy if exists staff_update on public.%I', t);
    execute format('create policy staff_update on public.%I for update to authenticated using ((select public.pos_is_staff())) with check ((select public.pos_is_staff()))', t);
  end loop;
end $$;

drop policy if exists staff_delete on public.products;
create policy staff_delete on public.products for delete to authenticated using ((select public.pos_is_staff()));
drop policy if exists staff_delete on public.product_categories;
create policy staff_delete on public.product_categories for delete to authenticated using ((select public.pos_is_staff()));

-- cash_ledger: เครื่องเพิ่มได้เฉพาะ เงินเข้า/ออกลิ้นชักระหว่างกะ (ยอดขาย/คืน/รับชำระ มาจาก RPC เท่านั้น)
drop policy if exists shift_cash_insert on public.cash_ledger;
create policy shift_cash_insert on public.cash_ledger for insert to authenticated
  with check ((select public.pos_is_staff()) and type in ('SHIFT_CASH_IN','SHIFT_CASH_OUT'));
drop policy if exists shift_cash_update on public.cash_ledger;
create policy shift_cash_update on public.cash_ledger for update to authenticated
  using ((select public.pos_is_staff()) and type in ('SHIFT_CASH_IN','SHIFT_CASH_OUT'))
  with check ((select public.pos_is_staff()) and type in ('SHIFT_CASH_IN','SHIFT_CASH_OUT'));

-- app_users: เห็นเฉพาะแถวตัวเอง หรือถ้าเป็น OWNER/MANAGER เห็นทั้งหมด; เขียนได้เฉพาะ OWNER/MANAGER (trigger กันยกระดับสิทธิ์)
drop policy if exists users_select on public.app_users;
create policy users_select on public.app_users for select to authenticated using (auth_user_id = auth.uid() or (select public.pos_is_manager()));
drop policy if exists users_insert on public.app_users;
create policy users_insert on public.app_users for insert to authenticated with check ((select public.pos_is_manager()));
drop policy if exists users_update on public.app_users;
create policy users_update on public.app_users for update to authenticated using ((select public.pos_is_manager())) with check ((select public.pos_is_manager()));

-- audit_logs: เพิ่มได้ (พนักงาน) / อ่านได้เฉพาะ OWNER, MANAGER / แก้ลบไม่ได้ (trigger)
drop policy if exists audit_insert on public.audit_logs;
create policy audit_insert on public.audit_logs for insert to authenticated with check ((select public.pos_is_staff()));
drop policy if exists audit_select on public.audit_logs;
create policy audit_select on public.audit_logs for select to authenticated using ((select public.pos_is_manager()));

-- ตั้งค่าร้าน: แก้ได้เฉพาะ OWNER
drop policy if exists settings_insert on public.shop_settings;
create policy settings_insert on public.shop_settings for insert to authenticated with check (public.pos_current_role() = 'OWNER');
drop policy if exists settings_update on public.shop_settings;
create policy settings_update on public.shop_settings for update to authenticated using (public.pos_current_role() = 'OWNER') with check (public.pos_current_role() = 'OWNER');

grant select on public.product_variants_view, public.v_daily_sales, public.v_customer_ar, public.v_ap_open,
                public.v_stock_valuation, public.v_shift_summary to authenticated;

-- ---------------------------------------------------------------------
-- 7) Storage (ต้องรันด้วยสิทธิ์ postgres ใน SQL Editor)
--    product-images : public (แอปใช้ getPublicUrl)
--    delivery-notes : public ตามที่แอปใช้ getPublicUrl — ใครมีลิงก์เปิดได้ ห้ามอัปโหลดเอกสารที่เป็นความลับ
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('product-images', 'product-images', true, 10485760, array['image/jpeg','image/png','image/webp','image/gif']),
  ('delivery-notes', 'delivery-notes', true, 15728640, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists smartpos_storage_read_public on storage.objects;      -- ลบ policy เดิมที่เปิด list ให้คนนอก
drop policy if exists smartpos_storage_read_staff on storage.objects;
create policy smartpos_storage_read_staff on storage.objects for select to authenticated
  using (bucket_id in ('product-images','delivery-notes') and public.pos_is_staff());
drop policy if exists smartpos_storage_insert_authenticated on storage.objects;
drop policy if exists smartpos_storage_insert_staff on storage.objects;
create policy smartpos_storage_insert_staff on storage.objects for insert to authenticated
  with check (bucket_id in ('product-images','delivery-notes') and public.pos_is_staff());
drop policy if exists smartpos_storage_update_authenticated on storage.objects;
drop policy if exists smartpos_storage_update_staff on storage.objects;
create policy smartpos_storage_update_staff on storage.objects for update to authenticated
  using (bucket_id in ('product-images','delivery-notes') and public.pos_is_staff())
  with check (bucket_id in ('product-images','delivery-notes') and public.pos_is_staff());
drop policy if exists smartpos_storage_delete_authenticated on storage.objects;
drop policy if exists smartpos_storage_delete_staff on storage.objects;
create policy smartpos_storage_delete_staff on storage.objects for delete to authenticated
  using (bucket_id in ('product-images','delivery-notes') and public.pos_is_staff());

comment on schema public is 'Smart POS v2 — single shop; money/stock/debt change only through RPC';

-- ---------------------------------------------------------------------
-- ตรวจหลังติดตั้ง (รันแยกทีละบรรทัดได้)
--   select public.pos_schema_version();                         -- ต้องได้ version = smartpos-v2
--   select count(*) from public.app_users;                      -- 0 จนกว่าจะสมัครเจ้าของร้านจากหน้าแอป
--   select * from public.v_daily_sales order by day desc;       -- รายงานยอดขาย/กำไรขั้นต้นรายวัน
-- ---------------------------------------------------------------------


-- ######## แพตช์ 003: สิทธิ์ผู้จัดการ, การอนุมัติ, PIN ########
-- =====================================================================
-- SMART-POS PATCH 003: บังคับสิทธิ์ฝั่งเซิร์ฟเวอร์ + การอนุมัติโดยผู้จัดการ + PIN
-- รันหลัง SMART-POS-SETUP-v2.sql  (ทดสอบบน staging ก่อนเสมอ)
-- =====================================================================

create or replace function public.pos_require_manager() returns uuid
language plpgsql stable security definer set search_path = public, auth as $$
declare v uuid;
begin
  v := public.pos_require_staff();
  if not public.pos_is_manager() then
    raise exception 'ต้องเป็นผู้จัดการหรือ OWNER เท่านั้น' using errcode = '42501';
  end if;
  return v;
end $$;
-- ---- RPC ที่อ่อนไหว: เฉพาะผู้จัดการ ----
create or replace function public.adjust_stock(p_variant_id uuid, p_mode text, p_value numeric, p_reason text, p_op_ref text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_old numeric; v_new numeric; v_delta numeric; v_user uuid;
begin
  v_user := public.pos_require_manager();
  if p_value is null then raise exception 'ต้องระบุจำนวน'; end if;
  if p_op_ref is not null and exists (select 1 from public.inventory_movements where op_ref = p_op_ref) then
    return jsonb_build_object('duplicate', true);
  end if;
  select stock_quantity into v_old from public.product_variants where id = p_variant_id for update;
  if not found then raise exception 'ไม่พบรุ่นสินค้า'; end if;
  if upper(p_mode) = 'SET' then v_new := p_value;
  elsif upper(p_mode) = 'ADD' then v_new := v_old + p_value;
  elsif upper(p_mode) = 'SUBTRACT' then v_new := v_old - p_value;
  else raise exception 'p_mode ต้องเป็น SET, ADD หรือ SUBTRACT'; end if;
  if v_new < 0 then raise exception 'สต็อกต้องไม่ติดลบ'; end if;
  v_delta := v_new - v_old;
  update public.product_variants set stock_quantity = v_new, stock_seeded = true where id = p_variant_id;
  insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, op_ref, created_by)
  values (p_variant_id, v_delta, coalesce(nullif(p_reason, ''), 'ปรับสต็อก'), 'ADJUST', p_op_ref, v_user);
  perform public.pos_audit('ADJUST_STOCK', 'product_variants', p_variant_id::text,
    jsonb_build_object('old', v_old, 'new', v_new, 'reason', p_reason));
  return jsonb_build_object('variant_id', p_variant_id, 'old_stock', v_old, 'stock_quantity', v_new, 'change_qty', v_delta);
end $$;
create or replace function public.seed_variant_stock(p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; v_id uuid; v_stock numeric; v_count int := 0; v_user uuid;
begin
  v_user := public.pos_require_manager();
  for x in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_id := (x->>'variant_id')::uuid; v_stock := greatest(coalesce((x->>'stock')::numeric, 0), 0);
    update public.product_variants set stock_quantity = v_stock, stock_seeded = true
    where id = v_id and not stock_seeded;
    if found then
      insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, ref_id, created_by)
      values (v_id, v_stock, 'ยอดยกมา', 'SEED', v_id, v_user);
      v_count := v_count + 1;
    elsif not exists (select 1 from public.product_variants where id = v_id) then
      raise exception 'ไม่พบรุ่นสินค้า % บนเซิร์ฟเวอร์ (ซิงค์สินค้าก่อน)', v_id;
    end if;
  end loop;
  return jsonb_build_object('seeded', v_count);
end $$;
create or replace function public.seed_customer_debt(p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; v_id uuid; v_debt numeric; v_count int := 0; v_user uuid;
begin
  v_user := public.pos_require_manager();
  for x in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_id := (x->>'customer_id')::uuid; v_debt := greatest(coalesce((x->>'debt')::numeric, 0), 0);
    update public.customers set debt = round(v_debt, 2), debt_seeded = true where id = v_id and not debt_seeded;
    if found then
      if v_debt > 0 then
        insert into public.customer_ledger(customer_id, entry_type, amount, balance_after, ref_type, created_by)
        values (v_id, 'OPENING', round(v_debt, 2), round(v_debt, 2), 'SEED', v_user);
      end if;
      v_count := v_count + 1;
    elsif not exists (select 1 from public.customers where id = v_id) then
      raise exception 'ไม่พบลูกค้า % บนเซิร์ฟเวอร์', v_id;
    end if;
  end loop;
  return jsonb_build_object('seeded', v_count);
end $$;
create or replace function public.delete_entity(p_kind text, p_id uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_table text; v_count int := 0; v_debt numeric;
begin
  perform public.pos_require_manager();
  v_table := case lower(p_kind) when 'product' then 'products' when 'customer' then 'customers'
                                when 'supplier' then 'suppliers' when 'category' then 'categories' else null end;
  if v_table is null then raise exception 'ไม่รองรับการลบชนิดข้อมูล %', p_kind; end if;
  if v_table = 'products' then
    update public.products set is_active = false where id = p_id;
    get diagnostics v_count = row_count;
    update public.product_variants set is_active = false where product_id = p_id;
  elsif v_table = 'customers' then
    select debt into v_debt from public.customers where id = p_id;
    if not found then raise exception 'ไม่พบลูกค้า'; end if;
    if v_debt > 0 then raise exception 'ลูกค้ายังมียอดหนี้ค้าง % บาท ลบไม่ได้ (รับชำระให้ครบก่อน)', v_debt; end if;
    update public.customers set is_active = false where id = p_id;
    get diagnostics v_count = row_count;
  elsif v_table = 'suppliers' then
    update public.suppliers set is_active = false where id = p_id;
    get diagnostics v_count = row_count;
  else
    delete from public.categories where id = p_id;
    get diagnostics v_count = row_count;
  end if;
  if v_count = 0 then raise exception 'ไม่พบข้อมูลที่จะลบ'; end if;
  perform public.pos_audit('DELETE_ENTITY', v_table, p_id::text, jsonb_build_object('note', p_note));
  return jsonb_build_object('kind', v_table, 'id', p_id, 'affected', v_count);
end $$;
create or replace function public.receive_goods(p_client_ref text, p_supplier_id uuid, p_doc_ref text, p_terms integer,
  p_received_at timestamptz, p_items jsonb, p_ap_id uuid default null, p_pay_now boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor uuid; x jsonb; v_po uuid; v_ap uuid; v_variant uuid; v_product uuid; v_qty numeric; v_cost numeric; v_total numeric := 0;
begin
  v_actor := public.pos_require_manager();
  if p_client_ref is not null then
    select id into v_po from public.purchase_orders where client_ref = p_client_ref;
    if v_po is not null then
      select id into v_ap from public.accounts_payable where purchase_order_id = v_po;
      return jsonb_build_object('po_id', v_po, 'ap_id', v_ap, 'duplicate', true);
    end if;
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'ไม่มีรายการรับสินค้า'; end if;
  if p_supplier_id is not null and not exists (select 1 from public.suppliers where id = p_supplier_id) then raise exception 'ไม่พบผู้ขาย'; end if;

  insert into public.purchase_orders(client_ref, supplier_id, doc_ref, terms, received_at, created_by)
  values (p_client_ref, p_supplier_id, p_doc_ref, coalesce(p_terms, 30), coalesce(p_received_at, now()), v_actor) returning id into v_po;

  for x in select value from jsonb_array_elements(p_items) loop
    v_product := nullif(x->>'product_id', '')::uuid; v_variant := nullif(x->>'variant_id', '')::uuid;
    v_qty := coalesce((x->>'quantity')::numeric, 0); v_cost := coalesce((x->>'unit_cost')::numeric, 0);
    if v_qty <= 0 or v_cost < 0 then raise exception 'จำนวนหรือทุนรับสินค้าไม่ถูกต้อง'; end if;
    if v_variant is null then raise exception 'รายการรับสินค้าต้องระบุ variant_id'; end if;
    -- ต้นทุนถัวเฉลี่ยถ่วงน้ำหนัก (สูตรเดียวกับหน้าแอป): (สต็อกเดิม x ทุนเดิม + รับใหม่ x ทุนใหม่) / (สต็อกเดิม + รับใหม่)
    update public.product_variants set
      cost_price = case when v_cost <= 0 then cost_price
                        when stock_quantity > 0 then round((stock_quantity * cost_price + v_qty * v_cost) / (stock_quantity + v_qty), 2)
                        else v_cost end,
      stock_quantity = stock_quantity + v_qty
    where id = v_variant;
    if not found then raise exception 'ไม่พบรุ่นสินค้า %', v_variant; end if;
    insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, ref_id, created_by)
    values (v_variant, v_qty, 'รับสินค้าเข้าสต็อก', 'PURCHASE', v_po, v_actor);
    insert into public.purchase_order_items(purchase_order_id, product_id, variant_id, quantity, unit_cost, line_total)
    values (v_po, v_product, v_variant, v_qty, v_cost, round(v_qty * v_cost, 2));
    v_total := v_total + round(v_qty * v_cost, 2);
  end loop;
  update public.purchase_orders set total = v_total where id = v_po;

  insert into public.accounts_payable(id, supplier_id, purchase_order_id, doc_ref, amount, credit_terms, status, paid_at)
  values (coalesce(p_ap_id, gen_random_uuid()), p_supplier_id, v_po, p_doc_ref, v_total, coalesce(p_terms, 30),
          case when p_pay_now then 'PAID' else 'OPEN' end, case when p_pay_now then now() end)
  on conflict (id) do update set purchase_order_id = excluded.purchase_order_id, supplier_id = excluded.supplier_id,
    doc_ref = excluded.doc_ref, amount = excluded.amount, credit_terms = excluded.credit_terms
  returning id into v_ap;

  perform public.pos_audit('RECEIVE_GOODS', 'purchase_orders', v_po::text, jsonb_build_object('total', v_total, 'items', jsonb_array_length(p_items)));
  return jsonb_build_object('po_id', v_po, 'ap_id', v_ap, 'total', v_total);
end $$;

-- ---- PIN: hash ย้ายไปตารางที่พนักงานอ่านไม่ได้ ----
create table if not exists public.app_user_secrets (
  app_user_id uuid primary key references public.app_users(id) on delete cascade,
  pin_hash text not null,
  failed_count integer not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.app_user_secrets enable row level security;
revoke all on public.app_user_secrets from anon, authenticated;

create table if not exists public.manager_approvals (
  id uuid primary key default gen_random_uuid(),
  approver_id uuid not null references public.app_users(id),
  actions text[] not null,
  note text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '5 minutes',
  used_at timestamptz
);
alter table public.manager_approvals enable row level security;
revoke all on public.manager_approvals from anon, authenticated;

-- เมื่อมีการเขียน pin ใน app_users ให้เก็บ hash ไว้ในตารางความลับแล้วแทนที่ด้วยค่าคงที่
create or replace function public.trg_secret_pin() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.pin is distinct from 'secret' then
    insert into public.app_user_secrets(app_user_id, pin_hash) values (new.id, new.pin)
    on conflict (app_user_id) do update set pin_hash = excluded.pin_hash, failed_count = 0,
      locked_until = null, updated_at = now();
    update public.app_users set pin = 'secret' where id = new.id;
  end if;
  return null;
end $$;
drop trigger if exists secret_pin on public.app_users;
create trigger secret_pin after insert or update of pin on public.app_users
  for each row execute function public.trg_secret_pin();

-- ตรวจ PIN พร้อมล็อก 15 นาทีหลังผิด 5 ครั้ง
-- หมายเหตุ: ห้าม raise เมื่อ PIN ผิด เพราะจะ rollback ตัวนับความผิดพลาด
create or replace function public.pos_check_pin(p_app_user_id uuid, p_pin_hash text) returns boolean
language plpgsql security definer set search_path = public as $$
declare s record;
begin
  select * into s from public.app_user_secrets where app_user_id = p_app_user_id for update;
  if not found then return false; end if;
  if s.locked_until is not null and s.locked_until > now() then
    raise exception 'PIN ถูกล็อกชั่วคราว ลองใหม่อีกประมาณ % นาที',
      ceil(extract(epoch from (s.locked_until - now())) / 60);
  end if;
  if s.pin_hash = p_pin_hash then
    update public.app_user_secrets set failed_count = 0, locked_until = null, updated_at = now()
      where app_user_id = p_app_user_id;
    return true;
  end if;
  update public.app_user_secrets set
      failed_count = failed_count + 1,
      locked_until = case when failed_count + 1 >= 5 then now() + interval '15 minutes' end,
      updated_at = now()
    where app_user_id = p_app_user_id;
  return false;
end $$;

-- ผู้ใช้ดึง hash ของตัวเองเท่านั้น (ใช้ตอนล็อกอินบนเครื่องเพื่อให้ออฟไลน์ได้)
create or replace function public.get_my_pin_hash() returns text
language sql stable security definer set search_path = public, auth as $$
  select s.pin_hash from public.app_user_secrets s
  join public.app_users u on u.id = s.app_user_id
  where u.auth_user_id = auth.uid() and u.is_active limit 1
$$;

-- ตรวจ PIN ของผู้ใช้คนใดก็ได้ที่ระบุ (ใช้หน้าล็อกอิน)
create or replace function public.verify_pin(p_app_user_id uuid, p_pin_hash text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.pos_require_staff();
  return jsonb_build_object('ok', public.pos_check_pin(p_app_user_id, p_pin_hash));
end $$;

-- ---- การอนุมัติโดยผู้จัดการ (ใช้ PIN ผู้จัดการ ได้โทเค็นอายุ 5 นาที ใช้ซ้ำไม่ได้) ----
create or replace function public.manager_approve(p_app_user_id uuid, p_pin_hash text, p_actions text[], p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_role text; v_id uuid; v_ok boolean;
begin
  perform public.pos_require_staff();
  if p_actions is null or cardinality(p_actions) = 0
     or not (p_actions <@ array['NEGATIVE_STOCK','PRICE_BELOW_LIST','BACKDATE']) then
    raise exception 'ประเภทการอนุมัติไม่ถูกต้อง';
  end if;
  select role into v_role from public.app_users where id = p_app_user_id and is_active;
  if v_role is null or v_role not in ('OWNER','MANAGER') then
    return jsonb_build_object('ok', false, 'reason', 'ไม่ใช่ผู้จัดการ');
  end if;
  v_ok := public.pos_check_pin(p_app_user_id, p_pin_hash);
  if not v_ok then return jsonb_build_object('ok', false, 'reason', 'PIN ไม่ถูกต้อง'); end if;
  insert into public.manager_approvals(approver_id, actions, note)
  values (p_app_user_id, p_actions, p_note) returning id into v_id;
  perform public.pos_audit('MANAGER_APPROVE', 'manager_approvals', v_id::text,
    jsonb_build_object('actions', p_actions, 'note', p_note));
  return jsonb_build_object('ok', true, 'approval_id', v_id, 'expires_in_sec', 300);
end $$;

create or replace function public.pos_check_approval(p_token uuid, p_action text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if p_token is null or not exists (
    select 1 from public.manager_approvals a
    where a.id = p_token and a.used_at is null and a.expires_at > now() and p_action = any(a.actions)
  ) then
    raise exception 'ต้องให้ผู้จัดการอนุมัติก่อน (%)', p_action using errcode = 'P0001';
  end if;
end $$;

create or replace function public.pos_finish_approval(p_token uuid) returns void
language sql security definer set search_path = public as $$
  update public.manager_approvals set used_at = now() where id = p_token and used_at is null
$$;

-- ---- ราคา/ทุนแก้ได้เฉพาะผู้จัดการ (ใช้กับผู้ใช้ที่ล็อกอินผ่าน API เท่านั้น ฟังก์ชันภายในไม่ติด) ----
create or replace function public.trg_guard_price() returns trigger language plpgsql as $$
begin
  if current_user = 'authenticated'
     and (new.price is distinct from old.price or new.cost_price is distinct from old.cost_price)
     and not public.pos_is_manager() then
    raise exception 'เฉพาะผู้จัดการเท่านั้นที่แก้ราคาหรือทุนสินค้าได้';
  end if;
  return new;
end $$;
drop trigger if exists guard_variant_price on public.product_variants;
create trigger guard_variant_price before update on public.product_variants
  for each row execute function public.trg_guard_price();

create or replace function public.trg_guard_fraction_price() returns trigger language plpgsql as $$
begin
  if current_user = 'authenticated' and new.price is distinct from old.price and not public.pos_is_manager() then
    raise exception 'เฉพาะผู้จัดการเท่านั้นที่แก้ราคาหน่วยย่อยได้';
  end if;
  return new;
end $$;
drop trigger if exists guard_fraction_price on public.product_fractions;
create trigger guard_fraction_price before update on public.product_fractions
  for each row execute function public.trg_guard_fraction_price();
-- ---- ขาย: ตรวจราคา/สต็อกติดลบ/บิลย้อนหลังที่เซิร์ฟเวอร์ ----
drop function if exists public.create_sale(text,uuid,uuid,uuid,numeric,numeric,text,jsonb,boolean,text,numeric,timestamptz);
create or replace function public.create_sale(
  p_bill_number text, p_customer_id uuid, p_user_id uuid, p_shift_id uuid,
  p_discount_amount numeric, p_tax_amount numeric, p_payment_method text, p_items jsonb,
  p_allow_negative boolean, p_tax_mode text, p_expected_total numeric default null,
  p_created_at timestamptz default null,
  p_approval uuid default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid; v_user uuid; v_method text; v_is_credit boolean; v_bill_id uuid; v_exist record;
  x jsonb; v_subtotal numeric := 0; v_discount numeric; v_tax numeric; v_tax_mode text;
  v_calc numeric; v_total numeric; v_round numeric := 0; v_tol numeric; v_cogs numeric := 0;
  v_qty numeric; v_price numeric; v_variant uuid; v_fraction uuid; v_product uuid; v_name text;
  v_ratio numeric; v_stock_qty numeric; v_stock numeric; v_cost numeric; v_list numeric; v_line_cost numeric;
  v_debt numeric; v_limit numeric; v_new_debt numeric; v_created timestamptz; v_shift_status text; v_n int;
begin
  v_actor := public.pos_require_staff();
  if coalesce(trim(p_bill_number), '') = '' then raise exception 'ต้องระบุเลขบิล'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'ไม่มีรายการสินค้า'; end if;

  select id into v_user from public.app_users where id = p_user_id and is_active;
  v_user := coalesce(v_user, v_actor);

  v_method := upper(trim(coalesce(p_payment_method, 'CASH')));
  v_method := case v_method when 'เงินสด' then 'CASH' when 'เครดิต' then 'CREDIT' when 'ON_CREDIT' then 'CREDIT'
                            when 'โอน' then 'TRANSFER' when 'โอนเงิน' then 'TRANSFER' else v_method end;
  v_is_credit := (v_method = 'CREDIT');

  -- กันบิลซ้ำ: เลขเดียวกัน + รายการเท่ากัน = ส่งซ้ำ; เลขเดียวกันแต่ต่างกัน = เลขบิลชนกัน (แจ้ง error ไม่ทิ้งเงียบ)
  select id, total into v_exist from public.bills where bill_number = p_bill_number;
  if found then
    select count(*) into v_n from public.bill_items where bill_id = v_exist.id;
    if v_n <> jsonb_array_length(p_items) or abs(v_exist.total - coalesce(p_expected_total, v_exist.total)) > 0.05 then
      raise exception 'เลขบิล % ซ้ำกับบิลอื่นที่มีรายการต่างกัน (เครื่องออกเลขบิลชนกัน)', p_bill_number;
    end if;
    return jsonb_build_object('bill_id', v_exist.id, 'total', v_exist.total, 'duplicate', true);
  end if;

  v_created := case when p_created_at is null or p_created_at > now() + interval '10 minutes'
                      or p_created_at < now() - interval '400 days' then now() else p_created_at end;

  if p_created_at is not null and p_created_at < now() - interval '48 hours' then
    perform public.pos_check_approval(p_approval, 'BACKDATE');
  end if;

  if p_shift_id is not null then
    select status into v_shift_status from public.shifts where id = p_shift_id;
    if not found then raise exception 'ไม่พบกะ %', p_shift_id; end if;
    if v_shift_status <> 'OPEN' then raise exception 'กะนี้ปิดแล้ว ไม่สามารถบันทึกบิล % เข้ากะนี้ได้', p_bill_number; end if;
  end if;

  -- ล็อกรุ่นสินค้าตามลำดับ id กัน deadlock เมื่อขายพร้อมกันหลายเครื่อง
  perform 1 from public.product_variants
  where id in (select nullif(e->>'variant_id', '')::uuid from jsonb_array_elements(p_items) e where nullif(e->>'variant_id', '') is not null)
  order by id for update;

  for x in select value from jsonb_array_elements(p_items) loop
    v_qty := coalesce((x->>'quantity')::numeric, 0); v_price := coalesce((x->>'unit_price')::numeric, 0);
    if v_qty <= 0 or v_price < 0 then raise exception 'จำนวนหรือราคาสินค้าไม่ถูกต้อง'; end if;
    v_subtotal := v_subtotal + round(v_qty * v_price, 2);
  end loop;

  v_discount := least(greatest(coalesce(p_discount_amount, 0), 0), v_subtotal);
  v_tax_mode := upper(coalesce(nullif(p_tax_mode, ''), 'NONE'));
  if v_tax_mode not in ('NONE', 'INCLUDED', 'EXCLUDED') then raise exception 'tax_mode ไม่ถูกต้อง: %', p_tax_mode; end if;
  v_tax := case when v_tax_mode = 'NONE' then 0 else greatest(coalesce(p_tax_amount, 0), 0) end;
  v_calc := round(v_subtotal - v_discount + case when v_tax_mode = 'EXCLUDED' then v_tax else 0 end, 2);
  v_total := v_calc;
  v_tol := greatest(0.02, 0.01 * jsonb_array_length(p_items));
  if p_expected_total is not null then
    if abs(v_calc - p_expected_total) > v_tol then
      raise exception 'ยอดบิลไม่ตรง: เซิร์ฟเวอร์คำนวณได้ %, หน้า POS ส่ง %', v_calc, p_expected_total;
    end if;
    v_total := round(p_expected_total, 2);            -- ยอดที่เก็บเงินจริง; ส่วนต่างเก็บเป็นเศษปัด
    v_round := round(v_total - v_calc, 2);
  end if;

  if v_is_credit then
    if p_customer_id is null then raise exception 'ขายเชื่อต้องระบุลูกค้า'; end if;
    select debt, credit_limit into v_debt, v_limit from public.customers where id = p_customer_id and is_active for update;
    if not found then raise exception 'ไม่พบลูกค้า'; end if;
    if v_debt + v_total > v_limit then raise exception 'ยอดหนี้เกินวงเงินลูกค้า (หนี้ % + บิล % > วงเงิน %)', v_debt, v_total, v_limit; end if;
  elsif p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'ไม่พบลูกค้า';
  end if;

  insert into public.bills(bill_number, customer_id, user_id, shift_id, subtotal, discount_amount, tax_amount, rounding_amount,
                           total, payment_method, status, tax_mode, created_at)
  values (p_bill_number, p_customer_id, v_user, p_shift_id, v_subtotal, v_discount, v_tax, v_round,
          v_total, v_method, case when v_is_credit then 'CREDIT' else 'PAID' end, v_tax_mode, v_created)
  returning id into v_bill_id;

  for x in select value from jsonb_array_elements(p_items) loop
    v_product := nullif(x->>'product_id', '')::uuid; v_variant := nullif(x->>'variant_id', '')::uuid;
    v_fraction := nullif(x->>'fraction_id', '')::uuid;
    v_qty := (x->>'quantity')::numeric; v_price := (x->>'unit_price')::numeric;
    v_name := coalesce(nullif(x->>'item_name', ''), 'สินค้า');
    v_stock_qty := v_qty; v_line_cost := 0; v_list := null;
    if v_variant is not null then
      select stock_quantity, cost_price, price into v_stock, v_cost, v_list from public.product_variants where id = v_variant;
      if not found then raise exception 'ไม่พบรุ่นสินค้า %', v_variant; end if;
      if v_fraction is not null then
        select quantity_ratio, price into v_ratio, v_list from public.product_fractions where id = v_fraction and variant_id = v_variant;
        if not found then raise exception 'ไม่พบหน่วยย่อยสินค้า %', v_fraction; end if;
        v_stock_qty := v_qty / v_ratio;
      end if;
      if v_list is not null and v_list > 0 and v_price < v_list then
        perform public.pos_check_approval(p_approval, 'PRICE_BELOW_LIST');
      end if;
      if v_stock < v_stock_qty then
        if not coalesce(p_allow_negative, false) then
          raise exception 'สต็อกไม่พอสำหรับ % (เหลือ %)', v_name, v_stock;
        end if;
        perform public.pos_check_approval(p_approval, 'NEGATIVE_STOCK');
      end if;
      update public.product_variants set stock_quantity = stock_quantity - v_stock_qty where id = v_variant;
      insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, ref_id, created_at, created_by)
      values (v_variant, -v_stock_qty, 'ขายสินค้า', 'SALE', v_bill_id, v_created, v_user);
      v_line_cost := round(v_cost * v_stock_qty, 4);
    end if;
    insert into public.bill_items(bill_id, product_id, variant_id, fraction_id, item_name, quantity, unit_price, list_price,
                                  line_total, line_cost, stock_quantity_delta)
    values (v_bill_id, v_product, v_variant, v_fraction, v_name, v_qty, v_price, v_list,
            round(v_qty * v_price, 2), v_line_cost, case when v_variant is not null then v_stock_qty else 0 end);
    v_cogs := v_cogs + v_line_cost;
  end loop;
  update public.bills set cogs_total = round(v_cogs, 2) where id = v_bill_id;

  if v_is_credit then
    update public.customers set debt = debt + v_total where id = p_customer_id returning debt into v_new_debt;
    insert into public.customer_ledger(customer_id, entry_type, amount, balance_after, ref_type, ref_id, created_at, created_by)
    values (p_customer_id, 'SALE', v_total, v_new_debt, 'BILL', v_bill_id::text, v_created, v_user);
  else
    insert into public.payments(bill_id, method, amount, created_at) values (v_bill_id, v_method, v_total, v_created);
    if v_method = 'CASH' then
      insert into public.cash_ledger(shift_id, type, income, description, ref_id, payment_method, created_at, created_by)
      values (p_shift_id, 'SALE', v_total, 'รับเงินขายสินค้า ' || p_bill_number, v_bill_id::text, 'CASH', v_created, v_user);
    end if;
  end if;

  if p_approval is not null then perform public.pos_finish_approval(p_approval); end if;
  perform public.pos_audit('CREATE_SALE', 'bills', v_bill_id::text,
    jsonb_build_object('bill_number', p_bill_number, 'total', v_total, 'method', v_method, 'items', jsonb_array_length(p_items), 'cashier', v_user));
  return jsonb_build_object('bill_id', v_bill_id, 'bill_number', p_bill_number, 'subtotal', v_subtotal, 'total', v_total, 'stock_updated', true);
end $$;

-- ---- ย้าย PIN เดิมเข้าตารางความลับ ----
insert into public.app_user_secrets(app_user_id, pin_hash)
select id, pin from public.app_users where pin <> 'secret'
on conflict (app_user_id) do nothing;
update public.app_users set pin = 'secret' where pin <> 'secret';

-- ---- สิทธิ์: พนักงานอ่านคอลัมน์ pin ไม่ได้อีกต่อไป (รวมผู้จัดการ) ----
revoke select on public.app_users from authenticated;
grant select (id, auth_user_id, name, role, permissions, is_active, created_at) on public.app_users to authenticated;

-- ---- สิทธิ์เรียกฟังก์ชันใหม่ ----
grant execute on function public.pos_require_manager() to authenticated;
grant execute on function public.get_my_pin_hash() to authenticated;
grant execute on function public.verify_pin(uuid,text) to authenticated;
grant execute on function public.manager_approve(uuid,text,text[],text) to authenticated;
grant execute on function public.create_sale(text,uuid,uuid,uuid,numeric,numeric,text,jsonb,boolean,text,numeric,timestamptz,uuid) to authenticated;


-- ######## แพตช์ 004: เปิด/ปิดร้าน และจ่ายเจ้าหนี้เงินสด ########
-- =====================================================================
-- SMART-POS PATCH 004: เปิด/ปิดร้าน (แทนกะ) + จ่ายเจ้าหนี้เงินสดลงกะ
-- รันหลัง PATCH-003 (ทดสอบบน staging ก่อนเสมอ)
-- =====================================================================

alter table public.shop_settings
  add column if not exists business_open time not null default '08:00',
  add column if not exists business_close time not null default '20:00',
  add column if not exists timezone text not null default 'Asia/Bangkok',
  add column if not exists auto_open_enabled boolean not null default true,
  add column if not exists auto_close_enabled boolean not null default true,
  add column if not exists default_opening_cash numeric not null default 0 check (default_opening_cash >= 0);

-- ---- กะ: เก็บแหล่งที่มาการเปิด/ปิด และสถานะรอตรวจ ----
alter table public.shifts
  add column if not exists open_source text not null default 'MANUAL'
    check (open_source in ('MANUAL','AUTO_TRANSACTION','AUTO_SCHEDULE')),
  add column if not exists close_source text check (close_source in ('MANUAL','AUTO_SCHEDULE')),
  add column if not exists needs_review boolean not null default false,
  add column if not exists summary jsonb;

-- มีกะเปิดได้ไม่เกิน 1 กะในเวลาเดียว (กันการเปิดซ้อนจากหลายเครื่อง)
create unique index if not exists uq_one_open_shift on public.shifts((status)) where status = 'OPEN';

-- ---- ใครก็เปิดร้านได้ (พนักงาน) ใส่เงินทอนเริ่มต้น ----
create or replace function public.open_store(p_opening_cash numeric, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor uuid; v_id uuid; v_open record;
begin
  v_actor := public.pos_require_staff();
  if p_opening_cash is null or p_opening_cash < 0 then raise exception 'เงินทอนเริ่มต้นไม่ถูกต้อง'; end if;
  perform pg_advisory_xact_lock(hashtext('smartpos_store_open'));
  select * into v_open from public.shifts where status = 'OPEN' for update;
  if found then
    if v_open.needs_review and v_open.open_source <> 'MANUAL' then
      -- ร้านถูกเปิดอัตโนมัติไปก่อน: ยืนยันเงินทอนเริ่มต้นที่นับจริง
      update public.shifts set opening_cash = round(p_opening_cash, 2), needs_review = false,
        opened_by = v_actor where id = v_open.id;
      perform public.pos_audit('CONFIRM_OPENING_CASH', 'shifts', v_open.id::text,
        jsonb_build_object('opening_cash', p_opening_cash, 'note', p_note));
      return jsonb_build_object('shift_id', v_open.id, 'status', 'CONFIRMED', 'opening_cash', p_opening_cash);
    end if;
    return jsonb_build_object('shift_id', v_open.id, 'status', 'ALREADY_OPEN', 'opening_cash', v_open.opening_cash);
  end if;
  insert into public.shifts(id, opening_cash, status, opened_by, open_source, needs_review)
  values (gen_random_uuid(), round(p_opening_cash, 2), 'OPEN', v_actor, 'MANUAL', false)
  returning id into v_id;
  perform public.pos_audit('OPEN_STORE', 'shifts', v_id::text,
    jsonb_build_object('opening_cash', p_opening_cash, 'note', p_note));
  return jsonb_build_object('shift_id', v_id, 'status', 'OPENED', 'opening_cash', p_opening_cash);
end $$;

-- เปิดร้านอัตโนมัติเมื่อมีธุรกรรมแต่ยังไม่ได้เปิด (ใช้เงินทอนเริ่มต้นจากตั้งค่า และให้คนยืนยันภายหลัง)
create or replace function public.pos_ensure_open_shift() returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_actor uuid; v_default numeric;
begin
  v_actor := public.pos_current_app_user_id();
  perform pg_advisory_xact_lock(hashtext('smartpos_store_open'));
  select id into v_id from public.shifts where status = 'OPEN' limit 1;
  if v_id is not null then return v_id; end if;
  select coalesce(default_opening_cash, 0) into v_default from public.shop_settings limit 1;
  insert into public.shifts(id, opening_cash, status, opened_by, open_source, needs_review)
  values (gen_random_uuid(), coalesce(v_default, 0), 'OPEN', v_actor, 'AUTO_TRANSACTION', true)
  returning id into v_id;
  perform public.pos_audit('AUTO_OPEN_STORE', 'shifts', v_id::text, jsonb_build_object('reason', 'transaction'));
  return v_id;
end $$;

-- เปิดตามเวลาทำการ (เรียกโดย pg_cron ทุก 5 นาที)
create or replace function public.auto_open_shift_by_schedule() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s record; v_now timestamptz := now(); v_open_ts timestamptz; v_close_ts timestamptz; v_id uuid; v_default numeric;
begin
  select * into s from public.shop_settings limit 1;
  if not found or not s.auto_open_enabled then return jsonb_build_object('skipped', true); end if;
  v_open_ts := ((v_now at time zone s.timezone)::date + s.business_open) at time zone s.timezone;
  v_close_ts := ((v_now at time zone s.timezone)::date + s.business_close) at time zone s.timezone;
  if v_now < v_open_ts or v_now >= v_close_ts then return jsonb_build_object('opened', false); end if;
  perform pg_advisory_xact_lock(hashtext('smartpos_store_open'));
  if exists (select 1 from public.shifts where status = 'OPEN') then return jsonb_build_object('opened', false); end if;
  insert into public.shifts(id, opening_cash, status, opened_by, open_source, needs_review, opened_at)
  values (gen_random_uuid(), coalesce(s.default_opening_cash, 0), 'OPEN', null, 'AUTO_SCHEDULE', true, v_open_ts)
  returning id into v_id;
  perform public.pos_audit('AUTO_OPEN_STORE', 'shifts', v_id::text, jsonb_build_object('reason', 'schedule'));
  return jsonb_build_object('opened', true, 'shift_id', v_id);
end $$;

-- ปิดร้านอัตโนมัติเมื่อถึงเวลาปิด: ปิดด้วยเงินที่ระบบคำนวณ (ยังไม่ได้นับจริง) และตั้งให้ตรวจ
create or replace function public.auto_close_shifts() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s record; v_close_ts timestamptz; sh record; v_in numeric; v_out numeric; v_expected numeric; v_n int := 0;
begin
  select * into s from public.shop_settings limit 1;
  if not found or not s.auto_close_enabled then return jsonb_build_object('skipped', true); end if;
  v_close_ts := ((now() at time zone s.timezone)::date + s.business_close) at time zone s.timezone;
  if now() < v_close_ts then return jsonb_build_object('closed', 0); end if;
  for sh in select * from public.shifts where status = 'OPEN' and opened_at < v_close_ts for update loop
    select coalesce(sum(income),0), coalesce(sum(expense),0) into v_in, v_out from public.cash_ledger where shift_id = sh.id;
    v_expected := round(sh.opening_cash + v_in - v_out, 2);
    update public.shifts set status = 'CLOSED', closed_at = v_close_ts, closing_cash = v_expected,
      expected_cash = v_expected, cash_variance = 0, close_source = 'AUTO_SCHEDULE', needs_review = true,
      close_note = 'ปิดอัตโนมัติตามเวลาทำการ ยังไม่ได้นับเงินจริง'
    where id = sh.id;
    perform public.pos_audit('AUTO_CLOSE_STORE', 'shifts', sh.id::text, jsonb_build_object('expected_cash', v_expected));
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('closed', v_n);
end $$;

-- ปิดร้านแบบ manual ผ่าน close_shift เดิม; สรุปยอดคำนวณอัตโนมัติเมื่อกะปิด
create or replace function public.trg_shift_summary() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_methods jsonb; v_cash jsonb; v_bills int; v_total numeric;
begin
  select coalesce(jsonb_object_agg(payment_method, t), '{}'::jsonb), coalesce(sum(t),0), coalesce(sum(n),0)::int
    into v_methods, v_total, v_bills
  from (select payment_method, sum(total) t, count(*) n from public.bills where shift_id = new.id group by payment_method) b;
  select coalesce(jsonb_object_agg(type, jsonb_build_object('in', i, 'out', o)), '{}'::jsonb) into v_cash
  from (select type, sum(income) i, sum(expense) o from public.cash_ledger where shift_id = new.id group by type) c;
  update public.shifts set summary = jsonb_build_object(
      'opening_cash', new.opening_cash, 'expected_cash', new.expected_cash, 'closing_cash', new.closing_cash,
      'variance', new.cash_variance, 'bills', v_bills, 'sales_total', v_total,
      'sales_by_method', v_methods, 'cash_movements', v_cash,
      'opened_at', new.opened_at, 'closed_at', new.closed_at, 'open_source', new.open_source,
      'close_source', new.close_source, 'needs_review', new.needs_review)
    where id = new.id;
  return null;
end $$;
drop trigger if exists shift_summary on public.shifts;
create trigger shift_summary after update of status on public.shifts
  for each row when (new.status = 'CLOSED' and old.status = 'OPEN') execute function public.trg_shift_summary();
drop function if exists public.create_sale(text,uuid,uuid,uuid,numeric,numeric,text,jsonb,boolean,text,numeric,timestamptz,uuid);
create or replace function public.create_sale(
  p_bill_number text, p_customer_id uuid, p_user_id uuid, p_shift_id uuid,
  p_discount_amount numeric, p_tax_amount numeric, p_payment_method text, p_items jsonb,
  p_allow_negative boolean, p_tax_mode text, p_expected_total numeric default null,
  p_created_at timestamptz default null,
  p_approval uuid default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid; v_user uuid; v_method text; v_is_credit boolean; v_bill_id uuid; v_exist record;
  x jsonb; v_subtotal numeric := 0; v_discount numeric; v_tax numeric; v_tax_mode text;
  v_calc numeric; v_total numeric; v_round numeric := 0; v_tol numeric; v_cogs numeric := 0;
  v_qty numeric; v_price numeric; v_variant uuid; v_fraction uuid; v_product uuid; v_name text;
  v_ratio numeric; v_stock_qty numeric; v_stock numeric; v_cost numeric; v_list numeric; v_line_cost numeric;
  v_debt numeric; v_limit numeric; v_new_debt numeric; v_created timestamptz; v_shift_status text; v_n int;
begin
  v_actor := public.pos_require_staff();
  if coalesce(trim(p_bill_number), '') = '' then raise exception 'ต้องระบุเลขบิล'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'ไม่มีรายการสินค้า'; end if;

  select id into v_user from public.app_users where id = p_user_id and is_active;
  v_user := coalesce(v_user, v_actor);

  v_method := upper(trim(coalesce(p_payment_method, 'CASH')));
  v_method := case v_method when 'เงินสด' then 'CASH' when 'เครดิต' then 'CREDIT' when 'ON_CREDIT' then 'CREDIT'
                            when 'โอน' then 'TRANSFER' when 'โอนเงิน' then 'TRANSFER' else v_method end;
  v_is_credit := (v_method = 'CREDIT');

  -- กันบิลซ้ำ: เลขเดียวกัน + รายการเท่ากัน = ส่งซ้ำ; เลขเดียวกันแต่ต่างกัน = เลขบิลชนกัน (แจ้ง error ไม่ทิ้งเงียบ)
  select id, total into v_exist from public.bills where bill_number = p_bill_number;
  if found then
    select count(*) into v_n from public.bill_items where bill_id = v_exist.id;
    if v_n <> jsonb_array_length(p_items) or abs(v_exist.total - coalesce(p_expected_total, v_exist.total)) > 0.05 then
      raise exception 'เลขบิล % ซ้ำกับบิลอื่นที่มีรายการต่างกัน (เครื่องออกเลขบิลชนกัน)', p_bill_number;
    end if;
    return jsonb_build_object('bill_id', v_exist.id, 'total', v_exist.total, 'duplicate', true);
  end if;

  v_created := case when p_created_at is null or p_created_at > now() + interval '10 minutes'
                      or p_created_at < now() - interval '400 days' then now() else p_created_at end;

  if p_created_at is not null and p_created_at < now() - interval '48 hours' then
    perform public.pos_check_approval(p_approval, 'BACKDATE');
  end if;

  -- ไม่มีร้านเปิดอยู่ หรือกะที่ส่งมาปิดแล้ว -> เปิดร้านอัตโนมัติแล้วบันทึกเข้ากะที่เปิดอยู่
  if p_shift_id is null or not exists (select 1 from public.shifts where id = p_shift_id and status = 'OPEN') then
    p_shift_id := public.pos_ensure_open_shift();
  end if;

  -- ล็อกรุ่นสินค้าตามลำดับ id กัน deadlock เมื่อขายพร้อมกันหลายเครื่อง
  perform 1 from public.product_variants
  where id in (select nullif(e->>'variant_id', '')::uuid from jsonb_array_elements(p_items) e where nullif(e->>'variant_id', '') is not null)
  order by id for update;

  for x in select value from jsonb_array_elements(p_items) loop
    v_qty := coalesce((x->>'quantity')::numeric, 0); v_price := coalesce((x->>'unit_price')::numeric, 0);
    if v_qty <= 0 or v_price < 0 then raise exception 'จำนวนหรือราคาสินค้าไม่ถูกต้อง'; end if;
    v_subtotal := v_subtotal + round(v_qty * v_price, 2);
  end loop;

  v_discount := least(greatest(coalesce(p_discount_amount, 0), 0), v_subtotal);
  v_tax_mode := upper(coalesce(nullif(p_tax_mode, ''), 'NONE'));
  if v_tax_mode not in ('NONE', 'INCLUDED', 'EXCLUDED') then raise exception 'tax_mode ไม่ถูกต้อง: %', p_tax_mode; end if;
  v_tax := case when v_tax_mode = 'NONE' then 0 else greatest(coalesce(p_tax_amount, 0), 0) end;
  v_calc := round(v_subtotal - v_discount + case when v_tax_mode = 'EXCLUDED' then v_tax else 0 end, 2);
  v_total := v_calc;
  v_tol := greatest(0.02, 0.01 * jsonb_array_length(p_items));
  if p_expected_total is not null then
    if abs(v_calc - p_expected_total) > v_tol then
      raise exception 'ยอดบิลไม่ตรง: เซิร์ฟเวอร์คำนวณได้ %, หน้า POS ส่ง %', v_calc, p_expected_total;
    end if;
    v_total := round(p_expected_total, 2);            -- ยอดที่เก็บเงินจริง; ส่วนต่างเก็บเป็นเศษปัด
    v_round := round(v_total - v_calc, 2);
  end if;

  if v_is_credit then
    if p_customer_id is null then raise exception 'ขายเชื่อต้องระบุลูกค้า'; end if;
    select debt, credit_limit into v_debt, v_limit from public.customers where id = p_customer_id and is_active for update;
    if not found then raise exception 'ไม่พบลูกค้า'; end if;
    if v_debt + v_total > v_limit then raise exception 'ยอดหนี้เกินวงเงินลูกค้า (หนี้ % + บิล % > วงเงิน %)', v_debt, v_total, v_limit; end if;
  elsif p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'ไม่พบลูกค้า';
  end if;

  insert into public.bills(bill_number, customer_id, user_id, shift_id, subtotal, discount_amount, tax_amount, rounding_amount,
                           total, payment_method, status, tax_mode, created_at)
  values (p_bill_number, p_customer_id, v_user, p_shift_id, v_subtotal, v_discount, v_tax, v_round,
          v_total, v_method, case when v_is_credit then 'CREDIT' else 'PAID' end, v_tax_mode, v_created)
  returning id into v_bill_id;

  for x in select value from jsonb_array_elements(p_items) loop
    v_product := nullif(x->>'product_id', '')::uuid; v_variant := nullif(x->>'variant_id', '')::uuid;
    v_fraction := nullif(x->>'fraction_id', '')::uuid;
    v_qty := (x->>'quantity')::numeric; v_price := (x->>'unit_price')::numeric;
    v_name := coalesce(nullif(x->>'item_name', ''), 'สินค้า');
    v_stock_qty := v_qty; v_line_cost := 0; v_list := null;
    if v_variant is not null then
      select stock_quantity, cost_price, price into v_stock, v_cost, v_list from public.product_variants where id = v_variant;
      if not found then raise exception 'ไม่พบรุ่นสินค้า %', v_variant; end if;
      if v_fraction is not null then
        select quantity_ratio, price into v_ratio, v_list from public.product_fractions where id = v_fraction and variant_id = v_variant;
        if not found then raise exception 'ไม่พบหน่วยย่อยสินค้า %', v_fraction; end if;
        v_stock_qty := v_qty / v_ratio;
      end if;
      if v_list is not null and v_list > 0 and v_price < v_list then
        perform public.pos_check_approval(p_approval, 'PRICE_BELOW_LIST');
      end if;
      if v_stock < v_stock_qty then
        if not coalesce(p_allow_negative, false) then
          raise exception 'สต็อกไม่พอสำหรับ % (เหลือ %)', v_name, v_stock;
        end if;
        perform public.pos_check_approval(p_approval, 'NEGATIVE_STOCK');
      end if;
      update public.product_variants set stock_quantity = stock_quantity - v_stock_qty where id = v_variant;
      insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, ref_id, created_at, created_by)
      values (v_variant, -v_stock_qty, 'ขายสินค้า', 'SALE', v_bill_id, v_created, v_user);
      v_line_cost := round(v_cost * v_stock_qty, 4);
    end if;
    insert into public.bill_items(bill_id, product_id, variant_id, fraction_id, item_name, quantity, unit_price, list_price,
                                  line_total, line_cost, stock_quantity_delta)
    values (v_bill_id, v_product, v_variant, v_fraction, v_name, v_qty, v_price, v_list,
            round(v_qty * v_price, 2), v_line_cost, case when v_variant is not null then v_stock_qty else 0 end);
    v_cogs := v_cogs + v_line_cost;
  end loop;
  update public.bills set cogs_total = round(v_cogs, 2) where id = v_bill_id;

  if v_is_credit then
    update public.customers set debt = debt + v_total where id = p_customer_id returning debt into v_new_debt;
    insert into public.customer_ledger(customer_id, entry_type, amount, balance_after, ref_type, ref_id, created_at, created_by)
    values (p_customer_id, 'SALE', v_total, v_new_debt, 'BILL', v_bill_id::text, v_created, v_user);
  else
    insert into public.payments(bill_id, method, amount, created_at) values (v_bill_id, v_method, v_total, v_created);
    if v_method = 'CASH' then
      insert into public.cash_ledger(shift_id, type, income, description, ref_id, payment_method, created_at, created_by)
      values (p_shift_id, 'SALE', v_total, 'รับเงินขายสินค้า ' || p_bill_number, v_bill_id::text, 'CASH', v_created, v_user);
    end if;
  end if;

  if p_approval is not null then perform public.pos_finish_approval(p_approval); end if;
  perform public.pos_audit('CREATE_SALE', 'bills', v_bill_id::text,
    jsonb_build_object('bill_number', p_bill_number, 'total', v_total, 'method', v_method, 'items', jsonb_array_length(p_items), 'cashier', v_user));
  return jsonb_build_object('bill_id', v_bill_id, 'bill_number', p_bill_number, 'subtotal', v_subtotal, 'total', v_total, 'stock_updated', true);
end $$;
create or replace function public.receive_goods(p_client_ref text, p_supplier_id uuid, p_doc_ref text, p_terms integer,
  p_received_at timestamptz, p_items jsonb, p_ap_id uuid default null, p_pay_now boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor uuid; x jsonb; v_po uuid; v_ap uuid; v_variant uuid; v_product uuid; v_qty numeric; v_cost numeric; v_total numeric := 0;
begin
  v_actor := public.pos_require_manager();
  if p_client_ref is not null then
    select id into v_po from public.purchase_orders where client_ref = p_client_ref;
    if v_po is not null then
      select id into v_ap from public.accounts_payable where purchase_order_id = v_po;
      return jsonb_build_object('po_id', v_po, 'ap_id', v_ap, 'duplicate', true);
    end if;
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'ไม่มีรายการรับสินค้า'; end if;
  if p_supplier_id is not null and not exists (select 1 from public.suppliers where id = p_supplier_id) then raise exception 'ไม่พบผู้ขาย'; end if;

  insert into public.purchase_orders(client_ref, supplier_id, doc_ref, terms, received_at, created_by)
  values (p_client_ref, p_supplier_id, p_doc_ref, coalesce(p_terms, 30), coalesce(p_received_at, now()), v_actor) returning id into v_po;

  for x in select value from jsonb_array_elements(p_items) loop
    v_product := nullif(x->>'product_id', '')::uuid; v_variant := nullif(x->>'variant_id', '')::uuid;
    v_qty := coalesce((x->>'quantity')::numeric, 0); v_cost := coalesce((x->>'unit_cost')::numeric, 0);
    if v_qty <= 0 or v_cost < 0 then raise exception 'จำนวนหรือทุนรับสินค้าไม่ถูกต้อง'; end if;
    if v_variant is null then raise exception 'รายการรับสินค้าต้องระบุ variant_id'; end if;
    -- ต้นทุนถัวเฉลี่ยถ่วงน้ำหนัก (สูตรเดียวกับหน้าแอป): (สต็อกเดิม x ทุนเดิม + รับใหม่ x ทุนใหม่) / (สต็อกเดิม + รับใหม่)
    update public.product_variants set
      cost_price = case when v_cost <= 0 then cost_price
                        when stock_quantity > 0 then round((stock_quantity * cost_price + v_qty * v_cost) / (stock_quantity + v_qty), 2)
                        else v_cost end,
      stock_quantity = stock_quantity + v_qty
    where id = v_variant;
    if not found then raise exception 'ไม่พบรุ่นสินค้า %', v_variant; end if;
    insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, ref_id, created_by)
    values (v_variant, v_qty, 'รับสินค้าเข้าสต็อก', 'PURCHASE', v_po, v_actor);
    insert into public.purchase_order_items(purchase_order_id, product_id, variant_id, quantity, unit_cost, line_total)
    values (v_po, v_product, v_variant, v_qty, v_cost, round(v_qty * v_cost, 2));
    v_total := v_total + round(v_qty * v_cost, 2);
  end loop;
  update public.purchase_orders set total = v_total where id = v_po;

  insert into public.accounts_payable(id, supplier_id, purchase_order_id, doc_ref, amount, credit_terms, status, paid_at)
  values (coalesce(p_ap_id, gen_random_uuid()), p_supplier_id, v_po, p_doc_ref, v_total, coalesce(p_terms, 30),
          'OPEN', null)
  on conflict (id) do update set purchase_order_id = excluded.purchase_order_id, supplier_id = excluded.supplier_id,
    doc_ref = excluded.doc_ref, amount = excluded.amount, credit_terms = excluded.credit_terms
  returning id into v_ap;

  perform public.pos_audit('RECEIVE_GOODS', 'purchase_orders', v_po::text, jsonb_build_object('total', v_total, 'items', jsonb_array_length(p_items)));
  return jsonb_build_object('po_id', v_po, 'ap_id', v_ap, 'total', v_total);
end $$;

-- ---- จ่ายเจ้าหนี้: บันทึกวิธีจ่าย และถ้าเป็นเงินสดให้ลงเงินสดในกะที่เปิดอยู่ ----
alter table public.supplier_payments
  add column if not exists payment_method text not null default 'TRANSFER' check (payment_method in ('CASH','TRANSFER')),
  add column if not exists shift_id uuid references public.shifts(id);

create or replace function public.pay_supplier(p_ap_id uuid, p_method text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor uuid; ap record; v_method text; v_shift uuid;
begin
  v_actor := public.pos_require_staff();
  v_method := upper(trim(coalesce(p_method, '')));
  if v_method not in ('CASH','TRANSFER') then raise exception 'วิธีจ่ายต้องเป็น CASH หรือ TRANSFER'; end if;
  select * into ap from public.accounts_payable where id = p_ap_id for update;
  if not found then raise exception 'ไม่พบรายการเจ้าหนี้'; end if;
  if ap.status = 'PAID' then return jsonb_build_object('ap_id', p_ap_id, 'duplicate', true); end if;
  if v_method = 'CASH' then v_shift := public.pos_ensure_open_shift(); end if;
  -- บันทึกหลักฐานก่อน เพื่อให้ trg_ap_paid_record ข้ามไป (on conflict do nothing) และยังเก็บวิธีจ่ายไว้
  insert into public.supplier_payments(ap_id, supplier_id, amount, paid_at, paid_by, note, payment_method, shift_id)
  values (ap.id, ap.supplier_id, ap.amount, now(), v_actor, p_note, v_method, v_shift);
  if v_method = 'CASH' then
    insert into public.cash_ledger(shift_id, type, income, expense, description, ref_id, payment_method, created_by)
    values (v_shift, 'SUPPLIER_PAYMENT', 0, ap.amount, 'จ่ายเจ้าหนี้ ' || coalesce(ap.doc_ref, ''), ap.id::text, 'CASH', v_actor);
  end if;
  update public.accounts_payable set status = 'PAID', paid_at = now() where id = p_ap_id;
  perform public.pos_audit('PAY_SUPPLIER', 'accounts_payable', p_ap_id::text,
    jsonb_build_object('amount', ap.amount, 'method', v_method, 'shift_id', v_shift));
  return jsonb_build_object('ap_id', p_ap_id, 'amount', ap.amount, 'method', v_method, 'shift_id', v_shift);
end $$;

-- ปิดการแก้สถานะ AP โดยตรงจากเครื่อง (ต้องผ่าน pay_supplier)
revoke update (status, paid_at) on public.accounts_payable from authenticated;

-- ---- ตั้งเวลาอัตโนมัติ (ต้องเปิดใช้ extension pg_cron ใน Supabase ก่อน) ----
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname in ('smartpos-auto-open','smartpos-auto-close');
    perform cron.schedule('smartpos-auto-open', '*/5 * * * *', 'select public.auto_open_shift_by_schedule()');
    perform cron.schedule('smartpos-auto-close', '*/5 * * * *', 'select public.auto_close_shifts()');
  else
    raise notice 'ยังไม่ได้เปิด pg_cron: เปิดอัตโนมัติ/ปิดอัตโนมัติจะไม่ทำงาน';
  end if;
end $$;

-- ---- สิทธิ์ ----
grant insert (id,shop_name,phone,tax_id,address,vat_registered,vat_rate,updated_at,business_open,business_close,timezone,auto_open_enabled,auto_close_enabled,default_opening_cash),
      update (shop_name,phone,tax_id,address,vat_registered,vat_rate,updated_at,business_open,business_close,timezone,auto_open_enabled,auto_close_enabled,default_opening_cash) on public.shop_settings to authenticated;
grant execute on function public.open_store(numeric,text) to authenticated;
grant execute on function public.pay_supplier(uuid,text,text) to authenticated;
grant execute on function public.create_sale(text,uuid,uuid,uuid,numeric,numeric,text,jsonb,boolean,text,numeric,timestamptz,uuid) to authenticated;
grant execute on function public.receive_goods(text,uuid,text,integer,timestamptz,jsonb,uuid,boolean) to authenticated;

-- ######## แพตช์ 005: index ที่ขาด ########
-- =====================================================================
-- SMART-POS PATCH 005: index ที่ขาดสำหรับการค้นหา/รวมยอดที่โตขึ้นเรื่อยๆ
-- รันหลัง PATCH-004 (ปลอดภัยรันซ้ำได้: ใช้ if not exists)
-- ใช้ create index (ไม่ใช่ concurrently) เพราะ Supabase SQL editor รันในทรานแซกชัน
-- ถ้าตารางมีข้อมูลมาก ควรรันช่วงที่ร้านปิด
-- =====================================================================

create index if not exists idx_bill_items_variant_id        on public.bill_items(variant_id);
create index if not exists idx_payments_bill_id             on public.payments(bill_id);
create index if not exists idx_return_items_return_id       on public.return_items(return_id);
create index if not exists idx_purchase_order_items_po_id   on public.purchase_order_items(purchase_order_id);
create index if not exists idx_customer_payments_customer   on public.customer_payments(customer_id);

-- หมายเหตุ: income_expenses ไม่มีการใช้งานในแอป (ไม่มีการอ้างอิงในไฟล์ index.html)
-- จึงไม่เพิ่มสิทธิ์เขียน เพื่อไม่เปิดช่องทางที่ไม่ได้ใช้

-- ######## แพตช์ 006: ตำแหน่งชั้นวางสินค้า ########
-- =====================================================================
-- SMART-POS PATCH 006: ตำแหน่งชั้นวางสินค้า (โซน-ชั้น-ช่อง) สำหรับแผนผังร้าน
-- ต้องรันก่อนอัปโหลดแอปเวอร์ชันที่ส่ง location_code (ไม่งั้นการซิงก์สินค้าจะล้มทั้งชุด)
-- ปลอดภัยรันซ้ำได้
-- =====================================================================

alter table public.product_variants add column if not exists location_code text;

-- รูปแบบที่แอปใช้: โซนเป็นตัวอักษร A-Z ชั้นและช่องเป็นตัวเลข เช่น A-2-3
alter table public.product_variants drop constraint if exists product_variants_location_code_format;
alter table public.product_variants add constraint product_variants_location_code_format
  check (location_code is null or location_code ~ '^[A-Z]-[0-9]{1,2}-[0-9]{1,2}$');

create index if not exists idx_product_variants_location on public.product_variants(location_code);

-- พนักงานจัดวางสินค้าได้ (ไม่เกี่ยวกับราคาหรือสต็อก)
grant insert (location_code), update (location_code) on public.product_variants to authenticated;

-- ######## แพตช์ 007: จ่ายเจ้าหนี้ (แหล่งเงินสดคือลิ้นชักในแอป) ########
-- =====================================================================
-- SMART-POS PATCH 007: จ่ายเจ้าหนี้ — แหล่งความจริงของเงินสดคือลิ้นชักในแอป
-- ค่าเริ่มต้น p_post_cash = false: ไม่ลงเงินสดซ้ำใน cash_ledger
-- (ลิ้นชักในแอปบันทึกเงินออกเองแล้ว) ใช้ p_post_cash = true เฉพาะกรณีที่ไม่มีแอปลิ้นชัก
-- รันหลัง PATCH-006 (ปลอดภัยรันซ้ำได้)
-- =====================================================================

drop function if exists public.pay_supplier(uuid, text, text);

create or replace function public.pay_supplier(
  p_ap_id uuid, p_method text, p_note text default null, p_post_cash boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor uuid; ap record; v_method text; v_shift uuid;
begin
  v_actor := public.pos_require_staff();
  v_method := upper(trim(coalesce(p_method, '')));
  if v_method not in ('CASH','TRANSFER') then raise exception 'วิธีจ่ายต้องเป็น CASH หรือ TRANSFER'; end if;
  select * into ap from public.accounts_payable where id = p_ap_id for update;
  if not found then raise exception 'ไม่พบรายการเจ้าหนี้'; end if;
  if ap.status = 'PAID' then return jsonb_build_object('ap_id', p_ap_id, 'duplicate', true); end if;
  if v_method = 'CASH' and p_post_cash then v_shift := public.pos_ensure_open_shift(); end if;
  insert into public.supplier_payments(ap_id, supplier_id, amount, paid_at, paid_by, note, payment_method, shift_id)
  values (ap.id, ap.supplier_id, ap.amount, now(), v_actor, p_note, v_method, v_shift);
  if v_method = 'CASH' and p_post_cash then
    insert into public.cash_ledger(shift_id, type, income, expense, description, ref_id, payment_method, created_by)
    values (v_shift, 'SUPPLIER_PAYMENT', 0, ap.amount, 'จ่ายเจ้าหนี้ ' || coalesce(ap.doc_ref, ''), ap.id::text, 'CASH', v_actor);
  end if;
  update public.accounts_payable set status = 'PAID', paid_at = now() where id = p_ap_id;
  perform public.pos_audit('PAY_SUPPLIER', 'accounts_payable', p_ap_id::text,
    jsonb_build_object('amount', ap.amount, 'method', v_method, 'posted_cash', p_post_cash and v_method = 'CASH'));
  return jsonb_build_object('ap_id', p_ap_id, 'amount', ap.amount, 'method', v_method, 'shift_id', v_shift);
end $$;

grant execute on function public.pay_supplier(uuid, text, text, boolean) to authenticated;

-- ######## แพตช์ 008: เซสชันพนักงานและสิทธิ์ที่เซิร์ฟเวอร์ ########
-- =====================================================================
-- SMART-POS PATCH 008: เซสชันพนักงาน (token) + บังคับสิทธิ์ที่เซิร์ฟเวอร์
-- - ล็อกอินพนักงานด้วย PIN (ตรวจที่เซิร์ฟเวอร์ มีล็อกเมื่อผิดหลายครั้ง) ได้ token อายุ 12 ชม.
-- - เก็บเฉพาะ hash ของ token ในตาราง pos_sessions
-- - RPC ที่แก้ในรอบนี้รับ p_session: ถ้ามี token จะตรวจสิทธิ์รายบุคคล
--   ถ้าไม่มี token (แอปรุ่นเดิม/ออฟไลน์/เจ้าของร้าน) ใช้กติกาเดิม (legacy) เพื่อไม่ให้ระบบหยุด
-- รันหลัง PATCH-007 (ปลอดภัยรันซ้ำได้)
-- =====================================================================

create table if not exists public.pos_sessions (
  token_hash text primary key,
  app_user_id uuid not null references public.app_users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked boolean not null default false
);
alter table public.pos_sessions enable row level security;
revoke all on public.pos_sessions from anon, authenticated;

-- ตรวจ token และสิทธิ์ของผู้ใช้; คืน app_users.id ของผู้ที่ทำรายการ
-- p_legacy: 'MANAGER' หรือ 'STAFF' ใช้เมื่อไม่มี token (กติกาเดิม)
create or replace function public.pos_check_perm(p_session uuid, p_perm text, p_legacy text default 'STAFF')
returns uuid language plpgsql stable security definer set search_path = public, auth as $$
declare v_user uuid; u record;
begin
  if p_session is null then
    if p_legacy = 'MANAGER' then return public.pos_require_manager(); end if;
    return public.pos_require_staff();
  end if;
  select s.app_user_id into v_user from public.pos_sessions s
   where s.token_hash = encode(sha256(convert_to(p_session::text, 'UTF8')), 'hex')
     and not s.revoked and s.expires_at > now();
  if v_user is null then raise exception 'เซสชันหมดอายุ กรุณาล็อกอินใหม่' using errcode = '42501'; end if;
  select * into u from public.app_users where id = v_user and is_active;
  if not found then raise exception 'บัญชีนี้ถูกปิดการใช้งาน' using errcode = '42501'; end if;
  if u.role = 'OWNER' or u.permissions ? 'ALL' or u.permissions ? p_perm then return v_user; end if;
  raise exception 'ไม่มีสิทธิ์: %', p_perm using errcode = '42501';
end $$;

-- ล็อกอินพนักงาน: ตรวจ PIN แล้วออก token
create or replace function public.employee_login(p_app_user_id uuid, p_pin_hash text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_token uuid;
begin
  perform public.pos_require_staff();
  if not exists (select 1 from public.app_users where id = p_app_user_id and is_active) then
    return jsonb_build_object('ok', false, 'reason', 'ไม่พบผู้ใช้ที่ใช้งานได้');
  end if;
  if not public.pos_check_pin(p_app_user_id, p_pin_hash) then
    return jsonb_build_object('ok', false, 'reason', 'PIN ไม่ถูกต้อง');
  end if;
  v_token := gen_random_uuid();
  insert into public.pos_sessions(token_hash, app_user_id, expires_at)
  values (encode(sha256(convert_to(v_token::text, 'UTF8')), 'hex'), p_app_user_id, now() + interval '12 hours');
  delete from public.pos_sessions where expires_at < now() - interval '1 day';
  return jsonb_build_object('ok', true, 'session', v_token, 'expires_in_sec', 43200);
end $$;

-- ล็อกเอาต์: ยกเลิก token ทันที
create or replace function public.employee_logout(p_session uuid) returns void
language sql security definer set search_path = public as $$
  update public.pos_sessions set revoked = true
   where token_hash = encode(sha256(convert_to(p_session::text, 'UTF8')), 'hex')
$$;
-- ---- adjust_stock: เพิ่มพารามิเตอร์ p_session ----
drop function if exists public.adjust_stock(uuid,text,numeric,text,text);
create or replace function public.adjust_stock(p_variant_id uuid, p_mode text, p_value numeric, p_reason text, p_op_ref text default null, p_session uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_old numeric; v_new numeric; v_delta numeric; v_user uuid;
begin
  v_user := public.pos_check_perm(p_session, 'STOCK_ADJUST', 'MANAGER');
  if p_value is null then raise exception 'ต้องระบุจำนวน'; end if;
  if p_op_ref is not null and exists (select 1 from public.inventory_movements where op_ref = p_op_ref) then
    return jsonb_build_object('duplicate', true);
  end if;
  select stock_quantity into v_old from public.product_variants where id = p_variant_id for update;
  if not found then raise exception 'ไม่พบรุ่นสินค้า'; end if;
  if upper(p_mode) = 'SET' then v_new := p_value;
  elsif upper(p_mode) = 'ADD' then v_new := v_old + p_value;
  elsif upper(p_mode) = 'SUBTRACT' then v_new := v_old - p_value;
  else raise exception 'p_mode ต้องเป็น SET, ADD หรือ SUBTRACT'; end if;
  if v_new < 0 then raise exception 'สต็อกต้องไม่ติดลบ'; end if;
  v_delta := v_new - v_old;
  update public.product_variants set stock_quantity = v_new, stock_seeded = true where id = p_variant_id;
  insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, op_ref, created_by)
  values (p_variant_id, v_delta, coalesce(nullif(p_reason, ''), 'ปรับสต็อก'), 'ADJUST', p_op_ref, v_user);
  perform public.pos_audit('ADJUST_STOCK', 'product_variants', p_variant_id::text,
    jsonb_build_object('old', v_old, 'new', v_new, 'reason', p_reason));
  return jsonb_build_object('variant_id', p_variant_id, 'old_stock', v_old, 'stock_quantity', v_new, 'change_qty', v_delta);
end $$;
-- ---- pay_supplier: เพิ่มพารามิเตอร์ p_session ----
drop function if exists public.pay_supplier(uuid,text,text,boolean);
create or replace function public.pay_supplier(
  p_ap_id uuid, p_method text, p_note text default null, p_post_cash boolean default false,
  p_session uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor uuid; ap record; v_method text; v_shift uuid;
begin
  v_actor := public.pos_check_perm(p_session, 'PURCHASE', 'STAFF');
  v_method := upper(trim(coalesce(p_method, '')));
  if v_method not in ('CASH','TRANSFER') then raise exception 'วิธีจ่ายต้องเป็น CASH หรือ TRANSFER'; end if;
  select * into ap from public.accounts_payable where id = p_ap_id for update;
  if not found then raise exception 'ไม่พบรายการเจ้าหนี้'; end if;
  if ap.status = 'PAID' then return jsonb_build_object('ap_id', p_ap_id, 'duplicate', true); end if;
  if v_method = 'CASH' and p_post_cash then v_shift := public.pos_ensure_open_shift(); end if;
  insert into public.supplier_payments(ap_id, supplier_id, amount, paid_at, paid_by, note, payment_method, shift_id)
  values (ap.id, ap.supplier_id, ap.amount, now(), v_actor, p_note, v_method, v_shift);
  if v_method = 'CASH' and p_post_cash then
    insert into public.cash_ledger(shift_id, type, income, expense, description, ref_id, payment_method, created_by)
    values (v_shift, 'SUPPLIER_PAYMENT', 0, ap.amount, 'จ่ายเจ้าหนี้ ' || coalesce(ap.doc_ref, ''), ap.id::text, 'CASH', v_actor);
  end if;
  update public.accounts_payable set status = 'PAID', paid_at = now() where id = p_ap_id;
  perform public.pos_audit('PAY_SUPPLIER', 'accounts_payable', p_ap_id::text,
    jsonb_build_object('amount', ap.amount, 'method', v_method, 'posted_cash', p_post_cash and v_method = 'CASH'));
  return jsonb_build_object('ap_id', p_ap_id, 'amount', ap.amount, 'method', v_method, 'shift_id', v_shift);
end $$;

grant execute on function public.pos_check_perm(uuid,text,text) to authenticated;
grant execute on function public.employee_login(uuid,text) to authenticated;
grant execute on function public.employee_logout(uuid) to authenticated;
grant execute on function public.adjust_stock(uuid,text,numeric,text,text,uuid) to authenticated;
grant execute on function public.pay_supplier(uuid,text,text,boolean,uuid) to authenticated;

-- ######## แพตช์ 009: สิทธิ์รายบุคคลในการขายและการลบ ########
-- =====================================================================
-- SMART-POS PATCH 009: บังคับสิทธิ์รายบุคคลใน create_sale และ delete_entity
-- - การขายและการลบที่ส่ง token มา จะตรวจสิทธิ์ของผู้ที่ทำรายการ
-- - ถ้าผู้ใช้มีสิทธิ์ (PRICE_OVERRIDE / STOCK_NEGATIVE / BACKDATE) ไม่ต้องใช้ PIN อนุมัติ
-- - ถ้าไม่มีสิทธิ์ ยังขอโทเค็นอนุมัติแบบเดิมได้ (กันการใช้งานหลุด)
-- - ไม่ส่ง token: ใช้กติกาเดิม (legacy)
-- รันหลัง PATCH-008 (ปลอดภัยรันซ้ำได้)
-- =====================================================================

-- ใช้สิทธิ์ของผู้ใช้ก่อน ถ้าไม่มีสิทธิ์จึงตรวจโทเค็นอนุมัติ
create or replace function public.pos_approve_or_perm(p_session uuid, p_token uuid, p_action text, p_perm text)
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if p_session is not null then
    begin
      perform public.pos_check_perm(p_session, p_perm, 'MANAGER');
      return;
    exception when sqlstate '42501' then
      null;   -- ไม่มีสิทธิ์ ตกไปตรวจโทเค็นอนุมัติ
    end;
  end if;
  perform public.pos_check_approval(p_token, p_action);
end $$;

-- ---- create_sale: เพิ่ม p_session และตรวจสิทธิ์รายบุคคล ----
drop function if exists public.create_sale(text,uuid,uuid,uuid,numeric,numeric,text,jsonb,boolean,text,numeric,timestamptz,uuid);
create or replace function public.create_sale(
  p_bill_number text, p_customer_id uuid, p_user_id uuid, p_shift_id uuid,
  p_discount_amount numeric, p_tax_amount numeric, p_payment_method text, p_items jsonb,
  p_allow_negative boolean, p_tax_mode text, p_expected_total numeric default null,
  p_created_at timestamptz default null,
  p_approval uuid default null,
  p_session uuid default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid; v_user uuid; v_method text; v_is_credit boolean; v_bill_id uuid; v_exist record;
  x jsonb; v_subtotal numeric := 0; v_discount numeric; v_tax numeric; v_tax_mode text;
  v_calc numeric; v_total numeric; v_round numeric := 0; v_tol numeric; v_cogs numeric := 0;
  v_qty numeric; v_price numeric; v_variant uuid; v_fraction uuid; v_product uuid; v_name text;
  v_ratio numeric; v_stock_qty numeric; v_stock numeric; v_cost numeric; v_list numeric; v_line_cost numeric;
  v_debt numeric; v_limit numeric; v_new_debt numeric; v_created timestamptz; v_shift_status text; v_n int;
begin
  v_actor := public.pos_require_staff();
  if coalesce(trim(p_bill_number), '') = '' then raise exception 'ต้องระบุเลขบิล'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'ไม่มีรายการสินค้า'; end if;

  select id into v_user from public.app_users where id = p_user_id and is_active;
  v_user := coalesce(v_user, v_actor);

  v_method := upper(trim(coalesce(p_payment_method, 'CASH')));
  v_method := case v_method when 'เงินสด' then 'CASH' when 'เครดิต' then 'CREDIT' when 'ON_CREDIT' then 'CREDIT'
                            when 'โอน' then 'TRANSFER' when 'โอนเงิน' then 'TRANSFER' else v_method end;
  v_is_credit := (v_method = 'CREDIT');

  -- กันบิลซ้ำ: เลขเดียวกัน + รายการเท่ากัน = ส่งซ้ำ; เลขเดียวกันแต่ต่างกัน = เลขบิลชนกัน (แจ้ง error ไม่ทิ้งเงียบ)
  select id, total into v_exist from public.bills where bill_number = p_bill_number;
  if found then
    select count(*) into v_n from public.bill_items where bill_id = v_exist.id;
    if v_n <> jsonb_array_length(p_items) or abs(v_exist.total - coalesce(p_expected_total, v_exist.total)) > 0.05 then
      raise exception 'เลขบิล % ซ้ำกับบิลอื่นที่มีรายการต่างกัน (เครื่องออกเลขบิลชนกัน)', p_bill_number;
    end if;
    return jsonb_build_object('bill_id', v_exist.id, 'total', v_exist.total, 'duplicate', true);
  end if;

  v_created := case when p_created_at is null or p_created_at > now() + interval '10 minutes'
                      or p_created_at < now() - interval '400 days' then now() else p_created_at end;

  if p_created_at is not null and p_created_at < now() - interval '48 hours' then
    perform public.pos_approve_or_perm(p_session, p_approval, 'BACKDATE', 'BACKDATE');
  end if;

  -- ไม่มีร้านเปิดอยู่ หรือกะที่ส่งมาปิดแล้ว -> เปิดร้านอัตโนมัติแล้วบันทึกเข้ากะที่เปิดอยู่
  if p_shift_id is null or not exists (select 1 from public.shifts where id = p_shift_id and status = 'OPEN') then
    p_shift_id := public.pos_ensure_open_shift();
  end if;

  -- ล็อกรุ่นสินค้าตามลำดับ id กัน deadlock เมื่อขายพร้อมกันหลายเครื่อง
  perform 1 from public.product_variants
  where id in (select nullif(e->>'variant_id', '')::uuid from jsonb_array_elements(p_items) e where nullif(e->>'variant_id', '') is not null)
  order by id for update;

  for x in select value from jsonb_array_elements(p_items) loop
    v_qty := coalesce((x->>'quantity')::numeric, 0); v_price := coalesce((x->>'unit_price')::numeric, 0);
    if v_qty <= 0 or v_price < 0 then raise exception 'จำนวนหรือราคาสินค้าไม่ถูกต้อง'; end if;
    v_subtotal := v_subtotal + round(v_qty * v_price, 2);
  end loop;

  v_discount := least(greatest(coalesce(p_discount_amount, 0), 0), v_subtotal);
  v_tax_mode := upper(coalesce(nullif(p_tax_mode, ''), 'NONE'));
  if v_tax_mode not in ('NONE', 'INCLUDED', 'EXCLUDED') then raise exception 'tax_mode ไม่ถูกต้อง: %', p_tax_mode; end if;
  v_tax := case when v_tax_mode = 'NONE' then 0 else greatest(coalesce(p_tax_amount, 0), 0) end;
  v_calc := round(v_subtotal - v_discount + case when v_tax_mode = 'EXCLUDED' then v_tax else 0 end, 2);
  v_total := v_calc;
  v_tol := greatest(0.02, 0.01 * jsonb_array_length(p_items));
  if p_expected_total is not null then
    if abs(v_calc - p_expected_total) > v_tol then
      raise exception 'ยอดบิลไม่ตรง: เซิร์ฟเวอร์คำนวณได้ %, หน้า POS ส่ง %', v_calc, p_expected_total;
    end if;
    v_total := round(p_expected_total, 2);            -- ยอดที่เก็บเงินจริง; ส่วนต่างเก็บเป็นเศษปัด
    v_round := round(v_total - v_calc, 2);
  end if;

  if v_is_credit then
    if p_customer_id is null then raise exception 'ขายเชื่อต้องระบุลูกค้า'; end if;
    select debt, credit_limit into v_debt, v_limit from public.customers where id = p_customer_id and is_active for update;
    if not found then raise exception 'ไม่พบลูกค้า'; end if;
    if v_debt + v_total > v_limit then raise exception 'ยอดหนี้เกินวงเงินลูกค้า (หนี้ % + บิล % > วงเงิน %)', v_debt, v_total, v_limit; end if;
  elsif p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'ไม่พบลูกค้า';
  end if;

  insert into public.bills(bill_number, customer_id, user_id, shift_id, subtotal, discount_amount, tax_amount, rounding_amount,
                           total, payment_method, status, tax_mode, created_at)
  values (p_bill_number, p_customer_id, v_user, p_shift_id, v_subtotal, v_discount, v_tax, v_round,
          v_total, v_method, case when v_is_credit then 'CREDIT' else 'PAID' end, v_tax_mode, v_created)
  returning id into v_bill_id;

  for x in select value from jsonb_array_elements(p_items) loop
    v_product := nullif(x->>'product_id', '')::uuid; v_variant := nullif(x->>'variant_id', '')::uuid;
    v_fraction := nullif(x->>'fraction_id', '')::uuid;
    v_qty := (x->>'quantity')::numeric; v_price := (x->>'unit_price')::numeric;
    v_name := coalesce(nullif(x->>'item_name', ''), 'สินค้า');
    v_stock_qty := v_qty; v_line_cost := 0; v_list := null;
    if v_variant is not null then
      select stock_quantity, cost_price, price into v_stock, v_cost, v_list from public.product_variants where id = v_variant;
      if not found then raise exception 'ไม่พบรุ่นสินค้า %', v_variant; end if;
      if v_fraction is not null then
        select quantity_ratio, price into v_ratio, v_list from public.product_fractions where id = v_fraction and variant_id = v_variant;
        if not found then raise exception 'ไม่พบหน่วยย่อยสินค้า %', v_fraction; end if;
        v_stock_qty := v_qty / v_ratio;
      end if;
      if v_list is not null and v_list > 0 and v_price < v_list then
        perform public.pos_approve_or_perm(p_session, p_approval, 'PRICE_BELOW_LIST', 'PRICE_OVERRIDE');
      end if;
      if v_stock < v_stock_qty then
        if not coalesce(p_allow_negative, false) then
          raise exception 'สต็อกไม่พอสำหรับ % (เหลือ %)', v_name, v_stock;
        end if;
        perform public.pos_approve_or_perm(p_session, p_approval, 'NEGATIVE_STOCK', 'STOCK_NEGATIVE');
      end if;
      update public.product_variants set stock_quantity = stock_quantity - v_stock_qty where id = v_variant;
      insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, ref_id, created_at, created_by)
      values (v_variant, -v_stock_qty, 'ขายสินค้า', 'SALE', v_bill_id, v_created, v_user);
      v_line_cost := round(v_cost * v_stock_qty, 4);
    end if;
    insert into public.bill_items(bill_id, product_id, variant_id, fraction_id, item_name, quantity, unit_price, list_price,
                                  line_total, line_cost, stock_quantity_delta)
    values (v_bill_id, v_product, v_variant, v_fraction, v_name, v_qty, v_price, v_list,
            round(v_qty * v_price, 2), v_line_cost, case when v_variant is not null then v_stock_qty else 0 end);
    v_cogs := v_cogs + v_line_cost;
  end loop;
  update public.bills set cogs_total = round(v_cogs, 2) where id = v_bill_id;

  if v_is_credit then
    update public.customers set debt = debt + v_total where id = p_customer_id returning debt into v_new_debt;
    insert into public.customer_ledger(customer_id, entry_type, amount, balance_after, ref_type, ref_id, created_at, created_by)
    values (p_customer_id, 'SALE', v_total, v_new_debt, 'BILL', v_bill_id::text, v_created, v_user);
  else
    insert into public.payments(bill_id, method, amount, created_at) values (v_bill_id, v_method, v_total, v_created);
    if v_method = 'CASH' then
      insert into public.cash_ledger(shift_id, type, income, description, ref_id, payment_method, created_at, created_by)
      values (p_shift_id, 'SALE', v_total, 'รับเงินขายสินค้า ' || p_bill_number, v_bill_id::text, 'CASH', v_created, v_user);
    end if;
  end if;

  if p_approval is not null then perform public.pos_finish_approval(p_approval); end if;
  perform public.pos_audit('CREATE_SALE', 'bills', v_bill_id::text,
    jsonb_build_object('bill_number', p_bill_number, 'total', v_total, 'method', v_method, 'items', jsonb_array_length(p_items), 'cashier', v_user));
  return jsonb_build_object('bill_id', v_bill_id, 'bill_number', p_bill_number, 'subtotal', v_subtotal, 'total', v_total, 'stock_updated', true);
end $$;

-- ---- delete_entity: เพิ่ม p_session; สิทธิ์ตามชนิดข้อมูล ----
drop function if exists public.delete_entity(text,uuid,text);
create or replace function public.delete_entity(p_kind text, p_id uuid, p_note text default null, p_session uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_table text; v_count int := 0; v_debt numeric;
begin
  perform public.pos_check_perm(p_session, case lower(p_kind) when 'customer' then 'CUSTOMER_MANAGE' when 'supplier' then 'PURCHASE' else 'PRODUCT_DELETE' end, 'MANAGER');
  v_table := case lower(p_kind) when 'product' then 'products' when 'customer' then 'customers'
                                when 'supplier' then 'suppliers' when 'category' then 'categories' else null end;
  if v_table is null then raise exception 'ไม่รองรับการลบชนิดข้อมูล %', p_kind; end if;
  if v_table = 'products' then
    update public.products set is_active = false where id = p_id;
    get diagnostics v_count = row_count;
    update public.product_variants set is_active = false where product_id = p_id;
  elsif v_table = 'customers' then
    select debt into v_debt from public.customers where id = p_id;
    if not found then raise exception 'ไม่พบลูกค้า'; end if;
    if v_debt > 0 then raise exception 'ลูกค้ายังมียอดหนี้ค้าง % บาท ลบไม่ได้ (รับชำระให้ครบก่อน)', v_debt; end if;
    update public.customers set is_active = false where id = p_id;
    get diagnostics v_count = row_count;
  elsif v_table = 'suppliers' then
    update public.suppliers set is_active = false where id = p_id;
    get diagnostics v_count = row_count;
  else
    delete from public.categories where id = p_id;
    get diagnostics v_count = row_count;
  end if;
  if v_count = 0 then raise exception 'ไม่พบข้อมูลที่จะลบ'; end if;
  perform public.pos_audit('DELETE_ENTITY', v_table, p_id::text, jsonb_build_object('note', p_note));
  return jsonb_build_object('kind', v_table, 'id', p_id, 'affected', v_count);
end $$;

grant execute on function public.pos_approve_or_perm(uuid,uuid,text,text) to authenticated;
grant execute on function public.create_sale(text,uuid,uuid,uuid,numeric,numeric,text,jsonb,boolean,text,numeric,timestamptz,uuid,uuid) to authenticated;
grant execute on function public.delete_entity(text,uuid,text,uuid) to authenticated;

commit;
