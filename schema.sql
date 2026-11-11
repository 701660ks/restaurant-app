-- Restaurant app schema. Run in Supabase SQL editor. Enable Anonymous sign-ins in Auth settings.
create extension if not exists btree_gist;
create extension if not exists pgcrypto;

create type order_status as enum ('pending','accepted','preparing','ready','served','completed','cancelled');
create type pay_status as enum ('pending','paid','failed','refunded');
create type pay_method as enum ('cash','upi','gateway');
create type staff_role as enum ('waiter','chef','manager','cashier');
create type booking_status as enum ('pending','confirmed','rejected','cancelled');
create type table_status as enum ('available','occupied','reserved');

create sequence staff_seq;

create table admins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique not null references auth.users on delete cascade,
  email text, created_at timestamptz default now(), updated_at timestamptz default now());

-- Staff sign in via Supabase Auth: email staff-<staff_code>@staff.invalid, password = admin-issued PIN (hashed by Auth).
create table staff (
  id uuid primary key default gen_random_uuid(),
  staff_code text unique not null default 'ST' || lpad(nextval('staff_seq')::text, 4, '0'),
  user_id uuid unique references auth.users on delete set null,
  full_name text not null, mobile text not null unique check (mobile ~ '^[0-9+]{10,15}$'),
  email text, address text, role staff_role not null,
  joining_date date default current_date, salary numeric(10,2),
  active boolean not null default true,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table customers (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users on delete set null,
  name text not null, mobile text not null check (mobile ~ '^[0-9+]{10,15}$'),
  table_id uuid, -- table of the current verified QR session
  created_at timestamptz default now(), updated_at timestamptz default now());

create table food_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique, image_url text,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table food_items (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references food_categories on delete set null,
  name text not null, description text, image_url text,
  price numeric(10,2) not null check (price >= 0),
  is_veg boolean not null default true, available boolean not null default true,
  discount_percent numeric(5,2) not null default 0 check (discount_percent between 0 and 100),
  offer_text text, orders_count int not null default 0,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table restaurant_tables (
  id uuid primary key default gen_random_uuid(),
  number int not null unique, capacity int not null check (capacity > 0),
  status table_status not null default 'available',
  created_at timestamptz default now(), updated_at timestamptz default now());
alter table customers add foreign key (table_id) references restaurant_tables on delete set null;

create table table_qr_codes (
  id uuid primary key default gen_random_uuid(),
  table_id uuid not null unique references restaurant_tables on delete cascade,
  token text not null unique default encode(gen_random_bytes(24), 'hex'),
  created_at timestamptz default now(), updated_at timestamptz default now());

create table table_bookings (
  id uuid primary key default gen_random_uuid(),
  booking_code text unique not null default 'BK' || upper(substr(encode(gen_random_bytes(4),'hex'),1,6)),
  customer_id uuid references customers on delete set null,
  table_id uuid not null references restaurant_tables on delete cascade,
  customer_name text not null, mobile text not null, guests int not null check (guests > 0),
  starts_at timestamptz not null, ends_at timestamptz not null check (ends_at > starts_at),
  status booking_status not null default 'pending',
  created_at timestamptz default now(), updated_at timestamptz default now(),
  -- prevents overlapping active bookings for the same table
  exclude using gist (table_id with =, tstzrange(starts_at, ends_at) with &&)
    where (status in ('pending','confirmed')));

create table orders (
  id uuid primary key default gen_random_uuid(),
  order_no bigint generated always as identity,
  customer_id uuid not null references customers,
  table_id uuid not null references restaurant_tables,
  customer_name text not null,
  status order_status not null default 'pending',
  subtotal numeric(10,2) not null, tax numeric(10,2) not null,
  service_charge numeric(10,2) not null, discount numeric(10,2) not null, total numeric(10,2) not null,
  handled_by uuid references staff on delete set null,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders on delete cascade,
  food_item_id uuid references food_items on delete set null,
  name text not null, unit_price numeric(10,2) not null, quantity int not null check (quantity > 0),
  created_at timestamptz default now());

create table payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders on delete cascade,
  method pay_method not null, status pay_status not null default 'pending',
  amount numeric(10,2) not null, gateway_ref text, refunded_amount numeric(10,2) default 0,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table reviews (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references orders on delete cascade,
  customer_id uuid not null references customers,
  rating int not null check (rating between 1 and 5), comment text,
  created_at timestamptz default now());

create table notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_mobile text, user_id uuid, title text not null, body text,
  sent boolean not null default false, created_at timestamptz default now());

create table restaurant_settings ( -- single row
  id boolean primary key default true check (id),
  name text not null default 'My Restaurant', logo_url text, address text, phone text,
  opens time default '10:00', closes time default '23:00',
  working_days int[] default '{1,2,3,4,5,6,7}',
  tax_percent numeric(5,2) not null default 5, service_percent numeric(5,2) not null default 0,
  upi_id text, lat double precision, lng double precision, radius_m int not null default 50 check (radius_m > 0),
  updated_at timestamptz default now());
insert into restaurant_settings default values;

-- helpers
create function is_admin() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from admins where user_id = auth.uid()) $$;
create function my_staff_role() returns staff_role language sql stable security definer set search_path=public as
$$ select role from staff where user_id = auth.uid() and active $$;
create function my_customer_id() returns uuid language sql stable security definer set search_path=public as
$$ select id from customers where auth_user_id = auth.uid() $$;

-- generic updated_at trigger
create function touch() returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
do $$ declare t text; begin
  for t in select unnest(array['admins','staff','customers','food_categories','food_items','restaurant_tables',
    'table_qr_codes','table_bookings','orders','payments','restaurant_settings']) loop
    execute format('create trigger touch before update on %I for each row execute function touch()', t);
  end loop; end $$;

-- auto QR token per table
create function make_qr() returns trigger language plpgsql as $$
begin insert into table_qr_codes(table_id) values (new.id); return new; end $$;
create trigger table_qr after insert on restaurant_tables for each row execute function make_qr();

-- ===== RPCs =====
-- Verify QR token server-side; bind customer to table. Customer must be signed in anonymously.
create function start_table_session(p_token text, p_name text, p_mobile text, p_lat double precision, p_lng double precision)
returns table(table_id uuid, table_number int, customer_id uuid) language plpgsql security definer set search_path=public as $$
declare t restaurant_tables; c uuid; s restaurant_settings; dist double precision;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select rt.* into t from restaurant_tables rt join table_qr_codes q on q.table_id = rt.id where q.token = p_token;
  if not found then raise exception 'invalid QR code'; end if;
  select * into s from restaurant_settings;
  if s.lat is null or s.lng is null then raise exception 'restaurant location not configured'; end if;
  if p_lat is null or p_lng is null then raise exception 'location required'; end if;
  -- haversine distance in metres
  dist := 2 * 6371000 * asin(sqrt(power(sin(radians(p_lat - s.lat)/2),2)
          + cos(radians(s.lat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - s.lng)/2),2)));
  if dist > s.radius_m then
    raise exception 'You must be inside the restaurant to scan the table QR code and place an order.';
  end if;
  insert into customers(auth_user_id, name, mobile, table_id) values (auth.uid(), trim(p_name), trim(p_mobile), t.id)
  on conflict (auth_user_id) do update set name = excluded.name, mobile = excluded.mobile, table_id = t.id
  returning id into c;
  return query select t.id, t.number, c;
end $$;

-- Totals computed server-side from DB prices. p_items: [{"food_item_id": "...", "quantity": 2}]
create function place_order(p_items jsonb, p_method pay_method) returns uuid
language plpgsql security definer set search_path=public as $$
declare c customers; s restaurant_settings; oid uuid; sub numeric := 0; disc numeric := 0; i jsonb; f food_items; q int;
begin
  select * into c from customers where auth_user_id = auth.uid();
  if c.id is null or c.table_id is null then raise exception 'no verified table session'; end if;
  select * into s from restaurant_settings;
  if jsonb_array_length(p_items) = 0 then raise exception 'empty cart'; end if;
  insert into orders(customer_id, table_id, customer_name, subtotal, tax, service_charge, discount, total)
    values (c.id, c.table_id, c.name, 0, 0, 0, 0, 0) returning id into oid;
  for i in select * from jsonb_array_elements(p_items) loop
    q := (i->>'quantity')::int;
    if q is null or q < 1 or q > 50 then raise exception 'bad quantity'; end if;
    select * into f from food_items where id = (i->>'food_item_id')::uuid and available;
    if not found then raise exception 'item unavailable'; end if;
    insert into order_items(order_id, food_item_id, name, unit_price, quantity) values (oid, f.id, f.name, f.price, q);
    sub := sub + f.price * q; disc := disc + f.price * q * f.discount_percent / 100;
  end loop;
  update orders set subtotal = sub, discount = round(disc,2),
    tax = round((sub - disc) * s.tax_percent / 100, 2),
    service_charge = round((sub - disc) * s.service_percent / 100, 2),
    total = round((sub - disc) * (1 + (s.tax_percent + s.service_percent) / 100), 2)
  where id = oid;
  -- online methods stay 'pending' until a gateway webhook (service role) marks them paid
  insert into payments(order_id, method, amount) select id, p_method, total from orders where id = oid;
  update restaurant_tables set status = 'occupied' where id = c.table_id;
  return oid;
end $$;

create function available_tables(p_start timestamptz, p_end timestamptz, p_guests int)
returns setof restaurant_tables language sql stable security definer set search_path=public as $$
  select * from restaurant_tables t where capacity >= p_guests and not exists (
    select 1 from table_bookings b where b.table_id = t.id and b.status in ('pending','confirmed')
    and tstzrange(b.starts_at, b.ends_at) && tstzrange(p_start, p_end)) order by number $$;

create function book_table(p_table uuid, p_name text, p_mobile text, p_guests int, p_start timestamptz, p_end timestamptz)
returns text language plpgsql security definer set search_path=public as $$
declare c uuid; code text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_start < now() then raise exception 'start must be in the future'; end if;
  if not exists (select 1 from restaurant_tables where id = p_table and capacity >= p_guests) then raise exception 'table too small'; end if;
  insert into customers(auth_user_id, name, mobile) values (auth.uid(), trim(p_name), trim(p_mobile))
    on conflict (auth_user_id) do update set name = excluded.name, mobile = excluded.mobile returning id into c;
  insert into table_bookings(customer_id, table_id, customer_name, mobile, guests, starts_at, ends_at)
    values (c, p_table, trim(p_name), trim(p_mobile), p_guests, p_start, p_end) returning booking_code into code;
  return code; -- overlap => exclusion-constraint error
end $$;

-- Role-based status changes. Admin/manager: any. chef: preparing/ready. waiter: served. cashier: completed.
create function set_order_status(p_order uuid, p_status order_status) returns void
language plpgsql security definer set search_path=public as $$
declare r staff_role := my_staff_role(); sid uuid;
begin
  if not (is_admin() or r = 'manager'
    or (r = 'chef' and p_status in ('accepted','preparing','ready'))
    or (r = 'waiter' and p_status in ('accepted','served'))
    or (r = 'cashier' and p_status = 'completed')) then raise exception 'not allowed'; end if;
  select id into sid from staff where user_id = auth.uid();
  update orders set status = p_status, handled_by = coalesce(sid, handled_by) where id = p_order;
  if p_status = 'completed' then
    update food_items f set orders_count = orders_count + oi.quantity from order_items oi where oi.order_id = p_order and oi.food_item_id = f.id;
  end if;
end $$;

create function mark_cash_paid(p_order uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  if not (is_admin() or my_staff_role() in ('cashier','manager')) then raise exception 'not allowed'; end if;
  update payments set status = 'paid' where order_id = p_order and method = 'cash';
end $$;

-- ===== RLS =====
alter table admins enable row level security; alter table staff enable row level security;
alter table customers enable row level security; alter table food_categories enable row level security;
alter table food_items enable row level security; alter table restaurant_tables enable row level security;
alter table table_qr_codes enable row level security; alter table table_bookings enable row level security;
alter table orders enable row level security; alter table order_items enable row level security;
alter table payments enable row level security; alter table reviews enable row level security;
alter table notifications enable row level security; alter table restaurant_settings enable row level security;

-- admin: full access everywhere (tables with no other policy are admin/service-only)
do $$ declare t text; begin
  for t in select unnest(array['admins','staff','customers','food_categories','food_items','restaurant_tables',
    'table_qr_codes','table_bookings','orders','order_items','payments','reviews','notifications','restaurant_settings']) loop
    execute format('create policy admin_all on %I for all using (is_admin()) with check (is_admin())', t);
  end loop; end $$;

-- public menu / settings
create policy read_cat on food_categories for select using (true);
create policy read_food on food_items for select using (true);
create policy read_settings on restaurant_settings for select using (true);
-- staff (active) read ops data. Customer mobiles stay admin-only (orders hold a name snapshot).
create policy staff_self on staff for select using (user_id = auth.uid());
create policy staff_read_tables on restaurant_tables for select using (my_staff_role() is not null);
create policy staff_upd_tables on restaurant_tables for update using (my_staff_role() in ('waiter','manager')) with check (true);
create policy staff_read_orders on orders for select using (my_staff_role() is not null);
create policy staff_read_items on order_items for select using (my_staff_role() is not null);
create policy staff_read_pay on payments for select using (my_staff_role() in ('cashier','manager'));
-- customers: own data only
create policy cust_self on customers for select using (auth_user_id = auth.uid());
create policy cust_orders on orders for select using (customer_id = my_customer_id());
create policy cust_items on order_items for select using (exists (select 1 from orders o where o.id = order_id and o.customer_id = my_customer_id()));
create policy cust_pay on payments for select using (exists (select 1 from orders o where o.id = order_id and o.customer_id = my_customer_id()));
create policy cust_book on table_bookings for select using (customer_id = my_customer_id());
create policy cust_review_r on reviews for select using (customer_id = my_customer_id());
create policy cust_review_w on reviews for insert with check (customer_id = my_customer_id()
  and exists (select 1 from orders o where o.id = order_id and o.customer_id = my_customer_id() and o.status = 'completed'));
-- customers cannot read table_qr_codes (tokens) or insert orders/payments directly; only via RPCs above.

revoke execute on function set_order_status, mark_cash_paid from anon;
alter publication supabase_realtime add table orders, table_bookings, restaurant_tables;

-- demo data
insert into food_categories(name) values ('Starters'),('Mains'),('Drinks');
insert into food_items(category_id, name, description, price, is_veg, discount_percent)
  select id, 'Paneer Tikka', 'Grilled cottage cheese', 220, true, 10 from food_categories where name='Starters'
  union all select id, 'Butter Chicken', 'Creamy tomato gravy', 340, false, 0 from food_categories where name='Mains'
  union all select id, 'Masala Chai', 'Spiced tea', 60, true, 0 from food_categories where name='Drinks';
insert into restaurant_tables(number, capacity) values (1,2),(2,4),(3,4),(4,6);
-- After signing up your admin user in Auth: insert into admins(user_id,email) values ('<auth uid>','you@x.com');
