-- =============================================================================================
--  AMINE · أمين — base de données et logique serveur (Supabase / PostgreSQL 15+)
--  Version du schéma : 5
--
--  À exécuter EN ENTIER dans Supabase › SQL Editor › New query › Run.
--  Le script peut être ré-exécuté pour une mise à jour : il ne supprime aucune donnée.
--
--  Principe de sécurité
--  • Les tables vivent dans le schéma privé `amine`, inaccessible à l'API (rôles anon/authenticated).
--  • L'application n'accède aux données QUE par les fonctions du schéma `public` ci-dessous.
--    Chaque fonction vérifie qui appelle (auth.uid()), son rôle (client, commerçant, livreur,
--    admin) et valide toutes les entrées. Les prix et frais sont toujours recalculés ici.
--
--  Données personnelles et conservation
--  • Position GPS d'un livreur : une seule ligne par livreur, seulement pendant une course,
--    effacée à la fin de la course ou après 30 minutes sans mise à jour (amine.maintenance).
--  • Notifications supprimées après 120 jours ; compteurs anti-abus après 1 heure.
--  • Commandes conservées (comptabilité) ; si un client supprime son compte, ses coordonnées
--    sont retirées des commandes (nom, téléphone, adresse, notes) et son identifiant supprimé.
--  • Export des données personnelles : fonction export_my_data (bouton « Mes données »).
--  • Preuves de livraison (photo, signature, nom) : gardées avec la commande ; fichiers privés.
--  • Abonnements aux notifications push : supprimés avec le compte, ou quand le service de
--    l'appareil indique qu'ils ne sont plus valides ; file d'envoi vidée après 2 jours.
--  • Sauvegardes : aucune sauvegarde automatique sur l'offre gratuite de Supabase ; exporter
--    régulièrement (supabase db dump). Offre Pro : sauvegarde quotidienne, 7 jours conservés.
-- =============================================================================================

create schema if not exists amine;
revoke all on schema amine from public;

-- ── Paramètres de la plateforme ──────────────────────────────────────────────────────────────
create table if not exists amine.settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

-- ── Profils (1 par compte Supabase Auth) ────────────────────────────────────────────────────
create table if not exists amine.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  email            text,
  full_name        text not null default '' check (char_length(full_name) <= 120),
  phone            text check (phone is null or phone ~ '^\+216[2-9][0-9]{7}$'),
  phone_verified   boolean not null default false,
  locale           text not null default 'fr' check (locale in ('fr', 'ar', 'en')),
  is_admin         boolean not null default false,
  status           text not null default 'active' check (status in ('active', 'blocked')),
  marketing_opt_in boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists profiles_email_idx on amine.profiles (lower(email));

-- ── Villes et zones de livraison ────────────────────────────────────────────────────────────
create table if not exists amine.cities (
  id        uuid primary key default gen_random_uuid(),
  name_fr   text not null check (char_length(name_fr) between 2 and 60),
  name_ar   text not null check (char_length(name_ar) between 1 and 60),
  name_en   text not null check (char_length(name_en) between 2 and 60),
  is_active boolean not null default true,
  sort      int not null default 0
);

create table if not exists amine.zones (
  id          uuid primary key default gen_random_uuid(),
  city_id     uuid not null references amine.cities (id) on delete cascade,
  name_fr     text not null check (char_length(name_fr) between 2 and 60),
  name_ar     text not null check (char_length(name_ar) between 1 and 60),
  name_en     text not null check (char_length(name_en) between 2 and 60),
  center_lat  numeric(9, 6) not null check (center_lat between 30 and 38.5),
  center_lng  numeric(9, 6) not null check (center_lng between 7 and 12),
  radius_km   numeric(5, 2) not null check (radius_km > 0 and radius_km <= 50),
  base_fee    int not null default 2500 check (base_fee between 0 and 100000),
  included_km numeric(4, 1) not null default 2 check (included_km between 0 and 50),
  per_km_fee  int not null default 500 check (per_km_fee between 0 and 20000),
  max_fee     int not null default 9000 check (max_fee between 0 and 200000),
  services    text[] not null default array['grocery', 'shop', 'health', 'restaurant', 'parcel'],
  is_active   boolean not null default true,
  sort        int not null default 0,
  created_at  timestamptz not null default now()
);

-- ── Commerces ───────────────────────────────────────────────────────────────────────────────
create table if not exists amine.stores (
  id             uuid primary key default gen_random_uuid(),
  slug           text not null unique check (slug ~ '^[a-z0-9-]{3,80}$'),
  kind           text not null check (kind in ('grocery', 'shop', 'health', 'restaurant')),
  name           text not null check (char_length(name) between 2 and 80),
  name_ar        text check (name_ar is null or char_length(name_ar) <= 80),
  name_en        text check (name_en is null or char_length(name_en) <= 80),
  description    text check (description is null or char_length(description) <= 500),
  description_ar text check (description_ar is null or char_length(description_ar) <= 500),
  description_en text check (description_en is null or char_length(description_en) <= 500),
  phone          text check (phone is null or phone ~ '^\+216[2-9][0-9]{7}$'),
  address        text not null check (char_length(address) between 3 and 200),
  lat            numeric(9, 6) not null,
  lng            numeric(9, 6) not null,
  zone_id        uuid not null references amine.zones (id),
  logo_url       text check (logo_url is null or char_length(logo_url) <= 600),
  cover_url      text check (cover_url is null or char_length(cover_url) <= 600),
  status         text not null default 'pending' check (status in ('pending', 'active', 'rejected', 'suspended')),
  status_note    text check (status_note is null or char_length(status_note) <= 300),
  is_open        boolean not null default true,
  hours          jsonb not null default '{}'::jsonb,
  min_order      int not null default 0 check (min_order between 0 and 10000000),
  prep_minutes   int not null default 20 check (prep_minutes between 5 and 240),
  commission_bps int not null default 1000 check (commission_bps between 0 and 5000),
  owner_id       uuid references amine.profiles (id) on delete set null,
  rating_sum     int not null default 0,
  rating_count   int not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  approved_at    timestamptz
);
create index if not exists stores_zone_status_idx on amine.stores (zone_id, status);

create table if not exists amine.store_staff (
  store_id   uuid not null references amine.stores (id) on delete cascade,
  user_id    uuid not null references amine.profiles (id) on delete cascade,
  role       text not null default 'staff' check (role in ('owner', 'staff')),
  created_at timestamptz not null default now(),
  primary key (store_id, user_id)
);
create index if not exists store_staff_user_idx on amine.store_staff (user_id);

create table if not exists amine.sections (
  id         uuid primary key default gen_random_uuid(),
  store_id   uuid not null references amine.stores (id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 60),
  name_ar    text check (name_ar is null or char_length(name_ar) <= 60),
  name_en    text check (name_en is null or char_length(name_en) <= 60),
  sort       int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists sections_store_idx on amine.sections (store_id);

create table if not exists amine.products (
  id             uuid primary key default gen_random_uuid(),
  store_id       uuid not null references amine.stores (id) on delete cascade,
  section_id     uuid references amine.sections (id) on delete set null,
  sku            text check (sku is null or char_length(sku) between 1 and 60),
  name           text not null check (char_length(name) between 2 and 120),
  name_ar        text check (name_ar is null or char_length(name_ar) <= 120),
  name_en        text check (name_en is null or char_length(name_en) <= 120),
  description    text check (description is null or char_length(description) <= 500),
  description_ar text check (description_ar is null or char_length(description_ar) <= 500),
  description_en text check (description_en is null or char_length(description_en) <= 500),
  price          int not null check (price between 1 and 100000000),
  unit           text check (unit is null or char_length(unit) <= 20),
  stock          int check (stock is null or stock between 0 and 1000000),
  is_available   boolean not null default true,
  image_url      text check (image_url is null or char_length(image_url) <= 600),
  sort           int not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz
);
create index if not exists products_store_idx on amine.products (store_id) where deleted_at is null;
create unique index if not exists products_store_sku_idx on amine.products (store_id, sku)
  where sku is not null and deleted_at is null;

-- ── Adresses des clients ────────────────────────────────────────────────────────────────────
create table if not exists amine.addresses (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references amine.profiles (id) on delete cascade,
  label      text check (label is null or char_length(label) <= 40),
  line       text not null check (char_length(line) between 3 and 200),
  details    text check (details is null or char_length(details) <= 200),
  lat        numeric(9, 6) not null,
  lng        numeric(9, 6) not null,
  zone_id    uuid references amine.zones (id) on delete set null,
  located_by text not null default 'map' check (located_by in ('gps', 'map', 'zone')),
  created_at timestamptz not null default now()
);
create index if not exists addresses_user_idx on amine.addresses (user_id);

-- ── Livreurs ────────────────────────────────────────────────────────────────────────────────
create table if not exists amine.couriers (
  user_id      uuid primary key references amine.profiles (id) on delete cascade,
  vehicle      text not null check (vehicle in ('bike', 'scooter', 'car', 'foot')),
  zone_id      uuid references amine.zones (id) on delete set null,
  cin          text check (cin is null or cin ~ '^[0-9]{8}$'),
  note         text check (note is null or char_length(note) <= 300),
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'suspended')),
  status_note  text check (status_note is null or char_length(status_note) <= 300),
  is_online    boolean not null default false,
  last_seen_at timestamptz,
  rating_sum   int not null default 0,
  rating_count int not null default 0,
  created_at   timestamptz not null default now(),
  decided_at   timestamptz
);

-- ── Commandes (produits d'un commerce, ou colis) ────────────────────────────────────────────
create table if not exists amine.orders (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique,
  kind               text not null check (kind in ('store', 'parcel')),
  customer_id        uuid references amine.profiles (id) on delete set null,
  store_id           uuid references amine.stores (id) on delete restrict,
  courier_id         uuid references amine.couriers (user_id) on delete set null,
  zone_id            uuid references amine.zones (id) on delete set null,
  status             text not null check (status in ('placed', 'accepted', 'preparing', 'ready', 'picked_up', 'delivered', 'cancelled', 'rejected')),
  pickup_name        text not null,
  pickup_phone       text,
  pickup_address     text not null,
  pickup_details     text,
  pickup_lat         numeric(9, 6) not null,
  pickup_lng         numeric(9, 6) not null,
  dropoff_name       text not null,
  dropoff_phone      text,
  dropoff_address    text not null,
  dropoff_details    text,
  dropoff_lat        numeric(9, 6) not null,
  dropoff_lng        numeric(9, 6) not null,
  dropoff_located_by text,
  parcel_size        text check (parcel_size is null or parcel_size in ('small', 'medium', 'large')),
  parcel_description text check (parcel_description is null or char_length(parcel_description) <= 200),
  payer              text not null default 'customer' check (payer in ('customer', 'sender', 'recipient')),
  distance_km        numeric(6, 2) not null default 0,
  subtotal           int not null default 0 check (subtotal >= 0),
  delivery_fee       int not null default 0 check (delivery_fee >= 0),
  service_fee        int not null default 0 check (service_fee >= 0),
  total              int not null check (total >= 0),
  commission         int not null default 0 check (commission >= 0),
  courier_earning    int not null default 0 check (courier_earning >= 0),
  payment_method     text not null default 'cod' check (payment_method in ('cod')),
  cod_collected      int check (cod_collected is null or cod_collected >= 0),
  customer_note      text check (customer_note is null or char_length(customer_note) <= 300),
  cancel_reason      text check (cancel_reason is null or char_length(cancel_reason) <= 300),
  cancelled_by       text,
  store_rating       smallint check (store_rating is null or store_rating between 1 and 5),
  courier_rating     smallint check (courier_rating is null or courier_rating between 1 and 5),
  review_comment     text check (review_comment is null or char_length(review_comment) <= 500),
  idempotency_key    text check (idempotency_key is null or char_length(idempotency_key) <= 80),
  placed_at          timestamptz not null default now(),
  accepted_at        timestamptz,
  preparing_at       timestamptz,
  ready_at           timestamptz,
  assigned_at        timestamptz,
  picked_up_at       timestamptz,
  delivered_at       timestamptz,
  cancelled_at       timestamptz,
  updated_at         timestamptz not null default now()
);
create unique index if not exists orders_idempotency_idx on amine.orders (customer_id, idempotency_key)
  where idempotency_key is not null;
create index if not exists orders_customer_idx on amine.orders (customer_id, placed_at desc);
create index if not exists orders_store_idx on amine.orders (store_id, status, placed_at desc);
create index if not exists orders_courier_idx on amine.orders (courier_id, status);
create index if not exists orders_open_jobs_idx on amine.orders (zone_id, status) where courier_id is null;
create index if not exists orders_status_idx on amine.orders (status, placed_at);

create table if not exists amine.order_items (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references amine.orders (id) on delete cascade,
  product_id uuid references amine.products (id) on delete set null,
  name       text not null,
  unit       text,
  unit_price int not null check (unit_price > 0),
  quantity   int not null check (quantity between 1 and 99),
  total      int not null check (total > 0)
);
create index if not exists order_items_order_idx on amine.order_items (order_id);

create table if not exists amine.order_events (
  id         bigint generated always as identity primary key,
  order_id   uuid not null references amine.orders (id) on delete cascade,
  status     text not null,
  event      text not null default 'status',
  actor      text not null check (actor in ('customer', 'merchant', 'courier', 'admin', 'system')),
  actor_id   uuid,
  note       text,
  created_at timestamptz not null default now()
);
create index if not exists order_events_order_idx on amine.order_events (order_id, id);

-- Dernière position GPS partagée par le téléphone du livreur pendant une course (jamais inventée).
create table if not exists amine.courier_locations (
  courier_id  uuid primary key references amine.couriers (user_id) on delete cascade,
  order_id    uuid references amine.orders (id) on delete cascade,
  lat         numeric(9, 6) not null,
  lng         numeric(9, 6) not null,
  accuracy_m  int,
  heading     int,
  speed_kmh   int,
  recorded_at timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists amine.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references amine.profiles (id) on delete cascade,
  kind       text not null,
  params     jsonb not null default '{}'::jsonb,
  link       text,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on amine.notifications (user_id, created_at desc);

create table if not exists amine.rate_limits (
  key      text primary key,
  count    int not null,
  reset_at timestamptz not null
);

create table if not exists amine.audit_log (
  id         bigint generated always as identity primary key,
  actor_id   uuid,
  action     text not null,
  entity     text not null,
  entity_id  text,
  details    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists audit_log_created_idx on amine.audit_log (created_at desc);

-- ── Version 2 du schéma : AMINE fournisseur des restaurants ────────────────────────────────
-- Établissement du client (restaurant, café, hôtel…).
alter table amine.profiles add column if not exists business_name text
  check (business_name is null or char_length(business_name) between 2 and 120);
alter table amine.profiles add column if not exists business_type text
  check (business_type is null or business_type in ('restaurant', 'cafe', 'hotel', 'snack', 'caterer', 'bakery', 'other'));
alter table amine.profiles add column if not exists tax_id text
  check (tax_id is null or tax_id ~ '^[0-9A-Za-z/ .-]{4,30}$');

-- Référence du catalogue AMINE (illustration, synonymes de l'assistant).
alter table amine.products add column if not exists ref text check (ref is null or ref ~ '^[a-z0-9-]{2,60}$');

-- Commandes de professionnels : quantités jusqu'à 999, créneau de livraison, origine (appli ou assistant).
alter table amine.order_items drop constraint if exists order_items_quantity_check;
alter table amine.order_items add constraint order_items_quantity_check check (quantity between 1 and 999);
alter table amine.orders add column if not exists discount int not null default 0 check (discount >= 0);
alter table amine.orders add column if not exists promo_code text;
alter table amine.orders add column if not exists source text not null default 'app' check (source in ('app', 'chat'));
alter table amine.orders add column if not exists delivery_slot text
  check (delivery_slot is null or delivery_slot in ('asap', 'today_pm', 'tomorrow_am', 'tomorrow_noon', 'tomorrow_pm'));
alter table amine.orders add column if not exists deliver_on date;

-- Produits favoris (« mes produits habituels »).
create table if not exists amine.favorites (
  user_id    uuid not null references amine.profiles (id) on delete cascade,
  product_id uuid not null references amine.products (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, product_id)
);

create table if not exists amine.promotions (
  id                    uuid primary key default gen_random_uuid(),
  code                  text not null unique check (code ~ '^[A-Z0-9]{3,20}$'),
  description           text check (description is null or char_length(description) <= 120),
  kind                  text not null check (kind in ('percent', 'amount', 'free_delivery')),
  value                 int not null default 0 check (value >= 0 and value <= 100000000),
  max_discount          int check (max_discount is null or max_discount > 0),
  min_subtotal          int not null default 0 check (min_subtotal >= 0),
  zone_id               uuid references amine.zones (id) on delete cascade,
  store_id              uuid references amine.stores (id) on delete cascade,
  starts_at             timestamptz,
  ends_at               timestamptz,
  max_uses              int check (max_uses is null or max_uses > 0),
  max_uses_per_customer int not null default 1 check (max_uses_per_customer between 1 and 100),
  first_order_only      boolean not null default false,
  is_public             boolean not null default false,
  is_active             boolean not null default true,
  created_at            timestamptz not null default now(),
  created_by            uuid
);
alter table amine.promotions add column if not exists is_public boolean not null default false;
create index if not exists orders_promo_idx on amine.orders (promo_code) where promo_code is not null;

-- Réclamations des clients sur une commande.
create table if not exists amine.complaints (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references amine.orders (id) on delete cascade,
  customer_id uuid references amine.profiles (id) on delete set null,
  reason      text not null check (reason in ('missing_item', 'wrong_item', 'damaged', 'late', 'courier', 'payment', 'other')),
  message     text not null check (char_length(message) between 5 and 1000),
  status      text not null default 'open' check (status in ('open', 'in_progress', 'resolved', 'rejected')),
  reply       text check (reply is null or char_length(reply) <= 1000),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists complaints_status_idx on amine.complaints (status, created_at desc);
create index if not exists complaints_order_idx on amine.complaints (order_id);

-- Restaurants repérés dans OpenStreetMap, à contacter par l'équipe (jamais affichés aux clients).
create table if not exists amine.prospects (
  id            uuid primary key default gen_random_uuid(),
  osm_id        text not null unique check (osm_id ~ '^(node|way|relation)/[0-9]{1,15}$'),
  name          text not null check (char_length(name) between 1 and 120),
  name_ar       text check (name_ar is null or char_length(name_ar) <= 120),
  amenity       text not null check (amenity in ('restaurant', 'fast_food', 'cafe')),
  cuisine       text check (cuisine is null or char_length(cuisine) <= 120),
  address       text check (address is null or char_length(address) <= 200),
  phone         text check (phone is null or char_length(phone) <= 40),
  website       text check (website is null or char_length(website) <= 300),
  opening_hours text check (opening_hours is null or char_length(opening_hours) <= 200),
  lat           numeric(9, 6) not null,
  lng           numeric(9, 6) not null,
  zone_id       uuid references amine.zones (id) on delete set null,
  status        text not null default 'new' check (status in ('new', 'contacted', 'interested', 'refused', 'joined')),
  note          text check (note is null or char_length(note) <= 500),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists prospects_zone_idx on amine.prospects (zone_id, status);
-- Prospects ajoutés à la main (sans fiche OpenStreetMap ni coordonnées).
alter table amine.prospects alter column osm_id drop not null;
alter table amine.prospects alter column lat drop not null;
alter table amine.prospects alter column lng drop not null;
alter table amine.prospects add column if not exists source text not null default 'osm' check (source in ('osm', 'manual'));
alter table amine.prospects add column if not exists contact_name text
  check (contact_name is null or char_length(contact_name) <= 120);
alter table amine.prospects add column if not exists email text check (email is null or char_length(email) <= 160);
alter table amine.prospects add column if not exists contacted_at timestamptz;

-- Archivage : un dépôt, un livreur ou un code promo déjà utilisés dans des commandes ne sont pas
-- effacés (l'historique reste juste), ils sont archivés.
alter table amine.stores drop constraint if exists stores_status_check;
alter table amine.stores add constraint stores_status_check
  check (status in ('pending', 'active', 'rejected', 'suspended', 'archived'));
alter table amine.couriers drop constraint if exists couriers_status_check;
alter table amine.couriers add constraint couriers_status_check
  check (status in ('pending', 'approved', 'rejected', 'suspended', 'archived'));
alter table amine.promotions add column if not exists archived_at timestamptz;

-- Commandes saisies par l'équipe AMINE pour un client (téléphone, WhatsApp) ou créées par une
-- commande récurrente (version 3).
alter table amine.orders drop constraint if exists orders_source_check;
alter table amine.orders add constraint orders_source_check check (source in ('app', 'chat', 'admin', 'recurring'));

-- Produits de marque : marque, code-barres (EAN) et crédit de la photo (Open Food Facts, Wikimedia
-- Commons ou photo de l'équipe), affiché sous la photo comme l'exigent les licences libres.
alter table amine.products add column if not exists brand text check (brand is null or char_length(brand) between 1 and 60);
alter table amine.products add column if not exists barcode text check (barcode is null or barcode ~ '^[0-9]{8,14}$');
alter table amine.products add column if not exists image_credit jsonb;
create unique index if not exists products_store_barcode_idx on amine.products (store_id, barcode)
  where barcode is not null and deleted_at is null;

-- Note interne de l'équipe sur un client (jamais montrée au client).
alter table amine.profiles add column if not exists admin_note text
  check (admin_note is null or char_length(admin_note) <= 500);

-- ── Version 3 du schéma : vente aux professionnels ─────────────────────────────────────────
-- TVA par produit (0 = exonéré ; prix affichés TTC), prix par palier de quantité, dernier coût d'achat.
alter table amine.products add column if not exists vat_rate smallint not null default 19;
alter table amine.products drop constraint if exists products_vat_rate_check;
alter table amine.products add constraint products_vat_rate_check check (vat_rate in (0, 7, 13, 19));
alter table amine.products add column if not exists price_tiers jsonb not null default '[]'::jsonb;
alter table amine.products add column if not exists cost_price int
  check (cost_price is null or cost_price between 0 and 100000000);

-- Conditions commerciales d'un client : paiement à la livraison ou sur compte (à terme), délai,
-- plafond d'encours, remise générale (en points de base : 250 = 2,5 %).
alter table amine.profiles add column if not exists payment_terms text not null default 'cod';
alter table amine.profiles drop constraint if exists profiles_payment_terms_check;
alter table amine.profiles add constraint profiles_payment_terms_check check (payment_terms in ('cod', 'account'));
alter table amine.profiles add column if not exists payment_days int not null default 30
  check (payment_days between 0 and 120);
alter table amine.profiles add column if not exists credit_limit int not null default 0
  check (credit_limit between 0 and 1000000000);
alter table amine.profiles add column if not exists discount_bps int not null default 0
  check (discount_bps between 0 and 5000);

-- Prix négociés : un prix par client et par produit (prioritaire sur les paliers et la remise).
create table if not exists amine.client_prices (
  customer_id uuid not null references amine.profiles (id) on delete cascade,
  product_id  uuid not null references amine.products (id) on delete cascade,
  price       int not null check (price between 1 and 100000000),
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (customer_id, product_id)
);
create index if not exists client_prices_product_idx on amine.client_prices (product_id);

-- Lignes : taux de TVA et prix catalogue au moment de la commande ; quantité réellement livrée
-- (pesée au dépôt : 10,4 kg pour 10 kg commandés ; 0 = produit manquant).
alter table amine.order_items add column if not exists vat_rate smallint not null default 19;
alter table amine.order_items add column if not exists list_price int;
alter table amine.order_items add column if not exists actual_qty numeric(10, 3)
  check (actual_qty is null or actual_qty between 0 and 9999);
alter table amine.order_items drop constraint if exists order_items_total_check;
alter table amine.order_items add constraint order_items_total_check check (total >= 0);

-- Commandes récurrentes (« tous les lundis et jeudis matin ») : créées la veille du jour de
-- livraison, à l'heure réglée dans les paramètres.
create table if not exists amine.recurring_orders (
  id             uuid primary key default gen_random_uuid(),
  customer_id    uuid not null references amine.profiles (id) on delete cascade,
  store_id       uuid not null references amine.stores (id) on delete cascade,
  address_id     uuid references amine.addresses (id) on delete set null,
  items          jsonb not null,
  weekdays       int[] not null check (weekdays <@ array[1, 2, 3, 4, 5, 6, 7] and cardinality(weekdays) between 1 and 7),
  slot           text not null check (slot in ('am', 'noon', 'pm')),
  payment_method text not null default 'cod' check (payment_method in ('cod', 'account')),
  label          text check (label is null or char_length(label) <= 60),
  note           text check (note is null or char_length(note) <= 300),
  is_active      boolean not null default true,
  last_run_on    date,
  last_error     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid
);
create index if not exists recurring_orders_customer_idx on amine.recurring_orders (customer_id);

-- Tournées de livraison : plusieurs commandes d'un même jour confiées à un livreur, dans l'ordre.
create table if not exists amine.routes (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references amine.stores (id) on delete cascade,
  courier_id  uuid references amine.couriers (user_id) on delete set null,
  day         date not null,
  name        text check (name is null or char_length(name) <= 60),
  distance_km numeric(7, 2),
  created_at  timestamptz not null default now(),
  created_by  uuid
);
create index if not exists routes_day_idx on amine.routes (day, store_id);

-- Commandes : paiement sur compte, droit de timbre, pesée, récurrence, tournée.
alter table amine.orders drop constraint if exists orders_payment_method_check;
alter table amine.orders add constraint orders_payment_method_check check (payment_method in ('cod', 'account'));
alter table amine.orders add column if not exists stamp_fee int not null default 0 check (stamp_fee >= 0);
alter table amine.orders add column if not exists weights_adjusted_at timestamptz;
alter table amine.orders add column if not exists recurring_id uuid references amine.recurring_orders (id) on delete set null;
alter table amine.orders add column if not exists route_id uuid references amine.routes (id) on delete set null;
alter table amine.orders add column if not exists route_seq int;
create index if not exists orders_route_idx on amine.orders (route_id) where route_id is not null;

-- Factures et avoirs (numérotation continue par préfixe et par année). Les coordonnées du vendeur
-- et de l'acheteur, les lignes et la TVA sont figées au moment de l'émission.
create table if not exists amine.invoices (
  id             uuid primary key default gen_random_uuid(),
  number         text not null unique,
  kind           text not null check (kind in ('invoice', 'credit_note')),
  order_id       uuid references amine.orders (id) on delete restrict,
  invoice_id     uuid references amine.invoices (id) on delete restrict,
  customer_id    uuid references amine.profiles (id) on delete set null,
  store_id       uuid references amine.stores (id) on delete set null,
  issued_at      timestamptz not null default now(),
  due_on         date,
  seller         jsonb not null,
  buyer          jsonb not null,
  lines          jsonb not null,
  vat            jsonb not null,
  total_ht       int not null,
  total_vat      int not null,
  stamp          int not null default 0,
  total_ttc      int not null check (total_ttc >= 0),
  payment_method text not null,
  reason         text check (reason is null or char_length(reason) <= 300),
  reminded_at    timestamptz,
  created_by     uuid
);
create index if not exists invoices_customer_idx on amine.invoices (customer_id, issued_at);
create index if not exists invoices_issued_idx on amine.invoices (issued_at desc);
create unique index if not exists invoices_order_idx on amine.invoices (order_id) where kind = 'invoice';

create table if not exists amine.invoice_counters (
  prefix text not null,
  year   int not null,
  last   int not null default 0,
  primary key (prefix, year)
);

-- Compte client : montants dus (+) et réglés (−). Solde = somme des montants.
create table if not exists amine.account_entries (
  id          bigint generated always as identity primary key,
  customer_id uuid not null references amine.profiles (id) on delete cascade,
  kind        text not null check (kind in ('invoice', 'payment', 'credit_note', 'adjustment')),
  amount      int not null check (amount <> 0 and amount between -1000000000 and 1000000000),
  invoice_id  uuid references amine.invoices (id) on delete set null,
  method      text check (method is null or method in ('cash', 'cheque', 'transfer', 'card', 'other')),
  reference   text check (reference is null or char_length(reference) <= 80),
  note        text check (note is null or char_length(note) <= 300),
  occurred_on date not null default ((now() at time zone 'Africa/Tunis')::date),
  created_at  timestamptz not null default now(),
  created_by  uuid
);
create index if not exists account_entries_customer_idx on amine.account_entries (customer_id, occurred_on, id);

-- Achats et stock du dépôt : fournisseurs, réceptions (avec date limite), mouvements de stock.
create table if not exists amine.suppliers (
  id         uuid primary key default gen_random_uuid(),
  store_id   uuid not null references amine.stores (id) on delete cascade,
  name       text not null check (char_length(name) between 2 and 120),
  phone      text check (phone is null or phone ~ '^\+216[2-9][0-9]{7}$'),
  email      text check (email is null or char_length(email) <= 160),
  tax_id     text check (tax_id is null or char_length(tax_id) <= 30),
  address    text check (address is null or char_length(address) <= 200),
  note       text check (note is null or char_length(note) <= 300),
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists suppliers_store_idx on amine.suppliers (store_id);

create table if not exists amine.purchases (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references amine.stores (id) on delete cascade,
  supplier_id uuid references amine.suppliers (id) on delete set null,
  reference   text check (reference is null or char_length(reference) <= 60),
  received_on date not null,
  total       int not null default 0 check (total >= 0),
  status      text not null default 'received' check (status in ('received', 'cancelled')),
  note        text check (note is null or char_length(note) <= 300),
  created_at  timestamptz not null default now(),
  created_by  uuid
);
create index if not exists purchases_store_idx on amine.purchases (store_id, received_on desc);

create table if not exists amine.purchase_lines (
  id          uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references amine.purchases (id) on delete cascade,
  product_id  uuid references amine.products (id) on delete set null,
  name        text not null,
  unit        text,
  quantity    int not null check (quantity between 1 and 1000000),
  unit_cost   int not null check (unit_cost between 0 and 100000000),
  expiry_on   date,
  lot         text check (lot is null or char_length(lot) <= 40)
);
create index if not exists purchase_lines_purchase_idx on amine.purchase_lines (purchase_id);
create index if not exists purchase_lines_expiry_idx on amine.purchase_lines (expiry_on) where expiry_on is not null;

create table if not exists amine.stock_movements (
  id          bigint generated always as identity primary key,
  store_id    uuid not null references amine.stores (id) on delete cascade,
  product_id  uuid not null references amine.products (id) on delete cascade,
  kind        text not null check (kind in ('sale', 'return', 'purchase', 'purchase_cancel', 'loss', 'count', 'adjustment')),
  quantity    int not null,
  stock_after int,
  ref         text,
  reason      text,
  created_at  timestamptz not null default now(),
  created_by  uuid
);
create index if not exists stock_movements_store_idx on amine.stock_movements (store_id, created_at desc);
create index if not exists stock_movements_product_idx on amine.stock_movements (product_id, created_at desc);

-- ── Version 4 du schéma : livraison, espèces, achats, lots, notifications push ─────────────────
-- Preuve de livraison : nom de la personne qui a reçu, photo et signature (fichiers privés dans le
-- stockage « amine-proofs », lisibles seulement par le client, le dépôt, le livreur et l'administration).
alter table amine.orders add column if not exists pod_name text check (pod_name is null or char_length(pod_name) <= 80);
alter table amine.orders add column if not exists pod_photo text check (pod_photo is null or char_length(pod_photo) <= 200);
alter table amine.orders add column if not exists pod_signature text check (pod_signature is null or char_length(pod_signature) <= 200);
alter table amine.orders add column if not exists pod_at timestamptz;

-- Espèces remises par un livreur au dépôt ou à l'équipe AMINE. Espèces en main d'un livreur =
-- espèces encaissées (commandes livrées) − espèces remises.
create table if not exists amine.cash_handovers (
  id          uuid primary key default gen_random_uuid(),
  courier_id  uuid references amine.couriers (user_id) on delete set null,
  store_id    uuid references amine.stores (id) on delete set null,
  amount      int not null check (amount between 1 and 100000000),
  note        text check (note is null or char_length(note) <= 200),
  received_by uuid references amine.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists cash_handovers_courier_idx on amine.cash_handovers (courier_id, created_at desc);
-- Les espèces encaissées avant la version 4 ne sont pas comptées (réglées hors application).
alter table amine.couriers add column if not exists cash_since timestamptz not null default now();

-- Lots : quantité restante de chaque réception (consommée dans l'ordre des dates limites), et
-- répartition des sorties de stock par lot (pour remettre en stock le bon lot en cas d'annulation).
alter table amine.purchase_lines add column if not exists remaining int check (remaining is null or remaining >= 0);
-- Première mise à jour : le stock actuel est attribué aux réceptions les plus récentes (les plus
-- anciennes sont supposées vendues en premier).
update amine.purchase_lines l set remaining = greatest(0, least(l.quantity, x.stock - x.newer))
from (select l2.id, coalesce(p.stock, 0) as stock,
        coalesce(sum(l2.quantity) over (partition by l2.product_id order by pu.received_on desc, l2.id desc
          rows between unbounded preceding and 1 preceding), 0) as newer
      from amine.purchase_lines l2 join amine.purchases pu on pu.id = l2.purchase_id
      join amine.products p on p.id = l2.product_id
      where l2.remaining is null and pu.status = 'received') x
where l.id = x.id;
update amine.purchase_lines set remaining = 0 where remaining is null;
create index if not exists purchase_lines_remaining_idx on amine.purchase_lines (product_id) where remaining > 0;
create table if not exists amine.stock_lot_moves (
  id               bigint generated always as identity primary key,
  movement_id      bigint not null references amine.stock_movements (id) on delete cascade,
  purchase_line_id uuid not null references amine.purchase_lines (id) on delete cascade,
  quantity         int not null
);
create index if not exists stock_lot_moves_movement_idx on amine.stock_lot_moves (movement_id);
create index if not exists stock_lot_moves_line_idx on amine.stock_lot_moves (purchase_line_id);

-- Bons de commande aux fournisseurs (brouillon → envoyé → reçu, ou annulé).
create table if not exists amine.purchase_orders (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references amine.stores (id) on delete cascade,
  supplier_id uuid references amine.suppliers (id) on delete set null,
  number      text not null unique,
  status      text not null default 'draft' check (status in ('draft', 'sent', 'received', 'cancelled')),
  expected_on date,
  note        text check (note is null or char_length(note) <= 300),
  total       int not null default 0 check (total >= 0),
  purchase_id uuid references amine.purchases (id) on delete set null,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  sent_at     timestamptz,
  received_at timestamptz
);
create index if not exists purchase_orders_store_idx on amine.purchase_orders (store_id, created_at desc);
create table if not exists amine.purchase_order_lines (
  id         uuid primary key default gen_random_uuid(),
  po_id      uuid not null references amine.purchase_orders (id) on delete cascade,
  product_id uuid references amine.products (id) on delete set null,
  name       text not null,
  unit       text,
  quantity   int not null check (quantity between 1 and 1000000),
  unit_cost  int check (unit_cost is null or unit_cost between 0 and 100000000)
);
create index if not exists purchase_order_lines_po_idx on amine.purchase_order_lines (po_id);

-- Notifications « push » (application fermée) : abonnements des appareils, file d'envoi, clés VAPID.
-- La clé privée ne quitte jamais la base et la fonction d'envoi (Supabase Edge Function).
create table if not exists amine.push_subscriptions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references amine.profiles (id) on delete cascade,
  endpoint     text not null unique check (char_length(endpoint) <= 1000),
  p256dh       text not null check (char_length(p256dh) between 80 and 120),
  auth         text not null check (char_length(auth) between 16 and 40),
  created_at   timestamptz not null default now(),
  last_used_at timestamptz
);
create index if not exists push_subscriptions_user_idx on amine.push_subscriptions (user_id);
create table if not exists amine.push_queue (
  id              bigint generated always as identity primary key,
  subscription_id uuid not null references amine.push_subscriptions (id) on delete cascade,
  payload         jsonb not null,
  attempts        int not null default 0,
  taken_at        timestamptz,
  created_at      timestamptz not null default now()
);
create index if not exists push_queue_created_idx on amine.push_queue (created_at);
-- Clés VAPID créées par la fonction d'envoi au premier appel ; jeton (aléatoire) que la base envoie à
-- cette fonction pour la réveiller (un appel sans ce jeton est refusé).
create table if not exists amine.push_keys (
  id          int primary key default 1 check (id = 1),
  public_key  text check (public_key is null or public_key ~ '^[A-Za-z0-9_-]{80,100}$'),
  private_jwk jsonb,
  wake_token  text not null,
  created_at  timestamptz not null default now()
);
insert into amine.push_keys (id, wake_token)
values (1, replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
on conflict (id) do nothing;

-- Toutes les tables : RLS activé, aucune politique => aucun accès direct depuis l'API.
alter table amine.settings enable row level security;
alter table amine.profiles enable row level security;
alter table amine.cities enable row level security;
alter table amine.zones enable row level security;
alter table amine.stores enable row level security;
alter table amine.store_staff enable row level security;
alter table amine.sections enable row level security;
alter table amine.products enable row level security;
alter table amine.addresses enable row level security;
alter table amine.couriers enable row level security;
alter table amine.orders enable row level security;
alter table amine.order_items enable row level security;
alter table amine.order_events enable row level security;
alter table amine.courier_locations enable row level security;
alter table amine.notifications enable row level security;
alter table amine.rate_limits enable row level security;
alter table amine.audit_log enable row level security;
alter table amine.favorites enable row level security;
alter table amine.promotions enable row level security;
alter table amine.complaints enable row level security;
alter table amine.prospects enable row level security;
alter table amine.client_prices enable row level security;
alter table amine.recurring_orders enable row level security;
alter table amine.routes enable row level security;
alter table amine.invoices enable row level security;
alter table amine.invoice_counters enable row level security;
alter table amine.account_entries enable row level security;
alter table amine.suppliers enable row level security;
alter table amine.purchases enable row level security;
alter table amine.purchase_lines enable row level security;
alter table amine.stock_movements enable row level security;
alter table amine.cash_handovers enable row level security;
alter table amine.stock_lot_moves enable row level security;
alter table amine.purchase_orders enable row level security;
alter table amine.purchase_order_lines enable row level security;
alter table amine.push_subscriptions enable row level security;
alter table amine.push_queue enable row level security;
alter table amine.push_keys enable row level security;

-- =============================================================================================
--  Fonctions internes (schéma amine) — non appelables depuis l'API
-- =============================================================================================

-- Erreur métier : le message est un code stable traduit par l'application (ex. STORE_CLOSED).
create or replace function amine.err(p_code text, p_detail text default null) returns void
language plpgsql set search_path = '' as $$
begin
  if p_detail is null then
    raise exception using errcode = 'P0001', message = p_code;
  else
    raise exception using errcode = 'P0001', message = p_code, detail = p_detail;
  end if;
end $$;

create or replace function amine.default_setting(p_key text) returns jsonb
language sql immutable set search_path = '' as $$
  select case p_key
    when 'platform' then '{"name":"AMINE","support_phone":"","support_email":"","maintenance":false,"announcement":""}'::jsonb
    when 'orders' then '{"auto_cancel_minutes":30,"max_active_per_customer":5,"service_fee":0,"max_distance_km":15,"recurring_hour":15,"require_pod":false}'::jsonb
    when 'parcel' then '{"enabled":false,"size_fee":{"small":0,"medium":1500,"large":4000}}'::jsonb
    when 'couriers' then '{"share_bps":8000,"max_active_jobs":2}'::jsonb
    when 'auth' then '{"require_phone_verification":false,"admin_mfa_required":false}'::jsonb
    when 'push' then '{"enabled":false,"function_url":""}'::jsonb
    -- Fidélité (version 8) : points gagnés par dinar de marchandises livrées, valeur d'un point (millimes),
    -- seuil et plafond d'utilisation, parrainage (points offerts à chacun, première commande minimale,
    -- nombre de filleuls au plus), relance des restaurants inactifs (jours sans commande).
    when 'loyalty' then '{"enabled":true,"earn_per_dt":1,"point_value":10,"min_redeem":500,"max_redeem_bps":2000,"referral_enabled":true,"referral_points":1000,"referral_min_subtotal":100000,"referral_max":20,"remind_enabled":true,"remind_days":15}'::jsonb
    -- Facturation : préfixes de numérotation, droit de timbre par facture (millimes), TVA de la
    -- livraison, délai entre deux relances, mention libre en bas de facture. Prix affichés TTC.
    when 'invoicing' then '{"prefix":"FA","credit_prefix":"AV","stamp":1000,"delivery_vat_rate":19,"reminder_days":7,"vat_verified":false,"footer":""}'::jsonb
    when 'legal' then '{"company_name":"","legal_form":"","rne":"","tax_id":"","address":"","email":"","phone":"","director":"","host":"","reviewed":false}'::jsonb
    else '{}'::jsonb
  end
$$;

create or replace function amine.setting(p_key text) returns jsonb
language sql stable set search_path = '' as $$
  select amine.default_setting(p_key) || coalesce((select s.value from amine.settings s where s.key = p_key), '{}'::jsonb)
$$;

-- Solde de points de fidélité d'un client (table amine.loyalty_ledger, créée par 14_loyalty.sql : la fonction
-- est en plpgsql pour que les fichiers précédents puissent l'utiliser avant la création de la table).
create or replace function amine.loyalty_balance(p_customer uuid) returns int
language plpgsql stable set search_path = '' as $$
begin
  return coalesce((select sum(l.delta) from amine.loyalty_ledger l where l.customer_id = p_customer), 0)::int;
end $$;

-- Identité de l'appelant ---------------------------------------------------------------------
create or replace function amine.uid() returns uuid
language plpgsql stable set search_path = '' as $$
declare
  v uuid := auth.uid();
begin
  if v is null then
    perform amine.err('UNAUTHENTICATED');
  end if;
  return v;
end $$;

-- Facteur de double authentification (application TOTP) validé dans Supabase Auth.
create or replace function amine.has_mfa(p_user uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from auth.mfa_factors f where f.user_id = p_user and f.status = 'verified')
$$;

-- 'ok' ; 'required' : facteur validé mais session pas encore au niveau « aal2 » ; 'setup' : administrateur
-- tenu d'activer la double authentification (paramètre auth.admin_mfa_required).
create or replace function amine.mfa_state(p amine.profiles) returns text
language sql stable set search_path = '' as $$
  select case
    when coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2' then 'ok'
    when amine.has_mfa(p.id) then 'required'
    when p.is_admin and coalesce((amine.setting('auth') ->> 'admin_mfa_required')::boolean, false) then 'setup'
    else 'ok' end
$$;

create or replace function amine.me() returns amine.profiles
language plpgsql set search_path = '' as $$
declare
  v_uid uuid := amine.uid();
  p amine.profiles;
begin
  select * into p from amine.profiles where id = v_uid;
  if not found then
    -- Compte créé avant l'installation du script : on crée le profil manquant.
    insert into amine.profiles (id, email)
    select u.id, u.email from auth.users u where u.id = v_uid
    on conflict (id) do nothing;
    select * into p from amine.profiles where id = v_uid;
    if not found then
      perform amine.err('UNAUTHENTICATED');
    end if;
  end if;
  if p.status <> 'active' then
    perform amine.err('ACCOUNT_BLOCKED');
  end if;
  -- Double authentification : un compte qui l'a activée doit l'avoir validée pour cette session
  -- (niveau « aal2 » du jeton Supabase) ; un administrateur peut y être obligé (paramètres).
  case amine.mfa_state(p)
    when 'required' then perform amine.err('MFA_REQUIRED');
    when 'setup' then perform amine.err('MFA_SETUP_REQUIRED');
    else null;
  end case;
  return p;
end $$;

create or replace function amine.require_admin() returns amine.profiles
language plpgsql set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  if not p.is_admin then
    perform amine.err('FORBIDDEN');
  end if;
  return p;
end $$;

-- Membre du commerce (ou admin). p_owner_only : réservé au propriétaire (ou admin).
create or replace function amine.require_staff(p_store_id uuid, p_owner_only boolean default false) returns amine.stores
language plpgsql set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  s amine.stores;
  v_role text;
begin
  if p_store_id is null then
    perform amine.err('NOT_FOUND');
  end if;
  select * into s from amine.stores where id = p_store_id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if p.is_admin then
    return s;
  end if;
  select role into v_role from amine.store_staff where store_id = p_store_id and user_id = p.id;
  if v_role is null or (p_owner_only and v_role <> 'owner') then
    perform amine.err('FORBIDDEN');
  end if;
  return s;
end $$;

create or replace function amine.require_courier() returns amine.couriers
language plpgsql set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  c amine.couriers;
begin
  select * into c from amine.couriers where user_id = p.id;
  if not found or c.status <> 'approved' then
    perform amine.err('COURIER_NOT_APPROVED');
  end if;
  update amine.couriers set last_seen_at = now() where user_id = p.id;
  return c;
end $$;

-- Limitation de débit (fenêtre fixe) ---------------------------------------------------------
create or replace function amine.hit(p_key text, p_max int, p_window_seconds int) returns void
language plpgsql set search_path = '' as $$
declare
  v_count int;
begin
  insert into amine.rate_limits as r (key, count, reset_at)
  values (p_key, 1, now() + make_interval(secs => p_window_seconds))
  on conflict (key) do update set
    count = case when r.reset_at <= now() then 1 else r.count + 1 end,
    reset_at = case when r.reset_at <= now() then excluded.reset_at else r.reset_at end
  returning count into v_count;
  if v_count > p_max then
    perform amine.err('RATE_LIMITED');
  end if;
end $$;

-- Validation des entrées ---------------------------------------------------------------------
-- Texte nettoyé (caractères de contrôle retirés, espaces aux extrémités) ; null si vide.
create or replace function amine.txt(
  p_value text, p_field text, p_max int, p_required boolean default false, p_min int default 1, p_multiline boolean default false
) returns text
language plpgsql immutable set search_path = '' as $$
declare
  v text := coalesce(p_value, '');
begin
  if p_multiline then
    v := regexp_replace(v, E'[\\x01-\\x09\\x0B-\\x1F\\x7F]', ' ', 'g');
    v := regexp_replace(v, E'\\n{3,}', E'\n\n', 'g');
  else
    v := regexp_replace(v, E'[\\x01-\\x1F\\x7F]', ' ', 'g');
    v := regexp_replace(v, ' {2,}', ' ', 'g');
  end if;
  v := btrim(v);
  if v = '' then
    if p_required then
      perform amine.err('INVALID_INPUT', p_field);
    end if;
    return null;
  end if;
  if char_length(v) < p_min or char_length(v) > p_max then
    perform amine.err('INVALID_INPUT', p_field);
  end if;
  return v;
end $$;

-- Numéro tunisien => +216XXXXXXXX (null si invalide).
create or replace function amine.normalize_phone(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare
  d text;
begin
  if p is null then
    return null;
  end if;
  d := regexp_replace(p, '[^0-9+]', '', 'g');
  if d ~ '^\+216[0-9]{8}$' then
    d := substr(d, 5);
  elsif d ~ '^00216[0-9]{8}$' then
    d := substr(d, 6);
  elsif d ~ '^216[0-9]{8}$' then
    d := substr(d, 4);
  end if;
  if d ~ '^[2-9][0-9]{7}$' then
    return '+216' || d;
  end if;
  return null;
end $$;

create or replace function amine.phone_in(p text, p_field text, p_required boolean default false) returns text
language plpgsql immutable set search_path = '' as $$
declare
  v text;
begin
  if p is null or btrim(p) = '' then
    if p_required then
      perform amine.err('INVALID_PHONE', p_field);
    end if;
    return null;
  end if;
  v := amine.normalize_phone(p);
  if v is null then
    perform amine.err('INVALID_PHONE', p_field);
  end if;
  return v;
end $$;

-- Coordonnées : doivent être en Tunisie.
create or replace function amine.check_point(p_lat numeric, p_lng numeric) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p_lat is null or p_lng is null or p_lat < 30 or p_lat > 38.5 or p_lng < 7 or p_lng > 12 then
    perform amine.err('INVALID_LOCATION');
  end if;
end $$;

create or replace function amine.like_escape(p text) returns text
language sql immutable set search_path = '' as $$
  select replace(replace(replace(p, '\', '\\'), '%', '\%'), '_', '\_')
$$;

-- Recherche tolérante : minuscules, sans accents (é → e, œ → oe), lettres arabes normalisées
-- (أ إ آ ٱ → ا, ة → ه, ى → ي) et sans voyelles brèves ni tatweel.
create or replace function amine.fold(p text) returns text
language sql immutable set search_path = '' as $$
  select translate(replace(replace(lower(coalesce(p, '')), 'œ', 'oe'), 'æ', 'ae'),
    'àâäáãåçéèêëíìîïñóòôöõúùûüýÿأإآٱةىـًٌٍَُِّْ',
    'aaaaaaceeeeiiiinooooouuuuyyااااهي')
$$;

create or replace function amine.first_name(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(split_part(btrim(coalesce(p, '')), ' ', 1), '')
$$;

-- Image hébergée dans le stockage AMINE, dans le dossier du commerce.
create or replace function amine.media_url_ok(p_url text, p_store uuid) returns boolean
language sql immutable set search_path = '' as $$
  select p_url is null or (
    char_length(p_url) <= 600
    and p_url ~ '^https?://[^[:space:]"''<>\\]+$'
    and position(('/storage/v1/object/public/amine-media/stores/' || p_store::text || '/') in p_url) > 0
  )
$$;

-- Photo d'un produit : stockage AMINE du dépôt, ou photo sous licence libre d'Open Food Facts
-- (images.openfoodfacts.org) ou de Wikimedia Commons (upload.wikimedia.org).
create or replace function amine.product_image_ok(p_url text, p_store uuid) returns boolean
language sql immutable set search_path = '' as $$
  select amine.media_url_ok(p_url, p_store) or (
    char_length(p_url) <= 600 and p_url ~ '^https://(images\.openfoodfacts\.org/images/products/|static\.openfoodfacts\.org/images/products/|upload\.wikimedia\.org/wikipedia/commons/)[^[:space:]"''<>\\]+$'
  )
$$;

-- Crédit d'une photo : {"source": "openfoodfacts" | "wikimedia" | "own", "author": "...", "license": "CC BY-SA 3.0",
-- "url": "https://…" (page d'origine), "title": "..."}. null = aucune information.
create or replace function amine.credit_in(p jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare
  v_url text;
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p) <> 'object' or coalesce(p ->> 'source', '') not in ('openfoodfacts', 'wikimedia', 'own') then
    perform amine.err('INVALID_INPUT', 'image_credit');
  end if;
  v_url := nullif(btrim(coalesce(p ->> 'url', '')), '');
  if v_url is not null and (char_length(v_url) > 600
     or v_url !~ '^https://([a-z0-9-]+\.)*(openfoodfacts\.org|wikimedia\.org|wikipedia\.org)/[^[:space:]"''<>\\]*$') then
    perform amine.err('INVALID_INPUT', 'image_credit');
  end if;
  return jsonb_build_object('source', p ->> 'source',
    'author', left(nullif(btrim(regexp_replace(coalesce(p ->> 'author', ''), '[[:cntrl:]<>]', ' ', 'g')), ''), 200),
    'license', left(nullif(btrim(regexp_replace(coalesce(p ->> 'license', ''), '[[:cntrl:]<>]', ' ', 'g')), ''), 60),
    'title', left(nullif(btrim(regexp_replace(coalesce(p ->> 'title', ''), '[[:cntrl:]<>]', ' ', 'g')), ''), 200),
    'url', v_url);
end $$;

-- Géographie ---------------------------------------------------------------------------------
create or replace function amine.distance_km(p_lat1 numeric, p_lng1 numeric, p_lat2 numeric, p_lng2 numeric) returns numeric
language sql immutable set search_path = '' as $$
  select round((6371 * 2 * asin(least(1, sqrt(
    power(sin(radians((p_lat2 - p_lat1)::float8 / 2)), 2)
    + cos(radians(p_lat1::float8)) * cos(radians(p_lat2::float8)) * power(sin(radians((p_lng2 - p_lng1)::float8 / 2)), 2)
  ))))::numeric, 2)
$$;

-- Zone active couvrant un point (la plus proche si plusieurs).
create or replace function amine.zone_for(p_lat numeric, p_lng numeric) returns amine.zones
language sql stable set search_path = '' as $$
  select z.*
  from amine.zones z
  join amine.cities c on c.id = z.city_id
  where z.is_active and c.is_active
    and amine.distance_km(z.center_lat, z.center_lng, p_lat, p_lng) <= z.radius_km
  order by amine.distance_km(z.center_lat, z.center_lng, p_lat, p_lng)
  limit 1
$$;

create or replace function amine.fee_for(z amine.zones, p_km numeric) returns int
language sql immutable set search_path = '' as $$
  select least(z.max_fee, z.base_fee + z.per_km_fee * greatest(0, ceil(p_km - z.included_km))::int)
$$;

-- Horaires ------------------------------------------------------------------------------------
create or replace function amine.default_hours() returns jsonb
language sql immutable set search_path = '' as $$
  select '{"1":[["08:00","22:00"]],"2":[["08:00","22:00"]],"3":[["08:00","22:00"]],"4":[["08:00","22:00"]],"5":[["08:00","22:00"]],"6":[["08:00","22:00"]],"7":[["08:00","22:00"]]}'::jsonb
$$;

create or replace function amine.valid_hours(p jsonb) returns boolean
language plpgsql immutable set search_path = '' as $$
declare
  k text;
  v jsonb;
  slot jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return false;
  end if;
  for k, v in select e.key, e.value from jsonb_each(p) e loop
    if k !~ '^[1-7]$' or jsonb_typeof(v) <> 'array' or jsonb_array_length(v) > 3 then
      return false;
    end if;
    for slot in select a.value from jsonb_array_elements(v) a loop
      if jsonb_typeof(slot) <> 'array' or jsonb_array_length(slot) <> 2 then
        return false;
      end if;
      if coalesce(slot ->> 0, '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
         or coalesce(slot ->> 1, '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
         or slot ->> 0 = slot ->> 1 then
        return false;
      end if;
    end loop;
  end loop;
  return true;
end $$;

-- Ouvert maintenant ? (heure de Tunis ; un créneau 18:00–02:00 déborde sur le lendemain)
create or replace function amine.store_open_now(s amine.stores) returns boolean
language plpgsql stable set search_path = '' as $$
declare
  t timestamp := now() at time zone 'Africa/Tunis';
  dow int := extract(isodow from t)::int;
  prev int := case when extract(isodow from t)::int = 1 then 7 else extract(isodow from t)::int - 1 end;
  hm text := to_char(t, 'HH24:MI');
  slot jsonb;
begin
  if s.id is null or s.status <> 'active' or not s.is_open then
    return false;
  end if;
  if s.hours is null or s.hours = '{}'::jsonb then
    return true;
  end if;
  for slot in select a.value from jsonb_array_elements(coalesce(s.hours -> dow::text, '[]'::jsonb)) a loop
    if (slot ->> 0) < (slot ->> 1) then
      if hm >= slot ->> 0 and hm < slot ->> 1 then
        return true;
      end if;
    elsif hm >= slot ->> 0 then
      return true;
    end if;
  end loop;
  for slot in select a.value from jsonb_array_elements(coalesce(s.hours -> prev::text, '[]'::jsonb)) a loop
    if (slot ->> 0) > (slot ->> 1) and hm < slot ->> 1 then
      return true;
    end if;
  end loop;
  return false;
end $$;

-- Créneaux de livraison (heure de Tunis) ------------------------------------------------------
--   asap          : dès que possible, le dépôt doit être ouvert
--   today_pm      : aujourd'hui 14 h – 18 h (commande avant 12 h)
--   tomorrow_am   : demain 7 h – 10 h      tomorrow_noon : demain 10 h – 13 h
--   tomorrow_pm   : demain 14 h – 18 h
create or replace function amine.slot_start(p_day date, p_slot text) returns timestamptz
language sql stable set search_path = '' as $$
  select case
    when p_day is null or p_slot is null or p_slot = 'asap' then null
    else (p_day + case p_slot when 'tomorrow_am' then time '07:00' when 'tomorrow_noon' then time '10:00'
                      else time '14:00' end) at time zone 'Africa/Tunis'
  end
$$;

create or replace function amine.slot_end(p_day date, p_slot text) returns timestamptz
language sql stable set search_path = '' as $$
  select amine.slot_start(p_day, p_slot) + case p_slot when 'tomorrow_am' then interval '3 hours'
    when 'tomorrow_noon' then interval '3 hours' else interval '4 hours' end
$$;

-- Créneaux proposés maintenant pour un dépôt : [{id, available, deliver_on, start, end}]
create or replace function amine.slots(s amine.stores) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  t timestamp := now() at time zone 'Africa/Tunis';
  v_today date := (now() at time zone 'Africa/Tunis')::date;
  v jsonb := '[]'::jsonb;
  k text;
  d date;
begin
  v := v || jsonb_build_object('id', 'asap', 'available', amine.store_open_now(s), 'deliver_on', v_today,
    'start', null, 'end', null);
  foreach k in array array['today_pm', 'tomorrow_am', 'tomorrow_noon', 'tomorrow_pm'] loop
    d := case when k = 'today_pm' then v_today else v_today + 1 end;
    v := v || jsonb_build_object('id', k,
      'available', s.id is not null and s.status = 'active' and (k <> 'today_pm' or t::time < time '12:00'),
      'deliver_on', d, 'start', amine.slot_start(d, k), 'end', amine.slot_end(d, k));
  end loop;
  return v;
end $$;

-- Vérifie le créneau demandé et renvoie la date de livraison.
create or replace function amine.check_slot(s amine.stores, p_slot text) returns date
language plpgsql stable set search_path = '' as $$
declare
  e jsonb;
begin
  if coalesce(p_slot, 'asap') not in ('asap', 'today_pm', 'tomorrow_am', 'tomorrow_noon', 'tomorrow_pm') then
    perform amine.err('INVALID_INPUT', 'delivery_slot');
  end if;
  select x.value into e from jsonb_array_elements(amine.slots(s)) x where x.value ->> 'id' = coalesce(p_slot, 'asap');
  if not (e ->> 'available')::boolean then
    if coalesce(p_slot, 'asap') = 'asap' then
      perform amine.err('STORE_CLOSED');
    end if;
    perform amine.err('SLOT_UNAVAILABLE');
  end if;
  return (e ->> 'deliver_on')::date;
end $$;

-- Une course programmée est proposée aux livreurs 2 heures avant le début du créneau.
create or replace function amine.job_open(o amine.orders) returns boolean
language sql stable set search_path = '' as $$
  select coalesce(o.delivery_slot, 'asap') = 'asap'
      or now() >= amine.slot_start(o.deliver_on, o.delivery_slot) - interval '2 hours'
$$;

-- Identifiants lisibles ----------------------------------------------------------------------
create or replace function amine.new_order_code() returns text
language plpgsql volatile set search_path = '' as $$
declare
  alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  v text;
  i int;
begin
  loop
    v := 'AM';
    for i in 1..6 loop
      v := v || substr(alphabet, 1 + floor(random() * 32)::int, 1);
    end loop;
    exit when not exists (select 1 from amine.orders where code = v);
  end loop;
  return v;
end $$;

create or replace function amine.slugify(p text) returns text
language plpgsql volatile set search_path = '' as $$
declare
  alphabet constant text := 'abcdefghjkmnpqrstuvwxyz23456789';
  base text;
  v text;
  i int;
begin
  base := lower(coalesce(p, ''));
  base := translate(base, 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿ', 'aaaaaaceeeeiiiinooooouuuuyy');
  base := regexp_replace(base, '[^a-z0-9]+', '-', 'g');
  base := btrim(left(btrim(base, '-'), 50), '-');
  if char_length(base) < 2 then
    base := 'commerce';
  end if;
  loop
    v := base || '-';
    for i in 1..4 loop
      v := v || substr(alphabet, 1 + floor(random() * 31)::int, 1);
    end loop;
    exit when not exists (select 1 from amine.stores where slug = v);
  end loop;
  return v;
end $$;

-- Contexte des mouvements de stock de la transaction en cours (lu par le déclencheur qui journalise
-- chaque variation de stock : vente, retour, achat, perte, inventaire…).
create or replace function amine.stock_context(p_kind text, p_ref text default null, p_reason text default null) returns void
language sql set search_path = '' as $$
  select set_config('amine.stock_kind', coalesce(p_kind, ''), true),
    set_config('amine.stock_ref', coalesce(p_ref, ''), true),
    set_config('amine.stock_reason', coalesce(p_reason, ''), true)
$$;

-- Compte client (version 3) : solde et encours ---------------------------------------------------
create or replace function amine.account_balance(p_customer uuid) returns bigint
language sql stable set search_path = '' as $$
  select coalesce(sum(e.amount), 0)::bigint from amine.account_entries e where e.customer_id = p_customer
$$;

-- Encours : solde du compte + commandes payables sur compte qui ne sont pas encore livrées.
create or replace function amine.account_exposure(p_customer uuid) returns bigint
language sql stable set search_path = '' as $$
  select amine.account_balance(p_customer) + coalesce((
    select sum(o.total) from amine.orders o
    where o.customer_id = p_customer and o.payment_method = 'account'
      and o.status in ('placed', 'accepted', 'preparing', 'ready', 'picked_up')), 0)::bigint
$$;

-- Journal d'audit et notifications ------------------------------------------------------------
create or replace function amine.audit(p_action text, p_entity text, p_entity_id text, p_details jsonb default '{}'::jsonb) returns void
language sql set search_path = '' as $$
  insert into amine.audit_log (actor_id, action, entity, entity_id, details)
  values (auth.uid(), p_action, p_entity, p_entity_id, coalesce(p_details, '{}'::jsonb))
$$;

create or replace function amine.notify(p_user uuid, p_kind text, p_params jsonb default '{}'::jsonb, p_link text default null) returns void
language sql set search_path = '' as $$
  insert into amine.notifications (user_id, kind, params, link)
  select p_user, p_kind, coalesce(p_params, '{}'::jsonb), p_link
  where p_user is not null and exists (select 1 from amine.profiles where id = p_user)
$$;

create or replace function amine.notify_store(p_store uuid, p_kind text, p_params jsonb default '{}'::jsonb, p_link text default null) returns void
language sql set search_path = '' as $$
  insert into amine.notifications (user_id, kind, params, link)
  select st.user_id, p_kind, coalesce(p_params, '{}'::jsonb), p_link
  from amine.store_staff st where st.store_id = p_store
$$;

create or replace function amine.notify_admins(p_kind text, p_params jsonb default '{}'::jsonb, p_link text default null) returns void
language sql set search_path = '' as $$
  insert into amine.notifications (user_id, kind, params, link)
  select p.id, p_kind, coalesce(p_params, '{}'::jsonb), p_link
  from amine.profiles p where p.is_admin and p.status = 'active'
$$;

create or replace function amine.log_order(p_order uuid, p_status text, p_event text, p_actor text, p_actor_id uuid, p_note text) returns void
language sql set search_path = '' as $$
  insert into amine.order_events (order_id, status, event, actor, actor_id, note)
  values (p_order, p_status, p_event, p_actor, p_actor_id, p_note)
$$;

-- Machine à états des commandes ---------------------------------------------------------------
--   placed ─► accepted ─► preparing ─► ready ─► picked_up ─► delivered
--     └─► rejected            (annulation possible selon l'acteur, voir ci-dessous)
create or replace function amine.can_transition(o amine.orders, p_to text, p_actor text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare
  ok boolean;
begin
  ok := case o.status
    when 'placed' then p_to in ('accepted', 'rejected', 'cancelled')
    when 'accepted' then p_to in ('preparing', 'ready', 'cancelled')
    when 'preparing' then p_to in ('ready', 'cancelled')
    when 'ready' then p_to in ('picked_up', 'cancelled')
    when 'picked_up' then p_to in ('delivered', 'cancelled')
    else false
  end;
  if not ok then
    return false;
  end if;
  return case p_actor
    when 'admin' then true
    when 'system' then p_to = 'cancelled'
    when 'merchant' then o.kind = 'store' and p_to in ('accepted', 'rejected', 'preparing', 'ready')
    when 'courier' then p_to in ('picked_up', 'delivered')
    when 'customer' then p_to = 'cancelled' and (
      (o.kind = 'store' and o.status = 'placed')
      or (o.kind = 'parcel' and o.status = 'ready' and o.courier_id is null)
    )
    else false
  end;
end $$;

create or replace function amine.transition(o amine.orders, p_to text, p_actor text, p_actor_id uuid, p_note text default null) returns amine.orders
language plpgsql set search_path = '' as $$
declare
  r amine.orders;
  v_link_customer text;
begin
  if not amine.can_transition(o, p_to, p_actor) then
    perform amine.err('INVALID_TRANSITION');
  end if;
  if p_to = 'picked_up' and o.courier_id is null then
    perform amine.err('NO_COURIER');
  end if;

  update amine.orders set
    status = p_to,
    accepted_at = case when p_to = 'accepted' then now() else accepted_at end,
    preparing_at = case when p_to = 'preparing' then now() else preparing_at end,
    ready_at = case when p_to = 'ready' then now() else ready_at end,
    picked_up_at = case when p_to = 'picked_up' then now() else picked_up_at end,
    delivered_at = case when p_to = 'delivered' then now() else delivered_at end,
    cancelled_at = case when p_to in ('cancelled', 'rejected') then now() else cancelled_at end,
    cancel_reason = case when p_to in ('cancelled', 'rejected') then p_note else cancel_reason end,
    cancelled_by = case when p_to in ('cancelled', 'rejected') then p_actor else cancelled_by end,
    updated_at = now()
  where id = o.id and status = o.status
  returning * into r;
  if not found then
    perform amine.err('ORDER_CHANGED');
  end if;

  perform amine.log_order(r.id, p_to, 'status', p_actor, p_actor_id, p_note);

  if p_to in ('cancelled', 'rejected') and o.status in ('placed', 'accepted', 'preparing', 'ready') then
    -- Remise en stock : la marchandise n'a pas quitté le commerce.
    perform amine.stock_context('return', r.code, p_to);
    update amine.products p set stock = p.stock + i.quantity, updated_at = now()
    from amine.order_items i
    where i.order_id = r.id and i.product_id = p.id and p.stock is not null;
  end if;
  if p_to = 'delivered' and r.kind = 'store' then
    -- Facture, écriture au compte du client et encaissement en espèces éventuel (08_business.sql).
    perform amine.after_delivery(r);
  end if;
  if p_to in ('cancelled', 'rejected', 'delivered') and r.courier_id is not null then
    -- Fin de course : la position du livreur n'est plus partagée (sauf autre course en cours).
    delete from amine.courier_locations l
    where l.courier_id = r.courier_id
      and not exists (select 1 from amine.orders x where x.courier_id = r.courier_id
                      and x.status in ('accepted', 'preparing', 'ready', 'picked_up'));
  end if;

  -- Notifications
  v_link_customer := '#/orders/' || r.code;
  if p_actor <> 'customer' and p_to in ('accepted', 'rejected', 'ready', 'picked_up', 'delivered', 'cancelled') then
    if not (p_to = 'ready' and r.kind = 'parcel') then
      perform amine.notify(r.customer_id, 'order_' || p_to, jsonb_build_object('code', r.code, 'reason', r.cancel_reason), v_link_customer);
    end if;
  end if;
  if r.store_id is not null and p_to = 'cancelled' and p_actor <> 'merchant' then
    perform amine.notify_store(r.store_id, 'order_cancelled', jsonb_build_object('code', r.code),
      '#/depot/orders/' || r.code || '?store=' || r.store_id::text);
  end if;
  if r.courier_id is not null and p_to in ('cancelled', 'rejected') and p_actor <> 'courier' then
    perform amine.notify(r.courier_id, 'job_cancelled', jsonb_build_object('code', r.code), '#/courier');
  end if;
  return r;
end $$;

-- Représentation JSON d'une commande selon qui la regarde -----------------------------------
--   customer        : le client (propriétaire)
--   merchant        : le commerce (pas l'adresse du client)
--   courier_preview : un livreur avant d'accepter (zone et distance, pas d'adresse ni téléphone)
--   courier         : le livreur assigné (coordonnées complètes tant que la course est active)
--   admin           : tout
create or replace function amine.order_json(o amine.orders, p_view text) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  s amine.stores;
  c amine.couriers;
  cp amine.profiles;
  cu amine.profiles;
  z amine.zones;
  j jsonb;
  v_active boolean := o.status not in ('delivered', 'cancelled', 'rejected');
  v_full_dropoff boolean;
begin
  if o.store_id is not null then
    select * into s from amine.stores where id = o.store_id;
  end if;
  if o.courier_id is not null then
    select * into c from amine.couriers where user_id = o.courier_id;
    select * into cp from amine.profiles where id = o.courier_id;
  end if;
  if o.zone_id is not null then
    select * into z from amine.zones where id = o.zone_id;
  end if;

  j := jsonb_build_object(
    'id', o.id, 'code', o.code, 'kind', o.kind, 'status', o.status,
    'placed_at', o.placed_at, 'accepted_at', o.accepted_at, 'preparing_at', o.preparing_at,
    'ready_at', o.ready_at, 'assigned_at', o.assigned_at, 'picked_up_at', o.picked_up_at,
    'delivered_at', o.delivered_at, 'cancelled_at', o.cancelled_at, 'updated_at', o.updated_at,
    'subtotal', o.subtotal, 'delivery_fee', o.delivery_fee, 'service_fee', o.service_fee, 'total', o.total,
    'discount', o.discount, 'promo_code', o.promo_code, 'source', o.source,

    'delivery_slot', coalesce(o.delivery_slot, 'asap'), 'deliver_on', o.deliver_on,
    'slot_start', amine.slot_start(o.deliver_on, o.delivery_slot), 'slot_end', amine.slot_end(o.deliver_on, o.delivery_slot),
    'payment_method', o.payment_method, 'payer', o.payer, 'cod_collected', o.cod_collected,
    'stamp_fee', o.stamp_fee, 'weights_adjusted_at', o.weights_adjusted_at, 'recurring', o.recurring_id is not null,
    -- Montant à encaisser par le livreur : rien pour une commande payée sur compte.
    'to_collect', case when o.payment_method = 'account' then 0 else o.total end,
    'route_seq', case when p_view in ('courier', 'admin', 'merchant') then o.route_seq end,
    'invoice', (select jsonb_build_object('id', iv.id, 'number', iv.number) from amine.invoices iv
                where iv.order_id = o.id and iv.kind = 'invoice' and p_view in ('customer', 'admin', 'merchant')),
    'pod', case when o.pod_at is null or p_view not in ('customer', 'admin', 'merchant', 'courier') then null
      else jsonb_build_object('name', o.pod_name, 'at', o.pod_at, 'photo', o.pod_photo, 'signature', o.pod_signature) end,
    'parcel_size', o.parcel_size, 'parcel_description', o.parcel_description,
    'distance_km', o.distance_km, 'customer_note', o.customer_note,
    'cancel_reason', o.cancel_reason, 'cancelled_by', o.cancelled_by,
    'store_rating', o.store_rating, 'courier_rating', o.courier_rating, 'review_comment', o.review_comment,
    'has_courier', o.courier_id is not null,
    'zone', case when z.id is null then null else
      jsonb_build_object('id', z.id, 'name_fr', z.name_fr, 'name_ar', z.name_ar, 'name_en', z.name_en) end,
    'store', case when s.id is null then null else
      jsonb_build_object('id', s.id, 'slug', s.slug, 'kind', s.kind, 'name', s.name, 'name_ar', s.name_ar,
        'name_en', s.name_en, 'logo_url', s.logo_url, 'cover_url', s.cover_url,
        'phone', case when p_view in ('customer', 'admin') or (p_view = 'courier' and v_active) then s.phone end) end,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('product_id', i.product_id, 'name', i.name, 'unit', i.unit,
        'unit_price', i.unit_price, 'quantity', i.quantity, 'total', i.total,
        'actual_qty', i.actual_qty, 'list_price', i.list_price, 'vat_rate', i.vat_rate,
        'flash', i.flash_sale_id is not null,
        'image_url', pr.image_url, 'ref', pr.ref,
        'lots', case when p_view in ('merchant', 'admin') and i.product_id is not null then amine.order_item_lots(o.code, i.product_id) end)
        order by i.name)
      from amine.order_items i left join amine.products pr on pr.id = i.product_id
      where i.order_id = o.id), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('status', e.status, 'event', e.event, 'actor', e.actor, 'at', e.created_at,
        'note', case when p_view = 'admin' then e.note end) order by e.id)
      from amine.order_events e where e.order_id = o.id), '[]'::jsonb)
  );

  -- Fidélité : points utilisés sur la commande et points gagnés à la livraison.
  j := j || jsonb_build_object('loyalty_points', o.loyalty_points, 'loyalty_discount', o.loyalty_discount,
    'points_earned', case when p_view in ('customer', 'admin') and o.status = 'delivered' then
      (select coalesce(sum(l.delta), 0)::int from amine.loyalty_ledger l where l.order_id = o.id and l.kind = 'earn') end);

  -- Point de retrait (commerce ou expéditeur du colis)
  j := j || jsonb_build_object('pickup', jsonb_build_object(
    'name', o.pickup_name, 'address', o.pickup_address, 'lat', o.pickup_lat, 'lng', o.pickup_lng,
    'details', case when p_view in ('customer', 'admin') or (p_view = 'courier' and v_active) then o.pickup_details end,
    'phone', case when p_view = 'admin' or (p_view in ('customer', 'courier') and v_active) then o.pickup_phone end));

  -- Point de livraison
  v_full_dropoff := p_view in ('customer', 'admin') or (p_view = 'courier' and v_active);
  if v_full_dropoff then
    j := j || jsonb_build_object('dropoff', jsonb_build_object(
      'name', o.dropoff_name, 'phone', o.dropoff_phone, 'address', o.dropoff_address, 'details', o.dropoff_details,
      'lat', o.dropoff_lat, 'lng', o.dropoff_lng, 'located_by', o.dropoff_located_by));
  elsif p_view = 'merchant' then
    -- Le dépôt (équipe AMINE) voit l'établissement à livrer, pas son adresse.
    j := j || jsonb_build_object('dropoff', jsonb_build_object(
      'name', o.dropoff_name, 'phone', case when v_active then o.dropoff_phone end));
  elsif p_view = 'courier_preview' then
    z := amine.zone_for(o.dropoff_lat, o.dropoff_lng);
    j := j || jsonb_build_object('dropoff', jsonb_build_object(
      'lat', round(o.dropoff_lat, 2), 'lng', round(o.dropoff_lng, 2),
      'zone', case when z.id is null then null else
        jsonb_build_object('name_fr', z.name_fr, 'name_ar', z.name_ar, 'name_en', z.name_en) end));
  else
    j := j || jsonb_build_object('dropoff', jsonb_build_object('name', amine.first_name(o.dropoff_name)));
  end if;

  -- Livreur
  if c.user_id is not null then
    j := j || jsonb_build_object('courier', jsonb_build_object(
      'name', case when p_view = 'admin' then cp.full_name else amine.first_name(cp.full_name) end,
      'vehicle', c.vehicle,
      'phone', case when p_view = 'admin' or (p_view in ('customer', 'merchant') and v_active) then cp.phone end,
      'rating', case when c.rating_count > 0 then round(c.rating_sum::numeric / c.rating_count, 1) end,
      'id', case when p_view = 'admin' then c.user_id end));
  end if;

  -- Montants internes
  if p_view in ('merchant', 'admin') then
    j := j || jsonb_build_object('commission', o.commission);
  end if;
  if p_view in ('courier', 'courier_preview', 'admin') then
    j := j || jsonb_build_object('courier_earning', o.courier_earning);
  end if;
  if p_view = 'admin' then
    select * into cu from amine.profiles where id = o.customer_id;
    j := j || jsonb_build_object('customer', case when cu.id is null then null else
      jsonb_build_object('id', cu.id, 'name', cu.full_name, 'email', cu.email, 'phone', cu.phone,
        'business_name', cu.business_name, 'business_type', cu.business_type) end);
  end if;
  return j;
end $$;

-- Tâches de fond : exécutées au plus toutes les 2 minutes, à l'occasion des appels courants
-- (et par pg_cron si l'extension est activée).
create or replace function amine.maintenance() returns void
language plpgsql set search_path = '' as $$
declare
  v_last timestamptz;
  v_minutes int;
  o amine.orders;
begin
  select (value ->> 'last_run')::timestamptz into v_last from amine.settings where key = 'maintenance_state';
  if v_last is not null and v_last > now() - interval '2 minutes' then
    return;
  end if;
  if not pg_try_advisory_xact_lock(7240011) then
    return;
  end if;
  insert into amine.settings (key, value) values ('maintenance_state', jsonb_build_object('last_run', now()))
  on conflict (key) do update set value = excluded.value, updated_at = now();

  -- Commandes jamais acceptées par le dépôt : annulées automatiquement (immédiates : après le délai
  -- réglé ; programmées : au début du créneau).
  v_minutes := greatest(5, coalesce((amine.setting('orders') ->> 'auto_cancel_minutes')::int, 30));
  for o in
    select * from amine.orders
    where status = 'placed' and kind = 'store' and (
      (coalesce(delivery_slot, 'asap') = 'asap' and placed_at < now() - make_interval(mins => v_minutes))
      or (coalesce(delivery_slot, 'asap') <> 'asap' and now() >= amine.slot_start(deliver_on, delivery_slot)))
    order by placed_at limit 100 for update skip locked
  loop
    begin
      perform amine.transition(o, 'cancelled', 'system', null, 'merchant_no_response');
    exception when others then
      null;
    end;
  end loop;

  delete from amine.courier_locations l
  where l.updated_at < now() - interval '30 minutes'
     or not exists (select 1 from amine.orders x where x.courier_id = l.courier_id
                    and x.status in ('accepted', 'preparing', 'ready', 'picked_up'));
  update amine.couriers set is_online = false
  where is_online and (last_seen_at is null or last_seen_at < now() - interval '20 minutes');
  delete from amine.rate_limits where reset_at < now() - interval '1 hour';
  delete from amine.notifications where created_at < now() - interval '120 days';
  delete from amine.push_queue where created_at < now() - interval '2 days';
  -- Notifications push restées en file (fonction d'envoi indisponible) : nouvel essai.
  perform amine.push_wake();

  -- Commandes récurrentes du lendemain et relances des factures échues (08_business.sql).
  perform amine.run_recurring_orders();
  perform amine.remind_overdue_invoices();
  -- Relance des restaurants inactifs (14_loyalty.sql) : un incident ici ne bloque jamais les autres tâches.
  begin
    perform amine.remind_inactive_clients();
  exception when others then
    null;
  end;
end $$;

-- =============================================================================================
--  Fonctions publiques (visiteurs non connectés compris) : catalogue des dépôts et devis
-- =============================================================================================

-- Fonctions de la version 1 qui n'existent plus (annuaire de commerces).
drop function if exists public.list_stores(uuid, text, text);
drop function if exists public.list_stores(uuid, text, text, text, numeric, numeric);
drop function if exists public.get_store(text);
drop function if exists public.search_products(uuid, text);
drop function if exists public.get_store_reviews(text, int);

create or replace function public.amine_health() returns jsonb
language sql security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'app', 'amine', 'schema_version', 5, 'time', now())
$$;

create or replace function public.get_public_config() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  return jsonb_build_object(
    'schema_version', 5,
    'platform', amine.setting('platform'),
    -- Clé publique VAPID des notifications push, seulement si l'envoi est activé.
    'push', (select jsonb_build_object('public_key', k.public_key) from amine.push_keys k
      where k.id = 1 and k.public_key is not null and coalesce((amine.setting('push') ->> 'enabled')::boolean, false)),
    'parcel', amine.setting('parcel'),
    'auth', amine.setting('auth'),
    'legal', amine.setting('legal'),
    'orders', jsonb_build_object(
      'service_fee', (amine.setting('orders') ->> 'service_fee')::int,
      'max_distance_km', (amine.setting('orders') ->> 'max_distance_km')::numeric,
      'require_pod', coalesce((amine.setting('orders') ->> 'require_pod')::boolean, false)),
    'cities', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name_fr', c.name_fr, 'name_ar', c.name_ar, 'name_en', c.name_en)
        order by c.sort, c.name_fr)
      from amine.cities c where c.is_active), '[]'::jsonb),
    'zones', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', z.id, 'city_id', z.city_id, 'name_fr', z.name_fr, 'name_ar', z.name_ar, 'name_en', z.name_en,
          'center_lat', z.center_lat, 'center_lng', z.center_lng, 'radius_km', z.radius_km,
          'services', to_jsonb(z.services), 'base_fee', z.base_fee)
        order by c.sort, z.sort, z.name_fr)
      from amine.zones z join amine.cities c on c.id = z.city_id
      where z.is_active and c.is_active), '[]'::jsonb),
    -- Codes promo que l'administration a choisi d'annoncer.
    'promos', coalesce((
      select jsonb_agg(jsonb_build_object('code', pr.code, 'description', pr.description, 'kind', pr.kind,
          'value', pr.value, 'max_discount', pr.max_discount, 'min_subtotal', pr.min_subtotal, 'ends_at', pr.ends_at,
          'first_order_only', pr.first_order_only) order by pr.created_at desc)
      from amine.promotions pr
      where pr.is_public and pr.is_active and pr.archived_at is null and (pr.starts_at is null or pr.starts_at <= now())
        and (pr.ends_at is null or pr.ends_at > now())), '[]'::jsonb)
  );
end $$;

create or replace function amine.store_card(s amine.stores) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', s.id, 'slug', s.slug, 'kind', s.kind, 'name', s.name, 'name_ar', s.name_ar, 'name_en', s.name_en,
    'description', s.description, 'description_ar', s.description_ar, 'description_en', s.description_en,
    'logo_url', s.logo_url, 'cover_url', s.cover_url, 'address', s.address, 'lat', s.lat, 'lng', s.lng,
    'zone_id', s.zone_id, 'min_order', s.min_order, 'prep_minutes', s.prep_minutes,
    'open_now', amine.store_open_now(s),
    'rating', case when s.rating_count > 0 then round(s.rating_sum::numeric / s.rating_count, 1) end,
    'rating_count', s.rating_count,
    'base_fee', (select z.base_fee from amine.zones z where z.id = s.zone_id))
$$;

create or replace function amine.product_json(p amine.products) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'section_id', p.section_id, 'sku', p.sku,
    'name', p.name, 'name_ar', p.name_ar, 'name_en', p.name_en,
    'description', p.description, 'description_ar', p.description_ar, 'description_en', p.description_en,
    'price', p.price, 'unit', p.unit, 'image_url', p.image_url, 'image_credit', p.image_credit, 'ref', p.ref, 'sort', p.sort,
    'brand', p.brand, 'barcode', p.barcode, 'vat_rate', p.vat_rate, 'price_tiers', p.price_tiers,
    'available', p.is_available and (p.stock is null or p.stock > 0))
$$;

-- Prix unitaire d'un produit pour un client et une quantité :
--   1. prix négocié pour ce client (prix final) ;
--   2. sinon le prix du palier de quantité atteint (le plus bas), puis la remise générale du client,
--      arrondie à 10 millimes.
create or replace function amine.unit_price(p amine.products, p_customer uuid, p_qty int) returns int
language plpgsql stable set search_path = '' as $$
declare
  v_special int;
  v_price int := p.price;
  v_discount int;
  t jsonb;
begin
  if p_customer is not null then
    select cp.price into v_special from amine.client_prices cp where cp.customer_id = p_customer and cp.product_id = p.id;
    if v_special is not null then
      return v_special;
    end if;
  end if;
  for t in select e.value from jsonb_array_elements(coalesce(p.price_tiers, '[]'::jsonb)) e loop
    if coalesce(p_qty, 1) >= (t ->> 'min_qty')::int and (t ->> 'price')::int < v_price then
      v_price := (t ->> 'price')::int;
    end if;
  end loop;
  if p_customer is not null then
    select pr.discount_bps into v_discount from amine.profiles pr where pr.id = p_customer;
    if coalesce(v_discount, 0) > 0 then
      v_price := greatest(1, (round(v_price::numeric * (10000 - v_discount) / 10000 / 10) * 10)::int);
    end if;
  end if;
  return v_price;
end $$;

-- Droit de timbre ajouté à chaque commande facturée (0 si l'administration le désactive).
create or replace function amine.stamp_fee() returns int
language sql stable set search_path = '' as $$
  select greatest(0, least(100000, coalesce((amine.setting('invoicing') ->> 'stamp')::int, 0)))
$$;

-- Dépôt AMINE le plus proche qui livre ce point (dans la distance maximale de livraison).
create or replace function amine.depot_for(p_lat numeric, p_lng numeric) returns amine.stores
language sql stable set search_path = '' as $$
  select st.*
  from amine.stores st
  join amine.zones sz on sz.id = st.zone_id
  join amine.cities c on c.id = sz.city_id
  where st.status = 'active' and st.kind = 'grocery' and sz.is_active and c.is_active
    and 'grocery' = any (sz.services)
    and amine.distance_km(st.lat, st.lng, p_lat, p_lng)
        <= coalesce((amine.setting('orders') ->> 'max_distance_km')::numeric, 15)
  order by amine.distance_km(st.lat, st.lng, p_lat, p_lng)
  limit 1
$$;

-- Catalogue d'un client : sa zone (ou sa position exacte), le dépôt qui le sert, les rayons et les
-- produits disponibles, avec les prix de la base.
-- Le catalogue est visible partout en Tunisie : quand aucun dépôt ne livre l'endroit demandé (ou
-- qu'aucun endroit n'est donné), on renvoie les produits du dépôt actif le plus proche, avec
-- "delivers" = false (endroit connu mais pas livré) ou null (endroit inconnu). Seul "delivers" = true
-- permet de commander depuis l'accueil ; la commande revérifie de toute façon l'adresse.
create or replace function public.get_catalog(p_zone_id uuid default null, p_lat numeric default null, p_lng numeric default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  z amine.zones;
  s amine.stores;
  sz amine.zones;
  v_lat numeric;
  v_lng numeric;
  v_km numeric;
  v_delivers boolean;
  v_zone jsonb;
  -- Client connecté : ses prix négociés et sa remise sont affichés avec les produits.
  v_uid uuid := auth.uid();
  v_terms boolean := false;
begin
  perform amine.maintenance();
  if v_uid is not null then
    v_terms := exists (select 1 from amine.client_prices cp where cp.customer_id = v_uid)
      or exists (select 1 from amine.profiles pr where pr.id = v_uid and pr.discount_bps > 0);
  end if;
  if p_lat is not null and p_lng is not null then
    perform amine.check_point(p_lat, p_lng);
    v_lat := p_lat;
    v_lng := p_lng;
    z := amine.zone_for(p_lat, p_lng);
  elsif p_zone_id is not null then
    select zz.* into z from amine.zones zz join amine.cities c on c.id = zz.city_id
    where zz.id = p_zone_id and zz.is_active and c.is_active;
    v_lat := z.center_lat;
    v_lng := z.center_lng;
  end if;
  if z.id is not null then
    v_zone := jsonb_build_object('id', z.id, 'name_fr', z.name_fr, 'name_ar', z.name_ar, 'name_en', z.name_en);
    s := amine.depot_for(v_lat, v_lng);
  end if;

  if s.id is not null then
    v_delivers := true;
  else
    -- Consultation seulement : dépôt actif le plus proche (le plus ancien si l'endroit est inconnu).
    v_delivers := case when v_lat is null then null else false end;
    select st.* into s from amine.stores st
    where st.status = 'active' and st.kind = 'grocery'
    order by case when v_lat is null then 0 else amine.distance_km(st.lat, st.lng, v_lat, v_lng) end, st.created_at, st.id
    limit 1;
  end if;
  if s.id is null then
    return jsonb_build_object('zone', v_zone, 'depot', null, 'sections', '[]'::jsonb, 'products', '[]'::jsonb);
  end if;

  if v_lat is not null then
    v_km := amine.distance_km(s.lat, s.lng, v_lat, v_lng);
  end if;
  if v_delivers then
    select * into sz from amine.zones where id = s.zone_id;
  end if;
  return jsonb_build_object(
    'zone', v_zone,
    'depot', amine.store_card(s) || jsonb_build_object('phone', s.phone, 'hours', s.hours, 'distance_km', v_km,
      'delivery_fee', case when v_delivers then amine.fee_for(sz, v_km) end, 'delivers', v_delivers),
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object('id', sc.id, 'name', sc.name, 'name_ar', sc.name_ar, 'name_en', sc.name_en)
        order by sc.sort, sc.name)
      from amine.sections sc where sc.store_id = s.id), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(amine.product_json(p) || case when not v_terms then '{}'::jsonb
          else jsonb_build_object('client_price', nullif(amine.unit_price(p, v_uid, 1), p.price)) end
          || amine.flash_card(p, v_uid)
        order by p.sort, p.name)
      from amine.products p where p.store_id = s.id and p.deleted_at is null and p.is_available), '[]'::jsonb));
end $$;

-- Prix d'un panier, recalculés à partir de la base (jamais à partir du navigateur).
-- p_items : [{"product_id": "...", "qty": 2}, …] ; quantités de 1 à 999 (achats de professionnels).
-- p_customer : client qui commande (prix négociés, paliers, remise) ; null = prix catalogue.
drop function if exists amine.price_cart(uuid, jsonb, boolean);
create or replace function amine.price_cart(p_store_id uuid, p_items jsonb, p_strict boolean, p_customer uuid default null) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_lines jsonb := '[]'::jsonb;
  v_issues jsonb := '[]'::jsonb;
  v_sub bigint := 0;
  v_unit int;
  v_flash jsonb;
  rec record;
  pr amine.products;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    perform amine.err('INVALID_INPUT', 'items');
  end if;
  if jsonb_array_length(p_items) = 0 then
    perform amine.err('CART_EMPTY');
  end if;
  if jsonb_array_length(p_items) > 120 then
    perform amine.err('CART_TOO_LARGE');
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_items) e
    where jsonb_typeof(e) <> 'object'
       or coalesce(e ->> 'product_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(e ->> 'qty', '') !~ '^[0-9]{1,3}$'
       or (e ->> 'qty')::int < 1
  ) then
    perform amine.err('INVALID_INPUT', 'items');
  end if;

  for rec in
    with req as (
      select (e ->> 'product_id')::uuid as pid, sum((e ->> 'qty')::int) as qty
      from jsonb_array_elements(p_items) e
      group by 1
    )
    select r.pid, r.qty, p.id as found_id, p.name, p.unit, p.price, p.stock, p.is_available, p.deleted_at
    from req r
    left join amine.products p on p.id = r.pid and p.store_id = p_store_id
    order by r.pid
  loop
    if rec.qty > 999 then
      perform amine.err('QUANTITY_LIMIT', rec.pid::text);
    end if;
    if rec.found_id is null or rec.deleted_at is not null or not rec.is_available then
      if p_strict then
        perform amine.err('PRODUCT_UNAVAILABLE', rec.pid::text);
      end if;
      v_issues := v_issues || jsonb_build_object('product_id', rec.pid, 'code', 'PRODUCT_UNAVAILABLE');
    elsif rec.stock is not null and rec.stock < rec.qty then
      if p_strict then
        perform amine.err('OUT_OF_STOCK', rec.pid::text);
      end if;
      v_issues := v_issues || jsonb_build_object('product_id', rec.pid, 'code', 'OUT_OF_STOCK', 'available', rec.stock);
    else
      select * into pr from amine.products where id = rec.pid;
      v_unit := amine.unit_price(pr, p_customer, rec.qty::int);
      -- Vente flash en cours : son prix s'applique s'il est plus bas et si la quantité reste dans les limites.
      v_flash := amine.flash_for(rec.pid, v_unit, rec.qty::int);
      if coalesce((v_flash ->> 'applies')::boolean, false) then
        v_unit := (v_flash ->> 'price')::int;
      end if;
      v_lines := v_lines || jsonb_build_object('product_id', rec.pid, 'name', rec.name, 'unit', rec.unit,
        'unit_price', v_unit, 'list_price', rec.price, 'vat_rate', pr.vat_rate, 'quantity', rec.qty,
        'total', v_unit::bigint * rec.qty,
        'flash', v_flash,
        'flash_sale_id', case when coalesce((v_flash ->> 'applies')::boolean, false) then v_flash ->> 'id' end);
      v_sub := v_sub + v_unit::bigint * rec.qty;
    end if;
  end loop;
  if v_sub > 100000000 then
    perform amine.err('CART_TOO_LARGE');
  end if;
  return jsonb_build_object('lines', v_lines, 'issues', v_issues, 'subtotal', v_sub);
end $$;

create or replace function amine.couriers_online(p_zone uuid) returns int
language sql stable set search_path = '' as $$
  select count(*)::int from amine.couriers c
  where c.status = 'approved' and c.is_online and c.last_seen_at > now() - interval '20 minutes'
    and (c.zone_id is null or c.zone_id = p_zone)
$$;

-- Remise d'un code promo sur un montant (jamais plus que la commande).
create or replace function amine.promo_discount(pr amine.promotions, p_subtotal int, p_fee int, p_service int) returns int
language plpgsql immutable set search_path = '' as $$
declare
  v int;
begin
  v := case pr.kind
    when 'percent' then round(p_subtotal::numeric * least(pr.value, 100) / 100)::int
    when 'amount' then pr.value
    else p_fee end;
  if pr.max_discount is not null then
    v := least(v, pr.max_discount);
  end if;
  return greatest(0, least(v, p_subtotal + p_fee + p_service));
end $$;

-- Code promo : vérifie toutes les conditions et calcule la remise (financée par AMINE).
-- Renvoie null sans code, {ok:false, error} si le code ne s'applique pas.
create or replace function amine.promo_eval(
  p_code text, p_customer uuid, p_store amine.stores, p_subtotal int, p_fee int, p_service int, p_lock boolean default false
) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v_code text := upper(btrim(coalesce(p_code, '')));
  pr amine.promotions;
  v_count int;
  v_discount int;
begin
  if v_code = '' then
    -- Aucun code saisi : offre de bienvenue automatique éventuelle (14_loyalty.sql).
    return amine.auto_promo(p_customer, p_store, p_subtotal, p_fee, p_service, p_lock);
  end if;
  if v_code !~ '^[A-Z0-9]{3,20}$' then
    return jsonb_build_object('code', left(v_code, 20), 'ok', false, 'error', 'PROMO_INVALID');
  end if;
  if p_lock then
    select * into pr from amine.promotions where code = v_code for update;
  else
    select * into pr from amine.promotions where code = v_code;
  end if;
  if not found or not pr.is_active or pr.archived_at is not null then
    return jsonb_build_object('code', v_code, 'ok', false, 'error', 'PROMO_INVALID');
  end if;
  if pr.starts_at is not null and now() < pr.starts_at then
    return jsonb_build_object('code', v_code, 'ok', false, 'error', 'PROMO_NOT_STARTED');
  end if;
  if pr.ends_at is not null and now() >= pr.ends_at then
    return jsonb_build_object('code', v_code, 'ok', false, 'error', 'PROMO_EXPIRED');
  end if;
  if (pr.zone_id is not null and pr.zone_id <> p_store.zone_id) or (pr.store_id is not null and pr.store_id <> p_store.id) then
    return jsonb_build_object('code', v_code, 'ok', false, 'error', 'PROMO_NOT_APPLICABLE');
  end if;
  if p_subtotal < pr.min_subtotal then
    return jsonb_build_object('code', v_code, 'ok', false, 'error', 'PROMO_MIN_SUBTOTAL', 'min_subtotal', pr.min_subtotal);
  end if;
  if p_customer is null then
    return jsonb_build_object('code', v_code, 'ok', false, 'error', 'UNAUTHENTICATED');
  end if;
  if pr.max_uses is not null then
    select count(*) into v_count from amine.orders where promo_code = pr.code and status not in ('cancelled', 'rejected');
    if v_count >= pr.max_uses then
      return jsonb_build_object('code', v_code, 'ok', false, 'error', 'PROMO_EXHAUSTED');
    end if;
  end if;
  select count(*) into v_count from amine.orders
  where promo_code = pr.code and customer_id = p_customer and status not in ('cancelled', 'rejected');
  if v_count >= pr.max_uses_per_customer then
    return jsonb_build_object('code', v_code, 'ok', false, 'error', 'PROMO_ALREADY_USED');
  end if;
  if pr.first_order_only and exists (
    select 1 from amine.orders where customer_id = p_customer and status not in ('cancelled', 'rejected')) then
    return jsonb_build_object('code', v_code, 'ok', false, 'error', 'PROMO_FIRST_ORDER');
  end if;
  v_discount := amine.promo_discount(pr, p_subtotal, p_fee, p_service);
  return jsonb_build_object('code', pr.code, 'ok', true, 'discount', v_discount, 'kind', pr.kind,
    'description', pr.description);
end $$;

-- Devis d'une commande. Sans adresse (visiteur), les frais affichés sont ceux de base de la zone.
drop function if exists public.quote_order(uuid, jsonb, uuid);
drop function if exists public.quote_order(uuid, jsonb, uuid, text);
create or replace function public.quote_order(
  p_store_id uuid, p_items jsonb, p_address_id uuid default null, p_promo_code text default null,
  p_use_points boolean default false
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores;
  sz amine.zones;
  a amine.addresses;
  dz amine.zones;
  v_cart jsonb;
  v_sub int;
  v_fee int;
  v_km numeric;
  v_service int := greatest(0, coalesce((amine.setting('orders') ->> 'service_fee')::int, 0));
  v_max_km numeric := coalesce((amine.setting('orders') ->> 'max_distance_km')::numeric, 15);
  v_reason text;
  v_promo jsonb;
  v_discount int := 0;
  v_loyalty jsonb;
  v_loy_discount int := 0;
  v_stamp int := amine.stamp_fee();
  v_uid uuid := auth.uid();
  cu amine.profiles;
  v_exposure bigint;
begin
  select * into s from amine.stores where id = p_store_id;
  if not found or s.status <> 'active' then
    perform amine.err('STORE_NOT_FOUND');
  end if;
  select * into sz from amine.zones where id = s.zone_id;
  v_cart := amine.price_cart(s.id, p_items, false, v_uid);
  if v_uid is not null then
    select * into cu from amine.profiles where id = v_uid;
    v_exposure := amine.account_exposure(v_uid);
  end if;
  v_sub := (v_cart ->> 'subtotal')::int;

  if p_address_id is not null then
    select * into a from amine.addresses where id = p_address_id and user_id = amine.uid();
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
    v_km := amine.distance_km(s.lat, s.lng, a.lat, a.lng);
    dz := amine.zone_for(a.lat, a.lng);
    if dz.id is null then
      v_reason := 'ADDRESS_OUT_OF_ZONE';
    elsif v_km > v_max_km then
      v_reason := 'TOO_FAR';
    end if;
    v_fee := amine.fee_for(sz, v_km);
  else
    v_fee := sz.base_fee;
  end if;
  if not sz.is_active or not (s.kind = any (sz.services)) then
    v_reason := 'SERVICE_UNAVAILABLE';
  end if;
  v_promo := amine.promo_eval(p_promo_code, auth.uid(), s, v_sub, v_fee, v_service);
  if coalesce((v_promo ->> 'ok')::boolean, false) then
    v_discount := (v_promo ->> 'discount')::int;
  end if;
  -- Points de fidélité : utilisables par un client connecté, sur ce qui reste à payer après le code promo.
  if v_uid is not null then
    v_loyalty := amine.loyalty_redeem_calc(v_uid, v_sub, v_sub + v_fee + v_service + v_stamp - v_discount);
    if coalesce(p_use_points, false) and (v_loyalty ->> 'points')::int > 0 then
      v_loy_discount := (v_loyalty ->> 'discount')::int;
    end if;
    v_loyalty := v_loyalty || jsonb_build_object('applied', v_loy_discount > 0);
  end if;

  return jsonb_build_object(
    'lines', v_cart -> 'lines', 'issues', v_cart -> 'issues',
    'subtotal', v_sub, 'delivery_fee', v_fee, 'fee_is_estimate', p_address_id is null,
    'service_fee', v_service, 'discount', v_discount + v_loy_discount, 'promo_discount', v_discount,
    'loyalty', v_loyalty, 'loyalty_discount', v_loy_discount, 'promo', v_promo, 'stamp_fee', v_stamp,
    'total', v_sub + v_fee + v_service + v_stamp - v_discount - v_loy_discount,
    -- Paiement sur compte : seulement pour les clients qui en bénéficient, dans la limite de l'encours.
    'account', case when cu.id is null or cu.payment_terms <> 'account' then null else jsonb_build_object(
      'payment_days', cu.payment_days, 'credit_limit', cu.credit_limit, 'used', v_exposure,
      'available', greatest(0, cu.credit_limit - v_exposure)) end,
    'distance_km', v_km, 'min_order', s.min_order, 'min_order_ok', v_sub >= s.min_order,
    'open_now', amine.store_open_now(s), 'couriers_online', amine.couriers_online(s.zone_id),
    'prep_minutes', s.prep_minutes, 'slots', amine.slots(s),
    'deliverable', v_reason is null, 'reason', v_reason);
end $$;

create or replace function public.quote_parcel(
  p_pickup_lat numeric, p_pickup_lng numeric, p_dropoff_lat numeric, p_dropoff_lng numeric, p_size text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_parcel jsonb := amine.setting('parcel');
  pz amine.zones;
  dz amine.zones;
  v_km numeric;
  v_fee int;
  v_reason text;
begin
  perform amine.check_point(p_pickup_lat, p_pickup_lng);
  perform amine.check_point(p_dropoff_lat, p_dropoff_lng);
  if p_size is null or p_size not in ('small', 'medium', 'large') then
    perform amine.err('INVALID_INPUT', 'size');
  end if;
  pz := amine.zone_for(p_pickup_lat, p_pickup_lng);
  dz := amine.zone_for(p_dropoff_lat, p_dropoff_lng);
  v_km := amine.distance_km(p_pickup_lat, p_pickup_lng, p_dropoff_lat, p_dropoff_lng);
  if not coalesce((v_parcel ->> 'enabled')::boolean, false) then
    v_reason := 'PARCEL_DISABLED';
  elsif pz.id is null or dz.id is null then
    v_reason := 'ADDRESS_OUT_OF_ZONE';
  elsif not ('parcel' = any (pz.services)) then
    v_reason := 'SERVICE_UNAVAILABLE';
  elsif v_km > coalesce((amine.setting('orders') ->> 'max_distance_km')::numeric, 15) then
    v_reason := 'TOO_FAR';
  end if;
  if pz.id is not null then
    v_fee := amine.fee_for(pz, v_km) + coalesce((v_parcel -> 'size_fee' ->> p_size)::int, 0);
  end if;
  return jsonb_build_object('delivery_fee', v_fee, 'distance_km', v_km, 'deliverable', v_reason is null,
    'reason', v_reason, 'couriers_online', case when pz.id is null then 0 else amine.couriers_online(pz.id) end);
end $$;

-- =============================================================================================
--  Fonctions du client connecté : profil, adresses, commandes, colis, notifications, données
-- =============================================================================================

create or replace function public.get_me() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  c amine.couriers;
begin
  select * into c from amine.couriers where user_id = p.id;
  return jsonb_build_object(
    'id', p.id, 'email', p.email, 'full_name', p.full_name, 'phone', p.phone, 'phone_verified', p.phone_verified,
    'locale', p.locale, 'is_admin', p.is_admin, 'marketing_opt_in', p.marketing_opt_in, 'created_at', p.created_at,
    'business_name', p.business_name, 'business_type', p.business_type, 'tax_id', p.tax_id,
    'payment_terms', p.payment_terms, 'payment_days', p.payment_days, 'credit_limit', p.credit_limit,
    'discount_bps', p.discount_bps,
    'recurring', (select count(*) from amine.recurring_orders r where r.customer_id = p.id and r.is_active),
    'stores', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name, 'status', s.status, 'role', st.role)
        order by s.created_at)
      from amine.store_staff st join amine.stores s on s.id = st.store_id
      where st.user_id = p.id and s.status <> 'archived'), '[]'::jsonb),
    'courier', case when c.user_id is null or c.status = 'archived' then null else jsonb_build_object(
      'status', c.status, 'status_note', c.status_note, 'is_online', c.is_online, 'vehicle', c.vehicle, 'zone_id', c.zone_id) end,
    'unread', (select count(*) from amine.notifications n where n.user_id = p.id and n.read_at is null),
    'mfa', amine.has_mfa(p.id),
    -- Fidélité (14_loyalty.sql) : solde de points et programme actif ou non.
    'points', amine.loyalty_balance(p.id),
    'loyalty', coalesce((amine.setting('loyalty') ->> 'enabled')::boolean, false));
end $$;

create or replace function public.update_my_profile(
  p_full_name text, p_phone text, p_locale text, p_marketing_opt_in boolean default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  v_name text := amine.txt(p_full_name, 'full_name', 120, true, 2);
  v_phone text := amine.phone_in(p_phone, 'phone', false);
  v_verified boolean;
begin
  perform amine.hit('profile:' || p.id, 30, 3600);
  if p_locale is null or p_locale not in ('fr', 'ar', 'en') then
    perform amine.err('INVALID_INPUT', 'locale');
  end if;
  -- Le téléphone reste « vérifié » seulement s'il correspond au numéro confirmé par SMS.
  select exists (
    select 1 from auth.users u
    where u.id = p.id and u.phone_confirmed_at is not null and v_phone is not null
      and '+' || ltrim(u.phone, '+') = v_phone
  ) into v_verified;
  update amine.profiles set
    full_name = v_name, phone = v_phone, phone_verified = v_verified, locale = p_locale,
    marketing_opt_in = coalesce(p_marketing_opt_in, marketing_opt_in), updated_at = now()
  where id = p.id;
  return public.get_me();
end $$;

create or replace function amine.business_type_in(p text) returns text
language plpgsql immutable set search_path = '' as $$
begin
  if p is null or btrim(p) = '' then
    return null;
  end if;
  if p not in ('restaurant', 'cafe', 'hotel', 'snack', 'caterer', 'bakery', 'other') then
    perform amine.err('INVALID_INPUT', 'business_type');
  end if;
  return p;
end $$;

create or replace function amine.tax_id_in(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare
  v text := upper(btrim(coalesce(p, '')));
begin
  if v = '' then
    return null;
  end if;
  if v !~ '^[0-9A-Z/ .-]{4,30}$' then
    perform amine.err('INVALID_INPUT', 'tax_id');
  end if;
  return v;
end $$;

-- Établissement du client (restaurant, café, hôtel…) : obligatoire pour commander.
create or replace function public.update_my_business(p_business_name text, p_business_type text, p_tax_id text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  perform amine.hit('profile:' || p.id, 30, 3600);
  update amine.profiles set business_name = amine.txt(p_business_name, 'business_name', 120, true, 2),
    business_type = amine.business_type_in(p_business_type), tax_id = amine.tax_id_in(p_tax_id), updated_at = now()
  where id = p.id;
  return public.get_me();
end $$;

-- Adresses ------------------------------------------------------------------------------------
create or replace function amine.address_json(a amine.addresses) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', a.id, 'label', a.label, 'line', a.line, 'details', a.details,
    'lat', a.lat, 'lng', a.lng, 'zone_id', a.zone_id, 'located_by', a.located_by, 'created_at', a.created_at)
$$;

create or replace function public.list_my_addresses() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  return coalesce((select jsonb_agg(amine.address_json(a) order by a.created_at desc)
    from amine.addresses a where a.user_id = p.id), '[]'::jsonb);
end $$;

-- Création ou modification d'une adresse de livraison d'un compte (client lui-même ou équipe AMINE).
create or replace function amine.save_address_for(
  p_user uuid, p_id uuid, p_label text, p_line text, p_details text, p_lat numeric, p_lng numeric, p_located_by text
) returns amine.addresses
language plpgsql set search_path = '' as $$
declare
  v_label text := amine.txt(p_label, 'label', 40);
  v_line text := amine.txt(p_line, 'line', 200, true, 3);
  v_details text := amine.txt(p_details, 'details', 200);
  z amine.zones;
  a amine.addresses;
begin
  perform amine.check_point(p_lat, p_lng);
  if p_located_by is null or p_located_by not in ('gps', 'map', 'zone') then
    perform amine.err('INVALID_INPUT', 'located_by');
  end if;
  z := amine.zone_for(p_lat, p_lng);
  if z.id is null then
    perform amine.err('ADDRESS_OUT_OF_ZONE');
  end if;
  if p_id is null then
    if (select count(*) from amine.addresses where user_id = p_user) >= 20 then
      perform amine.err('TOO_MANY_ADDRESSES');
    end if;
    insert into amine.addresses (user_id, label, line, details, lat, lng, zone_id, located_by)
    values (p_user, v_label, v_line, v_details, round(p_lat, 6), round(p_lng, 6), z.id, p_located_by)
    returning * into a;
  else
    update amine.addresses set label = v_label, line = v_line, details = v_details, lat = round(p_lat, 6),
      lng = round(p_lng, 6), zone_id = z.id, located_by = p_located_by
    where id = p_id and user_id = p_user
    returning * into a;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
  end if;
  return a;
end $$;

create or replace function public.save_address(
  p_id uuid, p_label text, p_line text, p_details text, p_lat numeric, p_lng numeric, p_located_by text default 'map'
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  perform amine.hit('address:' || p.id, 40, 3600);
  return amine.address_json(amine.save_address_for(p.id, p_id, p_label, p_line, p_details, p_lat, p_lng, p_located_by));
end $$;

create or replace function public.delete_address(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  delete from amine.addresses where id = p_id and user_id = p.id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Passage de commande ---------------------------------------------------------------------------
drop function if exists amine.assert_can_order(amine.profiles);
create or replace function amine.assert_can_order(p amine.profiles, p_by_admin boolean default false) returns void
language plpgsql set search_path = '' as $$
declare
  v_max int := greatest(1, coalesce((amine.setting('orders') ->> 'max_active_per_customer')::int, 5));
begin
  if coalesce((amine.setting('platform') ->> 'maintenance')::boolean, false) then
    perform amine.err('MAINTENANCE');
  end if;
  if p.status <> 'active' then
    perform amine.err('ACCOUNT_BLOCKED');
  end if;
  if p.phone is null then
    perform amine.err('PHONE_REQUIRED');
  end if;
  if p_by_admin then
    return;
  end if;
  if coalesce((amine.setting('auth') ->> 'require_phone_verification')::boolean, false) and not p.phone_verified then
    perform amine.err('PHONE_NOT_VERIFIED');
  end if;
  if (select count(*) from amine.orders o
      where o.customer_id = p.id and o.status in ('placed', 'accepted', 'preparing', 'ready', 'picked_up')) >= v_max then
    perform amine.err('TOO_MANY_ACTIVE_ORDERS', v_max::text);
  end if;
end $$;

-- Réserve le stock des lignes d'un panier chiffré (ordre fixe des produits : pas d'interblocage).
create or replace function amine.reserve_stock(p_lines jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  v_line jsonb;
begin
  for v_line in select e.value from jsonb_array_elements(p_lines) e order by e.value ->> 'product_id' loop
    update amine.products set stock = stock - (v_line ->> 'quantity')::int, updated_at = now()
    where id = (v_line ->> 'product_id')::uuid and stock is not null and stock >= (v_line ->> 'quantity')::int;
    if not found and exists (select 1 from amine.products where id = (v_line ->> 'product_id')::uuid and stock is not null) then
      perform amine.err('OUT_OF_STOCK', v_line ->> 'product_id');
    end if;
  end loop;
end $$;

-- Paiement demandé : à la livraison (espèces) ou sur compte, seulement pour les clients qui ont des
-- conditions de paiement à terme et dans la limite de leur encours autorisé.
create or replace function amine.check_payment(p amine.profiles, p_method text, p_total int) returns void
language plpgsql set search_path = '' as $$
declare
  v_exposure bigint;
begin
  if p_method is null or p_method not in ('cod', 'account') then
    perform amine.err('INVALID_INPUT', 'payment_method');
  end if;
  if p_method = 'account' then
    if p.payment_terms <> 'account' then
      perform amine.err('ACCOUNT_NOT_ALLOWED');
    end if;
    v_exposure := amine.account_exposure(p.id);
    if v_exposure + p_total > p.credit_limit then
      perform amine.err('CREDIT_LIMIT_EXCEEDED', greatest(0, p.credit_limit - v_exposure)::text);
    end if;
  end if;
end $$;

-- Création d'une commande de produits AMINE (par le client, l'assistant, l'équipe AMINE ou une
-- commande récurrente). Toutes les vérifications sont ici : dépôt actif, créneau, adresse livrable,
-- prix (prix négociés du client compris), stock et paiement.
drop function if exists amine.create_store_order(amine.profiles, uuid, uuid, jsonb, text, text, text, text, text, text, uuid);
drop function if exists amine.create_store_order(amine.profiles, uuid, uuid, jsonb, text, text, text, text, text, text, uuid, text, uuid);
create or replace function amine.create_store_order(
  p amine.profiles, p_store_id uuid, p_address_id uuid, p_items jsonb, p_note text, p_key text, p_promo_code text,
  p_slot text, p_source text, p_actor text, p_actor_id uuid, p_payment text default 'cod', p_recurring uuid default null,
  p_use_points boolean default false
) returns amine.orders
language plpgsql set search_path = '' as $$
declare
  s amine.stores;
  sz amine.zones;
  a amine.addresses;
  dz amine.zones;
  v_cart jsonb;
  v_sub int;
  v_km numeric;
  v_fee int;
  v_service int := greatest(0, coalesce((amine.setting('orders') ->> 'service_fee')::int, 0));
  v_share int := least(10000, greatest(0, coalesce((amine.setting('couriers') ->> 'share_bps')::int, 8000)));
  v_note text := amine.txt(p_note, 'note', 300, false, 1, true);
  v_promo jsonb;
  v_discount int := 0;
  v_loyalty jsonb;
  v_loy_points int := 0;
  v_loy_discount int := 0;
  v_stamp int := amine.stamp_fee();
  v_total int;
  v_code text;
  v_day date;
  o amine.orders;
begin
  if p.business_name is null then
    perform amine.err('BUSINESS_REQUIRED');
  end if;
  select * into s from amine.stores where id = p_store_id for share;
  if not found or s.status <> 'active' then
    perform amine.err('STORE_NOT_FOUND');
  end if;
  v_day := amine.check_slot(s, p_slot);
  select * into sz from amine.zones where id = s.zone_id;
  if not sz.is_active or not (s.kind = any (sz.services)) then
    perform amine.err('SERVICE_UNAVAILABLE');
  end if;
  select * into a from amine.addresses where id = p_address_id and user_id = p.id;
  if not found then
    perform amine.err('ADDRESS_REQUIRED');
  end if;
  dz := amine.zone_for(a.lat, a.lng);
  if dz.id is null then
    perform amine.err('ADDRESS_OUT_OF_ZONE');
  end if;
  v_km := amine.distance_km(s.lat, s.lng, a.lat, a.lng);
  if v_km > coalesce((amine.setting('orders') ->> 'max_distance_km')::numeric, 15) then
    perform amine.err('TOO_FAR');
  end if;

  v_cart := amine.price_cart(s.id, p_items, true, p.id);
  v_sub := (v_cart ->> 'subtotal')::int;
  if v_sub < s.min_order then
    perform amine.err('MIN_ORDER_NOT_REACHED', s.min_order::text);
  end if;
  v_fee := amine.fee_for(sz, v_km);
  -- Code promo (la ligne est verrouillée : deux commandes simultanées ne dépassent pas les limites).
  v_promo := amine.promo_eval(p_promo_code, p.id, s, v_sub, v_fee, v_service, true);
  if v_promo is not null then
    if (v_promo ->> 'ok')::boolean then
      v_discount := (v_promo ->> 'discount')::int;
    elsif coalesce((v_promo ->> 'auto')::boolean, false) then
      -- Offre automatique qui ne s'applique pas à ce panier : pas de remise, pas d'erreur.
      v_promo := null;
    else
      perform amine.err(v_promo ->> 'error', v_promo ->> 'min_subtotal');
    end if;
  end if;
  -- Points de fidélité : utilisés seulement à la demande du client, dans les limites du programme.
  if coalesce(p_use_points, false) then
    v_loyalty := amine.loyalty_redeem_calc(p.id, v_sub, v_sub + v_fee + v_service + v_stamp - v_discount);
    v_loy_points := (v_loyalty ->> 'points')::int;
    v_loy_discount := (v_loyalty ->> 'discount')::int;
    if v_loy_points < 1 then
      perform amine.err('POINTS_NOT_USABLE');
    end if;
  end if;
  v_total := v_sub + v_fee + v_service + v_stamp - v_discount - v_loy_discount;
  perform amine.check_payment(p, coalesce(p_payment, 'cod'), v_total);
  v_code := amine.new_order_code();
  -- Prix flash : les quantités vendues sont recomptées sous verrou (deux commandes simultanées ne dépassent pas le stock offert).
  perform amine.flash_claim(v_cart -> 'lines');
  perform amine.stock_context('sale', v_code);
  perform amine.reserve_stock(v_cart -> 'lines');

  insert into amine.orders (
    code, kind, customer_id, store_id, zone_id, status,
    pickup_name, pickup_phone, pickup_address, pickup_lat, pickup_lng,
    dropoff_name, dropoff_phone, dropoff_address, dropoff_details, dropoff_lat, dropoff_lng, dropoff_located_by,
    payer, distance_km, subtotal, delivery_fee, service_fee, discount, promo_code, stamp_fee, total, commission,
    courier_earning, customer_note, idempotency_key, source, delivery_slot, deliver_on, payment_method, recurring_id,
    loyalty_points, loyalty_discount)
  values (
    v_code, 'store', p.id, s.id, s.zone_id, 'placed',
    s.name, s.phone, s.address, s.lat, s.lng,
    p.business_name, p.phone, a.line, a.details, a.lat, a.lng, a.located_by,
    'customer', v_km, v_sub, v_fee, v_service, v_discount + v_loy_discount, v_promo ->> 'code', v_stamp, v_total,
    round(v_sub::numeric * s.commission_bps / 10000)::int, round(v_fee::numeric * v_share / 10000)::int,
    v_note, p_key, p_source, coalesce(p_slot, 'asap'), v_day, coalesce(p_payment, 'cod'), p_recurring,
    v_loy_points, v_loy_discount)
  returning * into o;

  insert into amine.order_items (order_id, product_id, name, unit, unit_price, list_price, vat_rate, quantity, total, flash_sale_id)
  select o.id, (e.value ->> 'product_id')::uuid, e.value ->> 'name', e.value ->> 'unit',
    (e.value ->> 'unit_price')::int, (e.value ->> 'list_price')::int, (e.value ->> 'vat_rate')::smallint,
    (e.value ->> 'quantity')::int, (e.value ->> 'total')::int, (e.value ->> 'flash_sale_id')::uuid
  from jsonb_array_elements(v_cart -> 'lines') e;
  if v_loy_points > 0 then
    perform amine.loyalty_add(p.id, -v_loy_points, 'redeem', o.id, o.code);
  end if;

  perform amine.log_order(o.id, 'placed', 'status', p_actor, p_actor_id, case when p_source <> 'app' then p_source end);
  perform amine.notify_store(s.id, 'order_new', jsonb_build_object('code', o.code, 'total', o.total),
    '#/depot/orders/' || o.code || '?store=' || s.id::text);
  return o;
end $$;

drop function if exists public.place_order(uuid, jsonb, uuid, text, text);
drop function if exists public.place_order(uuid, jsonb, uuid, text, text, text);
drop function if exists public.place_order(uuid, jsonb, uuid, text, text, text, text, text);
drop function if exists public.place_order(uuid, jsonb, uuid, text, text, text, text, text, text);
create or replace function public.place_order(
  p_store_id uuid, p_items jsonb, p_address_id uuid, p_note text default null, p_idempotency_key text default null,
  p_promo_code text default null, p_delivery_slot text default 'asap', p_source text default 'app',
  p_payment_method text default 'cod', p_use_points boolean default false
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  v_key text := amine.txt(p_idempotency_key, 'idempotency_key', 80);
  v_existing text;
  o amine.orders;
begin
  if v_key is not null then
    select code into v_existing from amine.orders where customer_id = p.id and idempotency_key = v_key;
    if v_existing is not null then
      return jsonb_build_object('code', v_existing, 'replayed', true);
    end if;
  end if;
  if coalesce(p_source, 'app') not in ('app', 'chat') then
    perform amine.err('INVALID_INPUT', 'source');
  end if;
  perform amine.hit('order:' || p.id, 10, 600);
  perform amine.assert_can_order(p);
  o := amine.create_store_order(p, p_store_id, p_address_id, p_items, p_note, v_key, p_promo_code,
    coalesce(p_delivery_slot, 'asap'), coalesce(p_source, 'app'), 'customer', p.id, coalesce(p_payment_method, 'cod'),
    null, coalesce(p_use_points, false));
  return jsonb_build_object('code', o.code, 'replayed', false, 'total', o.total,
    'delivery_slot', o.delivery_slot, 'deliver_on', o.deliver_on, 'payment_method', o.payment_method);
exception
  when unique_violation then
    -- Deux envois simultanés du même panier : on renvoie la commande déjà créée.
    if v_key is not null then
      select code into v_existing from amine.orders where customer_id = p.id and idempotency_key = v_key;
      if v_existing is not null then
        return jsonb_build_object('code', v_existing, 'replayed', true);
      end if;
    end if;
    raise;
end $$;

-- p_pickup / p_dropoff : {"address": "...", "details": "...", "lat": 36.4, "lng": 10.7, "name": "...", "phone": "..."}
create or replace function public.place_parcel(
  p_pickup jsonb, p_dropoff jsonb, p_size text, p_description text default null, p_payer text default 'sender',
  p_note text default null, p_idempotency_key text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  v_parcel jsonb := amine.setting('parcel');
  v_share int := least(10000, greatest(0, coalesce((amine.setting('couriers') ->> 'share_bps')::int, 8000)));
  v_key text := amine.txt(p_idempotency_key, 'idempotency_key', 80);
  v_existing text;
  v_p_lat numeric;
  v_p_lng numeric;
  v_d_lat numeric;
  v_d_lng numeric;
  pz amine.zones;
  dz amine.zones;
  v_km numeric;
  v_fee int;
  o amine.orders;
begin
  if v_key is not null then
    select code into v_existing from amine.orders where customer_id = p.id and idempotency_key = v_key;
    if v_existing is not null then
      return jsonb_build_object('code', v_existing, 'replayed', true);
    end if;
  end if;
  perform amine.hit('order:' || p.id, 10, 600);
  perform amine.assert_can_order(p);
  if not coalesce((v_parcel ->> 'enabled')::boolean, false) then
    perform amine.err('PARCEL_DISABLED');
  end if;
  if p_pickup is null or jsonb_typeof(p_pickup) <> 'object' or p_dropoff is null or jsonb_typeof(p_dropoff) <> 'object' then
    perform amine.err('INVALID_INPUT', 'address');
  end if;
  if p_size is null or p_size not in ('small', 'medium', 'large') then
    perform amine.err('INVALID_INPUT', 'size');
  end if;
  if p_payer is null or p_payer not in ('sender', 'recipient') then
    perform amine.err('INVALID_INPUT', 'payer');
  end if;
  begin
    v_p_lat := (p_pickup ->> 'lat')::numeric;
    v_p_lng := (p_pickup ->> 'lng')::numeric;
    v_d_lat := (p_dropoff ->> 'lat')::numeric;
    v_d_lng := (p_dropoff ->> 'lng')::numeric;
  exception when others then
    perform amine.err('INVALID_LOCATION');
  end;
  perform amine.check_point(v_p_lat, v_p_lng);
  perform amine.check_point(v_d_lat, v_d_lng);
  pz := amine.zone_for(v_p_lat, v_p_lng);
  dz := amine.zone_for(v_d_lat, v_d_lng);
  if pz.id is null or dz.id is null then
    perform amine.err('ADDRESS_OUT_OF_ZONE');
  end if;
  if not ('parcel' = any (pz.services)) then
    perform amine.err('SERVICE_UNAVAILABLE');
  end if;
  v_km := amine.distance_km(v_p_lat, v_p_lng, v_d_lat, v_d_lng);
  if v_km > coalesce((amine.setting('orders') ->> 'max_distance_km')::numeric, 15) then
    perform amine.err('TOO_FAR');
  end if;
  v_fee := amine.fee_for(pz, v_km) + coalesce((v_parcel -> 'size_fee' ->> p_size)::int, 0);

  insert into amine.orders (
    code, kind, customer_id, zone_id, status,
    pickup_name, pickup_phone, pickup_address, pickup_details, pickup_lat, pickup_lng,
    dropoff_name, dropoff_phone, dropoff_address, dropoff_details, dropoff_lat, dropoff_lng, dropoff_located_by,
    parcel_size, parcel_description, payer, distance_km, subtotal, delivery_fee, service_fee, total, commission,
    courier_earning, customer_note, idempotency_key, ready_at)
  values (
    amine.new_order_code(), 'parcel', p.id, pz.id, 'ready',
    coalesce(amine.txt(p_pickup ->> 'name', 'pickup_name', 120), nullif(p.full_name, ''), '—'),
    coalesce(amine.phone_in(p_pickup ->> 'phone', 'pickup_phone'), p.phone),
    amine.txt(p_pickup ->> 'address', 'pickup_address', 200, true, 3),
    amine.txt(p_pickup ->> 'details', 'pickup_details', 200),
    round(v_p_lat, 6), round(v_p_lng, 6),
    amine.txt(p_dropoff ->> 'name', 'dropoff_name', 120, true, 2),
    amine.phone_in(p_dropoff ->> 'phone', 'dropoff_phone', true),
    amine.txt(p_dropoff ->> 'address', 'dropoff_address', 200, true, 3),
    amine.txt(p_dropoff ->> 'details', 'dropoff_details', 200),
    round(v_d_lat, 6), round(v_d_lng, 6),
    case when p_dropoff ->> 'located_by' in ('gps', 'map', 'zone') then p_dropoff ->> 'located_by' else 'map' end,
    p_size, amine.txt(p_description, 'description', 200), p_payer, v_km, 0, v_fee, 0, v_fee, 0,
    round(v_fee::numeric * v_share / 10000)::int,
    amine.txt(p_note, 'note', 300, false, 1, true), v_key, now())
  returning * into o;

  perform amine.log_order(o.id, 'ready', 'status', 'customer', p.id, null);
  return jsonb_build_object('code', o.code, 'replayed', false);
exception
  when unique_violation then
    if v_key is not null then
      select code into v_existing from amine.orders where customer_id = p.id and idempotency_key = v_key;
      if v_existing is not null then
        return jsonb_build_object('code', v_existing, 'replayed', true);
      end if;
    end if;
    raise;
end $$;

-- Suivi -----------------------------------------------------------------------------------------
create or replace function public.list_my_orders(p_limit int default 20, p_offset int default 0) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  return coalesce((
    select jsonb_agg(x.j order by x.placed_at desc)
    from (
      select jsonb_build_object('code', o.code, 'kind', o.kind, 'status', o.status, 'total', o.total,
          'placed_at', o.placed_at, 'delivered_at', o.delivered_at, 'source', o.source,
          'delivery_slot', coalesce(o.delivery_slot, 'asap'), 'deliver_on', o.deliver_on,
          'items_count', (select coalesce(sum(i.quantity), 0) from amine.order_items i where i.order_id = o.id),
          'lines', (select count(*) from amine.order_items i where i.order_id = o.id),
          'preview', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'ref', t.ref, 'quantity', t.quantity))
            from (select i.name, pr.ref, i.quantity from amine.order_items i left join amine.products pr on pr.id = i.product_id
                  where i.order_id = o.id order by i.total desc limit 4) t), '[]'::jsonb),
          'store', case when s.id is null then null else jsonb_build_object('id', s.id, 'name', s.name, 'name_ar', s.name_ar,
            'name_en', s.name_en, 'logo_url', s.logo_url, 'cover_url', s.cover_url, 'slug', s.slug, 'kind', s.kind) end,
          'dropoff_name', case when o.kind = 'parcel' then o.dropoff_name end) as j,
        o.placed_at
      from amine.orders o
      left join amine.stores s on s.id = o.store_id
      where o.customer_id = p.id
      order by o.placed_at desc
      limit least(greatest(coalesce(p_limit, 20), 1), 100) offset greatest(coalesce(p_offset, 0), 0)
    ) x), '[]'::jsonb);
end $$;

create or replace function public.get_my_order(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  o amine.orders;
begin
  perform amine.maintenance();
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and customer_id = p.id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.order_json(o, 'customer') || jsonb_build_object(
    'can_cancel', amine.can_transition(o, 'cancelled', 'customer'),
    'can_edit', o.kind = 'store' and o.status = 'placed',
    'can_rate', o.status = 'delivered' and o.store_rating is null and o.courier_rating is null,
    'complaints', coalesce((
      select jsonb_agg(amine.complaint_json(c) order by c.created_at desc)
      from amine.complaints c where c.order_id = o.id), '[]'::jsonb));
end $$;

-- Modifier une commande pas encore acceptée par le dépôt : note et créneau de livraison.
-- p_data : {"note": "...", "delivery_slot": "tomorrow_am"} (clés facultatives)
create or replace function public.update_my_order(p_code text, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  o amine.orders;
  s amine.stores;
  v_day date;
begin
  perform amine.hit('order_edit:' || p.id, 30, 600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and customer_id = p.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if o.kind <> 'store' or o.status <> 'placed' then
    perform amine.err('ORDER_LOCKED');
  end if;
  if p_data ? 'note' then
    o.customer_note := amine.txt(p_data ->> 'note', 'note', 300, false, 1, true);
  end if;
  if p_data ? 'delivery_slot' and coalesce(p_data ->> 'delivery_slot', 'asap') <> coalesce(o.delivery_slot, 'asap') then
    select * into s from amine.stores where id = o.store_id;
    v_day := amine.check_slot(s, coalesce(p_data ->> 'delivery_slot', 'asap'));
    o.delivery_slot := coalesce(p_data ->> 'delivery_slot', 'asap');
    o.deliver_on := v_day;
  end if;
  update amine.orders set customer_note = o.customer_note, delivery_slot = o.delivery_slot, deliver_on = o.deliver_on,
    updated_at = now()
  where id = o.id returning * into o;
  perform amine.log_order(o.id, o.status, 'updated', 'customer', p.id, null);
  perform amine.notify_store(o.store_id, 'order_updated', jsonb_build_object('code', o.code),
    '#/depot/orders/' || o.code || '?store=' || o.store_id::text);
  return public.get_my_order(o.code);
end $$;

-- Produits favoris (« mes produits habituels ») ------------------------------------------------------
drop function if exists public.toggle_favorite(uuid);
create or replace function public.toggle_favorite(p_product_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  perform amine.hit('favorite:' || p.id, 240, 3600);
  if exists (select 1 from amine.favorites where user_id = p.id and product_id = p_product_id) then
    delete from amine.favorites where user_id = p.id and product_id = p_product_id;
    return jsonb_build_object('favorite', false);
  end if;
  if not exists (select 1 from amine.products pr join amine.stores s on s.id = pr.store_id
                 where pr.id = p_product_id and pr.deleted_at is null and s.status = 'active') then
    perform amine.err('NOT_FOUND');
  end if;
  if (select count(*) from amine.favorites where user_id = p.id) >= 300 then
    perform amine.err('TOO_MANY_FAVORITES');
  end if;
  insert into amine.favorites (user_id, product_id) values (p.id, p_product_id);
  return jsonb_build_object('favorite', true);
end $$;

create or replace function public.list_my_favorites() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  return coalesce((
    select jsonb_agg(amine.product_json(pr) || jsonb_build_object('store_id', pr.store_id) order by f.created_at desc)
    from amine.favorites f join amine.products pr on pr.id = f.product_id
    where f.user_id = p.id and pr.deleted_at is null), '[]'::jsonb);
end $$;

-- Produits commandés le plus souvent ces 120 derniers jours (pour recommander en un geste).
create or replace function public.my_frequent_products(p_limit int default 12) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  return coalesce((
    select jsonb_agg(amine.product_json(pr) || jsonb_build_object('store_id', pr.store_id, 'times', t.times,
        'usual_qty', t.usual_qty) order by t.times desc, t.qty desc)
    from (
      select i.product_id, count(distinct o.id) as times, sum(i.quantity) as qty,
        round(avg(i.quantity))::int as usual_qty
      from amine.order_items i join amine.orders o on o.id = i.order_id
      where o.customer_id = p.id and o.status not in ('cancelled', 'rejected') and o.placed_at > now() - interval '120 days'
        and i.product_id is not null
      group by i.product_id
      order by 2 desc, 3 desc
      limit least(greatest(coalesce(p_limit, 12), 1), 50)) t
    join amine.products pr on pr.id = t.product_id
    where pr.deleted_at is null), '[]'::jsonb);
end $$;

-- Réclamations -------------------------------------------------------------------------------------
create or replace function amine.complaint_json(c amine.complaints) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', c.id, 'reason', c.reason, 'message', c.message, 'status', c.status,
    'reply', c.reply, 'created_at', c.created_at, 'updated_at', c.updated_at, 'resolved_at', c.resolved_at,
    'order_code', (select o.code from amine.orders o where o.id = c.order_id))
$$;

create or replace function amine.reason_in(p text) returns text
language plpgsql immutable set search_path = '' as $$
begin
  if p is null or p not in ('missing_item', 'wrong_item', 'damaged', 'late', 'courier', 'payment', 'other') then
    perform amine.err('INVALID_INPUT', 'reason');
  end if;
  return p;
end $$;

create or replace function public.create_complaint(p_code text, p_reason text, p_message text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  o amine.orders;
  c amine.complaints;
begin
  perform amine.hit('complaint:' || p.id, 5, 86400);
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and customer_id = p.id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if o.placed_at < now() - interval '30 days' then
    perform amine.err('COMPLAINT_TOO_LATE');
  end if;
  if exists (select 1 from amine.complaints where order_id = o.id and status in ('open', 'in_progress')) then
    perform amine.err('COMPLAINT_OPEN');
  end if;
  insert into amine.complaints (order_id, customer_id, reason, message)
  values (o.id, p.id, amine.reason_in(p_reason), amine.txt(p_message, 'message', 1000, true, 5, true))
  returning * into c;
  perform amine.notify_admins('complaint_new', jsonb_build_object('code', o.code), '#/admin/complaints');
  return amine.complaint_json(c);
end $$;

create or replace function public.list_my_complaints() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  return coalesce((
    select jsonb_agg(amine.complaint_json(c) order by c.created_at desc)
    from amine.complaints c where c.customer_id = p.id), '[]'::jsonb);
end $$;

-- Tant que l'équipe n'a pas commencé à la traiter, la réclamation peut être corrigée ou retirée.
create or replace function public.update_my_complaint(p_id uuid, p_reason text, p_message text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  c amine.complaints;
begin
  perform amine.hit('complaint_edit:' || p.id, 30, 3600);
  select * into c from amine.complaints where id = p_id and customer_id = p.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if c.status <> 'open' then
    perform amine.err('COMPLAINT_LOCKED');
  end if;
  update amine.complaints set reason = amine.reason_in(p_reason),
    message = amine.txt(p_message, 'message', 1000, true, 5, true), updated_at = now()
  where id = c.id returning * into c;
  return amine.complaint_json(c);
end $$;

create or replace function public.delete_my_complaint(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  c amine.complaints;
begin
  select * into c from amine.complaints where id = p_id and customer_id = p.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if c.status <> 'open' then
    perform amine.err('COMPLAINT_LOCKED');
  end if;
  delete from amine.complaints where id = c.id;
  return jsonb_build_object('ok', true);
end $$;

-- Position du livreur : uniquement pour le client de la commande, pendant la course, si le
-- téléphone du livreur l'a envoyée récemment. Aucune position n'est inventée.
create or replace function public.get_order_tracking(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  o amine.orders;
  l amine.courier_locations;
begin
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and customer_id = p.id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if o.courier_id is not null and o.status in ('accepted', 'preparing', 'ready', 'picked_up') then
    select * into l from amine.courier_locations
    where courier_id = o.courier_id and recorded_at > now() - interval '15 minutes';
  end if;
  return jsonb_build_object('status', o.status, 'updated_at', o.updated_at, 'has_courier', o.courier_id is not null,
    'location', case when l.courier_id is null then null else jsonb_build_object('lat', l.lat, 'lng', l.lng,
      'accuracy_m', l.accuracy_m, 'heading', l.heading, 'speed_kmh', l.speed_kmh, 'recorded_at', l.recorded_at) end);
end $$;

create or replace function public.cancel_my_order(p_code text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  o amine.orders;
begin
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and customer_id = p.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  o := amine.transition(o, 'cancelled', 'customer', p.id, coalesce(amine.txt(p_reason, 'reason', 200), 'customer_cancelled'));
  return amine.order_json(o, 'customer');
end $$;

create or replace function public.rate_order(p_code text, p_store_rating int, p_courier_rating int, p_comment text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  o amine.orders;
  v_comment text := amine.txt(p_comment, 'comment', 500, false, 1, true);
begin
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and customer_id = p.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if o.status <> 'delivered' or o.store_rating is not null or o.courier_rating is not null then
    perform amine.err('CANNOT_RATE');
  end if;
  if (p_store_rating is not null and p_store_rating not between 1 and 5)
     or (p_courier_rating is not null and p_courier_rating not between 1 and 5)
     or (p_store_rating is null and p_courier_rating is null) then
    perform amine.err('INVALID_INPUT', 'rating');
  end if;
  if o.store_id is null then
    p_store_rating := null;
  end if;
  if o.courier_id is null then
    p_courier_rating := null;
  end if;
  update amine.orders set store_rating = p_store_rating, courier_rating = p_courier_rating, review_comment = v_comment, updated_at = now()
  where id = o.id;
  if p_store_rating is not null then
    update amine.stores set rating_sum = rating_sum + p_store_rating, rating_count = rating_count + 1 where id = o.store_id;
  end if;
  if p_courier_rating is not null then
    update amine.couriers set rating_sum = rating_sum + p_courier_rating, rating_count = rating_count + 1 where user_id = o.courier_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Notifications ---------------------------------------------------------------------------------
create or replace function public.list_my_notifications(p_limit int default 30) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'params', n.params, 'link', n.link,
          'read', n.read_at is not null, 'created_at', n.created_at) order by n.created_at desc)
      from (select * from amine.notifications where user_id = p.id order by created_at desc
            limit least(greatest(coalesce(p_limit, 30), 1), 100)) n), '[]'::jsonb),
    'unread', (select count(*) from amine.notifications where user_id = p.id and read_at is null));
end $$;

-- p_ids : tableau JSON d'identifiants, ou null pour tout marquer comme lu.
create or replace function public.mark_notifications_read(p_ids jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  v_ids uuid[];
begin
  if p_ids is not null and jsonb_typeof(p_ids) <> 'null' then
    if jsonb_typeof(p_ids) <> 'array' or jsonb_array_length(p_ids) > 200 or exists (
      select 1 from jsonb_array_elements_text(p_ids) e
      where e.value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
      perform amine.err('INVALID_INPUT', 'ids');
    end if;
    select array_agg(e.value::uuid) into v_ids from jsonb_array_elements_text(p_ids) e;
  end if;
  update amine.notifications set read_at = now()
  where user_id = p.id and read_at is null and (v_ids is null or id = any (v_ids));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.delete_my_notifications(p_ids jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  v_ids uuid[];
  v_count int;
begin
  if p_ids is not null and jsonb_typeof(p_ids) <> 'null' then
    if jsonb_typeof(p_ids) <> 'array' or jsonb_array_length(p_ids) > 200 or exists (
      select 1 from jsonb_array_elements_text(p_ids) e
      where e.value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
      perform amine.err('INVALID_INPUT', 'ids');
    end if;
    select array_agg(e.value::uuid) into v_ids from jsonb_array_elements_text(p_ids) e;
  end if;
  delete from amine.notifications where user_id = p.id and (v_ids is null or id = any (v_ids));
  get diagnostics v_count = row_count;
  return jsonb_build_object('ok', true, 'deleted', v_count);
end $$;

-- Données personnelles : export et suppression -----------------------------------------------------
create or replace function public.export_my_data() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  perform amine.hit('export:' || p.id, 5, 3600);
  return jsonb_build_object(
    'exported_at', now(),
    'profile', to_jsonb(p),
    'addresses', coalesce((select jsonb_agg(to_jsonb(a)) from amine.addresses a where a.user_id = p.id), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(amine.order_json(o, 'customer') order by o.placed_at)
      from amine.orders o where o.customer_id = p.id), '[]'::jsonb),
    'courier', (select to_jsonb(c) from amine.couriers c where c.user_id = p.id),
    'deliveries', coalesce((select jsonb_agg(jsonb_build_object('code', o.code, 'status', o.status,
        'delivered_at', o.delivered_at, 'courier_earning', o.courier_earning, 'cod_collected', o.cod_collected))
      from amine.orders o where o.courier_id = p.id), '[]'::jsonb),
    'stores', coalesce((select jsonb_agg(jsonb_build_object('store_id', st.store_id, 'role', st.role))
      from amine.store_staff st where st.user_id = p.id), '[]'::jsonb),
    'favorites', coalesce((select jsonb_agg(jsonb_build_object('product', pr.name, 'added_at', f.created_at))
      from amine.favorites f join amine.products pr on pr.id = f.product_id where f.user_id = p.id), '[]'::jsonb),
    'complaints', coalesce((select jsonb_agg(amine.complaint_json(c)) from amine.complaints c
      where c.customer_id = p.id), '[]'::jsonb),
    'notifications', coalesce((select jsonb_agg(jsonb_build_object('kind', n.kind, 'params', n.params,
        'created_at', n.created_at)) from amine.notifications n where n.user_id = p.id), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg(amine.invoice_json(i) order by i.issued_at)
      from amine.invoices i where i.customer_id = p.id), '[]'::jsonb),
    'account_entries', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'amount', e.amount,
        'method', e.method, 'reference', e.reference, 'occurred_on', e.occurred_on) order by e.occurred_on, e.id)
      from amine.account_entries e where e.customer_id = p.id), '[]'::jsonb),
    'recurring_orders', coalesce((select jsonb_agg(amine.recurring_json(r) order by r.created_at)
      from amine.recurring_orders r where r.customer_id = p.id), '[]'::jsonb),
    'negotiated_prices', coalesce((select jsonb_agg(jsonb_build_object('product', pr.name, 'price', cp.price))
      from amine.client_prices cp join amine.products pr on pr.id = cp.product_id where cp.customer_id = p.id), '[]'::jsonb));
end $$;

-- Suppression d'un compte : les commandes passées sont conservées pour la comptabilité mais
-- anonymisées (nom, téléphone, adresse précise) ; le compte de connexion est supprimé.
create or replace function amine.erase_account(p amine.profiles) returns jsonb
language plpgsql set search_path = '' as $$
begin
  if exists (select 1 from amine.orders o where (o.customer_id = p.id or o.courier_id = p.id)
             and o.status in ('placed', 'accepted', 'preparing', 'ready', 'picked_up')) then
    perform amine.err('ACTIVE_ORDERS_EXIST');
  end if;
  if p.is_admin and (select count(*) from amine.profiles where is_admin and status = 'active' and id <> p.id) < 1 then
    perform amine.err('LAST_ADMIN');
  end if;
  -- Un compte client qui doit encore de l'argent (ou à qui AMINE en doit) n'est pas supprimé.
  if amine.account_balance(p.id) <> 0 then
    perform amine.err('ACCOUNT_BALANCE_NOT_ZERO');
  end if;
  update amine.orders set dropoff_name = '—', dropoff_phone = null, dropoff_details = null,
    dropoff_address = '—', dropoff_lat = round(dropoff_lat, 2), dropoff_lng = round(dropoff_lng, 2),
    customer_note = null, review_comment = null, pod_name = null,
    pickup_name = case when kind = 'parcel' then '—' else pickup_name end,
    pickup_phone = case when kind = 'parcel' then null else pickup_phone end,
    pickup_address = case when kind = 'parcel' then '—' else pickup_address end,
    pickup_details = case when kind = 'parcel' then null else pickup_details end
  where customer_id = p.id;
  -- Un dépôt appartenant au compte reste à AMINE : il est rattaché à un autre administrateur.
  update amine.stores set owner_id = (select x.id from amine.profiles x where x.is_admin and x.status = 'active'
      and x.id <> p.id order by x.created_at limit 1)
  where owner_id = p.id;
  delete from amine.addresses where user_id = p.id;
  delete from amine.notifications where user_id = p.id;
  delete from amine.favorites where user_id = p.id;
  -- Points et parrainages n'ont pas de valeur comptable : ils sont effacés avec le compte.
  delete from amine.loyalty_ledger where customer_id = p.id;
  delete from amine.referrals where referrer_id = p.id or referee_id = p.id;
  delete from amine.store_staff where user_id = p.id;
  update amine.complaints set message = '[supprimé]', reply = null where customer_id = p.id;
  delete from amine.courier_locations where courier_id = p.id;
  update amine.couriers set cin = null, note = null, is_online = false where user_id = p.id;
  update amine.profiles set email = null, full_name = '', phone = null, phone_verified = false,
    business_name = null, tax_id = null, admin_note = null, referral_code = null,
    marketing_opt_in = false, status = 'blocked', is_admin = false, updated_at = now()
  where id = p.id;
  perform amine.audit('account.deleted', 'profile', p.id::text, '{}'::jsonb);
  -- Suppression du compte de connexion (le profil suit par cascade). Si le projet n'autorise pas
  -- cette opération, le compte reste bloqué et anonymisé, et l'administrateur est prévenu.
  begin
    delete from auth.users where id = p.id;
  exception when insufficient_privilege then
    perform amine.notify_admins('account_deletion_pending', jsonb_build_object('user_id', p.id), '#/admin/clients');
    return jsonb_build_object('ok', true, 'login_deleted', false);
  end;
  return jsonb_build_object('ok', true, 'login_deleted', true);
end $$;

create or replace function public.delete_my_account(p_confirm text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  if coalesce(p_confirm, '') <> 'DELETE' then
    perform amine.err('CONFIRMATION_MISMATCH');
  end if;
  return amine.erase_account(p);
end $$;

-- =============================================================================================
--  Espace dépôt (préparation des commandes) : fiche du dépôt, catalogue, stock, commandes,
--  statistiques, équipe. Chaque fonction vérifie que l'appelant fait partie de l'équipe du dépôt
--  (ou est administrateur). Les dépôts sont créés par l'administration (07_admin.sql).
-- =============================================================================================

create or replace function amine.merchant_product_json(p amine.products) returns jsonb
language sql stable set search_path = '' as $$
  select amine.product_json(p) || jsonb_build_object('stock', p.stock, 'is_available', p.is_available,
    'updated_at', p.updated_at, 'cost_price', p.cost_price,
    'ordered', exists (select 1 from amine.order_items i where i.product_id = p.id))
$$;

create or replace function amine.merchant_store_json(s amine.stores) returns jsonb
language sql stable set search_path = '' as $$
  select amine.store_card(s) || jsonb_build_object(
    'phone', s.phone, 'hours', s.hours, 'status', s.status, 'status_note', s.status_note, 'is_open', s.is_open,
    'commission_bps', s.commission_bps, 'created_at', s.created_at, 'approved_at', s.approved_at,
    'role', (select st.role from amine.store_staff st where st.store_id = s.id and st.user_id = auth.uid()),
    'zone', (select jsonb_build_object('id', z.id, 'name_fr', z.name_fr, 'name_ar', z.name_ar, 'name_en', z.name_en,
      'services', to_jsonb(z.services)) from amine.zones z where z.id = s.zone_id),
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object('id', sc.id, 'name', sc.name, 'name_ar', sc.name_ar, 'name_en', sc.name_en,
        'sort', sc.sort) order by sc.sort, sc.name)
      from amine.sections sc where sc.store_id = s.id), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(amine.merchant_product_json(p) order by p.sort, p.name)
      from amine.products p where p.store_id = s.id and p.deleted_at is null), '[]'::jsonb))
$$;

-- Version 1 : les commerçants s'inscrivaient eux-mêmes. AMINE gère maintenant ses propres dépôts.
drop function if exists public.apply_store(text, text, text, text, numeric, numeric, text);

create or replace function public.merchant_store(p_store_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  return amine.merchant_store_json(s);
end $$;

-- Modification partielle : seules les clés présentes dans p_data sont modifiées.
create or replace function public.merchant_update_store(p_store_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id, true);
  z amine.zones;
  v_lat numeric;
  v_lng numeric;
begin
  perform amine.hit('store_update:' || auth.uid(), 120, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  if p_data ? 'name' then s.name := amine.txt(p_data ->> 'name', 'name', 80, true, 2); end if;
  if p_data ? 'name_ar' then s.name_ar := amine.txt(p_data ->> 'name_ar', 'name_ar', 80); end if;
  if p_data ? 'name_en' then s.name_en := amine.txt(p_data ->> 'name_en', 'name_en', 80); end if;
  if p_data ? 'description' then s.description := amine.txt(p_data ->> 'description', 'description', 500, false, 1, true); end if;
  if p_data ? 'description_ar' then s.description_ar := amine.txt(p_data ->> 'description_ar', 'description_ar', 500, false, 1, true); end if;
  if p_data ? 'description_en' then s.description_en := amine.txt(p_data ->> 'description_en', 'description_en', 500, false, 1, true); end if;
  if p_data ? 'phone' then s.phone := amine.phone_in(p_data ->> 'phone', 'phone', true); end if;
  if p_data ? 'address' then s.address := amine.txt(p_data ->> 'address', 'address', 200, true, 3); end if;
  if p_data ? 'lat' or p_data ? 'lng' then
    begin
      v_lat := (p_data ->> 'lat')::numeric;
      v_lng := (p_data ->> 'lng')::numeric;
    exception when others then
      perform amine.err('INVALID_LOCATION');
    end;
    perform amine.check_point(v_lat, v_lng);
    z := amine.zone_for(v_lat, v_lng);
    if z.id is null then
      perform amine.err('ADDRESS_OUT_OF_ZONE');
    end if;
    s.lat := round(v_lat, 6);
    s.lng := round(v_lng, 6);
    s.zone_id := z.id;
  end if;
  if p_data ? 'logo_url' then
    s.logo_url := nullif(btrim(coalesce(p_data ->> 'logo_url', '')), '');
    if not amine.media_url_ok(s.logo_url, s.id) then perform amine.err('INVALID_INPUT', 'logo_url'); end if;
  end if;
  if p_data ? 'cover_url' then
    s.cover_url := nullif(btrim(coalesce(p_data ->> 'cover_url', '')), '');
    if not amine.media_url_ok(s.cover_url, s.id) then perform amine.err('INVALID_INPUT', 'cover_url'); end if;
  end if;
  if p_data ? 'hours' then
    if not amine.valid_hours(p_data -> 'hours') then perform amine.err('INVALID_INPUT', 'hours'); end if;
    s.hours := p_data -> 'hours';
  end if;
  if p_data ? 'min_order' then
    if coalesce(p_data ->> 'min_order', '') !~ '^[0-9]{1,8}$' or (p_data ->> 'min_order')::int > 10000000 then
      perform amine.err('INVALID_INPUT', 'min_order');
    end if;
    s.min_order := (p_data ->> 'min_order')::int;
  end if;
  if p_data ? 'prep_minutes' then
    if coalesce(p_data ->> 'prep_minutes', '') !~ '^[0-9]{1,3}$' or (p_data ->> 'prep_minutes')::int not between 5 and 240 then
      perform amine.err('INVALID_INPUT', 'prep_minutes');
    end if;
    s.prep_minutes := (p_data ->> 'prep_minutes')::int;
  end if;
  update amine.stores set name = s.name, name_ar = s.name_ar, name_en = s.name_en, description = s.description,
    description_ar = s.description_ar, description_en = s.description_en, phone = s.phone, address = s.address,
    lat = s.lat, lng = s.lng, zone_id = s.zone_id, logo_url = s.logo_url, cover_url = s.cover_url, hours = s.hours,
    min_order = s.min_order, prep_minutes = s.prep_minutes,
    status = case when s.status = 'rejected' and coalesce((p_data ->> 'resubmit')::boolean, false) then 'pending' else s.status end,
    updated_at = now()
  where id = s.id
  returning * into s;
  if s.status = 'pending' and coalesce((p_data ->> 'resubmit')::boolean, false) then
    perform amine.notify_admins('store_application', jsonb_build_object('name', s.name), '#/admin/stores');
  end if;
  return amine.merchant_store_json(s);
end $$;

create or replace function public.merchant_set_open(p_store_id uuid, p_open boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  if p_open is null then
    perform amine.err('INVALID_INPUT', 'open');
  end if;
  update amine.stores set is_open = p_open, updated_at = now() where id = s.id returning * into s;
  return jsonb_build_object('is_open', s.is_open, 'open_now', amine.store_open_now(s));
end $$;

-- Rayons ---------------------------------------------------------------------------------------
create or replace function public.merchant_save_section(
  p_store_id uuid, p_id uuid, p_name text, p_name_ar text default null, p_name_en text default null, p_sort int default 0
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  v_name text := amine.txt(p_name, 'name', 60, true, 1);
  v_ar text := amine.txt(p_name_ar, 'name_ar', 60);
  v_en text := amine.txt(p_name_en, 'name_en', 60);
  sc amine.sections;
begin
  perform amine.hit('catalog:' || auth.uid(), 600, 3600);
  if p_id is null then
    if (select count(*) from amine.sections where store_id = s.id) >= 100 then
      perform amine.err('TOO_MANY_SECTIONS');
    end if;
    insert into amine.sections (store_id, name, name_ar, name_en, sort)
    values (s.id, v_name, v_ar, v_en, least(greatest(coalesce(p_sort, 0), 0), 100000))
    returning * into sc;
  else
    update amine.sections set name = v_name, name_ar = v_ar, name_en = v_en, sort = least(greatest(coalesce(p_sort, 0), 0), 100000)
    where id = p_id and store_id = s.id returning * into sc;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
  end if;
  return jsonb_build_object('id', sc.id, 'name', sc.name, 'name_ar', sc.name_ar, 'name_en', sc.name_en, 'sort', sc.sort);
end $$;

create or replace function public.merchant_delete_section(p_store_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  delete from amine.sections where id = p_id and store_id = s.id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Produits ---------------------------------------------------------------------------------------
create or replace function amine.int_in(p jsonb, p_key text, p_min int, p_max int, p_required boolean) returns int
language plpgsql immutable set search_path = '' as $$
declare
  v text := p ->> p_key;
begin
  if v is null or btrim(v) = '' then
    if p_required then
      perform amine.err('INVALID_INPUT', p_key);
    end if;
    return null;
  end if;
  if btrim(v) !~ '^-?[0-9]{1,10}$' then
    perform amine.err('INVALID_INPUT', p_key);
  end if;
  if btrim(v)::bigint < p_min or btrim(v)::bigint > p_max then
    perform amine.err('INVALID_INPUT', p_key);
  end if;
  return btrim(v)::int;
end $$;

create or replace function amine.barcode_in(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare
  v text := regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g');
begin
  if v = '' then
    return null;
  end if;
  if v !~ '^[0-9]{8,14}$' then
    perform amine.err('INVALID_INPUT', 'barcode');
  end if;
  return v;
end $$;

-- Taux de TVA d'un produit (0 = exonéré).
create or replace function amine.vat_in(p jsonb, p_key text) returns smallint
language plpgsql immutable set search_path = '' as $$
declare
  v text := btrim(coalesce(p ->> p_key, ''));
begin
  if v = '' then
    return 19;
  end if;
  if v not in ('0', '7', '13', '19') then
    perform amine.err('INVALID_INPUT', p_key);
  end if;
  return v::smallint;
end $$;

-- Prix par palier : [{"min_qty": 10, "price": 1900}, …] — au plus 5 paliers, quantités croissantes
-- (2 à 999), prix décroissants et inférieurs au prix de base.
create or replace function amine.tiers_in(p jsonb, p_price int) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare
  t jsonb;
  v jsonb := '[]'::jsonb;
  v_prev_qty int := 1;
  v_prev_price int := p_price;
  v_qty int;
  v_price int;
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return '[]'::jsonb;
  end if;
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) > 5 then
    perform amine.err('INVALID_INPUT', 'price_tiers');
  end if;
  for t in select e.value from jsonb_array_elements(p) e loop
    v_qty := amine.int_in(t, 'min_qty', 2, 999, true);
    v_price := amine.int_in(t, 'price', 1, 100000000, true);
    if v_qty <= v_prev_qty or v_price >= v_prev_price then
      perform amine.err('INVALID_INPUT', 'price_tiers');
    end if;
    v := v || jsonb_build_object('min_qty', v_qty, 'price', v_price);
    v_prev_qty := v_qty;
    v_prev_price := v_price;
  end loop;
  return v;
end $$;

-- Création (p_id null) ou modification complète d'un produit.
-- Clés : name, name_ar, name_en, description*, price, unit, stock, is_available, section_id, sku, ref,
-- brand, barcode, image_url, image_credit, sort, vat_rate, price_tiers, cost_price.
create or replace function public.merchant_save_product(p_store_id uuid, p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  v_section uuid;
  v_available boolean := true;
  v_image text;
  v_ref text := nullif(lower(btrim(coalesce(p_data ->> 'ref', ''))), '');
  v_credit jsonb;
  pr amine.products;
begin
  perform amine.hit('catalog:' || auth.uid(), 600, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  if v_ref is not null and v_ref !~ '^[a-z0-9-]{2,60}$' then
    perform amine.err('INVALID_INPUT', 'ref');
  end if;
  if p_data ? 'section_id' and nullif(p_data ->> 'section_id', '') is not null then
    begin
      v_section := (p_data ->> 'section_id')::uuid;
    exception when others then
      perform amine.err('INVALID_INPUT', 'section_id');
    end;
    if not exists (select 1 from amine.sections where id = v_section and store_id = s.id) then
      perform amine.err('INVALID_INPUT', 'section_id');
    end if;
  end if;
  if p_data ? 'is_available' then
    if jsonb_typeof(p_data -> 'is_available') <> 'boolean' then
      perform amine.err('INVALID_INPUT', 'is_available');
    end if;
    v_available := (p_data ->> 'is_available')::boolean;
  end if;
  v_image := nullif(btrim(coalesce(p_data ->> 'image_url', '')), '');
  if not amine.product_image_ok(v_image, s.id) then
    perform amine.err('INVALID_INPUT', 'image_url');
  end if;
  v_credit := case when v_image is null then null else amine.credit_in(p_data -> 'image_credit') end;

  if p_id is null then
    if (select count(*) from amine.products where store_id = s.id and deleted_at is null) >= 5000 then
      perform amine.err('TOO_MANY_PRODUCTS');
    end if;
    insert into amine.products (store_id, section_id, sku, name, name_ar, name_en, description, description_ar,
      description_en, price, unit, stock, is_available, image_url, image_credit, sort, ref, brand, barcode,
      vat_rate, price_tiers, cost_price)
    values (s.id, v_section, amine.txt(p_data ->> 'sku', 'sku', 60),
      amine.txt(p_data ->> 'name', 'name', 120, true, 2), amine.txt(p_data ->> 'name_ar', 'name_ar', 120),
      amine.txt(p_data ->> 'name_en', 'name_en', 120),
      amine.txt(p_data ->> 'description', 'description', 500, false, 1, true),
      amine.txt(p_data ->> 'description_ar', 'description_ar', 500, false, 1, true),
      amine.txt(p_data ->> 'description_en', 'description_en', 500, false, 1, true),
      amine.int_in(p_data, 'price', 1, 100000000, true), amine.txt(p_data ->> 'unit', 'unit', 20),
      amine.int_in(p_data, 'stock', 0, 1000000, false), v_available, v_image, v_credit,
      coalesce(amine.int_in(p_data, 'sort', 0, 100000, false), 0), v_ref,
      amine.txt(p_data ->> 'brand', 'brand', 60), amine.barcode_in(p_data ->> 'barcode'),
      amine.vat_in(p_data, 'vat_rate'),
      amine.tiers_in(p_data -> 'price_tiers', amine.int_in(p_data, 'price', 1, 100000000, true)),
      amine.int_in(p_data, 'cost_price', 0, 100000000, false))
    returning * into pr;
  else
    update amine.products set section_id = v_section, sku = amine.txt(p_data ->> 'sku', 'sku', 60),
      name = amine.txt(p_data ->> 'name', 'name', 120, true, 2), name_ar = amine.txt(p_data ->> 'name_ar', 'name_ar', 120),
      name_en = amine.txt(p_data ->> 'name_en', 'name_en', 120),
      description = amine.txt(p_data ->> 'description', 'description', 500, false, 1, true),
      description_ar = amine.txt(p_data ->> 'description_ar', 'description_ar', 500, false, 1, true),
      description_en = amine.txt(p_data ->> 'description_en', 'description_en', 500, false, 1, true),
      price = amine.int_in(p_data, 'price', 1, 100000000, true), unit = amine.txt(p_data ->> 'unit', 'unit', 20),
      stock = amine.int_in(p_data, 'stock', 0, 1000000, false), is_available = v_available, image_url = v_image,
      image_credit = v_credit,
      sort = coalesce(amine.int_in(p_data, 'sort', 0, 100000, false), 0),
      ref = case when p_data ? 'ref' then v_ref else ref end,
      brand = case when p_data ? 'brand' then amine.txt(p_data ->> 'brand', 'brand', 60) else brand end,
      barcode = case when p_data ? 'barcode' then amine.barcode_in(p_data ->> 'barcode') else barcode end,
      vat_rate = case when p_data ? 'vat_rate' then amine.vat_in(p_data, 'vat_rate') else vat_rate end,
      price_tiers = case when p_data ? 'price_tiers'
        then amine.tiers_in(p_data -> 'price_tiers', amine.int_in(p_data, 'price', 1, 100000000, true))
        -- Sans paliers dans la demande : on garde ceux qui restent sous le nouveau prix.
        else coalesce((select jsonb_agg(t.value) from jsonb_array_elements(price_tiers) t
          where (t.value ->> 'price')::int < amine.int_in(p_data, 'price', 1, 100000000, true)), '[]'::jsonb) end,
      cost_price = case when p_data ? 'cost_price' then amine.int_in(p_data, 'cost_price', 0, 100000000, false) else cost_price end,
      updated_at = now()
    where id = p_id and store_id = s.id and deleted_at is null
    returning * into pr;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
  end if;
  return amine.merchant_product_json(pr);
exception
  when unique_violation then
    if sqlerrm like '%barcode%' then
      perform amine.err('DUPLICATE_BARCODE');
    end if;
    perform amine.err('DUPLICATE_SKU');
end $$;

-- Photo d'un produit seule (outil « Photos » : Open Food Facts, Wikimedia Commons, photo de l'équipe).
create or replace function public.merchant_set_product_image(p_store_id uuid, p_id uuid, p_image_url text, p_credit jsonb default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  v_image text := nullif(btrim(coalesce(p_image_url, '')), '');
  pr amine.products;
begin
  perform amine.hit('catalog:' || auth.uid(), 600, 3600);
  if not amine.product_image_ok(v_image, s.id) then
    perform amine.err('INVALID_INPUT', 'image_url');
  end if;
  update amine.products set image_url = v_image, image_credit = case when v_image is null then null else amine.credit_in(p_credit) end,
    updated_at = now()
  where id = p_id and store_id = s.id and deleted_at is null returning * into pr;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.merchant_product_json(pr);
end $$;

create or replace function public.merchant_set_product_available(p_store_id uuid, p_id uuid, p_available boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  pr amine.products;
begin
  if p_available is null then
    perform amine.err('INVALID_INPUT', 'available');
  end if;
  update amine.products set is_available = p_available, updated_at = now()
  where id = p_id and store_id = s.id and deleted_at is null returning * into pr;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.merchant_product_json(pr);
end $$;

create or replace function public.merchant_set_stock(p_store_id uuid, p_id uuid, p_stock int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  pr amine.products;
begin
  if p_stock is not null and (p_stock < 0 or p_stock > 1000000) then
    perform amine.err('INVALID_INPUT', 'stock');
  end if;
  perform amine.stock_context('count', null, 'manual');
  update amine.products set stock = p_stock, updated_at = now()
  where id = p_id and store_id = s.id and deleted_at is null returning * into pr;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.merchant_product_json(pr);
end $$;

create or replace function public.merchant_delete_product(p_store_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  update amine.products set deleted_at = now(), is_available = false, sku = null, updated_at = now()
  where id = p_id and store_id = s.id and deleted_at is null;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Import d'un catalogue (CSV converti par l'application) : tout ou rien.
-- p_rows : [{"name": "...", "price": 2500, "sku": "...", "ref": "tomate", "section": "Légumes",
--            "section_ar": "...", "section_en": "...", "stock": 10, "unit": "kg", "brand": "...", "barcode": "...",
--            "image_url": "...", "image_credit": {...}, ...}]
-- Un produit existant est retrouvé par son code (sku), son code-barres ou sa référence AMINE (ref).
-- p_only_missing : n'ajoute que les produits absents (les prix déjà ajustés ne sont pas modifiés).
drop function if exists public.merchant_import_products(uuid, jsonb);
create or replace function public.merchant_import_products(p_store_id uuid, p_rows jsonb, p_only_missing boolean default false)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  r jsonb;
  i int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_skus text[] := '{}';
  v_barcodes text[] := '{}';
  v_barcode text;
  v_sku text;
  v_section_name text;
  v_section uuid;
  v_existing uuid;
  v_created int := 0;
  v_updated int := 0;
  v_sections int := 0;
  v_available boolean;
  v_detail text;
  v_ref text;
  v_skipped int := 0;
begin
  perform amine.hit('import:' || auth.uid(), 20, 3600);
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    perform amine.err('INVALID_INPUT', 'rows');
  end if;
  if jsonb_array_length(p_rows) > 1000 then
    perform amine.err('IMPORT_TOO_LARGE');
  end if;

  -- 1) Validation complète, sans rien écrire.
  for r in select e.value from jsonb_array_elements(p_rows) e loop
    i := i + 1;
    begin
      if jsonb_typeof(r) <> 'object' then
        perform amine.err('INVALID_INPUT', 'row');
      end if;
      perform amine.txt(r ->> 'name', 'name', 120, true, 2);
      perform amine.txt(r ->> 'name_ar', 'name_ar', 120);
      perform amine.txt(r ->> 'name_en', 'name_en', 120);
      perform amine.txt(r ->> 'description', 'description', 500, false, 1, true);
      perform amine.int_in(r, 'price', 1, 100000000, true);
      perform amine.int_in(r, 'stock', 0, 1000000, false);
      perform amine.txt(r ->> 'unit', 'unit', 20);
      perform amine.txt(r ->> 'section', 'section', 60);
      perform amine.txt(r ->> 'section_ar', 'section_ar', 60);
      perform amine.txt(r ->> 'section_en', 'section_en', 60);
      perform amine.txt(r ->> 'brand', 'brand', 60);
      perform amine.vat_in(r, 'vat_rate');
      v_barcode := amine.barcode_in(r ->> 'barcode');
      if v_barcode is not null then
        if v_barcode = any (v_barcodes) then
          perform amine.err('DUPLICATE_BARCODE', 'barcode');
        end if;
        v_barcodes := v_barcodes || v_barcode;
      end if;
      if not amine.product_image_ok(nullif(btrim(coalesce(r ->> 'image_url', '')), ''), s.id) then
        perform amine.err('INVALID_INPUT', 'image_url');
      end if;
      perform amine.credit_in(r -> 'image_credit');
      if nullif(r ->> 'ref', '') is not null and (r ->> 'ref') !~ '^[a-z0-9-]{2,60}$' then
        perform amine.err('INVALID_INPUT', 'ref');
      end if;
      v_sku := amine.txt(r ->> 'sku', 'sku', 60);
      if r ? 'available' and jsonb_typeof(r -> 'available') not in ('boolean', 'null') then
        perform amine.err('INVALID_INPUT', 'available');
      end if;
      if v_sku is not null then
        if v_sku = any (v_skus) then
          perform amine.err('DUPLICATE_SKU', 'sku');
        end if;
        v_skus := v_skus || v_sku;
      end if;
    exception when sqlstate 'P0001' then
      get stacked diagnostics v_detail = pg_exception_detail;
      if jsonb_array_length(v_errors) < 50 then
        v_errors := v_errors || jsonb_build_object('row', i, 'code', sqlerrm, 'field', nullif(v_detail, ''));
      end if;
    end;
  end loop;
  if jsonb_array_length(v_errors) > 0 then
    perform amine.err('IMPORT_INVALID', v_errors::text);
  end if;

  -- 2) Écriture.
  for r in select e.value from jsonb_array_elements(p_rows) e loop
    v_section := null;
    v_section_name := amine.txt(r ->> 'section', 'section', 60);
    if v_section_name is not null then
      select id into v_section from amine.sections where store_id = s.id and lower(name) = lower(v_section_name) limit 1;
      if v_section is null then
        insert into amine.sections (store_id, name, name_ar, name_en, sort)
        values (s.id, v_section_name, amine.txt(r ->> 'section_ar', 'section_ar', 60), amine.txt(r ->> 'section_en', 'section_en', 60),
          (select coalesce(max(sort), 0) + 1 from amine.sections where store_id = s.id))
        returning id into v_section;
        v_sections := v_sections + 1;
      end if;
    end if;
    v_sku := amine.txt(r ->> 'sku', 'sku', 60);
    v_available := coalesce((r ->> 'available')::boolean, true);
    v_existing := null;
    v_ref := nullif(r ->> 'ref', '');
    if v_sku is not null then
      select id into v_existing from amine.products where store_id = s.id and sku = v_sku and deleted_at is null;
    end if;
    if v_existing is null and nullif(r ->> 'barcode', '') is not null then
      select id into v_existing from amine.products
      where store_id = s.id and barcode = amine.barcode_in(r ->> 'barcode') and deleted_at is null;
    end if;
    if v_existing is null and v_ref is not null and nullif(r ->> 'barcode', '') is null then
      select id into v_existing from amine.products where store_id = s.id and ref = v_ref and deleted_at is null
      order by created_at limit 1;
    end if;
    if v_existing is not null and p_only_missing then
      v_skipped := v_skipped + 1;
    elsif v_existing is not null then
      update amine.products set name = amine.txt(r ->> 'name', 'name', 120, true, 2),
        name_ar = coalesce(amine.txt(r ->> 'name_ar', 'name_ar', 120), name_ar),
        name_en = coalesce(amine.txt(r ->> 'name_en', 'name_en', 120), name_en),
        description = coalesce(amine.txt(r ->> 'description', 'description', 500, false, 1, true), description),
        price = amine.int_in(r, 'price', 1, 100000000, true),
        unit = coalesce(amine.txt(r ->> 'unit', 'unit', 20), unit),
        stock = case when r ? 'stock' then amine.int_in(r, 'stock', 0, 1000000, false) else stock end,
        section_id = coalesce(v_section, section_id), is_available = v_available,
        ref = coalesce(nullif(r ->> 'ref', ''), ref),
        brand = coalesce(amine.txt(r ->> 'brand', 'brand', 60), brand),
        barcode = coalesce(amine.barcode_in(r ->> 'barcode'), barcode),
        vat_rate = case when nullif(r ->> 'vat_rate', '') is not null then amine.vat_in(r, 'vat_rate') else vat_rate end,
        image_url = coalesce(nullif(btrim(coalesce(r ->> 'image_url', '')), ''), image_url),
        image_credit = case when nullif(btrim(coalesce(r ->> 'image_url', '')), '') is not null then amine.credit_in(r -> 'image_credit') else image_credit end,
        updated_at = now()
      where id = v_existing;
      v_updated := v_updated + 1;
    else
      insert into amine.products (store_id, section_id, sku, name, name_ar, name_en, description, price, unit, stock,
        is_available, ref, sort, brand, barcode, image_url, image_credit, vat_rate)
      values (s.id, v_section, v_sku, amine.txt(r ->> 'name', 'name', 120, true, 2), amine.txt(r ->> 'name_ar', 'name_ar', 120),
        amine.txt(r ->> 'name_en', 'name_en', 120), amine.txt(r ->> 'description', 'description', 500, false, 1, true),
        amine.int_in(r, 'price', 1, 100000000, true), amine.txt(r ->> 'unit', 'unit', 20),
        amine.int_in(r, 'stock', 0, 1000000, false), v_available, v_ref,
        coalesce(amine.int_in(r, 'sort', 0, 100000, false), 0), amine.txt(r ->> 'brand', 'brand', 60),
        amine.barcode_in(r ->> 'barcode'), nullif(btrim(coalesce(r ->> 'image_url', '')), ''),
        case when nullif(btrim(coalesce(r ->> 'image_url', '')), '') is not null then amine.credit_in(r -> 'image_credit') end,
        amine.vat_in(r, 'vat_rate'));
      v_created := v_created + 1;
    end if;
  end loop;
  perform amine.audit('catalog.imported', 'store', s.id::text,
    jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped));
  return jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped, 'sections_created', v_sections);
end $$;

-- Ajustement des prix en un geste : +/- p_percent % sur un rayon (ou tout le catalogue),
-- arrondi à 10 millimes. Exemple : hausse de 5 % des légumes.
create or replace function public.merchant_adjust_prices(p_store_id uuid, p_section_id uuid, p_percent numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  v_count int;
begin
  perform amine.hit('catalog:' || auth.uid(), 600, 3600);
  if p_percent is null or p_percent < -90 or p_percent > 500 or p_percent = 0 then
    perform amine.err('INVALID_INPUT', 'percent');
  end if;
  if p_section_id is not null and not exists (select 1 from amine.sections where id = p_section_id and store_id = s.id) then
    perform amine.err('NOT_FOUND');
  end if;
  update amine.products set price = least(100000000, greatest(10, (round(price * (1 + p_percent / 100) / 10) * 10)::int)),
    price_tiers = coalesce((select jsonb_agg(jsonb_build_object('min_qty', (t.value ->> 'min_qty')::int,
        'price', least(100000000, greatest(10, (round((t.value ->> 'price')::int * (1 + p_percent / 100) / 10) * 10)::int)))
        order by (t.value ->> 'min_qty')::int)
      from jsonb_array_elements(price_tiers) t), '[]'::jsonb),
    updated_at = now()
  where store_id = s.id and deleted_at is null and (p_section_id is null or section_id = p_section_id);
  get diagnostics v_count = row_count;
  perform amine.audit('catalog.prices_adjusted', 'store', s.id::text,
    jsonb_build_object('percent', p_percent, 'section_id', p_section_id, 'products', v_count));
  return jsonb_build_object('updated', v_count);
end $$;

-- Commandes du dépôt ---------------------------------------------------------------------------
create or replace function public.merchant_orders(p_store_id uuid, p_scope text default 'active', p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  perform amine.maintenance();
  if p_scope = 'active' then
    return coalesce((
      select jsonb_agg(amine.order_json(o, 'merchant')
        order by coalesce(amine.slot_start(o.deliver_on, o.delivery_slot), o.placed_at), o.placed_at)
      from amine.orders o
      where o.store_id = s.id and o.status in ('placed', 'accepted', 'preparing', 'ready', 'picked_up')), '[]'::jsonb);
  elsif p_scope = 'all' then
    return coalesce((
      select jsonb_agg(amine.order_json(x, 'merchant') order by x.placed_at desc)
      from (select * from amine.orders o where o.store_id = s.id
            order by (o.status in ('placed', 'accepted', 'preparing', 'ready', 'picked_up')) desc, o.placed_at desc
            limit least(greatest(coalesce(p_limit, 50), 1), 200)) x), '[]'::jsonb);
  elsif p_scope = 'history' then
    return coalesce((
      select jsonb_agg(amine.order_json(x, 'merchant') order by x.placed_at desc)
      from (select * from amine.orders o
            where o.store_id = s.id and o.status in ('delivered', 'cancelled', 'rejected')
            order by o.placed_at desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) x), '[]'::jsonb);
  end if;
  perform amine.err('INVALID_INPUT', 'scope');
  return null;
end $$;

create or replace function public.merchant_order(p_store_id uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  o amine.orders;
  l amine.courier_locations;
begin
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and store_id = s.id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if o.courier_id is not null and o.status in ('accepted', 'preparing', 'ready') then
    select * into l from amine.courier_locations
    where courier_id = o.courier_id and recorded_at > now() - interval '15 minutes';
  end if;
  return amine.order_json(o, 'merchant') || jsonb_build_object(
    'courier_location', case when l.courier_id is null then null else
      jsonb_build_object('lat', l.lat, 'lng', l.lng, 'accuracy_m', l.accuracy_m, 'recorded_at', l.recorded_at) end);
end $$;

-- p_action : accept | reject | preparing | ready
create or replace function public.merchant_update_order(p_store_id uuid, p_code text, p_action text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  o amine.orders;
  v_to text;
  v_reason text := amine.txt(p_reason, 'reason', 200);
begin
  perform amine.hit('merchant_action:' || auth.uid(), 300, 600);
  v_to := case p_action when 'accept' then 'accepted' when 'reject' then 'rejected'
    when 'preparing' then 'preparing' when 'ready' then 'ready' end;
  if v_to is null then
    perform amine.err('INVALID_INPUT', 'action');
  end if;
  if v_to = 'rejected' and (v_reason is null or char_length(v_reason) < 3) then
    perform amine.err('REASON_REQUIRED');
  end if;
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and store_id = s.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  o := amine.transition(o, v_to, 'merchant', auth.uid(), case when v_to = 'rejected' then v_reason end);
  return amine.order_json(o, 'merchant');
end $$;

create or replace function public.merchant_stats(p_store_id uuid, p_days int default 30) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  v_days int := least(greatest(coalesce(p_days, 30), 1), 366);
  v_today timestamptz := date_trunc('day', now() at time zone 'Africa/Tunis') at time zone 'Africa/Tunis';
  v_from timestamptz;
begin
  v_from := v_today - make_interval(days => v_days - 1);
  return jsonb_build_object(
    'days', v_days,
    'today', (select jsonb_build_object(
        'orders', count(*) filter (where o.status not in ('cancelled', 'rejected')),
        'delivered', count(*) filter (where o.status = 'delivered'),
        'revenue', coalesce(sum(o.subtotal) filter (where o.status = 'delivered'), 0))
      from amine.orders o where o.store_id = s.id and o.placed_at >= v_today),
    'period', (select jsonb_build_object(
        'orders', count(*),
        'delivered', count(*) filter (where o.status = 'delivered'),
        'cancelled', count(*) filter (where o.status = 'cancelled'),
        'rejected', count(*) filter (where o.status = 'rejected'),
        'revenue', coalesce(sum(o.subtotal) filter (where o.status = 'delivered'), 0),
        'commission', coalesce(sum(o.commission) filter (where o.status = 'delivered'), 0),
        'avg_accept_minutes', round(avg(extract(epoch from (o.accepted_at - o.placed_at)) / 60)::numeric, 1))
      from amine.orders o where o.store_id = s.id and o.placed_at >= v_from),
    'daily', coalesce((
      select jsonb_agg(jsonb_build_object('day', d.day, 'orders', d.orders, 'revenue', d.revenue) order by d.day)
      from (
        select to_char(o.placed_at at time zone 'Africa/Tunis', 'YYYY-MM-DD') as day,
          count(*) as orders, coalesce(sum(o.subtotal) filter (where o.status = 'delivered'), 0) as revenue
        from amine.orders o where o.store_id = s.id and o.placed_at >= v_from
        group by 1) d), '[]'::jsonb),
    'top_products', coalesce((
      select jsonb_agg(jsonb_build_object('name', t.name, 'quantity', t.quantity, 'revenue', t.revenue) order by t.quantity desc)
      from (
        select i.name, sum(i.quantity) as quantity, sum(i.total) as revenue
        from amine.order_items i join amine.orders o on o.id = i.order_id
        where o.store_id = s.id and o.status = 'delivered' and o.placed_at >= v_from
        group by i.name order by 2 desc limit 10) t), '[]'::jsonb));
end $$;

-- Équipe -------------------------------------------------------------------------------------------
create or replace function public.merchant_staff(p_store_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id, true);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('user_id', p.id, 'name', p.full_name, 'email', p.email, 'role', st.role)
      order by st.role desc, p.full_name)
    from amine.store_staff st join amine.profiles p on p.id = st.user_id where st.store_id = s.id), '[]'::jsonb);
end $$;

create or replace function public.merchant_add_staff(p_store_id uuid, p_email text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id, true);
  v_user uuid;
begin
  perform amine.hit('staff:' || auth.uid(), 30, 3600);
  select id into v_user from amine.profiles
  where lower(email) = lower(btrim(coalesce(p_email, ''))) and status = 'active' limit 1;
  if v_user is null then
    perform amine.err('USER_NOT_FOUND');
  end if;
  insert into amine.store_staff (store_id, user_id, role) values (s.id, v_user, 'staff') on conflict do nothing;
  perform amine.audit('store.staff_added', 'store', s.id::text, jsonb_build_object('user_id', v_user));
  perform amine.notify(v_user, 'staff_added', jsonb_build_object('store', s.name), '#/depot');
  return public.merchant_staff(p_store_id);
end $$;

create or replace function public.merchant_remove_staff(p_store_id uuid, p_user_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id, true);
begin
  delete from amine.store_staff where store_id = s.id and user_id = p_user_id and role = 'staff';
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  perform amine.audit('store.staff_removed', 'store', s.id::text, jsonb_build_object('user_id', p_user_id));
  return public.merchant_staff(p_store_id);
end $$;

-- =============================================================================================
--  Espace livreur : candidature, disponibilité, courses, position GPS réelle, gains
-- =============================================================================================

create or replace function public.courier_me() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  c amine.couriers;
  z amine.zones;
  v_today timestamptz := date_trunc('day', now() at time zone 'Africa/Tunis') at time zone 'Africa/Tunis';
begin
  select * into c from amine.couriers where user_id = p.id;
  if not found then
    return jsonb_build_object('status', null);
  end if;
  select * into z from amine.zones where id = c.zone_id;
  return jsonb_build_object(
    'status', c.status, 'status_note', c.status_note, 'vehicle', c.vehicle, 'is_online', c.is_online,
    'has_cin', c.cin is not null, 'created_at', c.created_at,
    'rating', case when c.rating_count > 0 then round(c.rating_sum::numeric / c.rating_count, 1) end,
    'rating_count', c.rating_count,
    'zone', case when z.id is null then null else
      jsonb_build_object('id', z.id, 'name_fr', z.name_fr, 'name_ar', z.name_ar, 'name_en', z.name_en) end,
    'max_active_jobs', greatest(1, coalesce((amine.setting('couriers') ->> 'max_active_jobs')::int, 2)),
    'active_jobs', (select count(*) from amine.orders o where o.courier_id = p.id
      and o.status in ('accepted', 'preparing', 'ready', 'picked_up')),
    'today', (select jsonb_build_object('deliveries', count(*), 'earnings', coalesce(sum(o.courier_earning), 0),
        'cod', coalesce(sum(o.cod_collected), 0))
      from amine.orders o where o.courier_id = p.id and o.status = 'delivered' and o.delivered_at >= v_today),
    'week', (select jsonb_build_object('deliveries', count(*), 'earnings', coalesce(sum(o.courier_earning), 0),
        'cod', coalesce(sum(o.cod_collected), 0))
      from amine.orders o where o.courier_id = p.id and o.status = 'delivered' and o.delivered_at >= v_today - interval '6 days'),
    -- Version 4 : espèces encaissées et pas encore remises au dépôt ou à AMINE.
    'cash', amine.courier_cash_json(c));
end $$;

create or replace function public.apply_courier(p_vehicle text, p_zone_id uuid, p_cin text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  c amine.couriers;
  v_cin text := regexp_replace(coalesce(p_cin, ''), '[^0-9]', '', 'g');
  v_note text := amine.txt(p_note, 'note', 300, false, 1, true);
begin
  perform amine.hit('apply_courier:' || p.id, 5, 86400);
  if p.phone is null then
    perform amine.err('PHONE_REQUIRED');
  end if;
  if p_vehicle is null or p_vehicle not in ('bike', 'scooter', 'car', 'foot') then
    perform amine.err('INVALID_INPUT', 'vehicle');
  end if;
  if p_zone_id is null or not exists (select 1 from amine.zones where id = p_zone_id and is_active) then
    perform amine.err('INVALID_INPUT', 'zone_id');
  end if;
  if v_cin !~ '^[0-9]{8}$' then
    perform amine.err('INVALID_INPUT', 'cin');
  end if;
  select * into c from amine.couriers where user_id = p.id;
  if found then
    if c.status not in ('rejected', 'archived') then
      perform amine.err('ALREADY_APPLIED');
    end if;
    update amine.couriers set vehicle = p_vehicle, zone_id = p_zone_id, cin = v_cin, note = v_note,
      status = 'pending', status_note = null, decided_at = null
    where user_id = p.id;
  else
    insert into amine.couriers (user_id, vehicle, zone_id, cin, note) values (p.id, p_vehicle, p_zone_id, v_cin, v_note);
  end if;
  perform amine.audit('courier.applied', 'courier', p.id::text, '{}'::jsonb);
  perform amine.notify_admins('courier_application', jsonb_build_object('name', p.full_name), '#/admin/couriers');
  return public.courier_me();
end $$;

create or replace function public.courier_set_online(p_online boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
begin
  if p_online is null then
    perform amine.err('INVALID_INPUT', 'online');
  end if;
  update amine.couriers set is_online = p_online, last_seen_at = now() where user_id = c.user_id;
  if not p_online then
    delete from amine.courier_locations where courier_id = c.user_id;
  end if;
  return public.courier_me();
end $$;

-- Courses disponibles (aperçu sans adresse ni téléphone du client) et courses en cours.
create or replace function public.courier_jobs() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
begin
  perform amine.maintenance();
  return jsonb_build_object(
    'online', c.is_online,
    'max_active_jobs', greatest(1, coalesce((amine.setting('couriers') ->> 'max_active_jobs')::int, 2)),
    'available', case when not c.is_online then '[]'::jsonb else coalesce((
      select jsonb_agg(amine.order_json(x, 'courier_preview') order by x.ready_at nulls last, x.placed_at)
      from (select * from amine.orders o
            where o.courier_id is null and o.status in ('accepted', 'preparing', 'ready')
              and (c.zone_id is null or o.zone_id = c.zone_id) and amine.job_open(o)
            order by coalesce(amine.slot_start(o.deliver_on, o.delivery_slot), o.placed_at), o.placed_at
            limit 50) x), '[]'::jsonb) end,
    'mine', coalesce((
      select jsonb_agg(amine.order_json(o, 'courier') order by o.route_seq nulls last, o.assigned_at)
      from amine.orders o
      where o.courier_id = c.user_id and o.status in ('accepted', 'preparing', 'ready', 'picked_up')), '[]'::jsonb));
end $$;

create or replace function public.courier_job(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
  o amine.orders;
begin
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and courier_id = c.user_id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.order_json(o, 'courier');
end $$;

create or replace function public.courier_accept(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_max int := greatest(1, coalesce((amine.setting('couriers') ->> 'max_active_jobs')::int, 2));
  o amine.orders;
  v_name text;
begin
  perform amine.hit('courier_accept:' || c.user_id, 60, 600);
  if not c.is_online then
    perform amine.err('COURIER_OFFLINE');
  end if;
  if (select count(*) from amine.orders where courier_id = c.user_id
      and status in ('accepted', 'preparing', 'ready', 'picked_up')) >= v_max then
    perform amine.err('TOO_MANY_ACTIVE_JOBS', v_max::text);
  end if;
  update amine.orders x set courier_id = c.user_id, assigned_at = now(), updated_at = now()
  where x.code = v_code and x.courier_id is null and x.status in ('accepted', 'preparing', 'ready')
    and (c.zone_id is null or x.zone_id = c.zone_id) and amine.job_open(x)
  returning * into o;
  if not found then
    if exists (select 1 from amine.orders where code = v_code and courier_id is not null) then
      perform amine.err('ALREADY_ASSIGNED');
    end if;
    perform amine.err('JOB_UNAVAILABLE');
  end if;
  perform amine.log_order(o.id, o.status, 'courier_assigned', 'courier', c.user_id, null);
  select amine.first_name(full_name) into v_name from amine.profiles where id = c.user_id;
  perform amine.notify(o.customer_id, 'courier_assigned', jsonb_build_object('code', o.code, 'name', v_name),
    '#/orders/' || o.code);
  if o.store_id is not null then
    perform amine.notify_store(o.store_id, 'courier_assigned', jsonb_build_object('code', o.code, 'name', v_name),
      '#/depot/orders/' || o.code || '?store=' || o.store_id::text);
  end if;
  return amine.order_json(o, 'courier');
end $$;

create or replace function public.courier_release(p_code text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
  o amine.orders;
begin
  update amine.orders set courier_id = null, assigned_at = null, updated_at = now()
  where code = upper(btrim(coalesce(p_code, ''))) and courier_id = c.user_id and status in ('accepted', 'preparing', 'ready')
  returning * into o;
  if not found then
    perform amine.err('INVALID_TRANSITION');
  end if;
  perform amine.log_order(o.id, o.status, 'courier_released', 'courier', c.user_id, amine.txt(p_reason, 'reason', 200));
  if not exists (select 1 from amine.orders where courier_id = c.user_id and status in ('accepted', 'preparing', 'ready', 'picked_up')) then
    delete from amine.courier_locations where courier_id = c.user_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- p_action : picked_up | delivered (montant encaissé obligatoire à la livraison, sauf commande payée
-- sur compte : rien à encaisser)
-- Version 4 : preuve de livraison (nom de la personne qui a reçu, photo, signature) ; obligatoire
-- si l'administration l'exige (paramètres des commandes).
drop function if exists public.courier_update_job(text, text, int);

-- Fichier de preuve déposé dans le stockage privé « amine-proofs » sous orders/<id_commande>/.
create or replace function amine.pod_file(p_order uuid, p jsonb, p_key text) returns text
language plpgsql stable set search_path = '' as $$
declare
  v text := nullif(btrim(coalesce(p ->> p_key, '')), '');
begin
  if v is null then
    return null;
  end if;
  if v !~ ('^orders/' || p_order::text || '/' || p_key || '-[A-Za-z0-9_-]{6,40}\.(jpg|jpeg|png|webp)$')
     or not exists (select 1 from storage.objects o where o.bucket_id = 'amine-proofs' and o.name = v) then
    perform amine.err('INVALID_INPUT', p_key);
  end if;
  return v;
end $$;

create or replace function public.courier_update_job(p_code text, p_action text, p_cod_collected int default null,
  p_pod jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
  o amine.orders;
  v_name text;
  v_photo text;
  v_signature text;
begin
  perform amine.hit('courier_action:' || c.user_id, 120, 600);
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and courier_id = c.user_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if p_action = 'picked_up' then
    o := amine.transition(o, 'picked_up', 'courier', c.user_id);
  elsif p_action = 'delivered' then
    if p_pod is not null and jsonb_typeof(p_pod) <> 'object' then
      perform amine.err('INVALID_INPUT', 'pod');
    end if;
    v_name := amine.txt(p_pod ->> 'name', 'pod_name', 80);
    v_photo := amine.pod_file(o.id, p_pod, 'photo');
    v_signature := amine.pod_file(o.id, p_pod, 'signature');
    if coalesce((amine.setting('orders') ->> 'require_pod')::boolean, false)
       and (v_name is null or (v_photo is null and v_signature is null)) then
      perform amine.err('POD_REQUIRED');
    end if;
    if v_name is not null or v_photo is not null or v_signature is not null then
      update amine.orders set pod_name = v_name, pod_photo = v_photo, pod_signature = v_signature, pod_at = now()
      where id = o.id returning * into o;
    end if;
    if o.payment_method = 'account' then
      if coalesce(p_cod_collected, 0) <> 0 then
        perform amine.err('NOTHING_TO_COLLECT');
      end if;
      o := amine.transition(o, 'delivered', 'courier', c.user_id);
    else
      if p_cod_collected is null or p_cod_collected < 0 or p_cod_collected > 100000000 then
        perform amine.err('COD_AMOUNT_REQUIRED');
      end if;
      update amine.orders set cod_collected = p_cod_collected where id = o.id;
      o.cod_collected := p_cod_collected;
      o := amine.transition(o, 'delivered', 'courier', c.user_id,
        case when p_cod_collected <> o.total then 'cod_mismatch:' || p_cod_collected::text end);
    end if;
  else
    perform amine.err('INVALID_INPUT', 'action');
  end if;
  return amine.order_json(o, 'courier');
end $$;

-- Position envoyée par le téléphone du livreur (navigateur, avec son accord) pendant une course.
create or replace function public.courier_location(
  p_lat numeric, p_lng numeric, p_accuracy_m int default null, p_heading int default null, p_speed_kmh int default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
  o amine.orders;
begin
  perform amine.hit('location:' || c.user_id, 40, 60);
  perform amine.check_point(p_lat, p_lng);
  select * into o from amine.orders
  where courier_id = c.user_id and status in ('accepted', 'preparing', 'ready', 'picked_up')
  order by (status = 'picked_up') desc, assigned_at desc limit 1;
  if not found then
    delete from amine.courier_locations where courier_id = c.user_id;
    perform amine.err('NO_ACTIVE_JOB');
  end if;
  insert into amine.courier_locations as l (courier_id, order_id, lat, lng, accuracy_m, heading, speed_kmh, recorded_at, updated_at)
  values (c.user_id, o.id, round(p_lat, 6), round(p_lng, 6),
    case when p_accuracy_m between 0 and 100000 then p_accuracy_m end,
    case when p_heading between 0 and 360 then p_heading end,
    case when p_speed_kmh between 0 and 300 then p_speed_kmh end, now(), now())
  on conflict (courier_id) do update set order_id = excluded.order_id, lat = excluded.lat, lng = excluded.lng,
    accuracy_m = excluded.accuracy_m, heading = excluded.heading, speed_kmh = excluded.speed_kmh,
    recorded_at = excluded.recorded_at, updated_at = excluded.updated_at;
  return jsonb_build_object('ok', true, 'code', o.code);
end $$;

create or replace function public.courier_stop_location() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
begin
  delete from amine.courier_locations where courier_id = c.user_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.courier_history(p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  if not exists (select 1 from amine.couriers where user_id = p.id) then
    perform amine.err('COURIER_NOT_APPROVED');
  end if;
  return coalesce((
    select jsonb_agg(amine.order_json(x, 'courier') order by x.placed_at desc)
    from (select * from amine.orders o
          where o.courier_id = p.id and o.status in ('delivered', 'cancelled')
          order by o.placed_at desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) x), '[]'::jsonb);
end $$;

-- =============================================================================================
--  Administration (réservé aux comptes is_admin) : tableau de bord, dépôts, clients, livreurs,
--  commandes, zones, codes promo, réclamations, prospects, paramètres, finances, journal.
--  Suppression : un élément déjà utilisé par des commandes est archivé (l'historique reste juste).
-- =============================================================================================

-- Fonctions de la version 1 remplacées par celles ci-dessous.
drop function if exists public.admin_overview();
drop function if exists public.admin_stores(text, text);
drop function if exists public.admin_store_decide(uuid, text, text);
drop function if exists public.admin_store_settings(uuid, int);
drop function if exists public.admin_courier_decide(uuid, text, text);
drop function if exists public.admin_courier_zone(uuid, uuid);
drop function if exists public.admin_users(text, int, int);
drop function if exists public.admin_user_update(uuid, text, boolean);

-- Lecture des entrées JSON ----------------------------------------------------------------------
create or replace function amine.bool_in(p jsonb, p_key text) returns boolean
language plpgsql immutable set search_path = '' as $$
begin
  if jsonb_typeof(p -> p_key) <> 'boolean' then
    perform amine.err('INVALID_INPUT', p_key);
  end if;
  return (p ->> p_key)::boolean;
end $$;

create or replace function amine.uuid_in(p jsonb, p_key text, p_required boolean default false) returns uuid
language plpgsql immutable set search_path = '' as $$
declare
  v text := nullif(btrim(coalesce(p ->> p_key, '')), '');
begin
  if v is null then
    if p_required then
      perform amine.err('INVALID_INPUT', p_key);
    end if;
    return null;
  end if;
  if v !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    perform amine.err('INVALID_INPUT', p_key);
  end if;
  return v::uuid;
end $$;

create or replace function amine.ts_in(p jsonb, p_key text) returns timestamptz
language plpgsql stable set search_path = '' as $$
declare
  v text := nullif(btrim(coalesce(p ->> p_key, '')), '');
begin
  if v is null then
    return null;
  end if;
  if char_length(v) > 40 or v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then
    perform amine.err('INVALID_INPUT', p_key);
  end if;
  begin
    return v::timestamptz;
  exception when others then
    perform amine.err('INVALID_INPUT', p_key);
  end;
  return null;
end $$;

create or replace function amine.zone_ref(z amine.zones) returns jsonb
language sql stable set search_path = '' as $$
  select case when z.id is null then null else
    jsonb_build_object('id', z.id, 'name_fr', z.name_fr, 'name_ar', z.name_ar, 'name_en', z.name_en) end
$$;

-- Tableau de bord ---------------------------------------------------------------------------------
create or replace function amine.period_kpis(p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'orders', count(*) filter (where o.status not in ('cancelled', 'rejected')),
    'delivered', count(*) filter (where o.status = 'delivered'),
    'cancelled', count(*) filter (where o.status in ('cancelled', 'rejected')),
    'revenue', coalesce(sum(o.total) filter (where o.status = 'delivered'), 0),
    'discounts', coalesce(sum(o.discount) filter (where o.status = 'delivered'), 0),
    'clients', count(distinct o.customer_id) filter (where o.status not in ('cancelled', 'rejected')),
    'avg_basket', coalesce(round(avg(o.total) filter (where o.status = 'delivered')), 0),
    'new_clients', (select count(*) from amine.profiles p where p.created_at >= p_from and p.created_at < p_to
                    and not p.is_admin and p.status = 'active'))
  from amine.orders o where o.kind = 'store' and o.placed_at >= p_from and o.placed_at < p_to
$$;

create or replace function public.admin_dashboard(p_days int default 30) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_days int := least(greatest(coalesce(p_days, 30), 1), 366);
  v_today date := (now() at time zone 'Africa/Tunis')::date;
  v_from timestamptz := (v_today - v_days + 1)::timestamp at time zone 'Africa/Tunis';
  v_prev timestamptz := (v_today - 2 * v_days + 1)::timestamp at time zone 'Africa/Tunis';
  v_end timestamptz := (v_today + 1)::timestamp at time zone 'Africa/Tunis';
begin
  perform amine.maintenance();
  return jsonb_build_object(
    'days', v_days, 'today', v_today,
    'current', amine.period_kpis(v_from, v_end),
    'previous', amine.period_kpis(v_prev, v_from),
    'series', (
      select jsonb_agg(jsonb_build_object('day', d.day, 'orders', coalesce(x.orders, 0), 'revenue', coalesce(x.revenue, 0))
        order by d.day)
      from (select v_today - g as day from generate_series(0, v_days - 1) g) d
      left join (
        select (o.placed_at at time zone 'Africa/Tunis')::date as day,
          count(*) filter (where o.status not in ('cancelled', 'rejected')) as orders,
          coalesce(sum(o.total) filter (where o.status = 'delivered'), 0) as revenue
        from amine.orders o where o.kind = 'store' and o.placed_at >= v_from and o.placed_at < v_end
        group by 1) x on x.day = d.day),
    'live', (select jsonb_build_object(
        'placed', count(*) filter (where o.status = 'placed'),
        'accepted', count(*) filter (where o.status = 'accepted'),
        'preparing', count(*) filter (where o.status = 'preparing'),
        'ready', count(*) filter (where o.status = 'ready'),
        'picked_up', count(*) filter (where o.status = 'picked_up'),
        'scheduled', count(*) filter (where coalesce(o.delivery_slot, 'asap') <> 'asap'),
        'waiting_courier', count(*) filter (where o.courier_id is null and o.status in ('accepted', 'preparing', 'ready')
          and amine.job_open(o)))
      from amine.orders o where o.status in ('placed', 'accepted', 'preparing', 'ready', 'picked_up')),
    'latest', coalesce((
      select jsonb_agg(jsonb_build_object('code', o.code, 'kind', o.kind, 'status', o.status, 'total', o.total,
          'placed_at', o.placed_at, 'client', o.dropoff_name, 'source', o.source,
          'delivery_slot', coalesce(o.delivery_slot, 'asap'), 'deliver_on', o.deliver_on) order by o.placed_at desc)
      from (select * from amine.orders order by placed_at desc limit 8) o), '[]'::jsonb),
    'top_products', coalesce((
      select jsonb_agg(jsonb_build_object('name', t.name, 'ref', t.ref, 'unit', t.unit, 'quantity', t.quantity,
          'revenue', t.revenue) order by t.quantity desc)
      from (select i.name, max(pr.ref) as ref, max(i.unit) as unit, sum(i.quantity) as quantity, sum(i.total) as revenue
            from amine.order_items i join amine.orders o on o.id = i.order_id
            left join amine.products pr on pr.id = i.product_id
            where o.status not in ('cancelled', 'rejected') and o.placed_at >= v_from
            group by i.name order by 4 desc limit 6) t), '[]'::jsonb),
    'alerts', jsonb_build_object(
      'complaints_open', (select count(*) from amine.complaints where status in ('open', 'in_progress')),
      'late_orders', (select count(*) from amine.orders o where o.status in ('placed', 'accepted', 'preparing', 'ready', 'picked_up')
        and ((coalesce(o.delivery_slot, 'asap') = 'asap' and o.placed_at < now() - interval '90 minutes')
          or (coalesce(o.delivery_slot, 'asap') <> 'asap' and now() > amine.slot_end(o.deliver_on, o.delivery_slot)))),
      'low_stock', (select count(*) from amine.products pr join amine.stores s on s.id = pr.store_id
        where pr.deleted_at is null and pr.stock is not null and pr.stock <= 5 and s.status = 'active'),
      'couriers_online', (select count(*) from amine.couriers where status = 'approved' and is_online
        and last_seen_at > now() - interval '20 minutes'),
      'couriers_pending', (select count(*) from amine.couriers where status = 'pending'),
      'prospects_new', (select count(*) from amine.prospects where status = 'new'),
      -- Factures sur compte échues et non réglées ; marchandises reçues dont la date limite approche.
      'invoices_overdue', (select count(*) from amine.invoices i
        join lateral (select st.paid from amine.invoice_states(i.customer_id) st where st.invoice_id = i.id) s on true
        where i.kind = 'invoice' and i.customer_id is not null and i.due_on < v_today and s.paid < i.total_ttc),
      'expiring', (select count(*) from amine.purchase_lines l join amine.purchases pu on pu.id = l.purchase_id
        join amine.products pr on pr.id = l.product_id
        where pu.status = 'received' and l.expiry_on between v_today and v_today + 3 and l.remaining > 0
          and pr.deleted_at is null),
      'recurring_failed', (select count(*) from amine.recurring_orders r where r.is_active and r.last_error is not null)),
    'setup', jsonb_build_object(
      'zones', (select count(*) from amine.zones z join amine.cities c on c.id = z.city_id where z.is_active and c.is_active),
      'depots', (select count(*) from amine.stores where status = 'active'),
      'products', (select count(*) from amine.products pr join amine.stores s on s.id = pr.store_id
        where pr.deleted_at is null and s.status = 'active'),
      'couriers', (select count(*) from amine.couriers where status = 'approved'),
      'clients', (select count(*) from amine.profiles where business_name is not null and status = 'active'),
      'legal_reviewed', coalesce((amine.setting('legal') ->> 'reviewed')::boolean, false)));
end $$;

-- Dépôts AMINE -------------------------------------------------------------------------------------
create or replace function amine.depot_admin_json(s amine.stores) returns jsonb
language sql stable set search_path = '' as $$
  select amine.store_card(s) || jsonb_build_object(
    'status', s.status, 'status_note', s.status_note, 'phone', s.phone, 'hours', s.hours, 'is_open', s.is_open,
    'created_at', s.created_at,
    'zone', (select amine.zone_ref(z) from amine.zones z where z.id = s.zone_id),
    'products', (select count(*) from amine.products pr where pr.store_id = s.id and pr.deleted_at is null),
    'sections', (select count(*) from amine.sections sc where sc.store_id = s.id),
    'orders', (select count(*) from amine.orders o where o.store_id = s.id),
    'active_orders', (select count(*) from amine.orders o where o.store_id = s.id
      and o.status in ('placed', 'accepted', 'preparing', 'ready', 'picked_up')),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('user_id', p.id, 'name', p.full_name, 'email', p.email,
        'role', st.role) order by st.role desc, p.full_name)
      from amine.store_staff st join amine.profiles p on p.id = st.user_id where st.store_id = s.id), '[]'::jsonb))
$$;

create or replace function public.admin_depots(p_status text default null, p_query text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_q text := amine.txt(p_query, 'query', 60);
begin
  return coalesce((
    select jsonb_agg(amine.depot_admin_json(s) order by (s.status = 'archived'), s.created_at)
    from amine.stores s
    where ((p_status is null and s.status <> 'archived') or s.status = p_status)
      and (v_q is null or amine.fold(s.name) like '%' || amine.like_escape(amine.fold(v_q)) || '%'
           or s.address ilike '%' || amine.like_escape(v_q) || '%')), '[]'::jsonb);
end $$;

-- Création (p_id null) ou modification d'un dépôt. Clés de p_data : name, name_ar, name_en,
-- description*, phone, address, lat, lng, hours, min_order, prep_minutes, is_open, status.
create or replace function public.admin_save_depot(p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  s amine.stores;
  z amine.zones;
  v_lat numeric;
  v_lng numeric;
  v_status text;
begin
  perform amine.hit('admin_depot:' || a.id, 200, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  begin
    v_lat := (p_data ->> 'lat')::numeric;
    v_lng := (p_data ->> 'lng')::numeric;
  exception when others then
    perform amine.err('INVALID_LOCATION');
  end;
  perform amine.check_point(v_lat, v_lng);
  z := amine.zone_for(v_lat, v_lng);
  if z.id is null then
    perform amine.err('ADDRESS_OUT_OF_ZONE');
  end if;
  v_status := coalesce(nullif(p_data ->> 'status', ''), 'active');
  if v_status not in ('active', 'suspended', 'archived') then
    perform amine.err('INVALID_INPUT', 'status');
  end if;
  if p_data ? 'hours' and not amine.valid_hours(p_data -> 'hours') then
    perform amine.err('INVALID_INPUT', 'hours');
  end if;
  if p_data ? 'is_open' and jsonb_typeof(p_data -> 'is_open') <> 'boolean' then
    perform amine.err('INVALID_INPUT', 'is_open');
  end if;

  if p_id is null then
    insert into amine.stores (slug, kind, name, name_ar, name_en, description, description_ar, description_en, phone,
      address, lat, lng, zone_id, status, hours, min_order, prep_minutes, commission_bps, owner_id, is_open, approved_at)
    values (amine.slugify(p_data ->> 'name'), 'grocery', amine.txt(p_data ->> 'name', 'name', 80, true, 2),
      amine.txt(p_data ->> 'name_ar', 'name_ar', 80), amine.txt(p_data ->> 'name_en', 'name_en', 80),
      amine.txt(p_data ->> 'description', 'description', 500, false, 1, true),
      amine.txt(p_data ->> 'description_ar', 'description_ar', 500, false, 1, true),
      amine.txt(p_data ->> 'description_en', 'description_en', 500, false, 1, true),
      amine.phone_in(p_data ->> 'phone', 'phone', true), amine.txt(p_data ->> 'address', 'address', 200, true, 3),
      round(v_lat, 6), round(v_lng, 6), z.id, v_status,
      coalesce(case when p_data ? 'hours' then p_data -> 'hours' end, amine.default_hours()),
      coalesce(amine.int_in(p_data, 'min_order', 0, 10000000, false), 0),
      coalesce(amine.int_in(p_data, 'prep_minutes', 5, 240, false), 30), 0, a.id,
      coalesce((p_data ->> 'is_open')::boolean, true), now())
    returning * into s;
    insert into amine.store_staff (store_id, user_id, role) values (s.id, a.id, 'owner') on conflict do nothing;
    perform amine.audit('depot.created', 'store', s.id::text, jsonb_build_object('name', s.name));
  else
    select * into s from amine.stores where id = p_id for update;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
    update amine.stores set name = amine.txt(p_data ->> 'name', 'name', 80, true, 2),
      name_ar = amine.txt(p_data ->> 'name_ar', 'name_ar', 80), name_en = amine.txt(p_data ->> 'name_en', 'name_en', 80),
      description = amine.txt(p_data ->> 'description', 'description', 500, false, 1, true),
      description_ar = amine.txt(p_data ->> 'description_ar', 'description_ar', 500, false, 1, true),
      description_en = amine.txt(p_data ->> 'description_en', 'description_en', 500, false, 1, true),
      phone = amine.phone_in(p_data ->> 'phone', 'phone', true), address = amine.txt(p_data ->> 'address', 'address', 200, true, 3),
      lat = round(v_lat, 6), lng = round(v_lng, 6), zone_id = z.id, status = v_status,
      hours = case when p_data ? 'hours' then p_data -> 'hours' else hours end,
      min_order = coalesce(amine.int_in(p_data, 'min_order', 0, 10000000, false), min_order),
      prep_minutes = coalesce(amine.int_in(p_data, 'prep_minutes', 5, 240, false), prep_minutes),
      is_open = coalesce((p_data ->> 'is_open')::boolean, is_open),
      approved_at = coalesce(approved_at, case when v_status = 'active' then now() end),
      updated_at = now()
    where id = p_id returning * into s;
    perform amine.audit('depot.updated', 'store', s.id::text, jsonb_build_object('name', s.name, 'status', s.status));
  end if;
  return amine.depot_admin_json(s);
end $$;

create or replace function public.admin_delete_depot(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  s amine.stores;
begin
  select * into s from amine.stores where id = p_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if exists (select 1 from amine.orders where store_id = s.id and status in ('placed', 'accepted', 'preparing', 'ready', 'picked_up')) then
    perform amine.err('ACTIVE_ORDERS_EXIST');
  end if;
  if exists (select 1 from amine.orders where store_id = s.id) then
    update amine.stores set status = 'archived', is_open = false, updated_at = now() where id = s.id;
    perform amine.audit('depot.archived', 'store', s.id::text, jsonb_build_object('name', s.name));
    return jsonb_build_object('archived', true);
  end if;
  delete from amine.stores where id = s.id;
  perform amine.audit('depot.deleted', 'store', s.id::text, jsonb_build_object('name', s.name));
  return jsonb_build_object('deleted', true);
end $$;

-- Comptes : recherche par e-mail (pour rattacher un livreur, un membre d'équipe…) ----------------
create or replace function public.admin_find_user(p_email text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  p amine.profiles;
begin
  select * into p from amine.profiles where lower(email) = lower(btrim(coalesce(p_email, ''))) limit 1;
  if not found then
    return null;
  end if;
  return jsonb_build_object('id', p.id, 'email', p.email, 'full_name', p.full_name, 'phone', p.phone, 'status', p.status,
    'business_name', p.business_name, 'is_admin', p.is_admin,
    'courier', (select c.status from amine.couriers c where c.user_id = p.id));
end $$;

-- Clients (restaurants, cafés, hôtels…) et autres comptes ---------------------------------------------
create or replace function amine.client_json(p amine.profiles) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', p.id, 'full_name', p.full_name, 'email', p.email, 'phone', p.phone,
    'phone_verified', p.phone_verified, 'business_name', p.business_name, 'business_type', p.business_type,
    'tax_id', p.tax_id, 'admin_note', p.admin_note, 'is_admin', p.is_admin, 'status', p.status, 'locale', p.locale,
    'created_at', p.created_at,
    'payment_terms', p.payment_terms, 'payment_days', p.payment_days, 'credit_limit', p.credit_limit,
    'discount_bps', p.discount_bps, 'balance', amine.account_balance(p.id),
    'points', amine.loyalty_balance(p.id), 'marketing_opt_in', p.marketing_opt_in,
    'courier', (select c.status from amine.couriers c where c.user_id = p.id),
    'staff', (select count(*) from amine.store_staff st where st.user_id = p.id),
    'orders', (select count(*) from amine.orders o where o.customer_id = p.id and o.kind = 'store'),
    'spent', (select coalesce(sum(o.total), 0) from amine.orders o where o.customer_id = p.id and o.status = 'delivered'),
    'last_order_at', (select max(o.placed_at) from amine.orders o where o.customer_id = p.id),
    'zone', (select amine.zone_ref(z) from amine.addresses ad join amine.zones z on z.id = ad.zone_id
             where ad.user_id = p.id order by ad.created_at limit 1))
$$;

-- p_role : client | courier | staff | admin | null (tous)
create or replace function public.admin_clients(
  p_query text default null, p_role text default 'client', p_status text default null, p_limit int default 50, p_offset int default 0
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_q text := amine.txt(p_query, 'query', 80);
begin
  if p_role is not null and p_role not in ('client', 'courier', 'staff', 'admin') then
    perform amine.err('INVALID_INPUT', 'role');
  end if;
  if p_status is not null and p_status not in ('active', 'blocked') then
    perform amine.err('INVALID_INPUT', 'status');
  end if;
  return (
    with base as (
      select p.* from amine.profiles p
      where (p.email is not null or p.full_name <> '')
        and (p_status is null or p.status = p_status)
        and (v_q is null or amine.fold(p.full_name) like '%' || amine.like_escape(amine.fold(v_q)) || '%'
             or amine.fold(coalesce(p.business_name, '')) like '%' || amine.like_escape(amine.fold(v_q)) || '%'
             or p.email ilike '%' || amine.like_escape(v_q) || '%' or p.phone ilike '%' || amine.like_escape(v_q) || '%')
        and (p_role is null
          or (p_role = 'admin' and p.is_admin)
          or (p_role = 'courier' and exists (select 1 from amine.couriers c where c.user_id = p.id and c.status <> 'archived'))
          or (p_role = 'staff' and exists (select 1 from amine.store_staff st where st.user_id = p.id))
          or (p_role = 'client' and not p.is_admin
              and not exists (select 1 from amine.couriers c where c.user_id = p.id and c.status <> 'archived')
              and not exists (select 1 from amine.store_staff st where st.user_id = p.id)))
    )
    select jsonb_build_object(
      'total', (select count(*) from base),
      'items', coalesce((select jsonb_agg(amine.client_json(x) order by x.created_at desc)
        from (select * from base order by created_at desc
              limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0)) x), '[]'::jsonb)));
end $$;

create or replace function public.admin_client(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  p amine.profiles;
begin
  select * into p from amine.profiles where id = p_id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.client_json(p) || jsonb_build_object(
    'addresses', coalesce((select jsonb_agg(amine.address_json(ad) order by ad.created_at desc)
      from amine.addresses ad where ad.user_id = p.id), '[]'::jsonb),
    'recent_orders', coalesce((
      select jsonb_agg(jsonb_build_object('code', o.code, 'status', o.status, 'total', o.total, 'placed_at', o.placed_at,
          'delivery_slot', coalesce(o.delivery_slot, 'asap'), 'deliver_on', o.deliver_on, 'source', o.source)
        order by o.placed_at desc)
      from (select * from amine.orders where customer_id = p.id order by placed_at desc limit 20) o), '[]'::jsonb),
    'complaints', coalesce((select jsonb_agg(amine.complaint_json(c) order by c.created_at desc)
      from amine.complaints c where c.customer_id = p.id), '[]'::jsonb),
    'favorites', (select count(*) from amine.favorites f where f.user_id = p.id));
end $$;

-- Modification partielle d'un compte : seules les clés présentes dans p_data sont changées.
-- Clés : full_name, phone, business_name, business_type, tax_id, admin_note, status, is_admin, locale,
-- payment_terms (cod | account), payment_days, credit_limit, discount_bps.
create or replace function public.admin_save_client(p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  p amine.profiles;
begin
  perform amine.hit('admin_client:' || a.id, 300, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  select * into p from amine.profiles where id = p_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if p.id = a.id and (p_data ? 'status' or p_data ? 'is_admin') then
    perform amine.err('CANNOT_CHANGE_SELF');
  end if;
  if p_data ? 'full_name' then p.full_name := coalesce(amine.txt(p_data ->> 'full_name', 'full_name', 120, false, 2), ''); end if;
  if p_data ? 'phone' then
    p.phone := amine.phone_in(p_data ->> 'phone', 'phone', false);
    p.phone_verified := p.phone_verified and p.phone is not distinct from (select x.phone from amine.profiles x where x.id = p.id);
  end if;
  if p_data ? 'business_name' then p.business_name := amine.txt(p_data ->> 'business_name', 'business_name', 120, false, 2); end if;
  if p_data ? 'business_type' then p.business_type := amine.business_type_in(p_data ->> 'business_type'); end if;
  if p_data ? 'tax_id' then p.tax_id := amine.tax_id_in(p_data ->> 'tax_id'); end if;
  if p_data ? 'admin_note' then p.admin_note := amine.txt(p_data ->> 'admin_note', 'admin_note', 500, false, 1, true); end if;
  if p_data ? 'locale' then
    if coalesce(p_data ->> 'locale', '') not in ('fr', 'ar', 'en') then
      perform amine.err('INVALID_INPUT', 'locale');
    end if;
    p.locale := p_data ->> 'locale';
  end if;
  if p_data ? 'status' then
    if coalesce(p_data ->> 'status', '') not in ('active', 'blocked') then
      perform amine.err('INVALID_INPUT', 'status');
    end if;
    p.status := p_data ->> 'status';
  end if;
  if p_data ? 'is_admin' then
    p.is_admin := amine.bool_in(p_data, 'is_admin');
  end if;
  if p_data ? 'payment_terms' then
    if coalesce(p_data ->> 'payment_terms', '') not in ('cod', 'account') then
      perform amine.err('INVALID_INPUT', 'payment_terms');
    end if;
    p.payment_terms := p_data ->> 'payment_terms';
  end if;
  if p_data ? 'payment_days' then p.payment_days := amine.int_in(p_data, 'payment_days', 0, 120, true); end if;
  if p_data ? 'credit_limit' then p.credit_limit := amine.int_in(p_data, 'credit_limit', 0, 1000000000, true); end if;
  if p_data ? 'discount_bps' then p.discount_bps := amine.int_in(p_data, 'discount_bps', 0, 5000, true); end if;
  update amine.profiles set full_name = p.full_name, phone = p.phone, phone_verified = p.phone_verified,
    business_name = p.business_name, business_type = p.business_type, tax_id = p.tax_id, admin_note = p.admin_note,
    locale = p.locale, status = p.status, is_admin = p.is_admin, payment_terms = p.payment_terms,
    payment_days = p.payment_days, credit_limit = p.credit_limit, discount_bps = p.discount_bps, updated_at = now()
  where id = p.id returning * into p;
  if p.status = 'blocked' then
    update amine.couriers set is_online = false where user_id = p.id;
    delete from amine.courier_locations where courier_id = p.id;
  end if;
  perform amine.audit('client.updated', 'profile', p.id::text,
    jsonb_build_object('status', p.status, 'is_admin', p.is_admin, 'business_name', p.business_name,
      'payment_terms', p.payment_terms, 'credit_limit', p.credit_limit, 'discount_bps', p.discount_bps));
  return amine.client_json(p);
end $$;

create or replace function public.admin_delete_client(p_id uuid, p_confirm text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  p amine.profiles;
begin
  if coalesce(p_confirm, '') <> 'DELETE' then
    perform amine.err('CONFIRMATION_MISMATCH');
  end if;
  if p_id = a.id then
    perform amine.err('CANNOT_CHANGE_SELF');
  end if;
  select * into p from amine.profiles where id = p_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.erase_account(p);
end $$;

create or replace function public.admin_save_client_address(
  p_user_id uuid, p_id uuid, p_label text, p_line text, p_details text, p_lat numeric, p_lng numeric
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  if not exists (select 1 from amine.profiles where id = p_user_id) then
    perform amine.err('NOT_FOUND');
  end if;
  perform amine.audit('client.address_saved', 'profile', p_user_id::text, jsonb_build_object('address_id', p_id));
  return amine.address_json(amine.save_address_for(p_user_id, p_id, p_label, p_line, p_details, p_lat, p_lng, 'map'));
end $$;

create or replace function public.admin_delete_client_address(p_user_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  delete from amine.addresses where id = p_id and user_id = p_user_id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  perform amine.audit('client.address_deleted', 'profile', p_user_id::text, jsonb_build_object('address_id', p_id));
  return jsonb_build_object('ok', true);
end $$;

-- Livreurs --------------------------------------------------------------------------------------
create or replace function amine.courier_admin_json(c amine.couriers) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('user_id', c.user_id, 'name', p.full_name, 'email', p.email, 'phone', p.phone,
      'vehicle', c.vehicle, 'cin', c.cin, 'note', c.note, 'status', c.status, 'status_note', c.status_note,
      'is_online', c.is_online and c.last_seen_at > now() - interval '20 minutes', 'last_seen_at', c.last_seen_at,
      'created_at', c.created_at,
      'rating', case when c.rating_count > 0 then round(c.rating_sum::numeric / c.rating_count, 1) end,
      'zone', (select amine.zone_ref(z) from amine.zones z where z.id = c.zone_id),
      'deliveries', (select count(*) from amine.orders o where o.courier_id = c.user_id and o.status = 'delivered'),
      'active_jobs', (select count(*) from amine.orders o where o.courier_id = c.user_id
        and o.status in ('accepted', 'preparing', 'ready', 'picked_up')),
      'location', (select jsonb_build_object('lat', l.lat, 'lng', l.lng, 'recorded_at', l.recorded_at)
                   from amine.courier_locations l where l.courier_id = c.user_id))
  from amine.profiles p where p.id = c.user_id
$$;

create or replace function public.admin_couriers(p_status text default null, p_query text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_q text := amine.txt(p_query, 'query', 60);
begin
  return coalesce((
    select jsonb_agg(amine.courier_admin_json(c) order by (c.status = 'pending') desc, c.created_at desc)
    from amine.couriers c join amine.profiles p on p.id = c.user_id
    where ((p_status is null and c.status <> 'archived') or c.status = p_status)
      and (v_q is null or amine.fold(p.full_name) like '%' || amine.like_escape(amine.fold(v_q)) || '%'
           or p.phone ilike '%' || amine.like_escape(v_q) || '%' or p.email ilike '%' || amine.like_escape(v_q) || '%')
    ), '[]'::jsonb);
end $$;

-- Ajout (p_user_id null : compte retrouvé par p_email) ou modification d'un livreur.
-- Clés de p_data : vehicle, zone_id, cin, note, status, status_note, full_name, phone.
create or replace function public.admin_save_courier(p_user_id uuid, p_email text, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  p amine.profiles;
  c amine.couriers;
  v_status text;
  v_old text;
  v_cin text;
  v_zone uuid;
begin
  perform amine.hit('admin_courier:' || a.id, 200, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  if p_user_id is null then
    select * into p from amine.profiles where lower(email) = lower(btrim(coalesce(p_email, ''))) for update;
  else
    select * into p from amine.profiles where id = p_user_id for update;
  end if;
  if not found or p.email is null then
    perform amine.err('USER_NOT_FOUND');
  end if;
  if p.status <> 'active' then
    perform amine.err('ACCOUNT_BLOCKED');
  end if;
  select * into c from amine.couriers where user_id = p.id for update;
  v_old := c.status;
  if p_data ? 'full_name' then
    p.full_name := coalesce(amine.txt(p_data ->> 'full_name', 'full_name', 120, true, 2), p.full_name);
  end if;
  if p_data ? 'phone' then
    p.phone := amine.phone_in(p_data ->> 'phone', 'phone', true);
  end if;
  if p.phone is null then
    perform amine.err('PHONE_REQUIRED');
  end if;
  update amine.profiles set full_name = p.full_name, phone = p.phone,
    phone_verified = phone_verified and phone is not distinct from p.phone, updated_at = now()
  where id = p.id;

  c.vehicle := coalesce(nullif(p_data ->> 'vehicle', ''), c.vehicle);
  if c.vehicle is null or c.vehicle not in ('bike', 'scooter', 'car', 'foot') then
    perform amine.err('INVALID_INPUT', 'vehicle');
  end if;
  if p_data ? 'zone_id' then
    v_zone := amine.uuid_in(p_data, 'zone_id');
    if v_zone is not null and not exists (select 1 from amine.zones where id = v_zone) then
      perform amine.err('INVALID_INPUT', 'zone_id');
    end if;
    c.zone_id := v_zone;
  end if;
  if p_data ? 'cin' then
    v_cin := nullif(regexp_replace(coalesce(p_data ->> 'cin', ''), '[^0-9]', '', 'g'), '');
    if v_cin is not null and v_cin !~ '^[0-9]{8}$' then
      perform amine.err('INVALID_INPUT', 'cin');
    end if;
    c.cin := v_cin;
  end if;
  if p_data ? 'note' then c.note := amine.txt(p_data ->> 'note', 'note', 300, false, 1, true); end if;
  v_status := coalesce(nullif(p_data ->> 'status', ''), case when c.user_id is null or c.status = 'archived' then 'approved' else c.status end);
  if v_status not in ('pending', 'approved', 'rejected', 'suspended') then
    perform amine.err('INVALID_INPUT', 'status');
  end if;
  if p_data ? 'status_note' then c.status_note := amine.txt(p_data ->> 'status_note', 'status_note', 300); end if;
  if v_status in ('rejected', 'suspended') and v_status is distinct from v_old and c.status_note is null then
    perform amine.err('REASON_REQUIRED');
  end if;

  if c.user_id is null then
    insert into amine.couriers (user_id, vehicle, zone_id, cin, note, status, status_note, decided_at)
    values (p.id, c.vehicle, c.zone_id, c.cin, c.note, v_status, c.status_note, now())
    returning * into c;
  else
    update amine.couriers set vehicle = c.vehicle, zone_id = c.zone_id, cin = c.cin, note = c.note, status = v_status,
      status_note = c.status_note, decided_at = case when v_status is distinct from v_old then now() else decided_at end,
      is_online = case when v_status = 'approved' then is_online else false end
    where user_id = p.id returning * into c;
  end if;
  if v_status <> 'approved' then
    delete from amine.courier_locations where courier_id = c.user_id;
  end if;
  if v_status is distinct from v_old then
    perform amine.notify(c.user_id, 'courier_' || v_status, jsonb_build_object('note', c.status_note), '#/courier');
  end if;
  perform amine.audit('courier.saved', 'courier', c.user_id::text, jsonb_build_object('status', c.status, 'previous', v_old));
  return amine.courier_admin_json(c);
end $$;

create or replace function public.admin_delete_courier(p_user_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  c amine.couriers;
begin
  select * into c from amine.couriers where user_id = p_user_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if exists (select 1 from amine.orders where courier_id = c.user_id and status in ('accepted', 'preparing', 'ready', 'picked_up')) then
    perform amine.err('ACTIVE_ORDERS_EXIST');
  end if;
  delete from amine.courier_locations where courier_id = c.user_id;
  if exists (select 1 from amine.orders where courier_id = c.user_id) then
    update amine.couriers set status = 'archived', is_online = false, decided_at = now() where user_id = c.user_id;
    perform amine.audit('courier.archived', 'courier', c.user_id::text, '{}'::jsonb);
    return jsonb_build_object('archived', true);
  end if;
  delete from amine.couriers where user_id = c.user_id;
  perform amine.audit('courier.deleted', 'courier', c.user_id::text, '{}'::jsonb);
  return jsonb_build_object('deleted', true);
end $$;

-- Commandes ---------------------------------------------------------------------------------------
-- p_status : null | active | scheduled | placed | accepted | … | delivered | cancelled | rejected
create or replace function public.admin_orders(p_status text default null, p_query text default null, p_limit int default 50, p_offset int default 0) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_q text := amine.txt(p_query, 'query', 60);
begin
  return coalesce((
    select jsonb_agg(x.j order by x.placed_at desc)
    from (
      select jsonb_build_object('code', o.code, 'kind', o.kind, 'status', o.status, 'total', o.total,
          'placed_at', o.placed_at, 'updated_at', o.updated_at, 'has_courier', o.courier_id is not null,
          'store', (select s.name from amine.stores s where s.id = o.store_id),
          'client', o.dropoff_name, 'customer_id', o.customer_id, 'pickup', o.pickup_name, 'source', o.source,
          'delivery_slot', coalesce(o.delivery_slot, 'asap'), 'deliver_on', o.deliver_on,
          'items_count', (select count(*) from amine.order_items i where i.order_id = o.id),
          'courier', (select p.full_name from amine.profiles p where p.id = o.courier_id)) as j,
        o.placed_at
      from amine.orders o
      where (p_status is null
             or (p_status = 'active' and o.status in ('placed', 'accepted', 'preparing', 'ready', 'picked_up'))
             or (p_status = 'scheduled' and o.status in ('placed', 'accepted', 'preparing', 'ready')
                 and coalesce(o.delivery_slot, 'asap') <> 'asap')
             or o.status = p_status)
        and (v_q is null or o.code ilike '%' || amine.like_escape(v_q) || '%'
             or amine.fold(o.dropoff_name) like '%' || amine.like_escape(amine.fold(v_q)) || '%'
             or o.dropoff_phone ilike '%' || amine.like_escape(v_q) || '%'
             or o.pickup_name ilike '%' || amine.like_escape(v_q) || '%')
      order by o.placed_at desc
      limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0)) x), '[]'::jsonb);
end $$;

create or replace function public.admin_order(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  o amine.orders;
  l amine.courier_locations;
begin
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, '')));
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if o.courier_id is not null then
    select * into l from amine.courier_locations where courier_id = o.courier_id;
  end if;
  return amine.order_json(o, 'admin') || jsonb_build_object(
    'can_edit_items', o.kind = 'store' and o.status in ('placed', 'accepted'),
    'can_edit', o.kind = 'store' and o.status in ('placed', 'accepted', 'preparing'),
    'courier_location', case when l.courier_id is null then null else
      jsonb_build_object('lat', l.lat, 'lng', l.lng, 'accuracy_m', l.accuracy_m, 'recorded_at', l.recorded_at) end,
    'complaints', coalesce((select jsonb_agg(amine.complaint_json(c) order by c.created_at desc)
      from amine.complaints c where c.order_id = o.id), '[]'::jsonb),
    'event_actors', coalesce((
      select jsonb_agg(jsonb_build_object('at', e.created_at, 'name', p.full_name) order by e.id)
      from amine.order_events e left join amine.profiles p on p.id = e.actor_id where e.order_id = o.id), '[]'::jsonb));
end $$;

-- Commande saisie par l'équipe pour un client (appel, WhatsApp) : mêmes règles que dans l'appli.
drop function if exists public.admin_create_order(uuid, uuid, uuid, jsonb, text, text, text);
create or replace function public.admin_create_order(
  p_customer_id uuid, p_store_id uuid, p_address_id uuid, p_items jsonb, p_note text default null,
  p_delivery_slot text default 'asap', p_promo_code text default null, p_payment_method text default 'cod'
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  cu amine.profiles;
  o amine.orders;
begin
  perform amine.hit('admin_order:' || a.id, 120, 3600);
  select * into cu from amine.profiles where id = p_customer_id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  perform amine.assert_can_order(cu, true);
  o := amine.create_store_order(cu, p_store_id, p_address_id, p_items, p_note, null, p_promo_code,
    coalesce(p_delivery_slot, 'asap'), 'admin', 'admin', a.id, coalesce(p_payment_method, 'cod'));
  perform amine.notify(cu.id, 'order_created_for_you', jsonb_build_object('code', o.code, 'total', o.total), '#/orders/' || o.code);
  perform amine.audit('order.created', 'order', o.code, jsonb_build_object('customer_id', cu.id, 'total', o.total));
  return public.admin_order(o.code);
end $$;

-- Modification d'une commande par l'équipe : note, créneau, et produits tant que la préparation
-- n'a pas commencé (prix recalculés en base, stock remis puis réservé de nouveau).
-- p_data : {"items": [{"product_id": "...", "qty": 3}], "note": "...", "delivery_slot": "tomorrow_am"}
create or replace function public.admin_update_order(p_code text, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  o amine.orders;
  s amine.stores;
  v_cart jsonb;
  v_sub int;
  v_discount int;
  v_reprice jsonb;
  v_items boolean := false;
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if o.kind <> 'store' or o.status not in ('placed', 'accepted', 'preparing') then
    perform amine.err('ORDER_LOCKED');
  end if;
  select * into s from amine.stores where id = o.store_id;
  if p_data ? 'note' then
    o.customer_note := amine.txt(p_data ->> 'note', 'note', 300, false, 1, true);
  end if;
  if p_data ? 'delivery_slot' and coalesce(p_data ->> 'delivery_slot', 'asap') <> coalesce(o.delivery_slot, 'asap') then
    o.deliver_on := amine.check_slot(s, coalesce(p_data ->> 'delivery_slot', 'asap'));
    o.delivery_slot := coalesce(p_data ->> 'delivery_slot', 'asap');
  end if;
  if p_data ? 'items' then
    if o.status not in ('placed', 'accepted') then
      perform amine.err('ORDER_LOCKED');
    end if;
    v_items := true;
    -- L'ancien contenu revient en stock avant la nouvelle réservation.
    perform amine.stock_context('return', o.code, 'edited');
    update amine.products p set stock = p.stock + i.quantity, updated_at = now()
    from amine.order_items i where i.order_id = o.id and i.product_id = p.id and p.stock is not null;
    -- Les anciennes lignes sont retirées avant le nouveau chiffrage : leurs unités flash redeviennent disponibles.
    delete from amine.order_items where order_id = o.id;
    v_cart := amine.price_cart(o.store_id, p_data -> 'items', true, o.customer_id);
    perform amine.stock_context('sale', o.code, 'edited');
    perform amine.reserve_stock(v_cart -> 'lines');
    perform amine.flash_claim(v_cart -> 'lines');
    insert into amine.order_items (order_id, product_id, name, unit, unit_price, list_price, vat_rate, quantity, total, flash_sale_id)
    select o.id, (e.value ->> 'product_id')::uuid, e.value ->> 'name', e.value ->> 'unit',
      (e.value ->> 'unit_price')::int, (e.value ->> 'list_price')::int, (e.value ->> 'vat_rate')::smallint,
      (e.value ->> 'quantity')::int, (e.value ->> 'total')::int, (e.value ->> 'flash_sale_id')::uuid
    from jsonb_array_elements(v_cart -> 'lines') e;
    v_sub := (v_cart ->> 'subtotal')::int;
    -- Remise (code promo recalculé, points conservés dans la limite de ce qui reste à payer).
    v_reprice := amine.reprice_discount(o, v_sub);
    v_discount := (v_reprice ->> 'discount')::int;
    if (v_reprice ->> 'refund_points')::int > 0 then
      perform amine.loyalty_add(o.customer_id, (v_reprice ->> 'refund_points')::int, 'edit_refund', o.id, o.code);
    end if;
    o.subtotal := v_sub;
    o.discount := v_discount;
    o.loyalty_discount := (v_reprice ->> 'loyalty_discount')::int;
    o.loyalty_points := (v_reprice ->> 'loyalty_points')::int;
    o.total := v_sub + o.delivery_fee + o.service_fee + o.stamp_fee - v_discount;
    o.commission := round(v_sub::numeric * s.commission_bps / 10000)::int;
  end if;
  update amine.orders set customer_note = o.customer_note, delivery_slot = o.delivery_slot, deliver_on = o.deliver_on,
    subtotal = o.subtotal, discount = o.discount, loyalty_discount = o.loyalty_discount, loyalty_points = o.loyalty_points,
    total = o.total, commission = o.commission, updated_at = now()
  where id = o.id returning * into o;
  perform amine.log_order(o.id, o.status, 'updated', 'admin', a.id, case when v_items then 'items' end);
  perform amine.notify(o.customer_id, 'order_updated', jsonb_build_object('code', o.code, 'total', o.total), '#/orders/' || o.code);
  if v_items then
    perform amine.notify_store(o.store_id, 'order_updated', jsonb_build_object('code', o.code),
      '#/depot/orders/' || o.code || '?store=' || o.store_id::text);
  end if;
  perform amine.audit('order.updated', 'order', o.code, jsonb_build_object('items', v_items, 'total', o.total));
  return public.admin_order(o.code);
end $$;

-- p_action : cancel | status | assign | unassign
create or replace function public.admin_order_action(
  p_code text, p_action text, p_value text default null, p_reason text default null, p_cod_collected int default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  o amine.orders;
  v_reason text := amine.txt(p_reason, 'reason', 300);
  v_courier uuid;
  v_previous uuid;
begin
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if p_action = 'cancel' then
    if v_reason is null then
      perform amine.err('REASON_REQUIRED');
    end if;
    o := amine.transition(o, 'cancelled', 'admin', a.id, v_reason);
  elsif p_action = 'status' then
    if p_value is null or p_value not in ('accepted', 'preparing', 'ready', 'picked_up', 'delivered', 'rejected', 'cancelled') then
      perform amine.err('INVALID_INPUT', 'value');
    end if;
    if p_value in ('rejected', 'cancelled') and v_reason is null then
      perform amine.err('REASON_REQUIRED');
    end if;
    if p_value = 'delivered' and o.payment_method <> 'account' then
      if p_cod_collected is null or p_cod_collected < 0 or p_cod_collected > 100000000 then
        perform amine.err('COD_AMOUNT_REQUIRED');
      end if;
      update amine.orders set cod_collected = p_cod_collected where id = o.id;
      o.cod_collected := p_cod_collected;
    end if;
    o := amine.transition(o, p_value, 'admin', a.id, v_reason);
  elsif p_action = 'assign' then
    begin
      v_courier := p_value::uuid;
    exception when others then
      perform amine.err('INVALID_INPUT', 'value');
    end;
    if not exists (select 1 from amine.couriers where user_id = v_courier and status = 'approved') then
      perform amine.err('COURIER_NOT_APPROVED');
    end if;
    if o.status not in ('accepted', 'preparing', 'ready', 'picked_up') then
      perform amine.err('INVALID_TRANSITION');
    end if;
    v_previous := o.courier_id;
    update amine.orders set courier_id = v_courier, assigned_at = now(), updated_at = now() where id = o.id returning * into o;
    perform amine.log_order(o.id, o.status, 'courier_assigned', 'admin', a.id, v_reason);
    perform amine.notify(v_courier, 'job_assigned', jsonb_build_object('code', o.code), '#/courier/jobs/' || o.code);
    if v_previous is not null and v_previous <> v_courier then
      perform amine.notify(v_previous, 'job_unassigned', jsonb_build_object('code', o.code), '#/courier');
    end if;
  elsif p_action = 'unassign' then
    if o.courier_id is null or o.status not in ('accepted', 'preparing', 'ready') then
      perform amine.err('INVALID_TRANSITION');
    end if;
    v_previous := o.courier_id;
    update amine.orders set courier_id = null, assigned_at = null, updated_at = now() where id = o.id returning * into o;
    perform amine.log_order(o.id, o.status, 'courier_released', 'admin', a.id, v_reason);
    perform amine.notify(v_previous, 'job_unassigned', jsonb_build_object('code', o.code), '#/courier');
  else
    perform amine.err('INVALID_INPUT', 'action');
  end if;
  perform amine.audit('order.' || p_action, 'order', o.code, jsonb_build_object('value', p_value, 'reason', v_reason));
  return public.admin_order(o.code);
end $$;

-- Villes, zones et tarifs ------------------------------------------------------------------------------
create or replace function public.admin_zones() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  return jsonb_build_object(
    'cities', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object(
        'zones', (select count(*) from amine.zones z where z.city_id = c.id)) order by c.sort, c.name_fr)
      from amine.cities c), '[]'::jsonb),
    'zones', coalesce((select jsonb_agg(to_jsonb(z) || jsonb_build_object(
        'stores', (select count(*) from amine.stores s where s.zone_id = z.id and s.status = 'active'),
        'couriers', (select count(*) from amine.couriers c where c.zone_id = z.id and c.status = 'approved'),
        'clients', (select count(distinct ad.user_id) from amine.addresses ad where ad.zone_id = z.id),
        'prospects', (select count(*) from amine.prospects pr where pr.zone_id = z.id))
      order by z.sort, z.name_fr) from amine.zones z), '[]'::jsonb));
end $$;

create or replace function public.admin_save_city(p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  c amine.cities;
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  if p_data ? 'is_active' and jsonb_typeof(p_data -> 'is_active') <> 'boolean' then
    perform amine.err('INVALID_INPUT', 'is_active');
  end if;
  if p_id is null then
    insert into amine.cities (name_fr, name_ar, name_en, is_active, sort)
    values (amine.txt(p_data ->> 'name_fr', 'name_fr', 60, true, 2), amine.txt(p_data ->> 'name_ar', 'name_ar', 60, true),
      amine.txt(p_data ->> 'name_en', 'name_en', 60, true, 2), coalesce((p_data ->> 'is_active')::boolean, true),
      coalesce(amine.int_in(p_data, 'sort', 0, 1000, false), 0))
    returning * into c;
  else
    update amine.cities set name_fr = amine.txt(p_data ->> 'name_fr', 'name_fr', 60, true, 2),
      name_ar = amine.txt(p_data ->> 'name_ar', 'name_ar', 60, true), name_en = amine.txt(p_data ->> 'name_en', 'name_en', 60, true, 2),
      is_active = coalesce((p_data ->> 'is_active')::boolean, is_active),
      sort = coalesce(amine.int_in(p_data, 'sort', 0, 1000, false), sort)
    where id = p_id returning * into c;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
  end if;
  perform amine.audit('city.saved', 'city', c.id::text, to_jsonb(c));
  return to_jsonb(c);
end $$;

create or replace function public.admin_delete_city(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  c amine.cities;
begin
  select * into c from amine.cities where id = p_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if exists (select 1 from amine.zones where city_id = c.id) then
    -- Des zones y sont rattachées : la ville est désactivée (ses zones ne sont plus proposées).
    update amine.cities set is_active = false where id = c.id;
    perform amine.audit('city.archived', 'city', c.id::text, '{}'::jsonb);
    return jsonb_build_object('archived', true);
  end if;
  delete from amine.cities where id = c.id;
  perform amine.audit('city.deleted', 'city', c.id::text, to_jsonb(c));
  return jsonb_build_object('deleted', true);
end $$;

create or replace function public.admin_save_zone(p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  z amine.zones;
  v_services text[];
  v_city uuid;
  v_lat numeric;
  v_lng numeric;
  v_radius numeric;
  v_included numeric;
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  begin
    v_city := (p_data ->> 'city_id')::uuid;
    v_lat := (p_data ->> 'center_lat')::numeric;
    v_lng := (p_data ->> 'center_lng')::numeric;
    v_radius := (p_data ->> 'radius_km')::numeric;
    v_included := coalesce((p_data ->> 'included_km')::numeric, 2);
  exception when others then
    perform amine.err('INVALID_INPUT', 'data');
  end;
  if v_city is null or not exists (select 1 from amine.cities where id = v_city) then
    perform amine.err('INVALID_INPUT', 'city_id');
  end if;
  perform amine.check_point(v_lat, v_lng);
  if v_radius is null or v_radius <= 0 or v_radius > 50 then
    perform amine.err('INVALID_INPUT', 'radius_km');
  end if;
  if v_included < 0 or v_included > 50 then
    perform amine.err('INVALID_INPUT', 'included_km');
  end if;
  if jsonb_typeof(p_data -> 'services') <> 'array' then
    perform amine.err('INVALID_INPUT', 'services');
  end if;
  if p_data ? 'is_active' and jsonb_typeof(p_data -> 'is_active') <> 'boolean' then
    perform amine.err('INVALID_INPUT', 'is_active');
  end if;
  select coalesce(array_agg(distinct e.value), '{}') into v_services
  from jsonb_array_elements_text(p_data -> 'services') e
  where e.value in ('grocery', 'shop', 'health', 'restaurant', 'parcel');
  if p_id is null then
    insert into amine.zones (city_id, name_fr, name_ar, name_en, center_lat, center_lng, radius_km, base_fee, included_km,
      per_km_fee, max_fee, services, is_active, sort)
    values (v_city, amine.txt(p_data ->> 'name_fr', 'name_fr', 60, true, 2), amine.txt(p_data ->> 'name_ar', 'name_ar', 60, true),
      amine.txt(p_data ->> 'name_en', 'name_en', 60, true, 2), round(v_lat, 6), round(v_lng, 6), round(v_radius, 2),
      amine.int_in(p_data, 'base_fee', 0, 100000, true), round(v_included, 1), amine.int_in(p_data, 'per_km_fee', 0, 20000, true),
      amine.int_in(p_data, 'max_fee', 0, 200000, true), v_services, coalesce((p_data ->> 'is_active')::boolean, true),
      coalesce(amine.int_in(p_data, 'sort', 0, 1000, false), 0))
    returning * into z;
  else
    update amine.zones set city_id = v_city, name_fr = amine.txt(p_data ->> 'name_fr', 'name_fr', 60, true, 2),
      name_ar = amine.txt(p_data ->> 'name_ar', 'name_ar', 60, true), name_en = amine.txt(p_data ->> 'name_en', 'name_en', 60, true, 2),
      center_lat = round(v_lat, 6), center_lng = round(v_lng, 6), radius_km = round(v_radius, 2),
      base_fee = amine.int_in(p_data, 'base_fee', 0, 100000, true), included_km = round(v_included, 1),
      per_km_fee = amine.int_in(p_data, 'per_km_fee', 0, 20000, true), max_fee = amine.int_in(p_data, 'max_fee', 0, 200000, true),
      services = v_services, is_active = coalesce((p_data ->> 'is_active')::boolean, is_active),
      sort = coalesce(amine.int_in(p_data, 'sort', 0, 1000, false), sort)
    where id = p_id returning * into z;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
  end if;
  perform amine.audit('zone.saved', 'zone', z.id::text, to_jsonb(z));
  return to_jsonb(z);
end $$;

create or replace function public.admin_delete_zone(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  z amine.zones;
begin
  select * into z from amine.zones where id = p_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if exists (select 1 from amine.stores where zone_id = z.id) or exists (select 1 from amine.orders where zone_id = z.id)
     or exists (select 1 from amine.promotions where zone_id = z.id) then
    update amine.zones set is_active = false where id = z.id;
    perform amine.audit('zone.archived', 'zone', z.id::text, '{}'::jsonb);
    return jsonb_build_object('archived', true);
  end if;
  delete from amine.zones where id = z.id;
  perform amine.audit('zone.deleted', 'zone', z.id::text, to_jsonb(z));
  return jsonb_build_object('deleted', true);
end $$;

-- Codes promo ------------------------------------------------------------------------------------------
create or replace function amine.promotion_json(pr amine.promotions) returns jsonb
language sql stable set search_path = '' as $$
  select to_jsonb(pr) || jsonb_build_object(
    'uses', (select count(*) from amine.orders o where o.promo_code = pr.code and o.status not in ('cancelled', 'rejected')),
    'discount_total', (select coalesce(sum(o.discount), 0) from amine.orders o
      where o.promo_code = pr.code and o.status = 'delivered'),
    'zone', (select amine.zone_ref(z) from amine.zones z where z.id = pr.zone_id),
    'store', (select jsonb_build_object('id', s.id, 'name', s.name) from amine.stores s where s.id = pr.store_id))
$$;

create or replace function public.admin_promotions(p_archived boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  return coalesce((
    select jsonb_agg(amine.promotion_json(pr) order by pr.is_active desc, pr.created_at desc)
    from amine.promotions pr
    where (coalesce(p_archived, false) and pr.archived_at is not null) or (not coalesce(p_archived, false) and pr.archived_at is null)),
    '[]'::jsonb);
end $$;

-- Clés : code, description, kind (percent | amount | free_delivery), value, max_discount, min_subtotal,
-- zone_id, store_id, starts_at, ends_at, max_uses, max_uses_per_customer, first_order_only, is_public, is_active.
create or replace function public.admin_save_promotion(p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  pr amine.promotions;
  old amine.promotions;
  v_code text := upper(btrim(coalesce(p_data ->> 'code', '')));
  v_kind text := p_data ->> 'kind';
  v_value int;
  v_starts timestamptz := amine.ts_in(p_data, 'starts_at');
  v_ends timestamptz := amine.ts_in(p_data, 'ends_at');
  v_zone uuid := amine.uuid_in(p_data, 'zone_id');
  v_store uuid := amine.uuid_in(p_data, 'store_id');
  b text;
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  if v_code !~ '^[A-Z0-9]{3,20}$' then
    perform amine.err('INVALID_INPUT', 'code');
  end if;
  if v_kind is null or v_kind not in ('percent', 'amount', 'free_delivery') then
    perform amine.err('INVALID_INPUT', 'kind');
  end if;
  v_value := case when v_kind = 'free_delivery' then 0
    when v_kind = 'percent' then amine.int_in(p_data, 'value', 1, 100, true)
    else amine.int_in(p_data, 'value', 1, 100000000, true) end;
  if v_starts is not null and v_ends is not null and v_ends <= v_starts then
    perform amine.err('INVALID_INPUT', 'ends_at');
  end if;
  if v_zone is not null and not exists (select 1 from amine.zones where id = v_zone) then
    perform amine.err('INVALID_INPUT', 'zone_id');
  end if;
  if v_store is not null and not exists (select 1 from amine.stores where id = v_store) then
    perform amine.err('INVALID_INPUT', 'store_id');
  end if;
  foreach b in array array['first_order_only', 'is_public', 'is_active', 'auto_apply'] loop
    if p_data ? b and jsonb_typeof(p_data -> b) <> 'boolean' then
      perform amine.err('INVALID_INPUT', b);
    end if;
  end loop;
  if p_id is not null then
    select * into old from amine.promotions where id = p_id for update;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
    -- Le code d'une promotion déjà utilisée ne change plus (les commandes y font référence).
    if old.code <> v_code and exists (select 1 from amine.orders where promo_code = old.code) then
      perform amine.err('PROMO_CODE_LOCKED');
    end if;
  end if;
  begin
    if p_id is null then
      insert into amine.promotions (code, description, kind, value, max_discount, min_subtotal, zone_id, store_id,
        starts_at, ends_at, max_uses, max_uses_per_customer, first_order_only, is_public, is_active, auto_apply, created_by)
      values (v_code, amine.txt(p_data ->> 'description', 'description', 120), v_kind, v_value,
        amine.int_in(p_data, 'max_discount', 1, 100000000, false), coalesce(amine.int_in(p_data, 'min_subtotal', 0, 100000000, false), 0),
        v_zone, v_store, v_starts, v_ends, amine.int_in(p_data, 'max_uses', 1, 1000000, false),
        coalesce(amine.int_in(p_data, 'max_uses_per_customer', 1, 100, false), 1),
        coalesce((p_data ->> 'first_order_only')::boolean, false) or coalesce((p_data ->> 'auto_apply')::boolean, false),
        coalesce((p_data ->> 'is_public')::boolean, false),
        coalesce((p_data ->> 'is_active')::boolean, true), coalesce((p_data ->> 'auto_apply')::boolean, false), a.id)
      returning * into pr;
    else
      update amine.promotions set code = v_code, description = amine.txt(p_data ->> 'description', 'description', 120),
        kind = v_kind, value = v_value, max_discount = amine.int_in(p_data, 'max_discount', 1, 100000000, false),
        min_subtotal = coalesce(amine.int_in(p_data, 'min_subtotal', 0, 100000000, false), 0), zone_id = v_zone,
        store_id = v_store, starts_at = v_starts, ends_at = v_ends, max_uses = amine.int_in(p_data, 'max_uses', 1, 1000000, false),
        max_uses_per_customer = coalesce(amine.int_in(p_data, 'max_uses_per_customer', 1, 100, false), 1),
        -- Une offre automatique est toujours réservée à la première commande (offre de bienvenue).
        first_order_only = coalesce((p_data ->> 'first_order_only')::boolean, false) or coalesce((p_data ->> 'auto_apply')::boolean, false),
        auto_apply = coalesce((p_data ->> 'auto_apply')::boolean, false),
        is_public = coalesce((p_data ->> 'is_public')::boolean, false),
        is_active = coalesce((p_data ->> 'is_active')::boolean, true),
        archived_at = case when coalesce((p_data ->> 'is_active')::boolean, true) then null else archived_at end
      where id = p_id returning * into pr;
    end if;
  exception when unique_violation then
    perform amine.err('PROMO_CODE_EXISTS');
  end;
  perform amine.audit('promotion.saved', 'promotion', pr.id::text, jsonb_build_object('code', pr.code));
  return amine.promotion_json(pr);
end $$;

create or replace function public.admin_delete_promotion(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  pr amine.promotions;
begin
  select * into pr from amine.promotions where id = p_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if exists (select 1 from amine.orders where promo_code = pr.code) then
    update amine.promotions set is_active = false, is_public = false, archived_at = now() where id = pr.id;
    perform amine.audit('promotion.archived', 'promotion', pr.id::text, jsonb_build_object('code', pr.code));
    return jsonb_build_object('archived', true);
  end if;
  delete from amine.promotions where id = pr.id;
  perform amine.audit('promotion.deleted', 'promotion', pr.id::text, jsonb_build_object('code', pr.code));
  return jsonb_build_object('deleted', true);
end $$;

-- Réclamations ------------------------------------------------------------------------------------------
create or replace function amine.complaint_admin_json(c amine.complaints) returns jsonb
language sql stable set search_path = '' as $$
  select amine.complaint_json(c) || jsonb_build_object(
    'customer', (select jsonb_build_object('id', p.id, 'name', p.full_name, 'business_name', p.business_name,
      'phone', p.phone, 'email', p.email) from amine.profiles p where p.id = c.customer_id),
    'order', (select jsonb_build_object('code', o.code, 'status', o.status, 'total', o.total, 'placed_at', o.placed_at,
      'client', o.dropoff_name) from amine.orders o where o.id = c.order_id))
$$;

create or replace function public.admin_complaints(p_status text default null, p_query text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_q text := amine.txt(p_query, 'query', 60);
begin
  if p_status is not null and p_status not in ('open', 'in_progress', 'resolved', 'rejected', 'pending') then
    perform amine.err('INVALID_INPUT', 'status');
  end if;
  return jsonb_build_object(
    'counts', (select jsonb_build_object('open', count(*) filter (where status = 'open'),
        'in_progress', count(*) filter (where status = 'in_progress'), 'resolved', count(*) filter (where status = 'resolved'),
        'rejected', count(*) filter (where status = 'rejected')) from amine.complaints),
    'items', coalesce((
      select jsonb_agg(amine.complaint_admin_json(c) order by (c.status in ('open', 'in_progress')) desc, c.created_at desc)
      from amine.complaints c join amine.orders o on o.id = c.order_id
      where (p_status is null or c.status = p_status or (p_status = 'pending' and c.status in ('open', 'in_progress')))
        and (v_q is null or o.code ilike '%' || amine.like_escape(v_q) || '%'
             or amine.fold(o.dropoff_name) like '%' || amine.like_escape(amine.fold(v_q)) || '%')
      limit 300), '[]'::jsonb));
end $$;

create or replace function public.admin_update_complaint(p_id uuid, p_status text, p_reply text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  c amine.complaints;
  v_reply text := amine.txt(p_reply, 'reply', 1000, false, 1, true);
  v_code text;
begin
  if p_status is null or p_status not in ('open', 'in_progress', 'resolved', 'rejected') then
    perform amine.err('INVALID_INPUT', 'status');
  end if;
  if p_status in ('resolved', 'rejected') and v_reply is null then
    perform amine.err('REPLY_REQUIRED');
  end if;
  update amine.complaints set status = p_status, reply = v_reply, updated_at = now(),
    resolved_at = case when p_status in ('resolved', 'rejected') then coalesce(resolved_at, now()) else null end
  where id = p_id returning * into c;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  select code into v_code from amine.orders where id = c.order_id;
  perform amine.notify(c.customer_id, 'complaint_updated', jsonb_build_object('code', v_code, 'status', c.status),
    '#/orders/' || v_code);
  perform amine.audit('complaint.updated', 'complaint', c.id::text, jsonb_build_object('status', c.status));
  return amine.complaint_admin_json(c);
end $$;

create or replace function public.admin_delete_complaint(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  delete from amine.complaints where id = p_id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  perform amine.audit('complaint.deleted', 'complaint', p_id::text, '{}'::jsonb);
  return jsonb_build_object('deleted', true);
end $$;

-- Prospects : restaurants repérés dans OpenStreetMap (ou ajoutés à la main) à démarcher -----------------
create or replace function amine.prospect_json(pr amine.prospects) returns jsonb
language sql stable set search_path = '' as $$
  select to_jsonb(pr) || jsonb_build_object('zone', (select amine.zone_ref(z) from amine.zones z where z.id = pr.zone_id))
$$;

create or replace function public.admin_prospects(
  p_status text default null, p_zone_id uuid default null, p_query text default null, p_limit int default 100, p_offset int default 0
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_q text := amine.txt(p_query, 'query', 80);
begin
  if p_status is not null and p_status not in ('new', 'contacted', 'interested', 'refused', 'joined') then
    perform amine.err('INVALID_INPUT', 'status');
  end if;
  return (
    with base as (
      select pr.* from amine.prospects pr
      where (p_status is null or pr.status = p_status) and (p_zone_id is null or pr.zone_id = p_zone_id)
        and (v_q is null or amine.fold(pr.name) like '%' || amine.like_escape(amine.fold(v_q)) || '%'
             or amine.fold(coalesce(pr.cuisine, '')) like '%' || amine.like_escape(amine.fold(v_q)) || '%'
             or amine.fold(coalesce(pr.address, '')) like '%' || amine.like_escape(amine.fold(v_q)) || '%'
             or coalesce(pr.phone, '') like '%' || amine.like_escape(v_q) || '%')
    )
    select jsonb_build_object(
      'total', (select count(*) from base),
      'counts', (select jsonb_build_object('all', count(*), 'new', count(*) filter (where status = 'new'),
          'contacted', count(*) filter (where status = 'contacted'), 'interested', count(*) filter (where status = 'interested'),
          'refused', count(*) filter (where status = 'refused'), 'joined', count(*) filter (where status = 'joined'))
        from amine.prospects),
      'items', coalesce((select jsonb_agg(amine.prospect_json(x) order by x.name)
        from (select * from base order by name
              limit least(greatest(coalesce(p_limit, 100), 1), 500) offset greatest(coalesce(p_offset, 0), 0)) x), '[]'::jsonb)));
end $$;

-- Import depuis OpenStreetMap (Overpass) : met à jour les fiches existantes sans toucher au suivi
-- commercial (statut, note). p_rows : [{osm_id, name, name_ar, amenity, cuisine, address, phone, website,
-- opening_hours, lat, lng}]
create or replace function public.admin_import_prospects(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  r jsonb;
  v_lat numeric;
  v_lng numeric;
  v_created int := 0;
  v_updated int := 0;
  v_skipped int := 0;
  v_new boolean;
begin
  perform amine.hit('prospects_import:' || a.id, 30, 3600);
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    perform amine.err('INVALID_INPUT', 'rows');
  end if;
  if jsonb_array_length(p_rows) > 3000 then
    perform amine.err('IMPORT_TOO_LARGE');
  end if;
  for r in select e.value from jsonb_array_elements(p_rows) e loop
    begin
      if jsonb_typeof(r) <> 'object' or coalesce(r ->> 'osm_id', '') !~ '^(node|way|relation)/[0-9]{1,15}$'
         or coalesce(r ->> 'amenity', '') not in ('restaurant', 'fast_food', 'cafe')
         or nullif(btrim(regexp_replace(coalesce(r ->> 'name', ''), '[[:cntrl:]]', ' ', 'g')), '') is null then
        v_skipped := v_skipped + 1;
        continue;
      end if;
      v_lat := (r ->> 'lat')::numeric;
      v_lng := (r ->> 'lng')::numeric;
      if v_lat is null or v_lng is null or v_lat < 30 or v_lat > 38.5 or v_lng < 7 or v_lng > 12 then
        v_skipped := v_skipped + 1;
        continue;
      end if;
    exception when others then
      v_skipped := v_skipped + 1;
      continue;
    end;
    insert into amine.prospects as x (osm_id, source, name, name_ar, amenity, cuisine, address, phone, website,
      opening_hours, lat, lng, zone_id)
    values (r ->> 'osm_id', 'osm',
      left(btrim(regexp_replace(r ->> 'name', '[[:cntrl:]]', ' ', 'g')), 120),
      nullif(left(btrim(regexp_replace(coalesce(r ->> 'name_ar', ''), '[[:cntrl:]]', ' ', 'g')), 120), ''),
      r ->> 'amenity',
      nullif(left(btrim(regexp_replace(coalesce(r ->> 'cuisine', ''), '[[:cntrl:]]', ' ', 'g')), 120), ''),
      nullif(left(btrim(regexp_replace(coalesce(r ->> 'address', ''), '[[:cntrl:]]', ' ', 'g')), 200), ''),
      nullif(left(btrim(regexp_replace(coalesce(r ->> 'phone', ''), '[[:cntrl:]]', ' ', 'g')), 40), ''),
      case when coalesce(r ->> 'website', '') ~ '^https?://[^[:space:]"''<>\\]{3,}$' and char_length(r ->> 'website') <= 300
        then r ->> 'website' end,
      nullif(left(btrim(regexp_replace(coalesce(r ->> 'opening_hours', ''), '[[:cntrl:]]', ' ', 'g')), 200), ''),
      round(v_lat, 6), round(v_lng, 6), (amine.zone_for(v_lat, v_lng)).id)
    on conflict (osm_id) do update set name = excluded.name, name_ar = excluded.name_ar, amenity = excluded.amenity,
      cuisine = excluded.cuisine, address = coalesce(excluded.address, x.address), phone = coalesce(excluded.phone, x.phone),
      website = coalesce(excluded.website, x.website), opening_hours = excluded.opening_hours,
      lat = excluded.lat, lng = excluded.lng, zone_id = excluded.zone_id, updated_at = now()
    returning (xmax = 0) into v_new;
    if v_new then
      v_created := v_created + 1;
    else
      v_updated := v_updated + 1;
    end if;
  end loop;
  perform amine.audit('prospects.imported', 'prospect', null,
    jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped));
  return jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped);
end $$;

-- Clés : name, name_ar, amenity, cuisine, address, phone, email, website, contact_name, opening_hours,
-- status, note, lat, lng (facultatifs, ensemble).
create or replace function public.admin_save_prospect(p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  pr amine.prospects;
  v_status text := coalesce(nullif(p_data ->> 'status', ''), 'new');
  v_amenity text := coalesce(nullif(p_data ->> 'amenity', ''), 'restaurant');
  v_email text := amine.txt(p_data ->> 'email', 'email', 160);
  v_web text := amine.txt(p_data ->> 'website', 'website', 300);
  v_lat numeric;
  v_lng numeric;
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  if v_status not in ('new', 'contacted', 'interested', 'refused', 'joined') then
    perform amine.err('INVALID_INPUT', 'status');
  end if;
  if v_amenity not in ('restaurant', 'fast_food', 'cafe') then
    perform amine.err('INVALID_INPUT', 'amenity');
  end if;
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    perform amine.err('INVALID_INPUT', 'email');
  end if;
  if v_web is not null and v_web !~ '^https?://[^[:space:]"''<>\\]+$' then
    perform amine.err('INVALID_INPUT', 'website');
  end if;
  if nullif(p_data ->> 'lat', '') is not null or nullif(p_data ->> 'lng', '') is not null then
    begin
      v_lat := (p_data ->> 'lat')::numeric;
      v_lng := (p_data ->> 'lng')::numeric;
    exception when others then
      perform amine.err('INVALID_LOCATION');
    end;
    perform amine.check_point(v_lat, v_lng);
  end if;
  if p_id is null then
    insert into amine.prospects (source, name, name_ar, amenity, cuisine, address, phone, email, website, contact_name,
      opening_hours, status, note, lat, lng, zone_id, contacted_at)
    values ('manual', amine.txt(p_data ->> 'name', 'name', 120, true), amine.txt(p_data ->> 'name_ar', 'name_ar', 120),
      v_amenity, amine.txt(p_data ->> 'cuisine', 'cuisine', 120), amine.txt(p_data ->> 'address', 'address', 200),
      amine.txt(p_data ->> 'phone', 'phone', 40), v_email, v_web, amine.txt(p_data ->> 'contact_name', 'contact_name', 120),
      amine.txt(p_data ->> 'opening_hours', 'opening_hours', 200), v_status,
      amine.txt(p_data ->> 'note', 'note', 500, false, 1, true), round(v_lat, 6), round(v_lng, 6),
      case when v_lat is not null then (amine.zone_for(v_lat, v_lng)).id end,
      case when v_status <> 'new' then now() end)
    returning * into pr;
  else
    update amine.prospects set name = amine.txt(p_data ->> 'name', 'name', 120, true),
      name_ar = amine.txt(p_data ->> 'name_ar', 'name_ar', 120), amenity = v_amenity,
      cuisine = amine.txt(p_data ->> 'cuisine', 'cuisine', 120), address = amine.txt(p_data ->> 'address', 'address', 200),
      phone = amine.txt(p_data ->> 'phone', 'phone', 40), email = v_email, website = v_web,
      contact_name = amine.txt(p_data ->> 'contact_name', 'contact_name', 120),
      opening_hours = amine.txt(p_data ->> 'opening_hours', 'opening_hours', 200), status = v_status,
      note = amine.txt(p_data ->> 'note', 'note', 500, false, 1, true),
      lat = coalesce(round(v_lat, 6), lat), lng = coalesce(round(v_lng, 6), lng),
      zone_id = case when v_lat is not null then (amine.zone_for(v_lat, v_lng)).id else zone_id end,
      contacted_at = case when v_status <> 'new' then coalesce(contacted_at, now()) else contacted_at end,
      updated_at = now()
    where id = p_id returning * into pr;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
  end if;
  perform amine.audit('prospect.saved', 'prospect', pr.id::text, jsonb_build_object('status', pr.status));
  return amine.prospect_json(pr);
end $$;

create or replace function public.admin_delete_prospect(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  delete from amine.prospects where id = p_id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  perform amine.audit('prospect.deleted', 'prospect', p_id::text, '{}'::jsonb);
  return jsonb_build_object('deleted', true);
end $$;

-- Paramètres --------------------------------------------------------------------------------------------
create or replace function public.admin_settings() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  return jsonb_build_object('platform', amine.setting('platform'), 'orders', amine.setting('orders'),
    'parcel', amine.setting('parcel'), 'couriers', amine.setting('couriers'), 'auth', amine.setting('auth'),
    'legal', amine.setting('legal'), 'invoicing', amine.setting('invoicing'), 'push', amine.setting('push'),
    'loyalty', amine.setting('loyalty'),
    'push_status', jsonb_build_object(
      'pg_net', exists (select 1 from pg_extension where extname = 'pg_net'),
      'keys', exists (select 1 from amine.push_keys where id = 1 and public_key is not null),
      'subscriptions', (select count(*) from amine.push_subscriptions),
      'queued', (select count(*) from amine.push_queue where attempts < 5),
      'failed', (select count(*) from amine.push_queue where attempts >= 5)),
    'mfa', jsonb_build_object('me', amine.has_mfa(a.id), 'admins_without', (select count(*) from amine.profiles p
      where p.is_admin and p.status = 'active' and not amine.has_mfa(p.id))));
end $$;

create or replace function public.admin_update_setting(p_key text, p_value jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v jsonb;
  v_email text;
begin
  if p_value is null or jsonb_typeof(p_value) <> 'object' then
    perform amine.err('INVALID_INPUT', 'value');
  end if;
  if p_key = 'platform' then
    v_email := amine.txt(p_value ->> 'support_email', 'support_email', 120);
    if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      perform amine.err('INVALID_INPUT', 'support_email');
    end if;
    v := jsonb_build_object('name', amine.txt(p_value ->> 'name', 'name', 40, true, 2),
      'support_phone', coalesce(amine.phone_in(p_value ->> 'support_phone', 'support_phone'), ''),
      'support_email', coalesce(v_email, ''),
      'maintenance', amine.bool_in(p_value, 'maintenance'),
      'announcement', coalesce(amine.txt(p_value ->> 'announcement', 'announcement', 200), ''));
  elsif p_key = 'orders' then
    v := jsonb_build_object('auto_cancel_minutes', amine.int_in(p_value, 'auto_cancel_minutes', 5, 240, true),
      'max_active_per_customer', amine.int_in(p_value, 'max_active_per_customer', 1, 20, true),
      'service_fee', amine.int_in(p_value, 'service_fee', 0, 50000, true),
      'max_distance_km', amine.int_in(p_value, 'max_distance_km', 1, 100, true),
      'recurring_hour', coalesce(amine.int_in(p_value, 'recurring_hour', 6, 22, false),
        (amine.setting('orders') ->> 'recurring_hour')::int),
      'require_pod', case when p_value ? 'require_pod' then amine.bool_in(p_value, 'require_pod')
        else coalesce((amine.setting('orders') ->> 'require_pod')::boolean, false) end);
  elsif p_key = 'invoicing' then
    if coalesce(p_value ->> 'prefix', '') !~ '^[A-Z]{1,6}$' or coalesce(p_value ->> 'credit_prefix', '') !~ '^[A-Z]{1,6}$'
       or p_value ->> 'prefix' = p_value ->> 'credit_prefix' or 'BC' in (p_value ->> 'prefix', p_value ->> 'credit_prefix') then
      perform amine.err('INVALID_INPUT', 'prefix');
    end if;
    v := jsonb_build_object('prefix', p_value ->> 'prefix', 'credit_prefix', p_value ->> 'credit_prefix',
      'stamp', amine.int_in(p_value, 'stamp', 0, 100000, true),
      'delivery_vat_rate', amine.vat_in(p_value, 'delivery_vat_rate'),
      'reminder_days', amine.int_in(p_value, 'reminder_days', 1, 60, true),
      'vat_verified', amine.bool_in(p_value, 'vat_verified'),
      'footer', coalesce(amine.txt(p_value ->> 'footer', 'footer', 300, false, 1, true), ''));
  elsif p_key = 'parcel' then
    if jsonb_typeof(p_value -> 'size_fee') <> 'object' then
      perform amine.err('INVALID_INPUT', 'size_fee');
    end if;
    v := jsonb_build_object('enabled', amine.bool_in(p_value, 'enabled'), 'size_fee', jsonb_build_object(
      'small', amine.int_in(p_value -> 'size_fee', 'small', 0, 100000, true),
      'medium', amine.int_in(p_value -> 'size_fee', 'medium', 0, 100000, true),
      'large', amine.int_in(p_value -> 'size_fee', 'large', 0, 100000, true)));
  elsif p_key = 'couriers' then
    v := jsonb_build_object('share_bps', amine.int_in(p_value, 'share_bps', 0, 10000, true),
      'max_active_jobs', amine.int_in(p_value, 'max_active_jobs', 1, 5, true));
  elsif p_key = 'auth' then
    v := jsonb_build_object('require_phone_verification', amine.bool_in(p_value, 'require_phone_verification'),
      'admin_mfa_required', case when p_value ? 'admin_mfa_required' then amine.bool_in(p_value, 'admin_mfa_required')
        else coalesce((amine.setting('auth') ->> 'admin_mfa_required')::boolean, false) end);
    -- L'administrateur qui impose la double authentification doit l'avoir activée lui-même.
    if (v ->> 'admin_mfa_required')::boolean and not (amine.has_mfa(a.id) and coalesce(auth.jwt() ->> 'aal', '') = 'aal2') then
      perform amine.err('MFA_SETUP_REQUIRED');
    end if;
  elsif p_key = 'push' then
    v := jsonb_build_object('enabled', amine.bool_in(p_value, 'enabled'),
      'function_url', coalesce(btrim(p_value ->> 'function_url'), ''));
    -- Adresse d'une fonction Supabase (Edge Function) uniquement : la base n'appelle rien d'autre.
    if v ->> 'function_url' <> ''
       and v ->> 'function_url' !~ '^https://[a-z0-9-]{3,63}\.supabase\.co/functions/v1/[A-Za-z0-9_-]{1,60}$' then
      perform amine.err('INVALID_INPUT', 'function_url');
    end if;
    if (v ->> 'enabled')::boolean and v ->> 'function_url' = '' then
      perform amine.err('INVALID_INPUT', 'function_url');
    end if;
  elsif p_key = 'loyalty' then
    v := jsonb_build_object('enabled', coalesce(amine.bool_in(p_value, 'enabled'), (amine.setting('loyalty') ->> 'enabled')::boolean),
      'earn_per_dt', amine.int_in(p_value, 'earn_per_dt', 0, 100, true),
      'point_value', amine.int_in(p_value, 'point_value', 1, 1000, true),
      'min_redeem', amine.int_in(p_value, 'min_redeem', 1, 1000000, true),
      'max_redeem_bps', amine.int_in(p_value, 'max_redeem_bps', 0, 10000, true),
      'referral_enabled', coalesce(amine.bool_in(p_value, 'referral_enabled'), (amine.setting('loyalty') ->> 'referral_enabled')::boolean),
      'referral_points', amine.int_in(p_value, 'referral_points', 0, 1000000, true),
      'referral_min_subtotal', amine.int_in(p_value, 'referral_min_subtotal', 0, 100000000, true),
      'referral_max', amine.int_in(p_value, 'referral_max', 1, 1000, true),
      'remind_enabled', coalesce(amine.bool_in(p_value, 'remind_enabled'), (amine.setting('loyalty') ->> 'remind_enabled')::boolean),
      'remind_days', amine.int_in(p_value, 'remind_days', 7, 180, true));
  elsif p_key = 'legal' then
    v := jsonb_build_object(
      'company_name', coalesce(amine.txt(p_value ->> 'company_name', 'company_name', 120), ''),
      'legal_form', coalesce(amine.txt(p_value ->> 'legal_form', 'legal_form', 60), ''),
      'rne', coalesce(amine.txt(p_value ->> 'rne', 'rne', 40), ''),
      'tax_id', coalesce(amine.txt(p_value ->> 'tax_id', 'tax_id', 40), ''),
      'address', coalesce(amine.txt(p_value ->> 'address', 'address', 200), ''),
      'email', coalesce(amine.txt(p_value ->> 'email', 'email', 120), ''),
      'phone', coalesce(amine.txt(p_value ->> 'phone', 'phone', 30), ''),
      'director', coalesce(amine.txt(p_value ->> 'director', 'director', 120), ''),
      'host', coalesce(amine.txt(p_value ->> 'host', 'host', 300), ''),
      'reviewed', amine.bool_in(p_value, 'reviewed'));
  else
    perform amine.err('INVALID_INPUT', 'key');
  end if;
  insert into amine.settings (key, value, updated_at, updated_by) values (p_key, v, now(), a.id)
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = a.id;
  perform amine.audit('settings.' || p_key, 'settings', p_key, v);
  return v;
end $$;

-- Finances (commandes livrées sur une période, jours de Tunis inclus) ------------------------------------
create or replace function public.admin_finance(p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_from timestamptz;
  v_to timestamptz;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    perform amine.err('INVALID_INPUT', 'period');
  end if;
  v_from := p_from::timestamp at time zone 'Africa/Tunis';
  v_to := (p_to + 1)::timestamp at time zone 'Africa/Tunis';
  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'totals', (select jsonb_build_object('orders', count(*), 'gmv', coalesce(sum(o.total), 0),
        'subtotal', coalesce(sum(o.subtotal), 0), 'delivery_fees', coalesce(sum(o.delivery_fee), 0),
        'service_fees', coalesce(sum(o.service_fee), 0), 'discounts', coalesce(sum(o.discount), 0),
        'commission', coalesce(sum(o.commission), 0),
        'courier_earnings', coalesce(sum(o.courier_earning), 0), 'cod_collected', coalesce(sum(o.cod_collected), 0),
        'cod_gap', coalesce(sum(o.cod_collected - o.total) filter (where o.cod_collected is not null), 0))
      from amine.orders o where o.status = 'delivered' and o.delivered_at >= v_from and o.delivered_at < v_to),
    'by_store', coalesce((
      select jsonb_agg(jsonb_build_object('store_id', t.store_id, 'name', t.name, 'orders', t.orders, 'subtotal', t.subtotal,
        'discounts', t.discounts, 'commission', t.commission, 'net_due', t.subtotal - t.commission) order by t.subtotal desc)
      from (select o.store_id, s.name, count(*) as orders, sum(o.subtotal) as subtotal, sum(o.discount) as discounts,
              sum(o.commission) as commission
            from amine.orders o join amine.stores s on s.id = o.store_id
            where o.status = 'delivered' and o.delivered_at >= v_from and o.delivered_at < v_to
            group by o.store_id, s.name) t), '[]'::jsonb),
    'by_courier', coalesce((
      select jsonb_agg(jsonb_build_object('courier_id', t.courier_id, 'name', t.name, 'deliveries', t.deliveries,
        'delivery_fees', t.delivery_fees, 'earnings', t.earnings, 'cod_collected', t.cod) order by t.deliveries desc)
      from (select o.courier_id, p.full_name as name, count(*) as deliveries, sum(o.delivery_fee) as delivery_fees,
              sum(o.courier_earning) as earnings, coalesce(sum(o.cod_collected), 0) as cod
            from amine.orders o join amine.profiles p on p.id = o.courier_id
            where o.status = 'delivered' and o.delivered_at >= v_from and o.delivered_at < v_to
            group by o.courier_id, p.full_name) t), '[]'::jsonb),
    -- Espèces encore entre les mains des livreurs (aujourd'hui, quelle que soit la période).
    'cash_in_hand', (select coalesce(sum((amine.courier_cash_json(c) ->> 'in_hand')::bigint), 0) from amine.couriers c));
end $$;

create or replace function public.admin_audit(p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', l.id, 'action', l.action, 'entity', l.entity, 'entity_id', l.entity_id,
        'details', l.details, 'created_at', l.created_at, 'actor', p.full_name) order by l.id desc)
    from (select * from amine.audit_log order by id desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) l
    left join amine.profiles p on p.id = l.actor_id), '[]'::jsonb);
end $$;

-- Désigner le premier administrateur : à exécuter dans SQL Editor (jamais accessible par l'API).
--   select amine.grant_admin('vous@exemple.com');
create or replace function amine.grant_admin(p_email text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  select id into v_id from amine.profiles where lower(email) = lower(btrim(p_email));
  if v_id is null then
    select u.id into v_id from auth.users u where lower(u.email) = lower(btrim(p_email));
    if v_id is null then
      return 'Aucun compte avec cet e-mail. Créez d''abord le compte dans l''application.';
    end if;
    insert into amine.profiles (id, email) values (v_id, lower(btrim(p_email))) on conflict (id) do nothing;
  end if;
  update amine.profiles set is_admin = true, status = 'active', updated_at = now() where id = v_id;
  insert into amine.audit_log (actor_id, action, entity, entity_id) values (null, 'user.granted_admin', 'profile', v_id::text);
  return 'OK : ' || p_email || ' est administrateur.';
end $$;

-- =============================================================================================
--  Vente aux professionnels (version 3) : factures et avoirs, compte client (paiement à terme,
--  règlements, relances), prix négociés, commandes récurrentes, pesée réelle, achats et stock,
--  tournées de livraison.
--
--  Les factures sont des documents de gestion produits par AMINE. Depuis 2026, la facture
--  électronique transmise par Tunisie TradeNet (TTN) avec signature électronique est obligatoire
--  pour les entreprises assujetties à la TVA : l'export des factures sert à les reprendre dans le
--  logiciel qui les transmet. Les taux de TVA et le droit de timbre sont des paramètres à faire
--  valider par l'expert-comptable.
-- =============================================================================================

-- ── Factures ──────────────────────────────────────────────────────────────────────────────────
-- Numéro suivant, sans trou : la ligne du compteur reste verrouillée jusqu'à la fin de la transaction
-- (une émission annulée n'utilise pas de numéro).
create or replace function amine.next_invoice_number(p_prefix text) returns text
language plpgsql set search_path = '' as $$
declare
  v_year int := extract(year from now() at time zone 'Africa/Tunis')::int;
  v_n int;
begin
  insert into amine.invoice_counters as c (prefix, year, last) values (p_prefix, v_year, 1)
  on conflict (prefix, year) do update set last = c.last + 1
  returning c.last into v_n;
  return p_prefix || '-' || v_year::text || '-' || lpad(v_n::text, 5, '0');
end $$;

create or replace function amine.seller_json() returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'name', coalesce(nullif(x.l ->> 'company_name', ''), nullif(x.pl ->> 'name', ''), 'AMINE'),
    'legal_form', nullif(x.l ->> 'legal_form', ''), 'rne', nullif(x.l ->> 'rne', ''),
    'tax_id', nullif(x.l ->> 'tax_id', ''), 'address', nullif(x.l ->> 'address', ''),
    'phone', nullif(x.l ->> 'phone', ''), 'email', nullif(x.l ->> 'email', ''))
  from (select amine.setting('legal') as l, amine.setting('platform') as pl) x
$$;

-- Lignes d'une facture : produits (quantité réellement livrée), livraison, frais de service.
-- La remise est répartie au prorata (sur la livraison d'abord pour un code « livraison offerte »).
-- Les prix étant TTC, le HT et la TVA de chaque ligne en sont déduits (arrondis au millime).
create or replace function amine.order_invoice_lines(o amine.orders) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_fee_rate int := coalesce((amine.setting('invoicing') ->> 'delivery_vat_rate')::int, 19);
  v_kinds text[] := '{}';
  v_names text[] := '{}';
  v_units text[] := '{}';
  v_qtys numeric[] := '{}';
  v_prices int[] := '{}';
  v_rates int[] := '{}';
  v_ttcs bigint[] := '{}';
  v_allocs bigint[] := '{}';
  v_n int := 0;
  v_left bigint := greatest(o.discount, 0);
  v_free boolean := false;
  v_base bigint;
  v_share bigint;
  v_pass text;
  v_lines jsonb := '[]'::jsonb;
  v_net bigint;
  v_ht bigint;
  rec record;
  i int;
begin
  for rec in
    select it.name, it.unit, coalesce(it.actual_qty, it.quantity) as qty, it.unit_price, it.vat_rate, it.total
    from amine.order_items it where it.order_id = o.id and it.total > 0 order by it.name, it.id
  loop
    v_n := v_n + 1;
    v_kinds[v_n] := 'product'; v_names[v_n] := rec.name; v_units[v_n] := rec.unit; v_qtys[v_n] := rec.qty;
    v_prices[v_n] := rec.unit_price; v_rates[v_n] := rec.vat_rate; v_ttcs[v_n] := rec.total; v_allocs[v_n] := 0;
  end loop;
  if o.delivery_fee > 0 then
    v_n := v_n + 1;
    v_kinds[v_n] := 'delivery'; v_names[v_n] := null; v_units[v_n] := null; v_qtys[v_n] := 1;
    v_prices[v_n] := o.delivery_fee; v_rates[v_n] := v_fee_rate; v_ttcs[v_n] := o.delivery_fee; v_allocs[v_n] := 0;
  end if;
  if o.service_fee > 0 then
    v_n := v_n + 1;
    v_kinds[v_n] := 'service'; v_names[v_n] := null; v_units[v_n] := null; v_qtys[v_n] := 1;
    v_prices[v_n] := o.service_fee; v_rates[v_n] := 19; v_ttcs[v_n] := o.service_fee; v_allocs[v_n] := 0;
  end if;

  if o.promo_code is not null then
    select pr.kind = 'free_delivery' into v_free from amine.promotions pr where pr.code = o.promo_code;
  end if;
  if coalesce(v_free, false) then
    for i in 1..v_n loop
      if v_kinds[i] = 'delivery' and v_left > 0 then
        v_share := least(v_left, v_ttcs[i]);
        v_allocs[i] := v_allocs[i] + v_share;
        v_left := v_left - v_share;
      end if;
    end loop;
  end if;
  foreach v_pass in array array['product', 'other'] loop
    exit when v_left <= 0;
    v_base := 0;
    for i in 1..v_n loop
      if (v_pass = 'product') = (v_kinds[i] = 'product') then
        v_base := v_base + v_ttcs[i] - v_allocs[i];
      end if;
    end loop;
    continue when v_base <= 0;
    v_share := least(v_left, v_base);
    -- Part proportionnelle (arrondie vers le bas), puis le reste millime par millime.
    for i in 1..v_n loop
      if (v_pass = 'product') = (v_kinds[i] = 'product') then
        v_allocs[i] := v_allocs[i] + floor(v_share::numeric * (v_ttcs[i] - v_allocs[i]) / v_base)::bigint;
      end if;
    end loop;
    v_left := greatest(o.discount, 0);
    for i in 1..v_n loop
      v_left := v_left - v_allocs[i];
    end loop;
    for i in 1..v_n loop
      exit when v_left <= 0;
      if (v_pass = 'product') = (v_kinds[i] = 'product') and v_ttcs[i] > v_allocs[i] then
        v_share := least(v_left, v_ttcs[i] - v_allocs[i]);
        v_allocs[i] := v_allocs[i] + v_share;
        v_left := v_left - v_share;
      end if;
    end loop;
  end loop;

  for i in 1..v_n loop
    v_net := v_ttcs[i] - v_allocs[i];
    v_ht := round(v_net::numeric * 100 / (100 + v_rates[i]))::bigint;
    v_lines := v_lines || jsonb_build_object('kind', v_kinds[i], 'name', v_names[i], 'unit', v_units[i],
      'qty', v_qtys[i], 'unit_price', v_prices[i],
      'unit_price_ht', round(v_prices[i]::numeric * 100 / (100 + v_rates[i]))::bigint,
      'vat_rate', v_rates[i], 'discount', v_allocs[i], 'total_ttc', v_net, 'total_ht', v_ht, 'total_vat', v_net - v_ht);
  end loop;
  return v_lines;
end $$;

create or replace function amine.invoice_vat(p_lines jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('rate', x.rate, 'base', x.base, 'amount', x.amount) order by x.rate), '[]'::jsonb)
  from (select (l.value ->> 'vat_rate')::int as rate, sum((l.value ->> 'total_ht')::bigint) as base,
          sum((l.value ->> 'total_vat')::bigint) as amount
        from jsonb_array_elements(p_lines) l group by 1) x
$$;

create or replace function amine.invoice_json(i amine.invoices) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', i.id, 'number', i.number, 'kind', i.kind, 'issued_at', i.issued_at, 'due_on', i.due_on,
    'seller', i.seller, 'buyer', i.buyer, 'lines', i.lines, 'vat', i.vat, 'total_ht', i.total_ht,
    'total_vat', i.total_vat, 'stamp', i.stamp, 'total_ttc', i.total_ttc, 'payment_method', i.payment_method,
    'reason', i.reason, 'customer_id', i.customer_id,
    'order_code', (select o.code from amine.orders o where o.id = i.order_id),
    'delivered_at', (select o.delivered_at from amine.orders o where o.id = i.order_id),
    'original', (select jsonb_build_object('id', x.id, 'number', x.number) from amine.invoices x where x.id = i.invoice_id),
    'credit_notes', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'number', x.number, 'total_ttc', x.total_ttc)
        order by x.issued_at), '[]'::jsonb) from amine.invoices x where x.invoice_id = i.id),
    'footer', nullif(amine.setting('invoicing') ->> 'footer', ''),
    'vat_verified', coalesce((amine.setting('invoicing') ->> 'vat_verified')::boolean, false))
$$;

-- Facture d'une commande livrée (une seule par commande).
create or replace function amine.issue_invoice(o amine.orders) returns amine.invoices
language plpgsql set search_path = '' as $$
declare
  v_set jsonb := amine.setting('invoicing');
  v_today date := (now() at time zone 'Africa/Tunis')::date;
  cu amine.profiles;
  v_lines jsonb;
  v_ht bigint;
  v_vat bigint;
  inv amine.invoices;
begin
  select * into inv from amine.invoices where order_id = o.id and kind = 'invoice';
  if found then
    return inv;
  end if;
  select * into cu from amine.profiles where id = o.customer_id;
  v_lines := amine.order_invoice_lines(o);
  select coalesce(sum((l.value ->> 'total_ht')::bigint), 0), coalesce(sum((l.value ->> 'total_vat')::bigint), 0)
  into v_ht, v_vat from jsonb_array_elements(v_lines) l;
  insert into amine.invoices (number, kind, order_id, customer_id, store_id, due_on, seller, buyer, lines, vat,
    total_ht, total_vat, stamp, total_ttc, payment_method, created_by)
  values (amine.next_invoice_number(coalesce(nullif(v_set ->> 'prefix', ''), 'FA')), 'invoice', o.id, o.customer_id,
    o.store_id,
    case when o.payment_method = 'account' then v_today + coalesce(cu.payment_days, 30) else v_today end,
    amine.seller_json(),
    jsonb_build_object('name', coalesce(cu.business_name, o.dropoff_name), 'contact', nullif(cu.full_name, ''),
      'tax_id', cu.tax_id, 'address', o.dropoff_address, 'phone', o.dropoff_phone, 'email', cu.email),
    v_lines, amine.invoice_vat(v_lines), v_ht, v_vat, o.stamp_fee, v_ht + v_vat + o.stamp_fee, o.payment_method,
    auth.uid())
  returning * into inv;
  return inv;
end $$;

-- À la livraison : facture, montant dû au compte du client, et encaissement en espèces s'il y en a eu.
create or replace function amine.after_delivery(o amine.orders) returns void
language plpgsql set search_path = '' as $$
declare
  inv amine.invoices := amine.issue_invoice(o);
begin
  if o.customer_id is null then
    return;
  end if;
  if inv.total_ttc > 0 then
    insert into amine.account_entries (customer_id, kind, amount, invoice_id, reference, created_by)
    values (o.customer_id, 'invoice', inv.total_ttc, inv.id, inv.number, auth.uid());
  end if;
  if o.payment_method = 'cod' and coalesce(o.cod_collected, 0) > 0 then
    insert into amine.account_entries (customer_id, kind, amount, invoice_id, method, reference, note, created_by)
    values (o.customer_id, 'payment', -o.cod_collected, inv.id, 'cash', o.code, 'cod', auth.uid());
  end if;
  perform amine.notify(o.customer_id, 'invoice_issued',
    jsonb_build_object('number', inv.number, 'total', inv.total_ttc, 'due_on', inv.due_on, 'code', o.code),
    '#/account/invoices/' || inv.id::text);
end $$;

-- État de paiement des factures d'un client : règlements et avoirs soldent les factures dans l'ordre
-- de leur émission.
create or replace function amine.invoice_states(p_customer uuid)
returns table (invoice_id uuid, paid bigint)
language sql stable set search_path = '' as $$
  with credits as (
    select coalesce(-sum(e.amount), 0)::bigint as total
    from amine.account_entries e where e.customer_id = p_customer and e.amount < 0),
  inv as (
    select i.id, i.total_ttc::bigint as ttc,
      sum(i.total_ttc::bigint) over (order by i.issued_at, i.number rows between unbounded preceding and current row) as cum
    from amine.invoices i where i.customer_id = p_customer and i.kind = 'invoice')
  select inv.id, least(inv.ttc, greatest(0, c.total - (inv.cum - inv.ttc)))::bigint
  from inv cross join credits c
$$;

create or replace function amine.invoice_status(p_kind text, p_ttc bigint, p_paid bigint, p_due date) returns text
language sql stable set search_path = '' as $$
  select case
    when p_kind = 'credit_note' then 'credit_note'
    when p_paid >= p_ttc then 'paid'
    when p_due is not null and p_due < (now() at time zone 'Africa/Tunis')::date then 'overdue'
    when p_paid > 0 then 'partial'
    else 'unpaid' end
$$;

-- Relevé de compte d'un client : soldes, factures avec leur état, écritures avec solde progressif.
create or replace function amine.account_json(p_customer uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  cu amine.profiles;
  v_today date := (now() at time zone 'Africa/Tunis')::date;
  v_exposure bigint := amine.account_exposure(p_customer);
begin
  select * into cu from amine.profiles where id = p_customer;
  return jsonb_build_object(
    'balance', amine.account_balance(p_customer), 'exposure', v_exposure,
    'payment_terms', cu.payment_terms, 'payment_days', cu.payment_days, 'credit_limit', cu.credit_limit,
    'discount_bps', cu.discount_bps,
    'available', case when cu.payment_terms = 'account' then greatest(0, cu.credit_limit - v_exposure) end,
    'due', (select coalesce(sum(i.total_ttc - s.paid), 0) from amine.invoices i
      join amine.invoice_states(p_customer) s on s.invoice_id = i.id where s.paid < i.total_ttc),
    'overdue', (select coalesce(sum(i.total_ttc - s.paid), 0) from amine.invoices i
      join amine.invoice_states(p_customer) s on s.invoice_id = i.id where s.paid < i.total_ttc and i.due_on < v_today),
    'invoices', coalesce((
      select jsonb_agg(x.j order by x.issued_at desc) from (
        select i.issued_at, jsonb_build_object('id', i.id, 'number', i.number, 'kind', i.kind, 'issued_at', i.issued_at,
            'due_on', i.due_on, 'total_ttc', i.total_ttc, 'payment_method', i.payment_method,
            'paid', coalesce(s.paid, 0),
            'status', amine.invoice_status(i.kind, i.total_ttc, coalesce(s.paid, 0), i.due_on),
            'order_code', (select o.code from amine.orders o where o.id = i.order_id)) as j
        from amine.invoices i left join amine.invoice_states(p_customer) s on s.invoice_id = i.id
        where i.customer_id = p_customer order by i.issued_at desc limit 300) x), '[]'::jsonb),
    'entries', coalesce((
      select jsonb_agg(y.j order by y.occurred_on desc, y.id desc) from (
        select x.* from (
          select e.id, e.occurred_on, jsonb_build_object('id', e.id, 'kind', e.kind, 'amount', e.amount, 'method', e.method,
              'reference', e.reference, 'note', e.note, 'occurred_on', e.occurred_on, 'created_at', e.created_at,
              'invoice_id', e.invoice_id,
              'balance', sum(e.amount) over (order by e.occurred_on, e.id rows between unbounded preceding and current row)) as j
          from amine.account_entries e where e.customer_id = p_customer) x
        order by x.occurred_on desc, x.id desc limit 500) y), '[]'::jsonb));
end $$;

-- ── Client : compte, factures ─────────────────────────────────────────────────────────────────
create or replace function public.my_account() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  return amine.account_json(p.id);
end $$;

create or replace function public.get_my_invoice(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  i amine.invoices;
begin
  select * into i from amine.invoices where id = p_id and customer_id = p.id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.invoice_json(i);
end $$;

-- Facture d'une commande du dépôt (à joindre au bon de livraison).
create or replace function public.merchant_invoice(p_store_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  i amine.invoices;
begin
  select * into i from amine.invoices where id = p_id and store_id = s.id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.invoice_json(i);
end $$;

-- ── Administration : compte client, règlements, avoirs, factures, encours ──────────────────────
create or replace function public.admin_client_account(p_customer uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  if not exists (select 1 from amine.profiles where id = p_customer) then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.account_json(p_customer);
end $$;

create or replace function public.admin_invoice(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  i amine.invoices;
  v_paid bigint;
begin
  select * into i from amine.invoices where id = p_id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if i.customer_id is not null then
    select s.paid into v_paid from amine.invoice_states(i.customer_id) s where s.invoice_id = i.id;
  end if;
  return amine.invoice_json(i) || jsonb_build_object('paid', coalesce(v_paid, 0),
    'status', amine.invoice_status(i.kind, i.total_ttc, coalesce(v_paid, 0), i.due_on),
    'credited', (select coalesce(sum(x.total_ttc), 0) from amine.invoices x where x.invoice_id = i.id));
end $$;

-- p_data : {"kind": "payment" | "adjustment", "amount": 125000, "method": "cash" | "cheque" | "transfer" |
--           "card" | "other", "reference": "...", "note": "...", "occurred_on": "2026-10-15"}
-- Un règlement (montant positif) diminue ce que doit le client ; un ajustement est signé
-- (+ : le client doit plus, par exemple un chèque impayé ; − : un geste commercial).
create or replace function public.admin_record_payment(p_customer uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_kind text := coalesce(p_data ->> 'kind', 'payment');
  v_amount int;
  v_method text := nullif(p_data ->> 'method', '');
  v_day date;
  e amine.account_entries;
begin
  perform amine.hit('admin_payment:' || a.id, 300, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  if not exists (select 1 from amine.profiles where id = p_customer) then
    perform amine.err('NOT_FOUND');
  end if;
  if v_kind not in ('payment', 'adjustment') then
    perform amine.err('INVALID_INPUT', 'kind');
  end if;
  if v_kind = 'payment' then
    v_amount := -amine.int_in(p_data, 'amount', 1, 1000000000, true);
    if v_method is null or v_method not in ('cash', 'cheque', 'transfer', 'card', 'other') then
      perform amine.err('INVALID_INPUT', 'method');
    end if;
  else
    v_amount := amine.int_in(p_data, 'amount', -1000000000, 1000000000, true);
    if v_amount = 0 then
      perform amine.err('INVALID_INPUT', 'amount');
    end if;
    v_method := null;
  end if;
  v_day := coalesce(amine.date_in(p_data, 'occurred_on'), (now() at time zone 'Africa/Tunis')::date);
  if v_day > (now() at time zone 'Africa/Tunis')::date or v_day < (now() at time zone 'Africa/Tunis')::date - 366 then
    perform amine.err('INVALID_INPUT', 'occurred_on');
  end if;
  insert into amine.account_entries (customer_id, kind, amount, method, reference, note, occurred_on, created_by)
  values (p_customer, v_kind, v_amount, v_method, amine.txt(p_data ->> 'reference', 'reference', 80),
    amine.txt(p_data ->> 'note', 'note', 300), v_day, a.id)
  returning * into e;
  if v_kind = 'payment' then
    perform amine.notify(p_customer, 'payment_recorded', jsonb_build_object('amount', -v_amount, 'method', v_method),
      '#/account/billing');
  end if;
  perform amine.audit('account.' || v_kind, 'profile', p_customer::text,
    jsonb_build_object('amount', v_amount, 'method', v_method, 'entry', e.id));
  return amine.account_json(p_customer);
end $$;

-- Seuls les règlements et ajustements saisis à la main peuvent être retirés (erreur de saisie).
create or replace function public.admin_delete_account_entry(p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  e amine.account_entries;
begin
  select * into e from amine.account_entries where id = p_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if e.kind not in ('payment', 'adjustment') or (e.kind = 'payment' and e.note = 'cod') then
    perform amine.err('ENTRY_LOCKED');
  end if;
  delete from amine.account_entries where id = e.id;
  perform amine.audit('account.entry_deleted', 'profile', e.customer_id::text,
    jsonb_build_object('kind', e.kind, 'amount', e.amount, 'reference', e.reference));
  return amine.account_json(e.customer_id);
end $$;

-- Avoir sur une facture (produit manquant, geste commercial…) : au plus le montant restant de la
-- facture, réparti sur ses taux de TVA au prorata.
create or replace function public.admin_issue_credit_note(p_invoice_id uuid, p_amount int, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_set jsonb := amine.setting('invoicing');
  v_reason text := amine.txt(p_reason, 'reason', 300, true, 3);
  i amine.invoices;
  cn amine.invoices;
  v_credited bigint;
  v_base bigint;
  v_lines jsonb := '[]'::jsonb;
  v_left bigint;
  v_part bigint;
  v_ht bigint;
  v_count int;
  v_idx int := 0;
  r record;
begin
  perform amine.hit('admin_credit:' || a.id, 100, 3600);
  select * into i from amine.invoices where id = p_invoice_id and kind = 'invoice' for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  select coalesce(sum(total_ttc), 0) into v_credited from amine.invoices where invoice_id = i.id;
  if p_amount is null or p_amount < 1 or p_amount > i.total_ttc - i.stamp - v_credited then
    perform amine.err('CREDIT_TOO_HIGH', greatest(0, i.total_ttc - i.stamp - v_credited)::text);
  end if;
  v_base := i.total_ttc - i.stamp;
  v_left := p_amount;
  select count(*) into v_count from jsonb_array_elements(i.vat) v where (v.value ->> 'base')::bigint + (v.value ->> 'amount')::bigint > 0;
  for r in
    select (v.value ->> 'rate')::int as rate, (v.value ->> 'base')::bigint + (v.value ->> 'amount')::bigint as ttc
    from jsonb_array_elements(i.vat) v order by 2 desc
  loop
    continue when r.ttc <= 0;
    v_idx := v_idx + 1;
    v_part := case when v_idx = v_count then v_left else least(v_left, round(p_amount::numeric * r.ttc / v_base)::bigint) end;
    continue when v_part <= 0;
    v_left := v_left - v_part;
    v_ht := round(v_part::numeric * 100 / (100 + r.rate))::bigint;
    v_lines := v_lines || jsonb_build_object('kind', 'credit', 'name', v_reason, 'unit', null, 'qty', 1,
      'unit_price', v_part, 'unit_price_ht', v_ht, 'vat_rate', r.rate, 'discount', 0,
      'total_ttc', v_part, 'total_ht', v_ht, 'total_vat', v_part - v_ht);
  end loop;
  insert into amine.invoices (number, kind, order_id, invoice_id, customer_id, store_id, seller, buyer, lines, vat,
    total_ht, total_vat, stamp, total_ttc, payment_method, reason, created_by)
  select amine.next_invoice_number(coalesce(nullif(v_set ->> 'credit_prefix', ''), 'AV')), 'credit_note', i.order_id, i.id,
    i.customer_id, i.store_id, amine.seller_json(), i.buyer, v_lines, amine.invoice_vat(v_lines),
    coalesce(sum((l.value ->> 'total_ht')::bigint), 0), coalesce(sum((l.value ->> 'total_vat')::bigint), 0), 0, p_amount,
    i.payment_method, v_reason, a.id
  from jsonb_array_elements(v_lines) l
  returning * into cn;
  if i.customer_id is not null then
    insert into amine.account_entries (customer_id, kind, amount, invoice_id, reference, note, created_by)
    values (i.customer_id, 'credit_note', -p_amount, cn.id, cn.number, v_reason, a.id);
    -- Marchandise reprise : les points gagnés sur ce montant sont retirés.
    perform amine.loyalty_reverse(i.order_id, p_amount, cn.number);
    perform amine.notify(i.customer_id, 'credit_note_issued',
      jsonb_build_object('number', cn.number, 'amount', p_amount, 'invoice', i.number), '#/account/invoices/' || cn.id::text);
  end if;
  perform amine.audit('invoice.credit_note', 'invoice', i.number, jsonb_build_object('credit_note', cn.number, 'amount', p_amount));
  return public.admin_invoice(cn.id);
end $$;

-- Factures d'une période (export pour le comptable et la transmission TTN).
-- p_kind : null | invoice | credit_note ; p_status : null | unpaid | overdue | paid
create or replace function public.admin_invoices(
  p_from date, p_to date, p_query text default null, p_kind text default null, p_status text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_q text := amine.txt(p_query, 'query', 80);
  v_from timestamptz;
  v_to timestamptz;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then
    perform amine.err('INVALID_INPUT', 'period');
  end if;
  if p_kind is not null and p_kind not in ('invoice', 'credit_note') then
    perform amine.err('INVALID_INPUT', 'kind');
  end if;
  if p_status is not null and p_status not in ('unpaid', 'overdue', 'paid') then
    perform amine.err('INVALID_INPUT', 'status');
  end if;
  v_from := p_from::timestamp at time zone 'Africa/Tunis';
  v_to := (p_to + 1)::timestamp at time zone 'Africa/Tunis';
  return (
    with inv_rows as (
      select i.*, coalesce(s.paid, 0) as paid,
        amine.invoice_status(i.kind, i.total_ttc, coalesce(s.paid, 0), i.due_on) as status
      from amine.invoices i
      left join lateral (select st.paid from amine.invoice_states(i.customer_id) st where st.invoice_id = i.id) s on true
      where i.issued_at >= v_from and i.issued_at < v_to
        and (p_kind is null or i.kind = p_kind)
        and (v_q is null or i.number ilike '%' || amine.like_escape(v_q) || '%'
             or amine.fold(i.buyer ->> 'name') like '%' || amine.like_escape(amine.fold(v_q)) || '%')
    ), filtered as (
      select * from inv_rows
      where p_status is null or (p_status = 'paid' and status = 'paid')
        or (p_status = 'overdue' and status = 'overdue')
        or (p_status = 'unpaid' and status in ('unpaid', 'partial', 'overdue'))
    )
    select jsonb_build_object(
      'totals', (select jsonb_build_object('count', count(*),
          'total_ht', coalesce(sum(case when kind = 'credit_note' then -total_ht else total_ht end), 0),
          'total_vat', coalesce(sum(case when kind = 'credit_note' then -total_vat else total_vat end), 0),
          'stamp', coalesce(sum(stamp), 0),
          'total_ttc', coalesce(sum(case when kind = 'credit_note' then -total_ttc else total_ttc end), 0))
        from filtered),
      'items', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'number', f.number, 'kind', f.kind,
          'issued_at', f.issued_at, 'due_on', f.due_on, 'customer_id', f.customer_id, 'buyer', f.buyer,
          'total_ht', f.total_ht, 'total_vat', f.total_vat, 'stamp', f.stamp, 'total_ttc', f.total_ttc, 'vat', f.vat,
          'payment_method', f.payment_method, 'paid', f.paid, 'status', f.status,
          'order_code', (select o.code from amine.orders o where o.id = f.order_id)) order by f.issued_at desc, f.number desc)
        from (select * from filtered order by issued_at desc limit 2000) f), '[]'::jsonb)));
end $$;

-- Encours clients : soldes, montants échus et ancienneté des impayés.
create or replace function public.admin_receivables() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_today date := (now() at time zone 'Africa/Tunis')::date;
begin
  return coalesce((
    select jsonb_agg(x.j order by x.overdue desc, x.balance desc) from (
      select c.id, amine.account_balance(c.id) as balance, coalesce(u.overdue, 0) as overdue,
        jsonb_build_object('id', c.id, 'business_name', c.business_name, 'full_name', c.full_name, 'phone', c.phone,
          'payment_terms', c.payment_terms, 'payment_days', c.payment_days, 'credit_limit', c.credit_limit,
          'balance', amine.account_balance(c.id), 'exposure', amine.account_exposure(c.id),
          'due', coalesce(u.due, 0), 'overdue', coalesce(u.overdue, 0), 'oldest_due_on', u.oldest,
          'aging', jsonb_build_object('current', coalesce(u.current, 0), 'd30', coalesce(u.d30, 0),
            'd60', coalesce(u.d60, 0), 'd90', coalesce(u.d90, 0))) as j
      from amine.profiles c
      left join lateral (
        select sum(i.total_ttc - s.paid) as due,
          sum(i.total_ttc - s.paid) filter (where i.due_on < v_today) as overdue,
          min(i.due_on) as oldest,
          sum(i.total_ttc - s.paid) filter (where i.due_on >= v_today) as current,
          sum(i.total_ttc - s.paid) filter (where i.due_on < v_today and i.due_on >= v_today - 30) as d30,
          sum(i.total_ttc - s.paid) filter (where i.due_on < v_today - 30 and i.due_on >= v_today - 60) as d60,
          sum(i.total_ttc - s.paid) filter (where i.due_on < v_today - 60) as d90
        from amine.invoices i join amine.invoice_states(c.id) s on s.invoice_id = i.id
        where s.paid < i.total_ttc) u on true
      where exists (select 1 from amine.account_entries e where e.customer_id = c.id)
        or c.payment_terms = 'account') x
    where x.balance <> 0 or x.overdue > 0 or (x.j ->> 'payment_terms') = 'account'), '[]'::jsonb);
end $$;

-- ── Prix négociés ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_client_prices(p_customer uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('product_id', pr.id, 'name', pr.name, 'name_ar', pr.name_ar, 'name_en', pr.name_en,
        'unit', pr.unit, 'ref', pr.ref, 'brand', pr.brand, 'image_url', pr.image_url, 'price', cp.price,
        'list_price', pr.price, 'store_id', pr.store_id, 'store', s.name, 'deleted', pr.deleted_at is not null,
        'updated_at', cp.updated_at) order by pr.name)
    from amine.client_prices cp join amine.products pr on pr.id = cp.product_id join amine.stores s on s.id = pr.store_id
    where cp.customer_id = p_customer), '[]'::jsonb);
end $$;

-- p_price null : retire le prix négocié.
create or replace function public.admin_save_client_price(p_customer uuid, p_product_id uuid, p_price int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  perform amine.hit('admin_price:' || a.id, 600, 3600);
  if not exists (select 1 from amine.profiles where id = p_customer) then
    perform amine.err('NOT_FOUND');
  end if;
  if not exists (select 1 from amine.products where id = p_product_id and deleted_at is null) then
    perform amine.err('NOT_FOUND');
  end if;
  if p_price is null then
    delete from amine.client_prices where customer_id = p_customer and product_id = p_product_id;
  else
    if p_price < 1 or p_price > 100000000 then
      perform amine.err('INVALID_INPUT', 'price');
    end if;
    insert into amine.client_prices (customer_id, product_id, price, updated_at, updated_by)
    values (p_customer, p_product_id, p_price, now(), a.id)
    on conflict (customer_id, product_id) do update set price = excluded.price, updated_at = now(), updated_by = a.id;
  end if;
  perform amine.audit('client.price', 'profile', p_customer::text, jsonb_build_object('product_id', p_product_id, 'price', p_price));
  return public.admin_client_prices(p_customer);
end $$;

-- ── Commandes récurrentes ─────────────────────────────────────────────────────────────────────
create or replace function amine.recurring_next_on(r amine.recurring_orders) returns date
language sql stable set search_path = '' as $$
  select min(d)::date
  from generate_series(((now() at time zone 'Africa/Tunis')::date + 1)::timestamp,
    ((now() at time zone 'Africa/Tunis')::date + 8)::timestamp, interval '1 day') d
  where r.is_active and extract(isodow from d)::int = any (r.weekdays) and (r.last_run_on is null or d::date > r.last_run_on)
$$;

create or replace function amine.recurring_json(r amine.recurring_orders) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', r.id, 'customer_id', r.customer_id, 'store_id', r.store_id, 'address_id', r.address_id,
    'weekdays', to_jsonb(r.weekdays), 'slot', r.slot, 'payment_method', r.payment_method, 'label', r.label,
    'note', r.note, 'is_active', r.is_active, 'last_run_on', r.last_run_on, 'last_error', r.last_error,
    'created_at', r.created_at, 'updated_at', r.updated_at, 'next_on', amine.recurring_next_on(r),
    'address', (select amine.address_json(ad) from amine.addresses ad where ad.id = r.address_id),
    'store', (select jsonb_build_object('id', s.id, 'name', s.name, 'name_ar', s.name_ar, 'name_en', s.name_en)
              from amine.stores s where s.id = r.store_id),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('product_id', pr.id, 'qty', (e.value ->> 'qty')::int, 'name', pr.name,
          'name_ar', pr.name_ar, 'name_en', pr.name_en, 'unit', pr.unit, 'ref', pr.ref, 'image_url', pr.image_url,
          'unit_price', amine.unit_price(pr, r.customer_id, (e.value ->> 'qty')::int),
          'available', pr.deleted_at is null and pr.is_available) order by pr.name)
      from jsonb_array_elements(r.items) e
      join amine.products pr on pr.id = (e.value ->> 'product_id')::uuid), '[]'::jsonb),
    'customer', (select jsonb_build_object('id', p.id, 'business_name', p.business_name, 'full_name', p.full_name)
                 from amine.profiles p where p.id = r.customer_id))
$$;

-- p_data : {"store_id", "address_id", "items": [{"product_id", "qty"}], "weekdays": [1, 4],
--           "slot": "am" | "noon" | "pm", "payment_method": "cod" | "account", "label", "note", "is_active"}
create or replace function amine.save_recurring(p amine.profiles, p_id uuid, p_data jsonb, p_actor uuid) returns amine.recurring_orders
language plpgsql set search_path = '' as $$
declare
  r amine.recurring_orders;
  s amine.stores;
  v_store uuid;
  v_address uuid;
  v_days int[];
  v_slot text := p_data ->> 'slot';
  v_payment text := coalesce(nullif(p_data ->> 'payment_method', ''), 'cod');
  v_cart jsonb;
  v_items jsonb;
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  if p_id is not null then
    select * into r from amine.recurring_orders where id = p_id and customer_id = p.id for update;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
  elsif (select count(*) from amine.recurring_orders where customer_id = p.id) >= 10 then
    perform amine.err('TOO_MANY_RECURRING');
  end if;
  v_store := coalesce(amine.uuid_in(p_data, 'store_id'), r.store_id);
  select * into s from amine.stores where id = v_store and status = 'active';
  if not found then
    perform amine.err('STORE_NOT_FOUND');
  end if;
  v_address := coalesce(amine.uuid_in(p_data, 'address_id'), r.address_id);
  if v_address is null or not exists (select 1 from amine.addresses where id = v_address and user_id = p.id) then
    perform amine.err('ADDRESS_REQUIRED');
  end if;
  if jsonb_typeof(p_data -> 'weekdays') <> 'array' or exists (
      select 1 from jsonb_array_elements(p_data -> 'weekdays') w where w.value::text !~ '^[1-7]$') then
    perform amine.err('INVALID_INPUT', 'weekdays');
  end if;
  select array_agg(distinct w.value::text::int order by w.value::text::int) into v_days from jsonb_array_elements(p_data -> 'weekdays') w;
  if v_days is null then
    perform amine.err('INVALID_INPUT', 'weekdays');
  end if;
  if v_slot is null or v_slot not in ('am', 'noon', 'pm') then
    perform amine.err('INVALID_INPUT', 'slot');
  end if;
  if v_payment not in ('cod', 'account') or (v_payment = 'account' and p.payment_terms <> 'account') then
    perform amine.err('ACCOUNT_NOT_ALLOWED');
  end if;
  -- Contenu : mêmes règles qu'un panier ; chaque produit doit exister dans ce dépôt.
  v_cart := amine.price_cart(s.id, p_data -> 'items', false, p.id);
  if exists (select 1 from jsonb_array_elements(p_data -> 'items') e
             where not exists (select 1 from amine.products pr where pr.id = (e.value ->> 'product_id')::uuid
                               and pr.store_id = s.id and pr.deleted_at is null)) then
    perform amine.err('PRODUCT_UNAVAILABLE');
  end if;
  select jsonb_agg(jsonb_build_object('product_id', x.pid, 'qty', x.qty) order by x.pid) into v_items
  from (select (e.value ->> 'product_id')::uuid as pid, sum((e.value ->> 'qty')::int)::int as qty
        from jsonb_array_elements(p_data -> 'items') e group by 1) x;
  if p_id is null then
    insert into amine.recurring_orders (customer_id, store_id, address_id, items, weekdays, slot, payment_method, label, note,
      is_active, created_by)
    values (p.id, s.id, v_address, v_items, v_days, v_slot, v_payment, amine.txt(p_data ->> 'label', 'label', 60),
      amine.txt(p_data ->> 'note', 'note', 300, false, 1, true),
      coalesce(amine.bool_in(p_data, 'is_active'), true), p_actor)
    returning * into r;
  else
    update amine.recurring_orders set store_id = s.id, address_id = v_address, items = v_items, weekdays = v_days,
      slot = v_slot, payment_method = v_payment, label = amine.txt(p_data ->> 'label', 'label', 60),
      note = amine.txt(p_data ->> 'note', 'note', 300, false, 1, true),
      is_active = coalesce(amine.bool_in(p_data, 'is_active'), is_active), last_error = null, updated_at = now()
    where id = r.id returning * into r;
  end if;
  return r;
end $$;

create or replace function public.list_my_recurring() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  return coalesce((select jsonb_agg(amine.recurring_json(r) order by r.created_at)
    from amine.recurring_orders r where r.customer_id = p.id), '[]'::jsonb);
end $$;

create or replace function public.save_my_recurring(p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  perform amine.hit('recurring:' || p.id, 60, 3600);
  if p.business_name is null then
    perform amine.err('BUSINESS_REQUIRED');
  end if;
  return amine.recurring_json(amine.save_recurring(p, p_id, p_data, p.id));
end $$;

create or replace function public.delete_my_recurring(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  delete from amine.recurring_orders where id = p_id and customer_id = p.id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return jsonb_build_object('deleted', true);
end $$;

create or replace function public.admin_recurring(p_customer uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  return coalesce((select jsonb_agg(amine.recurring_json(r) order by r.is_active desc, r.created_at desc)
    from amine.recurring_orders r where p_customer is null or r.customer_id = p_customer), '[]'::jsonb);
end $$;

create or replace function public.admin_save_recurring(p_id uuid, p_customer uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  cu amine.profiles;
  r amine.recurring_orders;
begin
  perform amine.hit('admin_recurring:' || a.id, 300, 3600);
  select * into cu from amine.profiles where id = p_customer;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if cu.business_name is null then
    perform amine.err('BUSINESS_REQUIRED');
  end if;
  r := amine.save_recurring(cu, p_id, p_data, a.id);
  perform amine.audit('recurring.saved', 'profile', cu.id::text, jsonb_build_object('recurring_id', r.id));
  return amine.recurring_json(r);
end $$;

create or replace function public.admin_delete_recurring(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  r amine.recurring_orders;
begin
  delete from amine.recurring_orders where id = p_id returning * into r;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  perform amine.audit('recurring.deleted', 'profile', r.customer_id::text, jsonb_build_object('recurring_id', r.id));
  return jsonb_build_object('deleted', true);
end $$;

-- Tâche de fond : à partir de l'heure réglée (15 h par défaut, heure de Tunis), crée les commandes du
-- lendemain. Un échec (stock, plafond d'encours…) est signalé au client et à l'équipe.
create or replace function amine.run_recurring_orders() returns void
language plpgsql set search_path = '' as $$
declare
  v_now timestamp := now() at time zone 'Africa/Tunis';
  v_hour int := coalesce((amine.setting('orders') ->> 'recurring_hour')::int, 15);
  v_day date := (now() at time zone 'Africa/Tunis')::date + 1;
  r amine.recurring_orders;
  cu amine.profiles;
  o amine.orders;
  v_error text;
begin
  if extract(hour from v_now)::int < v_hour then
    return;
  end if;
  for r in
    select * from amine.recurring_orders x
    where x.is_active and extract(isodow from v_day)::int = any (x.weekdays)
      and (x.last_run_on is null or x.last_run_on < v_day)
    order by x.created_at limit 50 for update skip locked
  loop
    begin
      select * into cu from amine.profiles where id = r.customer_id;
      perform amine.assert_can_order(cu, true);
      o := amine.create_store_order(cu, r.store_id, r.address_id, r.items, r.note,
        'rec:' || r.id::text || ':' || v_day::text, null, 'tomorrow_' || r.slot, 'recurring', 'system', null,
        r.payment_method, r.id);
      update amine.recurring_orders set last_run_on = v_day, last_error = null where id = r.id;
      perform amine.notify(r.customer_id, 'recurring_created',
        jsonb_build_object('code', o.code, 'total', o.total, 'label', r.label, 'day', v_day), '#/orders/' || o.code);
    exception when others then
      v_error := left(sqlerrm, 80);
      update amine.recurring_orders set last_run_on = v_day, last_error = v_error where id = r.id;
      perform amine.notify(r.customer_id, 'recurring_failed',
        jsonb_build_object('label', r.label, 'error', v_error, 'day', v_day), '#/account/recurring');
      perform amine.notify_admins('recurring_failed',
        jsonb_build_object('label', r.label, 'error', v_error, 'day', v_day,
          'client', (select x.business_name from amine.profiles x where x.id = r.customer_id)),
        '#/admin/clients/' || r.customer_id::text);
    end;
  end loop;
end $$;

-- Tâche de fond : relance des factures sur compte échues et impayées (au plus une fois tous les
-- « reminder_days » jours par facture).
create or replace function amine.remind_overdue_invoices() returns void
language plpgsql set search_path = '' as $$
declare
  v_today date := (now() at time zone 'Africa/Tunis')::date;
  v_days int := greatest(1, coalesce((amine.setting('invoicing') ->> 'reminder_days')::int, 7));
  rec record;
begin
  for rec in
    select i.id, i.number, i.customer_id, i.total_ttc - s.paid as due, i.due_on
    from amine.invoices i
    join lateral (select st.paid from amine.invoice_states(i.customer_id) st where st.invoice_id = i.id) s on true
    where i.kind = 'invoice' and i.payment_method = 'account' and i.customer_id is not null and i.due_on < v_today
      and s.paid < i.total_ttc and (i.reminded_at is null or i.reminded_at < now() - make_interval(days => v_days))
    order by i.due_on limit 50
  loop
    update amine.invoices set reminded_at = now() where id = rec.id;
    perform amine.notify(rec.customer_id, 'invoice_overdue',
      jsonb_build_object('number', rec.number, 'amount', rec.due, 'due_on', rec.due_on), '#/account/billing');
    perform amine.notify_admins('invoice_overdue',
      jsonb_build_object('number', rec.number, 'amount', rec.due, 'due_on', rec.due_on,
        'client', (select x.business_name from amine.profiles x where x.id = rec.customer_id)),
      '#/admin/clients/' || rec.customer_id::text);
  end loop;
end $$;

-- ── Pesée réelle au dépôt ─────────────────────────────────────────────────────────────────────
-- p_lines : [{"product_id": "...", "actual_qty": 10.4}] — 0 = produit manquant, null = quantité
-- commandée. Montants recalculés (prix unitaire de la commande × quantité livrée) ; le client est
-- prévenu du nouveau total. Le stock n'est pas modifié (l'inventaire le corrige).
create or replace function public.merchant_set_weights(p_store_id uuid, p_code text, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  o amine.orders;
  l jsonb;
  v_pid uuid;
  v_qty numeric;
  it amine.order_items;
  v_sub bigint;
  v_reprice jsonb;
  v_discount int;
begin
  perform amine.hit('merchant_action:' || auth.uid(), 300, 600);
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0
     or jsonb_array_length(p_lines) > 120 then
    perform amine.err('INVALID_INPUT', 'lines');
  end if;
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and store_id = s.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if o.status not in ('accepted', 'preparing') then
    perform amine.err('ORDER_LOCKED');
  end if;
  for l in select e.value from jsonb_array_elements(p_lines) e loop
    if jsonb_typeof(l) <> 'object' then
      perform amine.err('INVALID_INPUT', 'lines');
    end if;
    v_pid := amine.uuid_in(l, 'product_id', true);
    select * into it from amine.order_items where order_id = o.id and product_id = v_pid;
    if not found then
      perform amine.err('INVALID_INPUT', 'product_id');
    end if;
    if l -> 'actual_qty' is null or jsonb_typeof(l -> 'actual_qty') = 'null' then
      v_qty := null;
    else
      if (l ->> 'actual_qty') !~ '^[0-9]{1,4}(\.[0-9]{1,3})?$' then
        perform amine.err('INVALID_INPUT', 'actual_qty');
      end if;
      v_qty := (l ->> 'actual_qty')::numeric;
      if v_qty > it.quantity * 3 then
        perform amine.err('WEIGHT_TOO_HIGH', it.name);
      end if;
    end if;
    update amine.order_items set actual_qty = v_qty, total = round(unit_price * coalesce(v_qty, quantity))::int
    where id = it.id;
  end loop;
  select coalesce(sum(total), 0) into v_sub from amine.order_items where order_id = o.id;
  v_reprice := amine.reprice_discount(o, v_sub::int);
  v_discount := (v_reprice ->> 'discount')::int;
  if (v_reprice ->> 'refund_points')::int > 0 then
    perform amine.loyalty_add(o.customer_id, (v_reprice ->> 'refund_points')::int, 'edit_refund', o.id, o.code);
  end if;
  update amine.orders set subtotal = v_sub, discount = v_discount,
    loyalty_discount = (v_reprice ->> 'loyalty_discount')::int, loyalty_points = (v_reprice ->> 'loyalty_points')::int,
    total = v_sub + delivery_fee + service_fee + stamp_fee - v_discount,
    commission = round(v_sub::numeric * s.commission_bps / 10000)::int, weights_adjusted_at = now(), updated_at = now()
  where id = o.id returning * into o;
  perform amine.log_order(o.id, o.status, 'weights', 'merchant', auth.uid(), null);
  perform amine.notify(o.customer_id, 'order_weights', jsonb_build_object('code', o.code, 'total', o.total), '#/orders/' || o.code);
  return amine.order_json(o, 'merchant');
end $$;

-- ── Stock : journal des mouvements ────────────────────────────────────────────────────────────
-- Chaque variation de stock d'un produit est journalisée, avec la nature indiquée par
-- amine.stock_context() (vente, retour, achat, perte, inventaire ; « ajustement » par défaut).
-- Version 4 : chaque sortie de stock est prise sur les lots reçus, dans l'ordre des dates limites
-- (« premier périmé, premier sorti ») ; une commande annulée remet ses quantités dans les mêmes lots.
create or replace function amine.on_stock_change() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_kind text;
  v_ref text;
  v_delta int;
  v_mid bigint;
  v_left int;
  v_take int;
  l record;
begin
  if new.stock is null or (tg_op = 'UPDATE' and new.stock is not distinct from old.stock) then
    return new;
  end if;
  v_kind := case when tg_op = 'INSERT' then 'count'
    else coalesce(nullif(current_setting('amine.stock_kind', true), ''), 'adjustment') end;
  v_ref := nullif(current_setting('amine.stock_ref', true), '');
  v_delta := new.stock - case when tg_op = 'INSERT' then 0 else coalesce(old.stock, 0) end;
  insert into amine.stock_movements (store_id, product_id, kind, quantity, stock_after, ref, reason, created_by)
  values (new.store_id, new.id, v_kind, v_delta, new.stock, v_ref,
    nullif(current_setting('amine.stock_reason', true), ''), auth.uid())
  returning id into v_mid;
  if v_delta < 0 and v_kind <> 'purchase_cancel' then
    v_left := -v_delta;
    for l in
      select pl.id, pl.remaining from amine.purchase_lines pl join amine.purchases pu on pu.id = pl.purchase_id
      where pl.product_id = new.id and pl.remaining > 0 and pu.status = 'received'
      order by pl.expiry_on nulls last, pu.received_on, pl.id
      for update of pl
    loop
      exit when v_left <= 0;
      v_take := least(v_left, l.remaining);
      update amine.purchase_lines set remaining = remaining - v_take where id = l.id;
      insert into amine.stock_lot_moves (movement_id, purchase_line_id, quantity) values (v_mid, l.id, -v_take);
      v_left := v_left - v_take;
    end loop;
  elsif v_delta > 0 and v_kind = 'return' and v_ref is not null then
    v_left := v_delta;
    for l in
      select lm.purchase_line_id, -sum(lm.quantity)::int as qty
      from amine.stock_lot_moves lm join amine.stock_movements m on m.id = lm.movement_id
      where m.product_id = new.id and m.kind in ('sale', 'return') and m.ref = v_ref
      group by lm.purchase_line_id having -sum(lm.quantity) > 0
    loop
      exit when v_left <= 0;
      v_take := least(v_left, l.qty);
      update amine.purchase_lines set remaining = least(quantity, remaining + v_take) where id = l.purchase_line_id;
      insert into amine.stock_lot_moves (movement_id, purchase_line_id, quantity) values (v_mid, l.purchase_line_id, v_take);
      v_left := v_left - v_take;
    end loop;
  end if;
  return new;
end $$;

-- Lots d'où sont sortis les produits d'une commande (à préparer en priorité).
create or replace function amine.order_item_lots(p_code text, p_product uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_agg(jsonb_build_object('lot', pl.lot, 'expiry_on', pl.expiry_on, 'received_on', pu.received_on,
      'quantity', x.qty) order by pl.expiry_on nulls last, pu.received_on)
  from (select lm.purchase_line_id, -sum(lm.quantity)::int as qty
        from amine.stock_lot_moves lm join amine.stock_movements m on m.id = lm.movement_id
        where m.product_id = p_product and m.ref = p_code and m.kind in ('sale', 'return')
        group by lm.purchase_line_id having -sum(lm.quantity) > 0) x
  join amine.purchase_lines pl on pl.id = x.purchase_line_id
  join amine.purchases pu on pu.id = pl.purchase_id
$$;

drop trigger if exists amine_products_stock on amine.products;
create trigger amine_products_stock
  after insert or update of stock on amine.products
  for each row execute function amine.on_stock_change();

-- ── Fournisseurs ──────────────────────────────────────────────────────────────────────────────
create or replace function amine.supplier_json(x amine.suppliers) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', x.id, 'name', x.name, 'phone', x.phone, 'email', x.email, 'tax_id', x.tax_id,
    'address', x.address, 'note', x.note, 'is_active', x.is_active, 'created_at', x.created_at,
    'purchases', (select count(*) from amine.purchases pu where pu.supplier_id = x.id and pu.status = 'received'),
    'last_purchase_on', (select max(pu.received_on) from amine.purchases pu where pu.supplier_id = x.id and pu.status = 'received'))
$$;

create or replace function public.merchant_suppliers(p_store_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  return coalesce((select jsonb_agg(amine.supplier_json(x) order by x.is_active desc, x.name)
    from amine.suppliers x where x.store_id = s.id), '[]'::jsonb);
end $$;

-- p_data : {"name", "phone", "email", "tax_id", "address", "note", "is_active"}
create or replace function public.merchant_save_supplier(p_store_id uuid, p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  v_email text;
  x amine.suppliers;
begin
  perform amine.hit('catalog:' || auth.uid(), 600, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  v_email := amine.txt(p_data ->> 'email', 'email', 160);
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    perform amine.err('INVALID_INPUT', 'email');
  end if;
  if p_id is null then
    if (select count(*) from amine.suppliers where store_id = s.id) >= 500 then
      perform amine.err('TOO_MANY_SUPPLIERS');
    end if;
    insert into amine.suppliers (store_id, name, phone, email, tax_id, address, note, is_active)
    values (s.id, amine.txt(p_data ->> 'name', 'name', 120, true, 2), amine.phone_in(p_data ->> 'phone', 'phone'),
      v_email, amine.tax_id_in(p_data ->> 'tax_id'), amine.txt(p_data ->> 'address', 'address', 200),
      amine.txt(p_data ->> 'note', 'note', 300, false, 1, true), coalesce(amine.bool_in(p_data, 'is_active'), true))
    returning * into x;
  else
    update amine.suppliers set name = amine.txt(p_data ->> 'name', 'name', 120, true, 2),
      phone = amine.phone_in(p_data ->> 'phone', 'phone'), email = v_email, tax_id = amine.tax_id_in(p_data ->> 'tax_id'),
      address = amine.txt(p_data ->> 'address', 'address', 200), note = amine.txt(p_data ->> 'note', 'note', 300, false, 1, true),
      is_active = coalesce(amine.bool_in(p_data, 'is_active'), is_active)
    where id = p_id and store_id = s.id returning * into x;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
  end if;
  return amine.supplier_json(x);
end $$;

create or replace function public.merchant_delete_supplier(p_store_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  if not exists (select 1 from amine.suppliers where id = p_id and store_id = s.id) then
    perform amine.err('NOT_FOUND');
  end if;
  if exists (select 1 from amine.purchases where supplier_id = p_id) then
    update amine.suppliers set is_active = false where id = p_id;
    return jsonb_build_object('archived', true);
  end if;
  delete from amine.suppliers where id = p_id;
  return jsonb_build_object('deleted', true);
end $$;

-- ── Achats (réceptions de marchandise) ────────────────────────────────────────────────────────
create or replace function amine.purchase_json(pu amine.purchases, p_lines boolean) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', pu.id, 'reference', pu.reference, 'received_on', pu.received_on, 'total', pu.total,
    'status', pu.status, 'note', pu.note, 'created_at', pu.created_at,
    'supplier', (select jsonb_build_object('id', x.id, 'name', x.name) from amine.suppliers x where x.id = pu.supplier_id),
    'lines_count', (select count(*) from amine.purchase_lines l where l.purchase_id = pu.id),
    'by', (select p.full_name from amine.profiles p where p.id = pu.created_by))
  || case when not p_lines then '{}'::jsonb else jsonb_build_object('lines', coalesce((
    select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'name', l.name, 'unit', l.unit, 'quantity', l.quantity,
        'unit_cost', l.unit_cost, 'total', l.quantity::bigint * l.unit_cost, 'expiry_on', l.expiry_on, 'lot', l.lot, 'remaining', l.remaining,
        'ref', (select pr.ref from amine.products pr where pr.id = l.product_id)) order by l.name)
    from amine.purchase_lines l where l.purchase_id = pu.id), '[]'::jsonb)) end
$$;

create or replace function public.merchant_purchases(p_store_id uuid, p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  return coalesce((select jsonb_agg(amine.purchase_json(x, false) order by x.received_on desc, x.created_at desc)
    from (select * from amine.purchases where store_id = s.id order by received_on desc, created_at desc
          limit least(greatest(coalesce(p_limit, 50), 1), 300)) x), '[]'::jsonb);
end $$;

create or replace function public.merchant_purchase(p_store_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  pu amine.purchases;
begin
  select * into pu from amine.purchases where id = p_id and store_id = s.id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.purchase_json(pu, true);
end $$;

create or replace function amine.date_in(p jsonb, p_key text) returns date
language plpgsql immutable set search_path = '' as $$
declare
  v text := btrim(coalesce(p ->> p_key, ''));
begin
  if v = '' then
    return null;
  end if;
  if v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    perform amine.err('INVALID_INPUT', p_key);
  end if;
  begin
    return v::date;
  exception when others then
    perform amine.err('INVALID_INPUT', p_key);
  end;
  return null;
end $$;

-- Réception : le stock de chaque produit augmente et son coût d'achat est mis à jour.
-- p_data : {"supplier_id", "reference", "received_on", "note",
--           "lines": [{"product_id", "quantity", "unit_cost", "expiry_on", "lot"}]}
create or replace function public.merchant_save_purchase(p_store_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  pu amine.purchases;
begin
  perform amine.hit('purchase:' || auth.uid(), 120, 3600);
  -- En deux instructions : une fonction « stable » appelée dans la même requête ne verrait pas les lignes créées.
  pu := amine.create_purchase(s, p_data);
  return amine.purchase_json(pu, true);
end $$;

create or replace function amine.create_purchase(s amine.stores, p_data jsonb) returns amine.purchases
language plpgsql set search_path = '' as $$
declare
  v_today date := (now() at time zone 'Africa/Tunis')::date;
  v_supplier uuid;
  v_day date;
  v_expiry date;
  pu amine.purchases;
  pr amine.products;
  l jsonb;
  v_qty int;
  v_cost int;
  v_total bigint := 0;
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' or jsonb_typeof(p_data -> 'lines') <> 'array'
     or jsonb_array_length(p_data -> 'lines') = 0 or jsonb_array_length(p_data -> 'lines') > 200 then
    perform amine.err('INVALID_INPUT', 'lines');
  end if;
  v_supplier := amine.uuid_in(p_data, 'supplier_id');
  if v_supplier is not null and not exists (select 1 from amine.suppliers where id = v_supplier and store_id = s.id) then
    perform amine.err('INVALID_INPUT', 'supplier_id');
  end if;
  v_day := coalesce(amine.date_in(p_data, 'received_on'), v_today);
  if v_day > v_today or v_day < v_today - 366 then
    perform amine.err('INVALID_INPUT', 'received_on');
  end if;
  insert into amine.purchases (store_id, supplier_id, reference, received_on, note, created_by)
  values (s.id, v_supplier, amine.txt(p_data ->> 'reference', 'reference', 60), v_day,
    amine.txt(p_data ->> 'note', 'note', 300, false, 1, true), auth.uid())
  returning * into pu;
  perform amine.stock_context('purchase', coalesce(pu.reference, left(pu.id::text, 8)), null);
  for l in select e.value from jsonb_array_elements(p_data -> 'lines') e loop
    if jsonb_typeof(l) <> 'object' then
      perform amine.err('INVALID_INPUT', 'lines');
    end if;
    select * into pr from amine.products where id = amine.uuid_in(l, 'product_id', true) and store_id = s.id and deleted_at is null;
    if not found then
      perform amine.err('INVALID_INPUT', 'product_id');
    end if;
    v_qty := amine.int_in(l, 'quantity', 1, 1000000, true);
    v_cost := amine.int_in(l, 'unit_cost', 0, 100000000, true);
    v_expiry := amine.date_in(l, 'expiry_on');
    if v_expiry is not null and (v_expiry < v_day - 30 or v_expiry > v_day + 3650) then
      perform amine.err('INVALID_INPUT', 'expiry_on');
    end if;
    insert into amine.purchase_lines (purchase_id, product_id, name, unit, quantity, unit_cost, expiry_on, lot, remaining)
    values (pu.id, pr.id, pr.name, pr.unit, v_qty, v_cost, v_expiry, amine.txt(l ->> 'lot', 'lot', 40), v_qty);
    update amine.products set stock = least(1000000, coalesce(stock, 0) + v_qty), cost_price = v_cost, updated_at = now()
    where id = pr.id;
    v_total := v_total + v_qty::bigint * v_cost;
  end loop;
  if v_total > 2000000000 then
    perform amine.err('INVALID_INPUT', 'total');
  end if;
  update amine.purchases set total = v_total where id = pu.id returning * into pu;
  perform amine.audit('purchase.received', 'store', s.id::text, jsonb_build_object('purchase_id', pu.id, 'total', v_total));
  return pu;
end $$;

-- Annulation d'une réception saisie par erreur : les quantités sortent du stock.
create or replace function public.merchant_cancel_purchase(p_store_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  pu amine.purchases;
begin
  select * into pu from amine.purchases where id = p_id and store_id = s.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if pu.status <> 'received' then
    perform amine.err('INVALID_TRANSITION');
  end if;
  perform amine.stock_context('purchase_cancel', coalesce(pu.reference, left(pu.id::text, 8)), null);
  update amine.purchase_lines set remaining = 0 where purchase_id = pu.id;
  update amine.products p set stock = greatest(0, p.stock - x.qty), updated_at = now()
  from (select l.product_id, sum(l.quantity) as qty from amine.purchase_lines l where l.purchase_id = pu.id group by 1) x
  where p.id = x.product_id and p.stock is not null;
  update amine.purchases set status = 'cancelled' where id = pu.id returning * into pu;
  perform amine.audit('purchase.cancelled', 'store', s.id::text, jsonb_build_object('purchase_id', pu.id));
  return amine.purchase_json(pu, true);
end $$;

-- Perte (périmé, abîmé…) ou inventaire (stock compté).
-- p_kind : loss | count ; p_reason (perte) : expired | damaged | other
create or replace function public.merchant_record_stock(
  p_store_id uuid, p_product_id uuid, p_kind text, p_quantity int, p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  pr amine.products;
begin
  perform amine.hit('catalog:' || auth.uid(), 600, 3600);
  select * into pr from amine.products where id = p_product_id and store_id = s.id and deleted_at is null for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if p_kind = 'loss' then
    if p_quantity is null or p_quantity < 1 or p_quantity > 1000000 then
      perform amine.err('INVALID_INPUT', 'quantity');
    end if;
    if p_reason is null or p_reason not in ('expired', 'damaged', 'other') then
      perform amine.err('INVALID_INPUT', 'reason');
    end if;
    perform amine.stock_context('loss', null, p_reason);
    update amine.products set stock = greatest(0, coalesce(stock, 0) - p_quantity), updated_at = now() where id = pr.id
    returning * into pr;
  elsif p_kind = 'count' then
    if p_quantity is null or p_quantity < 0 or p_quantity > 1000000 then
      perform amine.err('INVALID_INPUT', 'quantity');
    end if;
    perform amine.stock_context('count', null, 'inventory');
    update amine.products set stock = p_quantity, updated_at = now() where id = pr.id returning * into pr;
  else
    perform amine.err('INVALID_INPUT', 'kind');
  end if;
  return amine.merchant_product_json(pr);
end $$;

-- Vue d'ensemble du stock : valeur au coût d'achat, ruptures, mouvements récents, dates limites proches.
create or replace function public.merchant_stock(p_store_id uuid, p_product_id uuid default null, p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  v_today date := (now() at time zone 'Africa/Tunis')::date;
begin
  return jsonb_build_object(
    'summary', (select jsonb_build_object(
        'value', coalesce(sum(p.stock::bigint * p.cost_price) filter (where p.cost_price is not null and p.stock > 0), 0),
        'tracked', count(*) filter (where p.stock is not null),
        'low', count(*) filter (where p.stock between 1 and 5),
        'out', count(*) filter (where p.stock = 0),
        'without_cost', count(*) filter (where p.stock > 0 and p.cost_price is null))
      from amine.products p where p.store_id = s.id and p.deleted_at is null),
    'movements', coalesce((
      select jsonb_agg(jsonb_build_object('id', m.id, 'product_id', m.product_id, 'name', p.name, 'name_ar', p.name_ar,
          'name_en', p.name_en, 'unit', p.unit, 'ref', p.ref, 'kind', m.kind, 'quantity', m.quantity,
          'stock_after', m.stock_after, 'reference', m.ref, 'reason', m.reason, 'created_at', m.created_at,
          'by', (select x.full_name from amine.profiles x where x.id = m.created_by)) order by m.id desc)
      from (select * from amine.stock_movements where store_id = s.id and (p_product_id is null or product_id = p_product_id)
            order by id desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) m
      join amine.products p on p.id = m.product_id), '[]'::jsonb),
    'expiring', coalesce((
      select jsonb_agg(jsonb_build_object('purchase_id', pu.id, 'product_id', p.id, 'name', p.name, 'name_ar', p.name_ar,
          'name_en', p.name_en, 'unit', p.unit, 'ref', p.ref, 'expiry_on', l.expiry_on, 'quantity', l.quantity,
          'remaining', l.remaining, 'lot', l.lot, 'received_on', pu.received_on, 'stock', p.stock,
          'days', l.expiry_on - v_today) order by l.expiry_on, p.name)
      from amine.purchase_lines l join amine.purchases pu on pu.id = l.purchase_id
      join amine.products p on p.id = l.product_id
      where pu.store_id = s.id and pu.status = 'received' and l.expiry_on is not null
        and l.expiry_on between v_today - 7 and v_today + 7 and l.remaining > 0 and p.deleted_at is null), '[]'::jsonb));
end $$;

-- ── Tournées de livraison (administration) ────────────────────────────────────────────────────
create or replace function amine.route_json(r amine.routes) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', r.id, 'day', r.day, 'name', r.name, 'distance_km', r.distance_km, 'created_at', r.created_at,
    'store', (select jsonb_build_object('id', s.id, 'name', s.name, 'lat', s.lat, 'lng', s.lng, 'address', s.address)
              from amine.stores s where s.id = r.store_id),
    'courier', (select jsonb_build_object('id', c.user_id, 'name', p.full_name, 'phone', p.phone, 'vehicle', c.vehicle,
                  'online', c.is_online and c.last_seen_at > now() - interval '20 minutes')
                from amine.couriers c join amine.profiles p on p.id = c.user_id where c.user_id = r.courier_id),
    'stops', coalesce((
      select jsonb_agg(jsonb_build_object('code', o.code, 'seq', o.route_seq, 'status', o.status,
          'business', o.dropoff_name, 'address', o.dropoff_address, 'details', o.dropoff_details, 'phone', o.dropoff_phone,
          'lat', o.dropoff_lat, 'lng', o.dropoff_lng, 'total', o.total,
          'to_collect', case when o.payment_method = 'account' then 0 else o.total end,
          'payment_method', o.payment_method, 'delivery_slot', coalesce(o.delivery_slot, 'asap'),
          'courier_id', o.courier_id) order by o.route_seq, o.placed_at)
      from amine.orders o where o.route_id = r.id), '[]'::jsonb))
$$;

create or replace function public.admin_routes(p_day date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_day date := coalesce(p_day, (now() at time zone 'Africa/Tunis')::date);
begin
  if v_day < (now() at time zone 'Africa/Tunis')::date - 60 or v_day > (now() at time zone 'Africa/Tunis')::date + 30 then
    perform amine.err('INVALID_INPUT', 'day');
  end if;
  return jsonb_build_object(
    'day', v_day,
    'routes', coalesce((select jsonb_agg(amine.route_json(r) order by r.created_at) from amine.routes r where r.day = v_day), '[]'::jsonb),
    'unrouted', coalesce((
      select jsonb_agg(jsonb_build_object('code', o.code, 'status', o.status, 'business', o.dropoff_name,
          'address', o.dropoff_address, 'lat', o.dropoff_lat, 'lng', o.dropoff_lng, 'total', o.total,
          'payment_method', o.payment_method, 'delivery_slot', coalesce(o.delivery_slot, 'asap'),
          'store_id', o.store_id, 'store', s.name, 'has_courier', o.courier_id is not null)
        order by coalesce(amine.slot_start(o.deliver_on, o.delivery_slot), o.placed_at), o.placed_at)
      from amine.orders o join amine.stores s on s.id = o.store_id
      where o.kind = 'store' and o.route_id is null and o.deliver_on = v_day
        and o.status in ('accepted', 'preparing', 'ready')), '[]'::jsonb),
    'couriers', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.user_id, 'name', p.full_name, 'phone', p.phone, 'vehicle', c.vehicle,
          'online', c.is_online and c.last_seen_at > now() - interval '20 minutes', 'zone_id', c.zone_id) order by p.full_name)
      from amine.couriers c join amine.profiles p on p.id = c.user_id where c.status = 'approved'), '[]'::jsonb),
    'depots', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name)
      from amine.stores s where s.status = 'active'), '[]'::jsonb));
end $$;

-- p_data : {"store_id", "day", "courier_id", "name", "codes": ["AM…", …]} — l'ordre de passage est
-- calculé au plus proche voisin depuis le dépôt ; le livreur choisi reçoit toutes les courses.
create or replace function public.admin_save_route(p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  r amine.routes;
  s amine.stores;
  v_day date;
  v_courier uuid;
  v_codes text[];
  v_lat numeric;
  v_lng numeric;
  v_seq int := 0;
  v_km numeric := 0;
  o amine.orders;
  v_assigned int := 0;
begin
  perform amine.hit('admin_route:' || a.id, 120, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' or jsonb_typeof(p_data -> 'codes') <> 'array'
     or jsonb_array_length(p_data -> 'codes') = 0 or jsonb_array_length(p_data -> 'codes') > 40 then
    perform amine.err('INVALID_INPUT', 'codes');
  end if;
  select array_agg(distinct upper(btrim(c.value))) into v_codes from jsonb_array_elements_text(p_data -> 'codes') c;
  if p_id is not null then
    select * into r from amine.routes where id = p_id for update;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
  end if;
  select * into s from amine.stores where id = coalesce(amine.uuid_in(p_data, 'store_id'), r.store_id) and status = 'active';
  if not found then
    perform amine.err('STORE_NOT_FOUND');
  end if;
  v_day := coalesce(amine.date_in(p_data, 'day'), r.day, (now() at time zone 'Africa/Tunis')::date);
  v_courier := amine.uuid_in(p_data, 'courier_id');
  if v_courier is not null and not exists (select 1 from amine.couriers where user_id = v_courier and status = 'approved') then
    perform amine.err('COURIER_NOT_APPROVED');
  end if;
  if exists (
    select 1 from unnest(v_codes) c left join amine.orders x on x.code = c
    where x.id is null or x.store_id <> s.id or x.kind <> 'store'
       or x.status not in ('accepted', 'preparing', 'ready', 'picked_up')
       or (x.route_id is not null and x.route_id is distinct from r.id)) then
    perform amine.err('ROUTE_ORDER_INVALID');
  end if;

  if r.id is null then
    insert into amine.routes (store_id, courier_id, day, name, created_by)
    values (s.id, v_courier, v_day, amine.txt(p_data ->> 'name', 'name', 60), a.id) returning * into r;
  else
    -- Commandes retirées de la tournée : libérées (sauf si déjà en route).
    update amine.orders x set route_id = null, route_seq = null,
      courier_id = case when x.status = 'picked_up' then x.courier_id
                        when x.courier_id = r.courier_id then null else x.courier_id end,
      assigned_at = case when x.status <> 'picked_up' and x.courier_id = r.courier_id then null else x.assigned_at end,
      updated_at = now()
    where x.route_id = r.id and not (x.code = any (v_codes));
    update amine.routes set store_id = s.id, courier_id = v_courier, day = v_day,
      name = amine.txt(p_data ->> 'name', 'name', 60) where id = r.id returning * into r;
  end if;

  -- Ordre de passage : au plus proche voisin, en partant du dépôt.
  update amine.orders set route_seq = null where code = any (v_codes);
  v_lat := s.lat;
  v_lng := s.lng;
  loop
    select * into o from amine.orders x
    where x.code = any (v_codes) and x.route_seq is null
    order by amine.distance_km(v_lat, v_lng, x.dropoff_lat, x.dropoff_lng), x.code
    limit 1;
    exit when not found;
    v_seq := v_seq + 1;
    v_km := v_km + amine.distance_km(v_lat, v_lng, o.dropoff_lat, o.dropoff_lng);
    v_lat := o.dropoff_lat;
    v_lng := o.dropoff_lng;
    update amine.orders x set route_id = r.id, route_seq = v_seq, updated_at = now(),
      courier_id = case when x.status = 'picked_up' then x.courier_id else coalesce(v_courier, x.courier_id) end,
      assigned_at = case when x.status <> 'picked_up' and v_courier is not null and x.courier_id is distinct from v_courier
                         then now() else x.assigned_at end
    where x.id = o.id;
    if v_courier is not null and o.status <> 'picked_up' and o.courier_id is distinct from v_courier then
      perform amine.log_order(o.id, o.status, 'courier_assigned', 'admin', a.id, 'route');
      v_assigned := v_assigned + 1;
    end if;
  end loop;
  update amine.routes set distance_km = round(v_km, 2) where id = r.id returning * into r;
  if v_courier is not null then
    perform amine.notify(v_courier, 'route_assigned', jsonb_build_object('day', v_day, 'count', v_seq), '#/courier');
  end if;
  perform amine.audit('route.saved', 'route', r.id::text, jsonb_build_object('orders', v_seq, 'courier_id', v_courier));
  return amine.route_json(r);
end $$;

create or replace function public.admin_delete_route(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  r amine.routes;
begin
  select * into r from amine.routes where id = p_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  update amine.orders x set route_id = null, route_seq = null,
    courier_id = case when x.status in ('picked_up', 'delivered') then x.courier_id
                      when x.courier_id = r.courier_id then null else x.courier_id end,
    assigned_at = case when x.status not in ('picked_up', 'delivered') and x.courier_id = r.courier_id then null else x.assigned_at end,
    updated_at = now()
  where x.route_id = r.id;
  delete from amine.routes where id = r.id;
  perform amine.audit('route.deleted', 'route', r.id::text, '{}'::jsonb);
  return jsonb_build_object('deleted', true);
end $$;

-- =============================================================================================
--  Opérations (version 4) : espèces remises par les livreurs, bons de commande aux fournisseurs
--  et suggestions de réapprovisionnement, sauvegarde complète, notifications push, double
--  authentification (aide de dépannage).
--  (Preuve de livraison : 06_courier.sql ; lots « premier périmé, premier sorti » : 08_business.sql.)
-- =============================================================================================

-- ── Espèces des livreurs ──────────────────────────────────────────────────────────────────────
-- En main = espèces encaissées sur les commandes livrées depuis la version 4 − espèces remises.
create or replace function amine.courier_cash_json(c amine.couriers) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('collected', x.collected, 'handed_over', x.handed, 'in_hand', x.collected - x.handed,
    'since', c.cash_since, 'last_handover_at', x.last_at)
  from (select
      coalesce((select sum(o.cod_collected) from amine.orders o where o.courier_id = c.user_id
        and o.status = 'delivered' and o.cod_collected is not null and o.delivered_at >= c.cash_since), 0)::bigint as collected,
      coalesce((select sum(h.amount) from amine.cash_handovers h where h.courier_id = c.user_id), 0)::bigint as handed,
      (select max(h.created_at) from amine.cash_handovers h where h.courier_id = c.user_id) as last_at) x
$$;

create or replace function amine.handover_json(h amine.cash_handovers) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', h.id, 'amount', h.amount, 'note', h.note, 'created_at', h.created_at,
    'store', (select jsonb_build_object('id', s.id, 'name', s.name) from amine.stores s where s.id = h.store_id),
    'courier', (select jsonb_build_object('id', p.id, 'name', p.full_name, 'phone', p.phone)
      from amine.profiles p where p.id = h.courier_id),
    'received_by', (select p.full_name from amine.profiles p where p.id = h.received_by))
$$;

create or replace function public.courier_cash(p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
begin
  return amine.courier_cash_json(c) || jsonb_build_object('handovers', coalesce((
    select jsonb_agg(amine.handover_json(h) order by h.created_at desc)
    from (select * from amine.cash_handovers where courier_id = c.user_id order by created_at desc
          limit least(greatest(coalesce(p_limit, 50), 1), 200)) h), '[]'::jsonb));
end $$;

-- Remise d'espèces : le montant ne peut pas dépasser ce que le livreur a en main.
create or replace function amine.record_handover(p_courier uuid, p_store uuid, p_amount int, p_note text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  c amine.couriers;
  h amine.cash_handovers;
  v_in_hand bigint;
begin
  select * into c from amine.couriers where user_id = p_courier for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if p_amount is null or p_amount < 1 or p_amount > 100000000 then
    perform amine.err('INVALID_INPUT', 'amount');
  end if;
  v_in_hand := (amine.courier_cash_json(c) ->> 'in_hand')::bigint;
  if p_amount > v_in_hand then
    perform amine.err('CASH_TOO_HIGH', greatest(v_in_hand, 0)::text);
  end if;
  insert into amine.cash_handovers (courier_id, store_id, amount, note, received_by)
  values (c.user_id, p_store, p_amount, amine.txt(p_note, 'note', 200), auth.uid())
  returning * into h;
  perform amine.audit('cash.handover', 'courier', c.user_id::text,
    jsonb_build_object('amount', p_amount, 'store_id', p_store, 'handover_id', h.id));
  perform amine.notify(c.user_id, 'cash_received', jsonb_build_object('amount', p_amount,
    'store', coalesce((select s.name from amine.stores s where s.id = p_store), 'AMINE')), '#/courier/cash');
  return amine.handover_json(h);
end $$;

-- Dépôt : livreurs ayant livré ses commandes (60 derniers jours), espèces en main, remises reçues.
create or replace function public.merchant_courier_cash(p_store_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  return jsonb_build_object(
    'couriers', coalesce((
      select jsonb_agg(x.j order by (x.j ->> 'in_hand')::bigint desc, x.j ->> 'name')
      from (select amine.courier_cash_json(c) || jsonb_build_object('courier_id', c.user_id, 'name', p.full_name,
                'phone', p.phone,
                'collected_here', coalesce((select sum(o.cod_collected) from amine.orders o where o.store_id = s.id
                  and o.courier_id = c.user_id and o.status = 'delivered' and o.delivered_at >= c.cash_since), 0),
                'handed_here', coalesce((select sum(h.amount) from amine.cash_handovers h
                  where h.store_id = s.id and h.courier_id = c.user_id), 0)) as j
            from amine.couriers c join amine.profiles p on p.id = c.user_id
            where exists (select 1 from amine.orders o where o.store_id = s.id and o.courier_id = c.user_id
              and o.status = 'delivered' and o.delivered_at >= now() - interval '60 days')) x), '[]'::jsonb),
    'handovers', coalesce((
      select jsonb_agg(amine.handover_json(h) order by h.created_at desc)
      from (select * from amine.cash_handovers where store_id = s.id order by created_at desc limit 100) h), '[]'::jsonb));
end $$;

create or replace function public.merchant_record_handover(p_store_id uuid, p_courier_id uuid, p_amount int,
  p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  perform amine.hit('handover:' || auth.uid(), 120, 3600);
  -- Seulement un livreur qui a livré des commandes de ce dépôt.
  if not exists (select 1 from amine.orders o where o.store_id = s.id and o.courier_id = p_courier_id
                 and o.status = 'delivered') then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.record_handover(p_courier_id, s.id, p_amount, p_note);
end $$;

create or replace function public.admin_courier_cash() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  return jsonb_build_object(
    'couriers', coalesce((
      select jsonb_agg(x.j order by (x.j ->> 'in_hand')::bigint desc, x.j ->> 'name')
      from (select amine.courier_cash_json(c) || jsonb_build_object('courier_id', c.user_id, 'name', p.full_name,
                'phone', p.phone, 'status', c.status, 'is_online', c.is_online) as j
            from amine.couriers c join amine.profiles p on p.id = c.user_id
            where c.status = 'approved' or exists (select 1 from amine.orders o where o.courier_id = c.user_id
              and o.status = 'delivered' and o.delivered_at >= c.cash_since)) x), '[]'::jsonb),
    'handovers', coalesce((
      select jsonb_agg(amine.handover_json(h) order by h.created_at desc)
      from (select * from amine.cash_handovers order by created_at desc limit 200) h), '[]'::jsonb));
end $$;

create or replace function public.admin_record_handover(p_courier_id uuid, p_amount int, p_note text default null,
  p_store_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  if p_store_id is not null and not exists (select 1 from amine.stores where id = p_store_id) then
    perform amine.err('INVALID_INPUT', 'store_id');
  end if;
  return amine.record_handover(p_courier_id, p_store_id, p_amount, p_note);
end $$;

-- Correction d'une remise saisie par erreur (administration).
create or replace function public.admin_delete_handover(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  h amine.cash_handovers;
begin
  delete from amine.cash_handovers where id = p_id returning * into h;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  perform amine.audit('cash.handover_deleted', 'courier', coalesce(h.courier_id::text, ''),
    jsonb_build_object('amount', h.amount, 'store_id', h.store_id, 'created_at', h.created_at));
  return jsonb_build_object('deleted', true);
end $$;

-- ── Bons de commande aux fournisseurs ─────────────────────────────────────────────────────────
create or replace function amine.po_json(po amine.purchase_orders, p_lines boolean) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', po.id, 'number', po.number, 'status', po.status, 'expected_on', po.expected_on,
    'note', po.note, 'total', po.total, 'created_at', po.created_at, 'sent_at', po.sent_at,
    'received_at', po.received_at, 'purchase_id', po.purchase_id,
    'supplier', (select jsonb_build_object('id', x.id, 'name', x.name, 'phone', x.phone, 'email', x.email,
        'address', x.address, 'tax_id', x.tax_id) from amine.suppliers x where x.id = po.supplier_id),
    'lines_count', (select count(*) from amine.purchase_order_lines l where l.po_id = po.id),
    'by', (select p.full_name from amine.profiles p where p.id = po.created_by))
  || case when not p_lines then '{}'::jsonb else jsonb_build_object(
    'store', (select jsonb_build_object('id', s.id, 'name', s.name, 'address', s.address, 'phone', s.phone)
      from amine.stores s where s.id = po.store_id),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'name', l.name, 'unit', l.unit,
          'quantity', l.quantity, 'unit_cost', l.unit_cost, 'total', l.quantity::bigint * coalesce(l.unit_cost, 0),
          'ref', pr.ref, 'stock', pr.stock, 'name_ar', pr.name_ar, 'name_en', pr.name_en) order by l.name)
      from amine.purchase_order_lines l left join amine.products pr on pr.id = l.product_id
      where l.po_id = po.id), '[]'::jsonb)) end
$$;

create or replace function public.merchant_pos(p_store_id uuid, p_status text default null, p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  if p_status is not null and p_status not in ('draft', 'sent', 'received', 'cancelled') then
    perform amine.err('INVALID_INPUT', 'status');
  end if;
  return coalesce((select jsonb_agg(amine.po_json(x, false) order by x.created_at desc)
    from (select * from amine.purchase_orders where store_id = s.id and (p_status is null or status = p_status)
          order by created_at desc limit least(greatest(coalesce(p_limit, 100), 1), 300)) x), '[]'::jsonb);
end $$;

create or replace function public.merchant_po(p_store_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  po amine.purchase_orders;
begin
  select * into po from amine.purchase_orders where id = p_id and store_id = s.id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.po_json(po, true);
end $$;

-- Brouillon (création ou modification) : p_data {"supplier_id", "expected_on", "note",
--   "lines": [{"product_id", "quantity", "unit_cost"}]} ; coût par défaut : dernier coût d'achat.
create or replace function public.merchant_save_po(p_store_id uuid, p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  v_today date := (now() at time zone 'Africa/Tunis')::date;
  po amine.purchase_orders;
  pr amine.products;
  l jsonb;
  v_supplier uuid;
  v_expected date;
  v_qty int;
  v_cost int;
  v_total bigint := 0;
  v_seen uuid[] := '{}';
begin
  perform amine.hit('po:' || auth.uid(), 120, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' or jsonb_typeof(p_data -> 'lines') <> 'array'
     or jsonb_array_length(p_data -> 'lines') = 0 or jsonb_array_length(p_data -> 'lines') > 200 then
    perform amine.err('INVALID_INPUT', 'lines');
  end if;
  v_supplier := amine.uuid_in(p_data, 'supplier_id');
  if v_supplier is not null and not exists (select 1 from amine.suppliers where id = v_supplier and store_id = s.id) then
    perform amine.err('INVALID_INPUT', 'supplier_id');
  end if;
  v_expected := amine.date_in(p_data, 'expected_on');
  if v_expected is not null and (v_expected < v_today - 1 or v_expected > v_today + 365) then
    perform amine.err('INVALID_INPUT', 'expected_on');
  end if;
  if p_id is null then
    insert into amine.purchase_orders (store_id, supplier_id, number, expected_on, note, created_by)
    values (s.id, v_supplier, amine.next_invoice_number('BC'), v_expected,
      amine.txt(p_data ->> 'note', 'note', 300, false, 1, true), auth.uid())
    returning * into po;
  else
    select * into po from amine.purchase_orders where id = p_id and store_id = s.id for update;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
    if po.status <> 'draft' then
      perform amine.err('INVALID_TRANSITION');
    end if;
    update amine.purchase_orders set supplier_id = v_supplier, expected_on = v_expected,
      note = amine.txt(p_data ->> 'note', 'note', 300, false, 1, true)
    where id = po.id;
    delete from amine.purchase_order_lines where po_id = po.id;
  end if;
  for l in select e.value from jsonb_array_elements(p_data -> 'lines') e loop
    if jsonb_typeof(l) <> 'object' then
      perform amine.err('INVALID_INPUT', 'lines');
    end if;
    select * into pr from amine.products where id = amine.uuid_in(l, 'product_id', true) and store_id = s.id and deleted_at is null;
    if not found or pr.id = any (v_seen) then
      perform amine.err('INVALID_INPUT', 'product_id');
    end if;
    v_seen := v_seen || pr.id;
    v_qty := amine.int_in(l, 'quantity', 1, 1000000, true);
    v_cost := coalesce(amine.int_in(l, 'unit_cost', 0, 100000000, false), pr.cost_price);
    insert into amine.purchase_order_lines (po_id, product_id, name, unit, quantity, unit_cost)
    values (po.id, pr.id, pr.name, pr.unit, v_qty, v_cost);
    v_total := v_total + v_qty::bigint * coalesce(v_cost, 0);
  end loop;
  if v_total > 2000000000 then
    perform amine.err('INVALID_INPUT', 'total');
  end if;
  update amine.purchase_orders set total = v_total where id = po.id returning * into po;
  perform amine.audit(case when p_id is null then 'po.created' else 'po.updated' end, 'store', s.id::text,
    jsonb_build_object('po_id', po.id, 'number', po.number, 'total', v_total));
  return amine.po_json(po, true);
end $$;

-- brouillon → envoyé (fournisseur obligatoire) ; envoyé → brouillon ; brouillon/envoyé → annulé.
create or replace function public.merchant_set_po_status(p_store_id uuid, p_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  po amine.purchase_orders;
begin
  select * into po from amine.purchase_orders where id = p_id and store_id = s.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if p_status = 'sent' and po.status = 'draft' then
    if po.supplier_id is null then
      perform amine.err('INVALID_INPUT', 'supplier_id');
    end if;
    update amine.purchase_orders set status = 'sent', sent_at = now() where id = po.id returning * into po;
  elsif p_status = 'draft' and po.status = 'sent' then
    update amine.purchase_orders set status = 'draft', sent_at = null where id = po.id returning * into po;
  elsif p_status = 'cancelled' and po.status in ('draft', 'sent') then
    update amine.purchase_orders set status = 'cancelled' where id = po.id returning * into po;
  elsif p_status not in ('sent', 'draft', 'cancelled') then
    perform amine.err('INVALID_INPUT', 'status');
  else
    perform amine.err('INVALID_TRANSITION');
  end if;
  perform amine.audit('po.' || p_status, 'store', s.id::text, jsonb_build_object('po_id', po.id, 'number', po.number));
  return amine.po_json(po, true);
end $$;

-- Réception d'un bon de commande : crée la réception (stock, lots, coûts) avec les quantités
-- réellement reçues. p_data : comme merchant_save_purchase (le fournisseur est celui du bon).
create or replace function public.merchant_receive_po(p_store_id uuid, p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  po amine.purchase_orders;
  pu amine.purchases;
begin
  perform amine.hit('purchase:' || auth.uid(), 120, 3600);
  select * into po from amine.purchase_orders where id = p_id and store_id = s.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if po.status not in ('draft', 'sent') then
    perform amine.err('INVALID_TRANSITION');
  end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'lines');
  end if;
  pu := amine.create_purchase(s, p_data || jsonb_build_object('supplier_id', po.supplier_id,
    'reference', coalesce(nullif(btrim(coalesce(p_data ->> 'reference', '')), ''), po.number)));
  update amine.purchase_orders set status = 'received', received_at = now(), purchase_id = pu.id
  where id = po.id returning * into po;
  perform amine.audit('po.received', 'store', s.id::text, jsonb_build_object('po_id', po.id, 'purchase_id', pu.id));
  return amine.po_json(po, true);
end $$;

create or replace function public.merchant_delete_po(p_store_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  po amine.purchase_orders;
begin
  select * into po from amine.purchase_orders where id = p_id and store_id = s.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if po.status not in ('draft', 'cancelled') then
    perform amine.err('INVALID_TRANSITION');
  end if;
  delete from amine.purchase_orders where id = po.id;
  perform amine.audit('po.deleted', 'store', s.id::text, jsonb_build_object('po_id', po.id, 'number', po.number));
  return jsonb_build_object('deleted', true);
end $$;

-- Suggestions de réapprovisionnement : ventes nettes des 28 derniers jours → besoin pour p_days jours,
-- moins le stock et les quantités déjà commandées (bons en brouillon ou envoyés).
create or replace function public.merchant_reorder_suggestions(p_store_id uuid, p_days int default 14) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  v_days int := least(greatest(coalesce(p_days, 14), 1), 90);
begin
  return jsonb_build_object('days', v_days, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('product_id', x.id, 'name', x.name, 'name_ar', x.name_ar, 'name_en', x.name_en,
        'unit', x.unit, 'ref', x.ref, 'stock', x.stock, 'sold_28d', x.sold, 'avg_daily', round(x.sold / 28.0, 2),
        'days_left', case when x.sold > 0 then floor(x.stock * 28.0 / x.sold)::int end,
        'on_order', x.on_order, 'suggested', x.need, 'unit_cost', x.unit_cost,
        'supplier', (select jsonb_build_object('id', sp.id, 'name', sp.name) from amine.suppliers sp where sp.id = x.supplier_id))
      order by case when x.sold > 0 then x.stock * 28.0 / x.sold end nulls last, x.name)
    from (
      select p.id, p.name, p.name_ar, p.name_en, p.unit, p.ref, p.stock,
        coalesce(sl.sold, 0) as sold, coalesce(oo.qty, 0) as on_order,
        -- Multiplication avant division : un besoin de 20 exactement ne devient pas 21 par arrondi.
        ceil(coalesce(sl.sold, 0) * v_days / 28.0)::int - p.stock - coalesce(oo.qty, 0)::int as need,
        coalesce(ls.unit_cost, p.cost_price) as unit_cost, ls.supplier_id
      from amine.products p
      left join lateral (select greatest(-sum(m.quantity), 0)::int as sold from amine.stock_movements m
        where m.product_id = p.id and m.kind in ('sale', 'return') and m.created_at >= now() - interval '28 days') sl on true
      left join lateral (select sum(l.quantity)::int as qty from amine.purchase_order_lines l
        join amine.purchase_orders po on po.id = l.po_id
        where l.product_id = p.id and po.store_id = s.id and po.status in ('draft', 'sent')) oo on true
      left join lateral (select pu.supplier_id, l.unit_cost from amine.purchase_lines l
        join amine.purchases pu on pu.id = l.purchase_id
        where l.product_id = p.id and pu.status = 'received' order by pu.received_on desc, pu.created_at desc limit 1) ls on true
      where p.store_id = s.id and p.deleted_at is null and p.stock is not null) x
    where x.need > 0), '[]'::jsonb));
end $$;

-- ── Sauvegarde complète (administration) ──────────────────────────────────────────────────────
-- Toutes les tables d'AMINE en JSON, sauf les données techniques sans valeur de sauvegarde ou
-- secrètes (limites de débit, clés et file des notifications push, abonnements des appareils).
-- Les fichiers (images, preuves de livraison) et les comptes Supabase Auth ne sont pas inclus.
create or replace function public.admin_export_all() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  r record;
  v jsonb := '{}'::jsonb;
  t jsonb;
begin
  perform amine.hit('export_all:' || a.id, 5, 3600);
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'amine' and c.relkind = 'r'
      and c.relname not in ('rate_limits', 'push_keys', 'push_queue', 'push_subscriptions')
    order by c.relname
  loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from amine.%I x', r.relname) into t;
    v := v || jsonb_build_object(r.relname, t);
  end loop;
  perform amine.audit('data.exported_all', 'platform', 'amine', jsonb_build_object('tables', (select count(*) from jsonb_object_keys(v))));
  return jsonb_build_object('app', 'amine', 'schema_version', 5, 'exported_at', now(), 'tables', v);
end $$;

-- ── Notifications push (application fermée) ──────────────────────────────────────────────────
-- Services de notification des navigateurs acceptés (empêche la base d'appeler d'autres adresses).
create or replace function amine.push_endpoint_ok(p text) returns boolean
language sql immutable set search_path = '' as $$
  select p is not null and char_length(p) <= 1000
    and p ~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+(\.[a-z0-9-]+)*\.push\.apple\.com|[a-z0-9-]+(\.[a-z0-9-]+)*\.notify\.windows\.com)/[A-Za-z0-9._~:/?=&%+-]+$'
$$;

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  perform amine.hit('push_sub:' || p.id, 30, 3600);
  if not amine.push_endpoint_ok(p_endpoint) then
    perform amine.err('INVALID_INPUT', 'endpoint');
  end if;
  if coalesce(p_p256dh, '') !~ '^[A-Za-z0-9_-]{80,100}={0,2}$' then
    perform amine.err('INVALID_INPUT', 'p256dh');
  end if;
  if coalesce(p_auth, '') !~ '^[A-Za-z0-9_-]{16,32}={0,2}$' then
    perform amine.err('INVALID_INPUT', 'auth');
  end if;
  -- Un appareil déjà enregistré pour un autre compte (déconnexion sans désabonnement) passe à ce compte.
  insert into amine.push_subscriptions (user_id, endpoint, p256dh, auth)
  values (p.id, p_endpoint, rtrim(p_p256dh, '='), rtrim(p_auth, '='))
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
    created_at = now();
  delete from amine.push_subscriptions where id in (
    select id from amine.push_subscriptions where user_id = p.id order by created_at desc offset 10);
  return jsonb_build_object('saved', true, 'enabled', coalesce((amine.setting('push') ->> 'enabled')::boolean, false));
end $$;

create or replace function public.delete_push_subscription(p_endpoint text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  delete from amine.push_subscriptions where endpoint = p_endpoint and user_id = p.id;
  return jsonb_build_object('deleted', found);
end $$;

-- Réveille la fonction d'envoi (Supabase Edge Function) par l'extension pg_net, une fois par
-- transaction, s'il reste des messages en file. Sans pg_net : rien (les messages restent en file).
create or replace function amine.push_wake() returns void
language plpgsql set search_path = '' as $$
declare
  v jsonb := amine.setting('push');
  v_token text;
begin
  if not coalesce((v ->> 'enabled')::boolean, false) or coalesce(v ->> 'function_url', '') = ''
     or coalesce(current_setting('amine.push_woken', true), '') = '1'
     or not exists (select 1 from pg_extension where extname = 'pg_net')
     or not exists (select 1 from amine.push_queue q where q.attempts < 5
                    and (q.taken_at is null or q.taken_at < now() - interval '2 minutes')) then
    return;
  end if;
  perform set_config('amine.push_woken', '1', true);
  select wake_token into v_token from amine.push_keys where id = 1;
  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 5000)'
    using v ->> 'function_url', '{}'::jsonb,
      jsonb_build_object('Content-Type', 'application/json', 'x-amine-wake', v_token);
exception when others then
  raise warning 'amine push_wake: %', sqlerrm;
end $$;

-- Chaque notification de l'application est mise en file pour les appareils abonnés du destinataire.
create or replace function amine.on_notification_push() returns trigger
language plpgsql set search_path = '' as $$
begin
  if coalesce((amine.setting('push') ->> 'enabled')::boolean, false) then
    insert into amine.push_queue (subscription_id, payload)
    select s.id, jsonb_build_object('id', new.id, 'kind', new.kind, 'params', new.params, 'link', new.link,
        'locale', p.locale, 'created_at', new.created_at)
    from amine.push_subscriptions s join amine.profiles p on p.id = s.user_id
    where s.user_id = new.user_id;
  end if;
  return null;
exception when others then
  raise warning 'amine push queue: %', sqlerrm;
  return null;
end $$;

create or replace function amine.on_notifications_inserted() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform amine.push_wake();
  return null;
end $$;

drop trigger if exists amine_notification_push on amine.notifications;
create trigger amine_notification_push after insert on amine.notifications
  for each row execute function amine.on_notification_push();
drop trigger if exists amine_notifications_wake on amine.notifications;
create trigger amine_notifications_wake after insert on amine.notifications
  for each statement execute function amine.on_notifications_inserted();

-- Fonctions appelées par la fonction d'envoi (connexion directe à la base, jamais par l'API).
create or replace function amine.push_config() returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('public_key', k.public_key, 'private_jwk', k.private_jwk, 'wake_token', k.wake_token)
  from amine.push_keys k where k.id = 1
$$;

-- Première exécution : la fonction d'envoi crée la paire de clés VAPID et l'enregistre (une seule fois).
create or replace function amine.push_set_keys(p_public text, p_private jsonb) returns jsonb
language plpgsql set search_path = '' as $$
begin
  if coalesce(p_public, '') !~ '^[A-Za-z0-9_-]{80,100}$' or p_private is null or jsonb_typeof(p_private) <> 'object'
     or p_private ->> 'kty' <> 'EC' or p_private ->> 'crv' <> 'P-256' or p_private ->> 'd' is null then
    perform amine.err('INVALID_INPUT', 'keys');
  end if;
  update amine.push_keys set public_key = p_public, private_jwk = p_private where id = 1 and public_key is null;
  return amine.push_config();
end $$;

create or replace function amine.push_take(p_limit int default 100) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v jsonb;
begin
  with picked as (
    select q.id from amine.push_queue q
    where q.attempts < 5 and (q.taken_at is null or q.taken_at < now() - interval '2 minutes')
    order by q.id limit least(greatest(coalesce(p_limit, 100), 1), 500)
    for update skip locked),
  upd as (
    update amine.push_queue q set taken_at = now(), attempts = q.attempts + 1
    from picked where q.id = picked.id
    returning q.id, q.subscription_id, q.payload)
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'subscription_id', s.id, 'endpoint', s.endpoint,
      'p256dh', s.p256dh, 'auth', s.auth, 'payload', u.payload) order by u.id), '[]'::jsonb)
  into v from upd u join amine.push_subscriptions s on s.id = u.subscription_id;
  return v;
end $$;

-- p_sent : messages acceptés par le service ; p_gone : abonnements expirés (réponse 404 ou 410).
create or replace function amine.push_done(p_sent bigint[], p_gone uuid[]) returns void
language plpgsql set search_path = '' as $$
begin
  update amine.push_subscriptions s set last_used_at = now()
  where s.id in (select q.subscription_id from amine.push_queue q where q.id = any (coalesce(p_sent, '{}')));
  delete from amine.push_queue where id = any (coalesce(p_sent, '{}'));
  delete from amine.push_subscriptions where id = any (coalesce(p_gone, '{}'));
end $$;

-- ── Double authentification : dépannage ───────────────────────────────────────────────────────
-- Téléphone perdu : retirer les facteurs d'un compte, depuis SQL Editor uniquement :
--   select amine.reset_mfa('vous@exemple.com');
create or replace function amine.reset_mfa(p_email text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_n int;
begin
  select u.id into v_id from auth.users u where lower(u.email) = lower(btrim(p_email));
  if v_id is null then
    return 'Aucun compte avec cet e-mail.';
  end if;
  delete from auth.mfa_factors where user_id = v_id;
  get diagnostics v_n = row_count;
  insert into amine.audit_log (actor_id, action, entity, entity_id, details)
  values (null, 'user.mfa_reset', 'profile', v_id::text, jsonb_build_object('factors', v_n));
  return 'OK : ' || v_n || ' facteur(s) retiré(s) pour ' || p_email || '.';
end $$;

-- =============================================================================================
--  Comptes (Supabase Auth), stockage des images, droits d'accès, données de départ
-- =============================================================================================

-- Profil créé automatiquement à l'inscription ----------------------------------------------------
create or replace function public.amine_handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into amine.profiles (id, email, full_name, phone, locale, business_name, business_type)
  values (
    new.id,
    lower(new.email),
    left(btrim(regexp_replace(coalesce(meta ->> 'full_name', ''), '[[:cntrl:]]', ' ', 'g')), 120),
    amine.normalize_phone(meta ->> 'phone'),
    case when meta ->> 'locale' in ('fr', 'ar', 'en') then meta ->> 'locale' else 'fr' end,
    nullif(left(btrim(regexp_replace(coalesce(meta ->> 'business_name', ''), '[[:cntrl:]]', ' ', 'g')), 120), ''),
    case when meta ->> 'business_type' in ('restaurant', 'cafe', 'hotel', 'snack', 'caterer', 'bakery', 'other')
      then meta ->> 'business_type' end)
  on conflict (id) do nothing;
  -- Code de parrainage saisi à l'inscription (facultatif) : un code invalide ne bloque jamais l'inscription.
  if nullif(btrim(coalesce(meta ->> 'referral_code', '')), '') is not null then
    begin
      perform amine.link_referral(new.id, meta ->> 'referral_code');
    exception when others then
      null;
    end;
  end if;
  return new;
exception when others then
  -- Une donnée de profil invalide ne doit jamais bloquer une inscription (le profil sera
  -- complété à la première connexion).
  raise warning 'amine_handle_new_user: %', sqlerrm;
  return new;
end $$;

drop trigger if exists amine_on_auth_user_created on auth.users;
create trigger amine_on_auth_user_created
  after insert on auth.users
  for each row execute function public.amine_handle_new_user();

-- E-mail modifié ou téléphone confirmé par SMS (Supabase Auth) : le profil suit.
create or replace function public.amine_handle_user_updated() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_phone text := amine.normalize_phone(new.phone);
begin
  update amine.profiles set
    email = lower(new.email),
    phone = case when new.phone_confirmed_at is not null and v_phone is not null then v_phone else phone end,
    phone_verified = case when new.phone_confirmed_at is not null and v_phone is not null then true else phone_verified end,
    updated_at = now()
  where id = new.id;
  return new;
exception when others then
  raise warning 'amine_handle_user_updated: %', sqlerrm;
  return new;
end $$;

drop trigger if exists amine_on_auth_user_updated on auth.users;
create trigger amine_on_auth_user_updated
  after update of email, phone, phone_confirmed_at on auth.users
  for each row execute function public.amine_handle_user_updated();

-- Stockage des images (logos, couvertures, produits) ------------------------------------------------
-- Bucket public en lecture ; écriture réservée à l'équipe du commerce dans stores/<id_commerce>/.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('amine-media', 'amine-media', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.amine_can_write_media(p_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_parts text[];
  v_store uuid;
begin
  if v_uid is null or p_name is null then
    return false;
  end if;
  v_parts := string_to_array(p_name, '/');
  if coalesce(array_length(v_parts, 1), 0) <> 3 or v_parts[1] <> 'stores'
     or v_parts[2] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or v_parts[3] !~ '^[A-Za-z0-9_-]{6,80}\.(jpg|jpeg|png|webp)$' then
    return false;
  end if;
  v_store := v_parts[2]::uuid;
  return exists (
    select 1 from amine.profiles p
    where p.id = v_uid and p.status = 'active' and amine.mfa_state(p) = 'ok'
      and (p.is_admin or exists (select 1 from amine.store_staff st where st.store_id = v_store and st.user_id = v_uid)));
end $$;

drop policy if exists "amine_media_insert" on storage.objects;
create policy "amine_media_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'amine-media' and public.amine_can_write_media(name));
drop policy if exists "amine_media_update" on storage.objects;
create policy "amine_media_update" on storage.objects for update to authenticated
  using (bucket_id = 'amine-media' and public.amine_can_write_media(name))
  with check (bucket_id = 'amine-media' and public.amine_can_write_media(name));
drop policy if exists "amine_media_delete" on storage.objects;
create policy "amine_media_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'amine-media' and public.amine_can_write_media(name));
drop policy if exists "amine_media_select" on storage.objects;
create policy "amine_media_select" on storage.objects for select to authenticated
  using (bucket_id = 'amine-media' and public.amine_can_write_media(name));

-- Preuves de livraison (version 4) : bucket privé, fichiers orders/<id_commande>/(photo|signature)-….
-- Dépôt : le livreur de la commande pendant la livraison. Lecture : le client de la commande, l'équipe
-- du dépôt, le livreur et l'administration. Aucune modification ni suppression par l'API.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('amine-proofs', 'amine-proofs', false, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.amine_can_access_proof(p_name text, p_write boolean) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_parts text[];
  p amine.profiles;
  o amine.orders;
begin
  if v_uid is null or p_name is null then
    return false;
  end if;
  v_parts := string_to_array(p_name, '/');
  if coalesce(array_length(v_parts, 1), 0) <> 3 or v_parts[1] <> 'orders'
     or v_parts[2] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or v_parts[3] !~ '^(photo|signature)-[A-Za-z0-9_-]{6,40}\.(jpg|jpeg|png|webp)$' then
    return false;
  end if;
  select * into p from amine.profiles where id = v_uid and status = 'active';
  if not found or amine.mfa_state(p) <> 'ok' then
    return false;
  end if;
  select * into o from amine.orders where id = v_parts[2]::uuid;
  if not found then
    return false;
  end if;
  if p_write then
    return o.courier_id = v_uid and o.status = 'picked_up';
  end if;
  return p.is_admin or o.customer_id = v_uid or o.courier_id = v_uid
    or exists (select 1 from amine.store_staff st where st.store_id = o.store_id and st.user_id = v_uid);
end $$;

drop policy if exists "amine_proofs_insert" on storage.objects;
create policy "amine_proofs_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'amine-proofs' and public.amine_can_access_proof(name, true));
drop policy if exists "amine_proofs_select" on storage.objects;
create policy "amine_proofs_select" on storage.objects for select to authenticated
  using (bucket_id = 'amine-proofs' and public.amine_can_access_proof(name, false));

-- Extension pg_net (appels HTTP depuis la base) : réveille la fonction d'envoi des notifications
-- push. Facultative : sans elle, tout le reste fonctionne.
do $$
begin
  create extension if not exists pg_net;
exception when others then
  raise notice 'pg_net non disponible : %', sqlerrm;
end $$;

-- Droits d'accès -----------------------------------------------------------------------------------
-- Chaque fonction exposée reçoit un droit explicite : le script fonctionne aussi sur les projets où
-- Supabase n'expose plus automatiquement les nouveaux objets du schéma public (changement 2026).
grant usage on schema public to anon, authenticated;
revoke all on all tables in schema amine from public, anon, authenticated;
revoke all on all sequences in schema amine from public, anon, authenticated;
revoke all on all functions in schema amine from public, anon, authenticated;
revoke all on schema amine from public, anon, authenticated;

do $$
declare
  r record;
  v_public text[] := array['amine_health', 'get_public_config', 'get_catalog', 'quote_order', 'quote_parcel'];
  v_authenticated text[] := array['get_me', 'update_my_profile', 'update_my_business',
    'list_my_addresses', 'save_address', 'delete_address',
    'place_order', 'place_parcel', 'list_my_orders', 'get_my_order', 'update_my_order', 'get_order_tracking',
    'cancel_my_order', 'rate_order', 'toggle_favorite', 'list_my_favorites', 'my_frequent_products',
    'create_complaint', 'list_my_complaints', 'update_my_complaint', 'delete_my_complaint',
    'list_my_notifications', 'mark_notifications_read', 'delete_my_notifications', 'export_my_data', 'delete_my_account',
    'merchant_store', 'merchant_update_store', 'merchant_set_open', 'merchant_save_section',
    'merchant_delete_section', 'merchant_save_product', 'merchant_set_product_available', 'merchant_set_stock',
    'merchant_delete_product', 'merchant_import_products', 'merchant_adjust_prices', 'merchant_set_product_image', 'merchant_orders', 'merchant_order',
    'merchant_update_order', 'merchant_stats', 'merchant_staff', 'merchant_add_staff', 'merchant_remove_staff',
    'courier_me', 'apply_courier', 'courier_set_online', 'courier_jobs', 'courier_job', 'courier_accept', 'courier_release',
    'courier_update_job', 'courier_location', 'courier_stop_location', 'courier_history',
    'admin_dashboard', 'admin_depots', 'admin_save_depot', 'admin_delete_depot', 'admin_find_user',
    'admin_clients', 'admin_client', 'admin_save_client', 'admin_delete_client', 'admin_save_client_address',
    'admin_delete_client_address', 'admin_couriers', 'admin_save_courier', 'admin_delete_courier',
    'admin_orders', 'admin_order', 'admin_create_order', 'admin_update_order', 'admin_order_action',
    'admin_zones', 'admin_save_city', 'admin_delete_city', 'admin_save_zone', 'admin_delete_zone',
    'admin_promotions', 'admin_save_promotion', 'admin_delete_promotion',
    'admin_complaints', 'admin_update_complaint', 'admin_delete_complaint',
    'admin_prospects', 'admin_import_prospects', 'admin_save_prospect', 'admin_delete_prospect',
    'admin_settings', 'admin_update_setting', 'admin_finance', 'admin_audit', 'amine_can_write_media',
    -- Version 3 : factures, compte client, prix négociés, récurrences, pesée, stock, tournées.
    'my_account', 'get_my_invoice', 'list_my_recurring', 'save_my_recurring', 'delete_my_recurring',
    'merchant_invoice', 'merchant_set_weights', 'merchant_suppliers', 'merchant_save_supplier', 'merchant_delete_supplier',
    'merchant_purchases', 'merchant_purchase', 'merchant_save_purchase', 'merchant_cancel_purchase',
    'merchant_record_stock', 'merchant_stock',
    'admin_client_account', 'admin_invoice', 'admin_record_payment', 'admin_delete_account_entry',
    'admin_issue_credit_note', 'admin_invoices', 'admin_receivables', 'admin_client_prices', 'admin_save_client_price',
    'admin_recurring', 'admin_save_recurring', 'admin_delete_recurring', 'admin_routes', 'admin_save_route',
    'admin_delete_route',
    -- Version 4 : preuve de livraison, espèces, bons de commande, sauvegarde, notifications push.
    'amine_can_access_proof', 'courier_cash', 'merchant_courier_cash', 'merchant_record_handover',
    'admin_courier_cash', 'admin_record_handover', 'admin_delete_handover',
    'merchant_pos', 'merchant_po', 'merchant_save_po', 'merchant_set_po_status', 'merchant_receive_po', 'merchant_delete_po',
    'merchant_reorder_suggestions', 'admin_export_all', 'save_push_subscription', 'delete_push_subscription'];
begin
  for r in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and (p.proname = any (v_public) or p.proname = any (v_authenticated)
      or p.proname in ('amine_handle_new_user', 'amine_handle_user_updated'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    if r.proname = any (v_public) then
      execute format('grant execute on function %s to anon, authenticated', r.sig);
    elsif r.proname = any (v_authenticated) then
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;
  end loop;
end $$;

-- Données de départ : Grand Tunis, zones de livraison du lancement (modifiables dans l'administration).
-- Rayons et centres approximatifs, à ajuster selon le terrain.
insert into amine.cities (id, name_fr, name_ar, name_en, sort) values
  ('6a1f0c3e-0001-4000-8000-000000000101', 'Grand Tunis', 'تونس الكبرى', 'Greater Tunis', 1)
on conflict (id) do nothing;

insert into amine.zones (id, city_id, name_fr, name_ar, name_en, center_lat, center_lng, radius_km, services, sort) values
  ('6a1f0c3e-0002-4000-8000-000000000101', '6a1f0c3e-0001-4000-8000-000000000101',
   'Tunis Centre', 'تونس المركز', 'Tunis Centre', 36.805000, 10.179000, 3.2, array['grocery'], 1),
  ('6a1f0c3e-0002-4000-8000-000000000102', '6a1f0c3e-0001-4000-8000-000000000101',
   'Les Berges du Lac', 'ضفاف البحيرة', 'Les Berges du Lac', 36.840000, 10.250000, 3.2, array['grocery'], 2),
  ('6a1f0c3e-0002-4000-8000-000000000103', '6a1f0c3e-0001-4000-8000-000000000101',
   'La Marsa – Carthage', 'المرسى – قرطاج', 'La Marsa – Carthage', 36.875000, 10.318000, 4.5, array['grocery'], 3),
  ('6a1f0c3e-0002-4000-8000-000000000104', '6a1f0c3e-0001-4000-8000-000000000101',
   'La Goulette – Le Kram', 'حلق الوادي – الكرم', 'La Goulette – Le Kram', 36.825000, 10.307000, 2.5, array['grocery'], 4),
  ('6a1f0c3e-0002-4000-8000-000000000105', '6a1f0c3e-0001-4000-8000-000000000101',
   'El Menzah – Ennasr', 'المنزه – النصر', 'El Menzah – Ennasr', 36.846000, 10.165000, 3.0, array['grocery'], 5),
  ('6a1f0c3e-0002-4000-8000-000000000106', '6a1f0c3e-0001-4000-8000-000000000101',
   'Ariana', 'أريانة', 'Ariana', 36.862500, 10.195600, 2.5, array['grocery'], 6),
  ('6a1f0c3e-0002-4000-8000-000000000107', '6a1f0c3e-0001-4000-8000-000000000101',
   'Le Bardo', 'باردو', 'Le Bardo', 36.809000, 10.134000, 2.5, array['grocery'], 7),
  ('6a1f0c3e-0002-4000-8000-000000000108', '6a1f0c3e-0001-4000-8000-000000000101',
   'Ben Arous – Mégrine', 'بن عروس – مقرين', 'Ben Arous – Megrine', 36.760000, 10.225000, 3.5, array['grocery'], 8)
on conflict (id) do nothing;

-- Tâches de fond toutes les 5 minutes si l'extension pg_cron est activée (facultatif : sans elle,
-- les mêmes tâches s'exécutent lors des appels de l'application).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('amine-maintenance', '*/5 * * * *', 'select amine.maintenance()');
  end if;
exception when others then
  raise notice 'pg_cron non configuré : %', sqlerrm;
end $$;

-- Demande à l'API de recharger la liste des fonctions.
notify pgrst, 'reload schema';

-- Installation terminée. Étapes suivantes : créez votre compte dans l'application, exécutez
--   select amine.grant_admin('votre@email.com');
-- puis, dans l'administration : créez votre dépôt et importez le catalogue de référence.

-- =============================================================================================
--  Suivi des erreurs de l'application (facultatif)
--  Le navigateur signale les erreurs inattendues (page blanche, exception non rattrapée) ; l'équipe
--  les consulte dans Administration › Journal. Rien de personnel n'est conservé : ni compte, ni
--  adresse IP ; les e-mails, numéros et identifiants sont masqués. Au plus 500 erreurs distinctes,
--  gardées 30 jours. Une application plus ancienne que ce script, ou une base sans ce script, continue
--  de fonctionner : le signalement échoue en silence.
-- =============================================================================================

create table if not exists amine.client_errors (
  id bigint generated always as identity primary key,
  fingerprint text not null unique,
  kind text not null default 'error' check (kind in ('error', 'rejection', 'render')),
  message text not null,
  stack text,
  route text,
  version text,
  locale text,
  browser text,
  count int not null default 1,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now()
);
create index if not exists client_errors_seen_idx on amine.client_errors (last_seen desc);
alter table amine.client_errors enable row level security;
revoke all on amine.client_errors from public, anon, authenticated;

-- Retire ce qui pourrait identifier une personne (e-mails, longs numéros, adresses de page complètes).
create or replace function amine.scrub(p_text text, p_max int) returns text
language sql immutable set search_path = '' as $$
  select left(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(coalesce(p_text, ''), E'[\\x01-\\x09\\x0B-\\x1F\\x7F]', ' ', 'g'),
          '[^[:space:]@<>()"'']+@[^[:space:]@<>()"'']+', '[e-mail]', 'g'),
        '\d{6,}', '#', 'g'),
      '([a-z][a-z0-9+.-]*://[^[:space:]?#)]*)[?#][^[:space:])]*', '\1', 'g'),
    p_max)
$$;

-- Signalement d'une erreur (appelable sans compte : l'erreur peut survenir avant la connexion).
create or replace function public.log_client_error(
  p_message text, p_stack text default null, p_route text default null, p_kind text default 'error',
  p_version text default null, p_locale text default null, p_browser text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_message text := btrim(regexp_replace(amine.scrub(p_message, 300), E'\\s+', ' ', 'g'));
  v_stack text := nullif(amine.scrub(p_stack, 1500), '');
  v_route text := nullif(left(regexp_replace(regexp_replace(regexp_replace(coalesce(p_route, ''), '[?].*$', ''),
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', ':id', 'g'),
    '/[A-Z0-9]{8}(/|$)', '/:code\1', 'g'), 120), '');
  v_kind text := case when p_kind in ('error', 'rejection', 'render') then p_kind else 'error' end;
  v_print text;
begin
  if v_message = '' then
    return;
  end if;
  -- Au plus 200 signalements par heure pour toute la plateforme : une boucle d'erreurs ne remplit pas la base.
  perform amine.hit('client_errors', 200, 3600);
  v_print := md5(v_kind || '|' || left(v_message, 200) || '|' || coalesce(split_part(v_stack, E'\n', 2), ''));
  insert into amine.client_errors as e (fingerprint, kind, message, stack, route, version, locale, browser)
  values (v_print, v_kind, v_message, v_stack, v_route, left(coalesce(p_version, ''), 20),
    case when p_locale in ('fr', 'ar', 'en') then p_locale end, left(coalesce(p_browser, ''), 40))
  on conflict (fingerprint) do update set count = e.count + 1, last_seen = now(), route = excluded.route,
    version = excluded.version, locale = excluded.locale, browser = excluded.browser;
  delete from amine.client_errors where last_seen < now() - interval '30 days';
  delete from amine.client_errors where id in (select id from amine.client_errors order by last_seen desc offset 500);
end $$;

-- Consultation par l'administration.
create or replace function public.admin_client_errors(p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'message', e.message, 'stack', e.stack,
        'route', e.route, 'version', e.version, 'locale', e.locale, 'browser', e.browser, 'count', e.count,
        'first_seen', e.first_seen, 'last_seen', e.last_seen) order by e.last_seen desc)
    from (select * from amine.client_errors order by last_seen desc
      limit least(greatest(coalesce(p_limit, 100), 1), 500)) e), '[]'::jsonb);
end $$;

create or replace function public.admin_clear_client_errors() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_count int;
begin
  delete from amine.client_errors;
  get diagnostics v_count = row_count;
  perform amine.audit('errors.cleared', 'client_errors', null, jsonb_build_object('count', v_count));
  return jsonb_build_object('deleted', v_count);
end $$;

-- Droits : le signalement est ouvert à tous ; la consultation, aux administrateurs connectés.
revoke all on function amine.scrub(text, int) from public, anon, authenticated;
revoke all on function public.log_client_error(text, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.admin_client_errors(int) from public, anon, authenticated;
revoke all on function public.admin_clear_client_errors() from public, anon, authenticated;
grant execute on function public.log_client_error(text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.admin_client_errors(int) to authenticated;
grant execute on function public.admin_clear_client_errors() to authenticated;

-- =============================================================================================
--  Chèques, virements bancaires et avances (version 6)
--
--  • Chèque encaissé à la livraison : le livreur note le numéro et la banque ; le chèque entre dans
--    un registre (collecté → reçu → déposé → encaissé ou impayé). Un chèque impayé remet la somme
--    au compte du client. Les espèces du livreur ne comptent plus que ce qui a réellement été payé
--    en espèces.
--  • Virement : le client téléverse son justificatif (image ou PDF) ; l'administration le valide
--    ou le refuse. Validé, il devient un règlement au compte du client. Un virement peut régler des
--    factures ou constituer une avance ; l'avance solde automatiquement les prochaines factures.
--  • Coordonnées bancaires d'AMINE (RIB / IBAN), affichées aux clients pour leurs virements.
--
--  Ce script remplace quelques fonctions des fichiers précédents (livraison par le livreur,
--  facturation à la livraison, espèces des livreurs, export des données, suppression d'une écriture) ;
--  il peut être rejoué sans risque.
-- =============================================================================================

-- ── Tables ────────────────────────────────────────────────────────────────────────────────────
alter table amine.orders add column if not exists cheque_amount int not null default 0;
alter table amine.orders drop constraint if exists orders_cheque_amount_check;
alter table amine.orders add constraint orders_cheque_amount_check check (cheque_amount between 0 and 1000000000);

create table if not exists amine.cheques (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references amine.profiles (id) on delete set null,
  order_id uuid references amine.orders (id) on delete set null,
  courier_id uuid references amine.profiles (id) on delete set null,
  number text not null check (number ~ '^[0-9A-Za-z/-]{3,30}$'),
  bank text not null check (char_length(bank) between 2 and 60),
  amount int not null check (amount between 1 and 1000000000),
  due_on date,
  status text not null default 'received' check (status in ('collected', 'received', 'deposited', 'cleared', 'bounced')),
  note text check (note is null or char_length(note) <= 300),
  collected_at timestamptz not null default now(),
  status_at timestamptz not null default now(),
  created_by uuid
);
create index if not exists cheques_status_idx on amine.cheques (status, collected_at desc);
create index if not exists cheques_customer_idx on amine.cheques (customer_id);
create index if not exists cheques_order_idx on amine.cheques (order_id);
create index if not exists cheques_courier_idx on amine.cheques (courier_id) where status = 'collected';
create index if not exists cheques_number_idx on amine.cheques (lower(bank), lower(number));
alter table amine.cheques enable row level security;
revoke all on amine.cheques from public, anon, authenticated;

create table if not exists amine.transfers (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references amine.profiles (id) on delete set null,
  purpose text not null default 'invoices' check (purpose in ('invoices', 'advance')),
  amount int not null check (amount between 1 and 1000000000),
  reference text check (reference is null or char_length(reference) <= 80),
  proof text not null check (char_length(proof) <= 200),
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected')),
  reject_reason text check (reject_reason is null or char_length(reject_reason) <= 300),
  entry_id bigint references amine.account_entries (id) on delete set null,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid
);
create index if not exists transfers_status_idx on amine.transfers (status, created_at desc);
create index if not exists transfers_customer_idx on amine.transfers (customer_id, created_at desc);
alter table amine.transfers enable row level security;
revoke all on amine.transfers from public, anon, authenticated;

create table if not exists amine.bank_account (
  id int primary key check (id = 1),
  holder text not null default '',
  bank text not null default '',
  rib text not null default '',
  iban text not null default '',
  note text not null default '',
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table amine.bank_account enable row level security;
revoke all on amine.bank_account from public, anon, authenticated;

-- Justificatifs de virement : même stockage privé que les preuves de livraison.
update storage.buckets set allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
where id = 'amine-proofs';

-- IBAN valide (contrôle modulo 97).
create or replace function amine.valid_iban(p_iban text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare
  v text := upper(regexp_replace(coalesce(p_iban, ''), '\s', '', 'g'));
  v_digits text := '';
  v_char text;
  i int;
begin
  if v !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' then
    return false;
  end if;
  v := substr(v, 5) || substr(v, 1, 4);
  for i in 1..char_length(v) loop
    v_char := substr(v, i, 1);
    v_digits := v_digits || case when v_char ~ '[0-9]' then v_char else (ascii(v_char) - 55)::text end;
  end loop;
  return v_digits::numeric % 97 = 1;
end $$;

-- ── Droits de lecture et d'écriture des justificatifs ─────────────────────────────────────────
--   orders/<id_commande>/(photo|signature)-…        preuves de livraison (inchangé)
--   transfers/<id_client>/proof-…                   justificatifs de virement : déposés par le client,
--                                                   lus par lui et par l'administration
create or replace function public.amine_can_access_proof(p_name text, p_write boolean) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_parts text[];
  p amine.profiles;
  o amine.orders;
begin
  if v_uid is null or p_name is null then
    return false;
  end if;
  v_parts := string_to_array(p_name, '/');
  if coalesce(array_length(v_parts, 1), 0) <> 3
     or v_parts[2] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  select * into p from amine.profiles where id = v_uid and status = 'active';
  if not found or amine.mfa_state(p) <> 'ok' then
    return false;
  end if;
  if v_parts[1] = 'transfers' then
    if v_parts[3] !~ '^proof-[A-Za-z0-9_-]{6,40}\.(jpg|jpeg|png|webp|pdf)$' then
      return false;
    end if;
    return v_parts[2]::uuid = v_uid or (not p_write and p.is_admin);
  end if;
  if v_parts[1] <> 'orders' or v_parts[3] !~ '^(photo|signature)-[A-Za-z0-9_-]{6,40}\.(jpg|jpeg|png|webp)$' then
    return false;
  end if;
  select * into o from amine.orders where id = v_parts[2]::uuid;
  if not found then
    return false;
  end if;
  if p_write then
    return o.courier_id = v_uid and o.status = 'picked_up';
  end if;
  return p.is_admin or o.customer_id = v_uid or o.courier_id = v_uid
    or exists (select 1 from amine.store_staff st where st.store_id = o.store_id and st.user_id = v_uid);
end $$;
revoke all on function public.amine_can_access_proof(text, boolean) from public, anon, authenticated;
grant execute on function public.amine_can_access_proof(text, boolean) to authenticated;

-- ── Chèques : présentation ────────────────────────────────────────────────────────────────────
create or replace function amine.cheque_json(c amine.cheques) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', c.id, 'number', c.number, 'bank', c.bank, 'amount', c.amount, 'due_on', c.due_on,
    'status', c.status, 'note', c.note, 'collected_at', c.collected_at, 'status_at', c.status_at,
    'order_code', (select o.code from amine.orders o where o.id = c.order_id),
    'customer', (select jsonb_build_object('id', p.id, 'name', coalesce(nullif(p.business_name, ''), p.full_name))
      from amine.profiles p where p.id = c.customer_id),
    'courier', (select jsonb_build_object('id', p.id, 'name', p.full_name) from amine.profiles p where p.id = c.courier_id),
    'duplicate', exists (select 1 from amine.cheques d
      where d.id <> c.id and lower(d.bank) = lower(c.bank) and lower(d.number) = lower(c.number)))
$$;

-- ── Espèces des livreurs : seulement ce qui a été payé en espèces ─────────────────────────────
-- (remplace la version de 09_operations.sql ; les chèques en main sont listés à part)
create or replace function amine.courier_cash_json(c amine.couriers) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('collected', x.collected, 'handed_over', x.handed, 'in_hand', x.collected - x.handed,
    'since', c.cash_since, 'last_handover_at', x.last_at, 'cheques', x.cheques)
  from (select
      coalesce((select sum(greatest(0, o.cod_collected - o.cheque_amount)) from amine.orders o where o.courier_id = c.user_id
        and o.status = 'delivered' and o.cod_collected is not null and o.delivered_at >= c.cash_since), 0)::bigint as collected,
      coalesce((select sum(h.amount) from amine.cash_handovers h where h.courier_id = c.user_id), 0)::bigint as handed,
      (select max(h.created_at) from amine.cash_handovers h where h.courier_id = c.user_id) as last_at,
      coalesce((select jsonb_agg(amine.cheque_json(k) order by k.collected_at) from amine.cheques k
        where k.courier_id = c.user_id and k.status = 'collected'), '[]'::jsonb) as cheques) x
$$;

create or replace function public.merchant_courier_cash(p_store_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  return jsonb_build_object(
    'couriers', coalesce((
      select jsonb_agg(x.j order by (x.j ->> 'in_hand')::bigint desc, x.j ->> 'name')
      from (select amine.courier_cash_json(c) || jsonb_build_object('courier_id', c.user_id, 'name', p.full_name,
                'phone', p.phone,
                'collected_here', coalesce((select sum(greatest(0, o.cod_collected - o.cheque_amount)) from amine.orders o
                  where o.store_id = s.id and o.courier_id = c.user_id and o.status = 'delivered'
                    and o.delivered_at >= c.cash_since), 0),
                'handed_here', coalesce((select sum(h.amount) from amine.cash_handovers h
                  where h.store_id = s.id and h.courier_id = c.user_id), 0),
                -- Le dépôt ne voit que les chèques de ses propres commandes.
                'cheques', coalesce((select jsonb_agg(amine.cheque_json(k) order by k.collected_at) from amine.cheques k
                  join amine.orders ko on ko.id = k.order_id
                  where k.courier_id = c.user_id and k.status = 'collected' and ko.store_id = s.id), '[]'::jsonb)) as j
            from amine.couriers c join amine.profiles p on p.id = c.user_id
            where exists (select 1 from amine.orders o where o.store_id = s.id and o.courier_id = c.user_id
              and o.status = 'delivered' and o.delivered_at >= now() - interval '60 days')) x), '[]'::jsonb),
    'handovers', coalesce((
      select jsonb_agg(amine.handover_json(h) order by h.created_at desc)
      from (select * from amine.cash_handovers where store_id = s.id order by created_at desc limit 100) h), '[]'::jsonb));
end $$;
revoke all on function public.merchant_courier_cash(uuid) from public, anon, authenticated;
grant execute on function public.merchant_courier_cash(uuid) to authenticated;

-- ── Livraison : espèces, chèque, ou les deux ──────────────────────────────────────────────────
-- p_cod_collected : total reçu à la porte (espèces + chèque). p_cheque : {"number", "bank",
-- "amount" (par défaut tout le montant reçu), "due_on" (chèque à date, facultatif)}.
drop function if exists public.courier_update_job(text, text, int, jsonb);
create or replace function public.courier_update_job(p_code text, p_action text, p_cod_collected int default null,
  p_pod jsonb default null, p_cheque jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
  o amine.orders;
  v_name text;
  v_photo text;
  v_signature text;
  v_number text;
  v_bank text;
  v_cheque int;
  v_due date;
  v_today date := (now() at time zone 'Africa/Tunis')::date;
begin
  perform amine.hit('courier_action:' || c.user_id, 120, 600);
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and courier_id = c.user_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if p_action = 'picked_up' then
    o := amine.transition(o, 'picked_up', 'courier', c.user_id);
  elsif p_action = 'delivered' then
    if p_pod is not null and jsonb_typeof(p_pod) <> 'object' then
      perform amine.err('INVALID_INPUT', 'pod');
    end if;
    v_name := amine.txt(p_pod ->> 'name', 'pod_name', 80);
    v_photo := amine.pod_file(o.id, p_pod, 'photo');
    v_signature := amine.pod_file(o.id, p_pod, 'signature');
    if coalesce((amine.setting('orders') ->> 'require_pod')::boolean, false)
       and (v_name is null or (v_photo is null and v_signature is null)) then
      perform amine.err('POD_REQUIRED');
    end if;
    if v_name is not null or v_photo is not null or v_signature is not null then
      update amine.orders set pod_name = v_name, pod_photo = v_photo, pod_signature = v_signature, pod_at = now()
      where id = o.id returning * into o;
    end if;
    if o.payment_method = 'account' then
      if coalesce(p_cod_collected, 0) <> 0 or p_cheque is not null then
        perform amine.err('NOTHING_TO_COLLECT');
      end if;
      o := amine.transition(o, 'delivered', 'courier', c.user_id);
    else
      if p_cod_collected is null or p_cod_collected < 0 or p_cod_collected > 100000000 then
        perform amine.err('COD_AMOUNT_REQUIRED');
      end if;
      if p_cheque is not null then
        if jsonb_typeof(p_cheque) <> 'object' then
          perform amine.err('INVALID_INPUT', 'cheque');
        end if;
        v_number := regexp_replace(coalesce(p_cheque ->> 'number', ''), '\s', '', 'g');
        if v_number !~ '^[0-9A-Za-z/-]{3,30}$' then
          perform amine.err('INVALID_INPUT', 'cheque_number');
        end if;
        v_bank := amine.txt(p_cheque ->> 'bank', 'cheque_bank', 60, true, 2);
        v_cheque := coalesce(amine.int_in(jsonb_build_object('cheque_amount', p_cheque ->> 'amount'), 'cheque_amount', 1, 100000000, false),
          p_cod_collected);
        if v_cheque < 1 or v_cheque > p_cod_collected then
          perform amine.err('INVALID_INPUT', 'cheque_amount');
        end if;
        v_due := amine.date_in(jsonb_build_object('cheque_due', p_cheque ->> 'due_on'), 'cheque_due');
        if v_due is not null and (v_due < v_today - 30 or v_due > v_today + 400) then
          perform amine.err('INVALID_INPUT', 'cheque_due');
        end if;
        insert into amine.cheques (customer_id, order_id, courier_id, number, bank, amount, due_on, status, created_by)
        values (o.customer_id, o.id, c.user_id, v_number, v_bank, v_cheque, v_due, 'collected', c.user_id);
        update amine.orders set cheque_amount = v_cheque where id = o.id;
        o.cheque_amount := v_cheque;
      end if;
      update amine.orders set cod_collected = p_cod_collected where id = o.id;
      o.cod_collected := p_cod_collected;
      o := amine.transition(o, 'delivered', 'courier', c.user_id,
        case when p_cod_collected <> o.total then 'cod_mismatch:' || p_cod_collected::text end);
    end if;
  else
    perform amine.err('INVALID_INPUT', 'action');
  end if;
  return amine.order_json(o, 'courier');
end $$;
revoke all on function public.courier_update_job(text, text, int, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.courier_update_job(text, text, int, jsonb, jsonb) to authenticated;

-- Facture, écriture au compte et règlement à la livraison (remplace la version de 08_business.sql :
-- la part payée par chèque est enregistrée comme règlement par chèque, le reste comme espèces).
create or replace function amine.after_delivery(o amine.orders) returns void
language plpgsql set search_path = '' as $$
declare
  inv amine.invoices := amine.issue_invoice(o);
  v_cheque int := least(coalesce(o.cheque_amount, 0), coalesce(o.cod_collected, 0));
  v_number text;
begin
  if o.customer_id is null then
    return;
  end if;
  if inv.total_ttc > 0 then
    insert into amine.account_entries (customer_id, kind, amount, invoice_id, reference, created_by)
    values (o.customer_id, 'invoice', inv.total_ttc, inv.id, inv.number, auth.uid());
  end if;
  if o.payment_method = 'cod' and coalesce(o.cod_collected, 0) > 0 then
    if v_cheque > 0 then
      select k.number into v_number from amine.cheques k where k.order_id = o.id order by k.collected_at desc limit 1;
      insert into amine.account_entries (customer_id, kind, amount, invoice_id, method, reference, note, created_by)
      values (o.customer_id, 'payment', -v_cheque, inv.id, 'cheque', coalesce(v_number, o.code), 'cod', auth.uid());
    end if;
    if o.cod_collected - v_cheque > 0 then
      insert into amine.account_entries (customer_id, kind, amount, invoice_id, method, reference, note, created_by)
      values (o.customer_id, 'payment', -(o.cod_collected - v_cheque), inv.id, 'cash', o.code, 'cod', auth.uid());
    end if;
  end if;
  perform amine.notify(o.customer_id, 'invoice_issued',
    jsonb_build_object('number', inv.number, 'total', inv.total_ttc, 'due_on', inv.due_on, 'code', o.code),
    '#/account/invoices/' || inv.id::text);
end $$;

-- Un règlement par chèque, par virement ou une avance ne s'efface pas : on le corrige par un ajustement
-- (remplace la version de 08_business.sql).
create or replace function public.admin_delete_account_entry(p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  e amine.account_entries;
begin
  select * into e from amine.account_entries where id = p_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if e.kind not in ('payment', 'adjustment') or (e.kind = 'payment' and e.note in ('cod', 'cheque', 'transfer', 'advance'))
     or (e.kind = 'adjustment' and e.note = 'cheque_bounced') then
    perform amine.err('ENTRY_LOCKED');
  end if;
  delete from amine.account_entries where id = e.id;
  perform amine.audit('account.entry_deleted', 'profile', e.customer_id::text,
    jsonb_build_object('kind', e.kind, 'amount', e.amount, 'reference', e.reference));
  return amine.account_json(e.customer_id);
end $$;
revoke all on function public.admin_delete_account_entry(bigint) from public, anon, authenticated;
grant execute on function public.admin_delete_account_entry(bigint) to authenticated;

-- ── Chèques : registre (administration) et réception au dépôt ─────────────────────────────────
create or replace function public.admin_cheques(p_status text default null, p_limit int default 200) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  if p_status is not null and p_status not in ('collected', 'received', 'deposited', 'cleared', 'bounced') then
    perform amine.err('INVALID_INPUT', 'status');
  end if;
  return jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(amine.cheque_json(k) order by k.collected_at desc)
      from (select * from amine.cheques where p_status is null or status = p_status
            order by collected_at desc limit least(greatest(coalesce(p_limit, 200), 1), 500)) k), '[]'::jsonb),
    'totals', coalesce((
      select jsonb_object_agg(t.status, jsonb_build_object('count', t.n, 'amount', t.total))
      from (select status, count(*) as n, sum(amount) as total from amine.cheques group by status) t), '{}'::jsonb));
end $$;

-- p_data : {"number", "bank", "amount", "due_on", "note", "order_code"}. Le chèque est dans les mains de
-- l'équipe (statut « reçu ») et le règlement est inscrit tout de suite au compte du client.
create or replace function public.admin_add_cheque(p_customer uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_number text;
  v_bank text;
  v_amount int;
  v_due date;
  v_order amine.orders;
  k amine.cheques;
  v_today date := (now() at time zone 'Africa/Tunis')::date;
begin
  perform amine.hit('admin_cheque:' || a.id, 200, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  if not exists (select 1 from amine.profiles where id = p_customer) then
    perform amine.err('NOT_FOUND');
  end if;
  v_number := regexp_replace(coalesce(p_data ->> 'number', ''), '\s', '', 'g');
  if v_number !~ '^[0-9A-Za-z/-]{3,30}$' then
    perform amine.err('INVALID_INPUT', 'number');
  end if;
  v_bank := amine.txt(p_data ->> 'bank', 'bank', 60, true, 2);
  v_amount := amine.int_in(p_data, 'amount', 1, 1000000000, true);
  v_due := amine.date_in(p_data, 'due_on');
  if v_due is not null and (v_due < v_today - 366 or v_due > v_today + 400) then
    perform amine.err('INVALID_INPUT', 'due_on');
  end if;
  if nullif(btrim(coalesce(p_data ->> 'order_code', '')), '') is not null then
    select * into v_order from amine.orders
    where code = upper(btrim(p_data ->> 'order_code')) and customer_id = p_customer;
    if not found then
      perform amine.err('NOT_FOUND', 'order_code');
    end if;
  end if;
  insert into amine.cheques (customer_id, order_id, number, bank, amount, due_on, status, note, created_by)
  values (p_customer, v_order.id, v_number, v_bank, v_amount, v_due, 'received', amine.txt(p_data ->> 'note', 'note', 300), a.id)
  returning * into k;
  insert into amine.account_entries (customer_id, kind, amount, method, reference, note, created_by)
  values (p_customer, 'payment', -v_amount, 'cheque', v_number, 'cheque', a.id);
  perform amine.notify(p_customer, 'payment_recorded', jsonb_build_object('amount', v_amount, 'method', 'cheque'), '#/account/billing');
  perform amine.audit('cheque.added', 'cheque', k.id::text, jsonb_build_object('number', v_number, 'bank', v_bank, 'amount', v_amount));
  return amine.cheque_json(k);
end $$;

-- collected → received → deposited → cleared | bounced
create or replace function public.admin_set_cheque_status(p_id uuid, p_status text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  k amine.cheques;
begin
  select * into k from amine.cheques where id = p_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if not ((k.status = 'collected' and p_status = 'received') or (k.status = 'received' and p_status = 'deposited')
          or (k.status = 'deposited' and p_status in ('cleared', 'bounced'))) then
    perform amine.err('INVALID_TRANSITION');
  end if;
  update amine.cheques set status = p_status, status_at = now(), note = coalesce(amine.txt(p_note, 'note', 300), note)
  where id = k.id returning * into k;
  if p_status = 'bounced' and k.customer_id is not null then
    -- Chèque impayé : la somme est de nouveau due par le client.
    insert into amine.account_entries (customer_id, kind, amount, reference, note, created_by)
    values (k.customer_id, 'adjustment', k.amount, k.number, 'cheque_bounced', a.id);
    perform amine.notify(k.customer_id, 'cheque_bounced', jsonb_build_object('number', k.number, 'amount', k.amount, 'bank', k.bank),
      '#/account/billing');
  end if;
  perform amine.audit('cheque.status', 'cheque', k.id::text, jsonb_build_object('status', p_status, 'number', k.number));
  return amine.cheque_json(k);
end $$;

-- Le dépôt confirme avoir reçu du livreur un chèque d'une de ses commandes.
create or replace function public.merchant_receive_cheque(p_store_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  k amine.cheques;
begin
  select k2.* into k from amine.cheques k2 join amine.orders o on o.id = k2.order_id
  where k2.id = p_id and o.store_id = s.id for update of k2;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if k.status <> 'collected' then
    perform amine.err('INVALID_TRANSITION');
  end if;
  update amine.cheques set status = 'received', status_at = now() where id = k.id returning * into k;
  perform amine.audit('cheque.status', 'cheque', k.id::text, jsonb_build_object('status', 'received', 'number', k.number, 'store_id', s.id));
  return amine.cheque_json(k);
end $$;

-- ── Coordonnées bancaires d'AMINE ─────────────────────────────────────────────────────────────
create or replace function public.payment_info() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  b amine.bank_account;
begin
  select * into b from amine.bank_account where id = 1;
  if not found or (b.rib = '' and b.iban = '') then
    return jsonb_build_object('bank', null);
  end if;
  return jsonb_build_object('bank', jsonb_build_object('holder', b.holder, 'bank', b.bank, 'rib', b.rib, 'iban', b.iban, 'note', b.note));
end $$;

-- p_data : {"holder", "bank", "rib" (20 chiffres), "iban" (TN…), "note"}
create or replace function public.admin_save_bank(p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_rib text;
  v_iban text;
  v_holder text;
  v_bank text;
  v_note text;
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  v_rib := regexp_replace(coalesce(p_data ->> 'rib', ''), '[\s.-]', '', 'g');
  v_iban := upper(regexp_replace(coalesce(p_data ->> 'iban', ''), '\s', '', 'g'));
  if v_rib <> '' and v_rib !~ '^[0-9]{20}$' then
    perform amine.err('INVALID_INPUT', 'rib');
  end if;
  if v_iban <> '' and (v_iban !~ '^TN[0-9]{22}$' or not amine.valid_iban(v_iban)) then
    perform amine.err('INVALID_INPUT', 'iban');
  end if;
  -- Quand les deux sont donnés, l'IBAN tunisien se compose de « TN » + clé + RIB.
  if v_rib <> '' and v_iban <> '' and substr(v_iban, 5) <> v_rib then
    perform amine.err('INVALID_INPUT', 'iban');
  end if;
  v_holder := coalesce(amine.txt(p_data ->> 'holder', 'holder', 120), '');
  v_bank := coalesce(amine.txt(p_data ->> 'bank', 'bank', 80), '');
  v_note := coalesce(amine.txt(p_data ->> 'note', 'note', 200), '');
  insert into amine.bank_account (id, holder, bank, rib, iban, note, updated_at, updated_by)
  values (1, v_holder, v_bank, v_rib, v_iban, v_note, now(), a.id)
  on conflict (id) do update set holder = excluded.holder, bank = excluded.bank, rib = excluded.rib, iban = excluded.iban,
    note = excluded.note, updated_at = now(), updated_by = a.id;
  perform amine.audit('bank.updated', 'settings', 'bank', jsonb_build_object('has_rib', v_rib <> '', 'has_iban', v_iban <> ''));
  return jsonb_build_object('holder', v_holder, 'bank', v_bank, 'rib', v_rib, 'iban', v_iban, 'note', v_note);
end $$;

create or replace function public.admin_bank() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  b amine.bank_account;
begin
  select * into b from amine.bank_account where id = 1;
  return jsonb_build_object('holder', coalesce(b.holder, ''), 'bank', coalesce(b.bank, ''), 'rib', coalesce(b.rib, ''),
    'iban', coalesce(b.iban, ''), 'note', coalesce(b.note, ''));
end $$;

-- ── Virements : justificatif du client, validation par l'administration ───────────────────────
create or replace function amine.transfer_json(t amine.transfers) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', t.id, 'purpose', t.purpose, 'amount', t.amount, 'reference', t.reference, 'proof', t.proof,
    'status', t.status, 'reject_reason', t.reject_reason, 'created_at', t.created_at, 'reviewed_at', t.reviewed_at,
    'customer', (select jsonb_build_object('id', p.id, 'name', coalesce(nullif(p.business_name, ''), p.full_name))
      from amine.profiles p where p.id = t.customer_id))
$$;

-- Le justificatif est d'abord déposé dans le stockage privé (transfers/<mon id>/proof-….<ext>), puis déclaré ici.
create or replace function public.submit_transfer(p_amount int, p_proof text, p_reference text default null,
  p_purpose text default 'invoices') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  t amine.transfers;
  v_proof text := btrim(coalesce(p_proof, ''));
  v_purpose text := coalesce(p_purpose, 'invoices');
begin
  perform amine.hit('transfer:' || p.id, 20, 3600);
  if p_amount is null or p_amount < 1 or p_amount > 1000000000 then
    perform amine.err('INVALID_INPUT', 'amount');
  end if;
  if v_purpose not in ('invoices', 'advance') then
    perform amine.err('INVALID_INPUT', 'purpose');
  end if;
  if v_proof !~ ('^transfers/' || p.id::text || '/proof-[A-Za-z0-9_-]{6,40}\.(jpg|jpeg|png|webp|pdf)$')
     or not exists (select 1 from storage.objects o where o.bucket_id = 'amine-proofs' and o.name = v_proof) then
    perform amine.err('INVALID_INPUT', 'proof');
  end if;
  if exists (select 1 from amine.transfers x where x.proof = v_proof) then
    perform amine.err('INVALID_INPUT', 'proof');
  end if;
  if (select count(*) from amine.transfers x where x.customer_id = p.id and x.status = 'pending') >= 5 then
    perform amine.err('TOO_MANY_PENDING');
  end if;
  insert into amine.transfers (customer_id, purpose, amount, reference, proof)
  values (p.id, v_purpose, p_amount, amine.txt(p_reference, 'reference', 80), v_proof)
  returning * into t;
  perform amine.notify_admins('transfer_submitted',
    jsonb_build_object('client', coalesce(nullif(p.business_name, ''), p.full_name), 'amount', p_amount),
    '#/admin/billing?tab=transfers');
  return amine.transfer_json(t);
end $$;

create or replace function public.my_transfers() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  return coalesce((
    select jsonb_agg(amine.transfer_json(t) order by t.created_at desc)
    from (select * from amine.transfers where customer_id = p.id order by created_at desc limit 50) t), '[]'::jsonb);
end $$;

create or replace function public.admin_transfers(p_status text default null, p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
begin
  if p_status is not null and p_status not in ('pending', 'confirmed', 'rejected') then
    perform amine.err('INVALID_INPUT', 'status');
  end if;
  return coalesce((
    select jsonb_agg(amine.transfer_json(t) order by (t.status = 'pending') desc, t.created_at desc)
    from (select * from amine.transfers where p_status is null or status = p_status
          order by (status = 'pending') desc, created_at desc limit least(greatest(coalesce(p_limit, 100), 1), 300)) t), '[]'::jsonb);
end $$;

-- p_action : confirm | reject. À la confirmation, le montant peut être corrigé (montant réellement reçu).
create or replace function public.admin_review_transfer(p_id uuid, p_action text, p_reason text default null,
  p_amount int default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  t amine.transfers;
  v_amount int;
  v_entry bigint;
  v_reason text := amine.txt(p_reason, 'reason', 300);
begin
  perform amine.hit('admin_transfer:' || a.id, 300, 3600);
  select * into t from amine.transfers where id = p_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if t.status <> 'pending' then
    perform amine.err('INVALID_TRANSITION');
  end if;
  if p_action = 'confirm' then
    if t.customer_id is null then
      perform amine.err('NOT_FOUND');
    end if;
    v_amount := coalesce(p_amount, t.amount);
    if v_amount < 1 or v_amount > 1000000000 then
      perform amine.err('INVALID_INPUT', 'amount');
    end if;
    insert into amine.account_entries (customer_id, kind, amount, method, reference, note, created_by)
    values (t.customer_id, 'payment', -v_amount, 'transfer', t.reference,
      case when t.purpose = 'advance' then 'advance' else 'transfer' end, a.id)
    returning id into v_entry;
    update amine.transfers set status = 'confirmed', amount = v_amount, entry_id = v_entry, reviewed_at = now(), reviewed_by = a.id
    where id = t.id returning * into t;
    perform amine.notify(t.customer_id, 'transfer_confirmed', jsonb_build_object('amount', v_amount), '#/account/billing');
    perform amine.audit('transfer.confirmed', 'transfer', t.id::text, jsonb_build_object('amount', v_amount, 'purpose', t.purpose));
  elsif p_action = 'reject' then
    if v_reason is null then
      perform amine.err('REASON_REQUIRED');
    end if;
    update amine.transfers set status = 'rejected', reject_reason = v_reason, reviewed_at = now(), reviewed_by = a.id
    where id = t.id returning * into t;
    perform amine.notify(t.customer_id, 'transfer_rejected', jsonb_build_object('reason', v_reason, 'amount', t.amount), '#/account/billing');
    perform amine.audit('transfer.rejected', 'transfer', t.id::text, jsonb_build_object('reason', v_reason));
  else
    perform amine.err('INVALID_INPUT', 'action');
  end if;
  return amine.transfer_json(t);
end $$;

-- ── Export des données personnelles : chèques, virements, points et parrainages en plus ─────────────────────────────
-- (remplace la version de 04_customer.sql)
create or replace function public.export_my_data() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  perform amine.hit('export:' || p.id, 5, 3600);
  return jsonb_build_object(
    'exported_at', now(),
    'profile', to_jsonb(p),
    'addresses', coalesce((select jsonb_agg(to_jsonb(a)) from amine.addresses a where a.user_id = p.id), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(amine.order_json(o, 'customer') order by o.placed_at)
      from amine.orders o where o.customer_id = p.id), '[]'::jsonb),
    'courier', (select to_jsonb(c) from amine.couriers c where c.user_id = p.id),
    'deliveries', coalesce((select jsonb_agg(jsonb_build_object('code', o.code, 'status', o.status,
        'delivered_at', o.delivered_at, 'courier_earning', o.courier_earning, 'cod_collected', o.cod_collected))
      from amine.orders o where o.courier_id = p.id), '[]'::jsonb),
    'stores', coalesce((select jsonb_agg(jsonb_build_object('store_id', st.store_id, 'role', st.role))
      from amine.store_staff st where st.user_id = p.id), '[]'::jsonb),
    'favorites', coalesce((select jsonb_agg(jsonb_build_object('product', pr.name, 'added_at', f.created_at))
      from amine.favorites f join amine.products pr on pr.id = f.product_id where f.user_id = p.id), '[]'::jsonb),
    'complaints', coalesce((select jsonb_agg(amine.complaint_json(c)) from amine.complaints c
      where c.customer_id = p.id), '[]'::jsonb),
    'notifications', coalesce((select jsonb_agg(jsonb_build_object('kind', n.kind, 'params', n.params,
        'created_at', n.created_at)) from amine.notifications n where n.user_id = p.id), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg(amine.invoice_json(i) order by i.issued_at)
      from amine.invoices i where i.customer_id = p.id), '[]'::jsonb),
    'account_entries', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'amount', e.amount,
        'method', e.method, 'reference', e.reference, 'occurred_on', e.occurred_on) order by e.occurred_on, e.id)
      from amine.account_entries e where e.customer_id = p.id), '[]'::jsonb),
    'recurring_orders', coalesce((select jsonb_agg(amine.recurring_json(r) order by r.created_at)
      from amine.recurring_orders r where r.customer_id = p.id), '[]'::jsonb),
    'negotiated_prices', coalesce((select jsonb_agg(jsonb_build_object('product', pr.name, 'price', cp.price))
      from amine.client_prices cp join amine.products pr on pr.id = cp.product_id where cp.customer_id = p.id), '[]'::jsonb),
    'cheques', coalesce((select jsonb_agg(jsonb_build_object('number', k.number, 'bank', k.bank, 'amount', k.amount,
        'due_on', k.due_on, 'status', k.status, 'collected_at', k.collected_at) order by k.collected_at)
      from amine.cheques k where k.customer_id = p.id), '[]'::jsonb),
    'transfers', coalesce((select jsonb_agg(jsonb_build_object('amount', t.amount, 'purpose', t.purpose, 'reference', t.reference,
        'status', t.status, 'created_at', t.created_at) order by t.created_at)
      from amine.transfers t where t.customer_id = p.id), '[]'::jsonb),
    'loyalty', jsonb_build_object('referral_code', p.referral_code,
      'balance', amine.loyalty_balance(p.id),
      'ledger', coalesce((select jsonb_agg(jsonb_build_object('points', l.delta, 'kind', l.kind, 'order', l.ref,
          'at', l.created_at) order by l.id) from amine.loyalty_ledger l where l.customer_id = p.id), '[]'::jsonb),
      'referrals', coalesce((select jsonb_agg(jsonb_build_object('role', case when r.referrer_id = p.id then 'referrer'
          else 'referee' end, 'status', r.status, 'at', r.created_at) order by r.created_at)
        from amine.referrals r where r.referrer_id = p.id or r.referee_id = p.id), '[]'::jsonb)));
end $$;
revoke all on function public.export_my_data() from public, anon, authenticated;
grant execute on function public.export_my_data() to authenticated;

-- ── Droits ────────────────────────────────────────────────────────────────────────────────────
revoke all on function amine.valid_iban(text) from public, anon, authenticated;
revoke all on function public.admin_cheques(text, int) from public, anon, authenticated;
revoke all on function public.admin_add_cheque(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.admin_set_cheque_status(uuid, text, text) from public, anon, authenticated;
revoke all on function public.merchant_receive_cheque(uuid, uuid) from public, anon, authenticated;
revoke all on function public.payment_info() from public, anon, authenticated;
revoke all on function public.admin_save_bank(jsonb) from public, anon, authenticated;
revoke all on function public.admin_bank() from public, anon, authenticated;
revoke all on function public.submit_transfer(int, text, text, text) from public, anon, authenticated;
revoke all on function public.my_transfers() from public, anon, authenticated;
revoke all on function public.admin_transfers(text, int) from public, anon, authenticated;
revoke all on function public.admin_review_transfer(uuid, text, text, int) from public, anon, authenticated;
grant execute on function public.admin_cheques(text, int) to authenticated;
grant execute on function public.admin_add_cheque(uuid, jsonb) to authenticated;
grant execute on function public.admin_set_cheque_status(uuid, text, text) to authenticated;
grant execute on function public.merchant_receive_cheque(uuid, uuid) to authenticated;
grant execute on function public.payment_info() to authenticated;
grant execute on function public.admin_save_bank(jsonb) to authenticated;
grant execute on function public.admin_bank() to authenticated;
grant execute on function public.submit_transfer(int, text, text, text) to authenticated;
grant execute on function public.my_transfers() to authenticated;
grant execute on function public.admin_transfers(text, int) to authenticated;
grant execute on function public.admin_review_transfer(uuid, text, text, int) to authenticated;

notify pgrst, 'reload schema';

-- =============================================================================================
--  Hygiène alimentaire : allergènes, températures, lots en quarantaine, rappel de lot (version 7)
--
--  • Allergènes : chaque produit porte la liste des 14 allergènes à déclaration obligatoire et une
--    classe de température (ambiant, frais, surgelé). Un produit dont les allergènes n'ont jamais
--    été vérifiés est signalé « non renseigné » (ce n'est pas la même chose que « aucun allergène »).
--  • Températures : relevés à la réception, au stockage et à la livraison (frais 0 à 5 °C, surgelé
--    -18 °C ou moins). Un relevé hors limites exige une action corrective et alerte l'administration.
--  • Lots : un lot suspect est mis en quarantaine (il sort du stock vendable et n'est plus servi),
--    puis remis en vente ou détruit. Le rappel de lot le met en quarantaine et prévient en un clic
--    tous les restaurants à qui il a été livré (liste des commandes tirée des mouvements de stock).
--
--  Ce script remplace quelques fonctions des fichiers précédents (fiche produit, mouvements de stock,
--  tournée du livreur) ; il peut être rejoué sans risque.
-- =============================================================================================

-- ── Produits : allergènes et classe de température ───────────────────────────────────────────
alter table amine.products add column if not exists allergens text[] not null default '{}';
alter table amine.products add column if not exists allergens_reviewed_at timestamptz;
alter table amine.products add column if not exists temp_class text not null default 'ambient';
alter table amine.products drop constraint if exists products_allergens_check;
alter table amine.products add constraint products_allergens_check check (allergens <@ array[
  'gluten', 'crustaceans', 'eggs', 'fish', 'peanuts', 'soy', 'milk', 'nuts', 'celery', 'mustard',
  'sesame', 'sulphites', 'lupin', 'molluscs']::text[]);
alter table amine.products drop constraint if exists products_temp_class_check;
alter table amine.products add constraint products_temp_class_check check (temp_class in ('ambient', 'chilled', 'frozen'));

-- ── Lots : quarantaine, destruction, rappel ──────────────────────────────────────────────────
alter table amine.purchase_lines add column if not exists quarantined_at timestamptz;
alter table amine.purchase_lines add column if not exists quarantine_reason text;
alter table amine.purchase_lines add column if not exists quarantined_qty int not null default 0;
alter table amine.purchase_lines add column if not exists disposed_at timestamptz;
alter table amine.purchase_lines add column if not exists recall_id uuid;
alter table amine.purchase_lines drop constraint if exists purchase_lines_quarantine_reason_check;
alter table amine.purchase_lines add constraint purchase_lines_quarantine_reason_check
  check (quarantine_reason is null or char_length(quarantine_reason) <= 200);
alter table amine.purchase_lines drop constraint if exists purchase_lines_quarantined_qty_check;
alter table amine.purchase_lines add constraint purchase_lines_quarantined_qty_check check (quarantined_qty between 0 and 1000000);
create index if not exists purchase_lines_hold_idx on amine.purchase_lines (product_id) where quarantined_at is not null;

alter table amine.stock_movements drop constraint if exists stock_movements_kind_check;
alter table amine.stock_movements add constraint stock_movements_kind_check
  check (kind in ('sale', 'return', 'purchase', 'purchase_cancel', 'loss', 'count', 'adjustment', 'quarantine', 'release'));

create table if not exists amine.lot_recalls (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references amine.stores (id) on delete cascade,
  purchase_line_id uuid references amine.purchase_lines (id) on delete set null,
  product_id uuid references amine.products (id) on delete set null,
  product_name text not null,
  lot text,
  expiry_on date,
  reason text not null check (char_length(reason) between 3 and 200),
  orders_count int not null default 0,
  customers_count int not null default 0,
  quantity int not null default 0,
  disposed boolean not null default false,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists lot_recalls_store_idx on amine.lot_recalls (store_id, created_at desc);
alter table amine.lot_recalls enable row level security;

-- ── Relevés de température ───────────────────────────────────────────────────────────────────
create table if not exists amine.temperature_logs (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references amine.stores (id) on delete cascade,
  kind text not null check (kind in ('reception', 'storage', 'delivery')),
  temp_class text not null check (temp_class in ('chilled', 'frozen')),
  temperature numeric(5, 1) not null check (temperature between -60 and 100),
  within_limits boolean not null,
  location text check (location is null or char_length(location) <= 60),
  purchase_id uuid references amine.purchases (id) on delete set null,
  product_id uuid references amine.products (id) on delete set null,
  order_id uuid references amine.orders (id) on delete cascade,
  corrective text check (corrective is null or char_length(corrective) <= 200),
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists temperature_logs_store_idx on amine.temperature_logs (store_id, created_at desc);
create unique index if not exists temperature_logs_delivery_idx on amine.temperature_logs (order_id) where kind = 'delivery';
alter table amine.temperature_logs enable row level security;

-- Limites réglementaires utilisées partout (frais : 0 à 5 °C ; surgelé : -18 °C ou moins).
create or replace function amine.temp_ok(p_class text, p_temp numeric) returns boolean
language sql immutable set search_path = '' as $$
  select case p_class when 'chilled' then p_temp between 0 and 5 when 'frozen' then p_temp <= -18 else true end
$$;

-- Texte d'un nombre saisi (virgule ou point) → numérique à une décimale.
create or replace function amine.temp_in(p_value text) returns numeric
language plpgsql immutable set search_path = '' as $$
declare
  v text := replace(btrim(coalesce(p_value, '')), ',', '.');
begin
  if v !~ '^-?[0-9]{1,3}([.][0-9]{1,2})?$' then
    perform amine.err('INVALID_INPUT', 'temperature');
  end if;
  if v::numeric < -60 or v::numeric > 100 then
    perform amine.err('INVALID_INPUT', 'temperature');
  end if;
  return round(v::numeric, 1);
end $$;

-- ── Fiche produit : allergènes visibles par tous les clients ────────────────────────────────
create or replace function amine.product_json(p amine.products) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'section_id', p.section_id, 'sku', p.sku,
    'name', p.name, 'name_ar', p.name_ar, 'name_en', p.name_en,
    'description', p.description, 'description_ar', p.description_ar, 'description_en', p.description_en,
    'price', p.price, 'unit', p.unit, 'image_url', p.image_url, 'image_credit', p.image_credit, 'ref', p.ref, 'sort', p.sort,
    'brand', p.brand, 'barcode', p.barcode, 'vat_rate', p.vat_rate, 'price_tiers', p.price_tiers,
    'allergens', to_jsonb(p.allergens), 'allergens_known', p.allergens_reviewed_at is not null,
    'temp_class', p.temp_class,
    'available', p.is_available and (p.stock is null or p.stock > 0))
$$;

-- ── Stock : les lots en quarantaine ne sont plus servis ─────────────────────────────────────
-- (remplace la version de 08_business.sql ; seuls changent la condition « quarantine » et le tri des lots)
create or replace function amine.on_stock_change() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_kind text;
  v_ref text;
  v_delta int;
  v_mid bigint;
  v_left int;
  v_take int;
  l record;
begin
  if new.stock is null or (tg_op = 'UPDATE' and new.stock is not distinct from old.stock) then
    return new;
  end if;
  v_kind := case when tg_op = 'INSERT' then 'count'
    else coalesce(nullif(current_setting('amine.stock_kind', true), ''), 'adjustment') end;
  v_ref := nullif(current_setting('amine.stock_ref', true), '');
  v_delta := new.stock - case when tg_op = 'INSERT' then 0 else coalesce(old.stock, 0) end;
  insert into amine.stock_movements (store_id, product_id, kind, quantity, stock_after, ref, reason, created_by)
  values (new.store_id, new.id, v_kind, v_delta, new.stock, v_ref,
    nullif(current_setting('amine.stock_reason', true), ''), auth.uid())
  returning id into v_mid;
  if v_delta < 0 and v_kind not in ('purchase_cancel', 'quarantine') then
    v_left := -v_delta;
    for l in
      select pl.id, pl.remaining from amine.purchase_lines pl join amine.purchases pu on pu.id = pl.purchase_id
      where pl.product_id = new.id and pl.remaining > 0 and pu.status = 'received'
        and pl.quarantined_at is null and pl.disposed_at is null
      order by pl.expiry_on nulls last, pu.received_on, pl.id
      for update of pl
    loop
      exit when v_left <= 0;
      v_take := least(v_left, l.remaining);
      update amine.purchase_lines set remaining = remaining - v_take where id = l.id;
      insert into amine.stock_lot_moves (movement_id, purchase_line_id, quantity) values (v_mid, l.id, -v_take);
      v_left := v_left - v_take;
    end loop;
  elsif v_delta > 0 and v_kind = 'return' and v_ref is not null then
    v_left := v_delta;
    for l in
      select lm.purchase_line_id, -sum(lm.quantity)::int as qty
      from amine.stock_lot_moves lm join amine.stock_movements m on m.id = lm.movement_id
      where m.product_id = new.id and m.kind in ('sale', 'return') and m.ref = v_ref
      group by lm.purchase_line_id having -sum(lm.quantity) > 0
    loop
      exit when v_left <= 0;
      v_take := least(v_left, l.qty);
      update amine.purchase_lines set remaining = least(quantity, remaining + v_take) where id = l.purchase_line_id;
      insert into amine.stock_lot_moves (movement_id, purchase_line_id, quantity) values (v_mid, l.purchase_line_id, v_take);
      v_left := v_left - v_take;
    end loop;
  end if;
  return new;
end $$;

-- Une réception dont un lot est en quarantaine ne peut pas être annulée (le stock a déjà été retiré).
create or replace function amine.purchase_hold_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled'
     and exists (select 1 from amine.purchase_lines l where l.purchase_id = new.id
                 and l.quarantined_at is not null and l.disposed_at is null) then
    perform amine.err('LOT_ON_HOLD');
  end if;
  return new;
end $$;
drop trigger if exists amine_purchases_hold on amine.purchases;
create trigger amine_purchases_hold before update of status on amine.purchases
  for each row execute function amine.purchase_hold_guard();

-- ── Lots : fiches et commandes concernées ────────────────────────────────────────────────────
-- Commandes (non annulées) servies avec un lot : quantité nette sortie de ce lot (ventes − retours).
create or replace function amine.lot_orders(p_line uuid) returns table (
  order_id uuid, code text, status text, customer_id uuid, quantity int, placed_at timestamptz,
  delivered_at timestamptz, business text, phone text)
language sql stable set search_path = '' as $$
  select o.id, o.code, o.status, o.customer_id, x.qty, o.placed_at, o.delivered_at, o.dropoff_name,
    coalesce(o.dropoff_phone, pr.phone)
  from (select m.ref, -sum(lm.quantity)::int as qty
        from amine.stock_lot_moves lm join amine.stock_movements m on m.id = lm.movement_id
        where lm.purchase_line_id = p_line and m.kind in ('sale', 'return') and m.ref is not null
        group by m.ref having -sum(lm.quantity) > 0) x
  join amine.orders o on o.code = x.ref
  left join amine.profiles pr on pr.id = o.customer_id
  where o.status not in ('cancelled', 'rejected')
$$;

create or replace function amine.lot_impact_json(p_line uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'orders', count(*),
    'customers', count(distinct x.customer_id),
    'quantity', coalesce(sum(x.quantity), 0),
    'delivered', count(*) filter (where x.status = 'delivered'),
    'open', count(*) filter (where x.status <> 'delivered'),
    'list', coalesce(jsonb_agg(jsonb_build_object('code', x.code, 'status', x.status, 'quantity', x.quantity,
      'placed_at', x.placed_at, 'delivered_at', x.delivered_at, 'business', x.business, 'phone', x.phone)
      order by x.placed_at desc), '[]'::jsonb))
  from amine.lot_orders(p_line) x
$$;

create or replace function amine.lot_json(l amine.purchase_lines, pu amine.purchases) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', l.id, 'purchase_id', pu.id, 'purchase_ref', pu.reference, 'product_id', l.product_id,
    'name', l.name, 'unit', l.unit,
    'name_ar', (select p.name_ar from amine.products p where p.id = l.product_id),
    'name_en', (select p.name_en from amine.products p where p.id = l.product_id),
    'temp_class', (select p.temp_class from amine.products p where p.id = l.product_id),
    'lot', l.lot, 'expiry_on', l.expiry_on, 'received_on', pu.received_on, 'quantity', l.quantity,
    'remaining', l.remaining, 'quarantined_qty', l.quarantined_qty,
    'supplier', (select su.name from amine.suppliers su where su.id = pu.supplier_id),
    'state', case when l.disposed_at is not null then 'disposed' when l.quarantined_at is not null then 'quarantined' else 'active' end,
    'reason', l.quarantine_reason, 'quarantined_at', l.quarantined_at, 'disposed_at', l.disposed_at,
    'recall', (select jsonb_build_object('id', r.id, 'created_at', r.created_at, 'orders', r.orders_count,
                 'customers', r.customers_count) from amine.lot_recalls r where r.id = l.recall_id))
$$;

-- Retire du stock vendable la quantité restante d'un lot (utilisé par la quarantaine et le rappel).
create or replace function amine.hold_lot(p_line uuid, p_reason text) returns amine.purchase_lines
language plpgsql set search_path = '' as $$
declare
  l amine.purchase_lines;
  pr amine.products;
  v_qty int := 0;
  v_ref text;
begin
  select * into l from amine.purchase_lines where id = p_line for update;
  if l.quarantined_at is not null or l.disposed_at is not null then
    perform amine.err('INVALID_TRANSITION');
  end if;
  select * into pr from amine.products where id = l.product_id for update;
  if found and pr.stock is not null then
    v_qty := least(l.remaining, pr.stock);
    if v_qty > 0 then
      v_ref := coalesce(l.lot, 'lot');
      perform amine.stock_context('quarantine', v_ref, left(p_reason, 80));
      update amine.products set stock = stock - v_qty, updated_at = now() where id = pr.id;
      perform amine.stock_context(null, null, null);
    end if;
  end if;
  update amine.purchase_lines set quarantined_at = now(), quarantine_reason = p_reason, quarantined_qty = v_qty
  where id = l.id returning * into l;
  return l;
end $$;

-- ── Lots : liste, quarantaine, remise en vente, destruction ──────────────────────────────────
-- p_state : active | quarantined | disposed | all
create or replace function public.merchant_lots(p_store_id uuid, p_search text default null, p_state text default 'all',
  p_limit int default 150) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
begin
  if p_state is null or p_state not in ('active', 'quarantined', 'disposed', 'all') then
    perform amine.err('INVALID_INPUT', 'state');
  end if;
  if v_search is not null and char_length(v_search) > 60 then
    perform amine.err('INVALID_INPUT', 'search');
  end if;
  return jsonb_build_object(
    'lots', coalesce((
      select jsonb_agg(amine.lot_json(l, pu) order by pu.received_on desc, l.expiry_on nulls last, l.name)
      from amine.purchase_lines l join amine.purchases pu on pu.id = l.purchase_id
      where l.id in (
        select l2.id from amine.purchase_lines l2 join amine.purchases pu2 on pu2.id = l2.purchase_id
        where pu2.store_id = s.id and pu2.status = 'received' and pu2.received_on >= current_date - 400
          and (p_state = 'all'
            or (p_state = 'quarantined' and l2.quarantined_at is not null and l2.disposed_at is null)
            or (p_state = 'disposed' and l2.disposed_at is not null)
            or (p_state = 'active' and l2.quarantined_at is null and l2.disposed_at is null))
          and (v_search is null or l2.name ilike '%' || replace(replace(v_search, '%', ''), '_', '') || '%'
               or l2.lot ilike '%' || replace(replace(v_search, '%', ''), '_', '') || '%')
        order by pu2.received_on desc, l2.id limit least(greatest(coalesce(p_limit, 150), 1), 400))), '[]'::jsonb));
end $$;

-- Aperçu d'un rappel : combien de commandes et de clients ont reçu ce lot.
create or replace function public.merchant_lot_impact(p_store_id uuid, p_line_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  l amine.purchase_lines;
  pu amine.purchases;
begin
  select l2.* into l from amine.purchase_lines l2 join amine.purchases p2 on p2.id = l2.purchase_id
  where l2.id = p_line_id and p2.store_id = s.id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  select * into pu from amine.purchases where id = l.purchase_id;
  return jsonb_build_object('lot', amine.lot_json(l, pu), 'impact', amine.lot_impact_json(l.id));
end $$;

create or replace function public.merchant_quarantine_lot(p_store_id uuid, p_line_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  l amine.purchase_lines;
  pu amine.purchases;
  v_reason text;
begin
  perform amine.hit('lots:' || auth.uid(), 120, 3600);
  v_reason := amine.txt(p_reason, 'reason', 200, true, 3);
  select l2.* into l from amine.purchase_lines l2 join amine.purchases p2 on p2.id = l2.purchase_id
  where l2.id = p_line_id and p2.store_id = s.id and p2.status = 'received' for update of l2;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  l := amine.hold_lot(l.id, v_reason);
  select * into pu from amine.purchases where id = l.purchase_id;
  perform amine.audit('lot.quarantined', 'store', s.id::text,
    jsonb_build_object('line_id', l.id, 'lot', l.lot, 'product', l.name, 'quantity', l.quarantined_qty, 'reason', v_reason));
  return amine.lot_json(l, pu);
end $$;

create or replace function public.merchant_release_lot(p_store_id uuid, p_line_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  l amine.purchase_lines;
  pu amine.purchases;
begin
  perform amine.hit('lots:' || auth.uid(), 120, 3600);
  select l2.* into l from amine.purchase_lines l2 join amine.purchases p2 on p2.id = l2.purchase_id
  where l2.id = p_line_id and p2.store_id = s.id and p2.status = 'received' for update of l2;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if l.quarantined_at is null or l.disposed_at is not null then
    perform amine.err('INVALID_TRANSITION');
  end if;
  if l.recall_id is not null then
    perform amine.err('LOT_RECALLED');
  end if;
  if l.quarantined_qty > 0 then
    perform amine.stock_context('release', coalesce(l.lot, 'lot'), null);
    update amine.products set stock = least(1000000, coalesce(stock, 0) + l.quarantined_qty), updated_at = now()
    where id = l.product_id and stock is not null;
    perform amine.stock_context(null, null, null);
  end if;
  update amine.purchase_lines set quarantined_at = null, quarantine_reason = null, quarantined_qty = 0
  where id = l.id returning * into l;
  select * into pu from amine.purchases where id = l.purchase_id;
  perform amine.audit('lot.released', 'store', s.id::text, jsonb_build_object('line_id', l.id, 'lot', l.lot, 'product', l.name));
  return amine.lot_json(l, pu);
end $$;

create or replace function public.merchant_dispose_lot(p_store_id uuid, p_line_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  l amine.purchase_lines;
  pu amine.purchases;
begin
  perform amine.hit('lots:' || auth.uid(), 120, 3600);
  select l2.* into l from amine.purchase_lines l2 join amine.purchases p2 on p2.id = l2.purchase_id
  where l2.id = p_line_id and p2.store_id = s.id and p2.status = 'received' for update of l2;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if l.quarantined_at is null or l.disposed_at is not null then
    perform amine.err('INVALID_TRANSITION');
  end if;
  update amine.purchase_lines set disposed_at = now(), remaining = 0 where id = l.id returning * into l;
  select * into pu from amine.purchases where id = l.purchase_id;
  perform amine.audit('lot.disposed', 'store', s.id::text,
    jsonb_build_object('line_id', l.id, 'lot', l.lot, 'product', l.name, 'quantity', l.quarantined_qty));
  return amine.lot_json(l, pu);
end $$;

-- Rappel d'un lot en un clic : quarantaine, puis message à chaque client ayant reçu ce lot (commande
-- livrée) et alerte du dépôt et de l'administration pour les commandes pas encore livrées.
create or replace function public.merchant_recall_lot(p_store_id uuid, p_line_id uuid, p_reason text,
  p_dispose boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  l amine.purchase_lines;
  pu amine.purchases;
  r amine.lot_recalls;
  x record;
  v_reason text;
  v_impact jsonb;
  v_params jsonb;
  v_label text;
begin
  perform amine.hit('lots:' || auth.uid(), 120, 3600);
  v_reason := amine.txt(p_reason, 'reason', 200, true, 3);
  select l2.* into l from amine.purchase_lines l2 join amine.purchases p2 on p2.id = l2.purchase_id
  where l2.id = p_line_id and p2.store_id = s.id and p2.status = 'received' for update of l2;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if l.recall_id is not null or l.disposed_at is not null then
    perform amine.err('INVALID_TRANSITION');
  end if;
  if l.quarantined_at is null then
    l := amine.hold_lot(l.id, v_reason);
  else
    update amine.purchase_lines set quarantine_reason = v_reason where id = l.id returning * into l;
  end if;
  v_impact := amine.lot_impact_json(l.id);
  insert into amine.lot_recalls (store_id, purchase_line_id, product_id, product_name, lot, expiry_on, reason,
    orders_count, customers_count, quantity, disposed, created_by)
  values (s.id, l.id, l.product_id, l.name, l.lot, l.expiry_on, v_reason,
    (v_impact ->> 'orders')::int, (v_impact ->> 'customers')::int, (v_impact ->> 'quantity')::int,
    coalesce(p_dispose, false), auth.uid())
  returning * into r;
  update amine.purchase_lines set recall_id = r.id where id = l.id returning * into l;
  if coalesce(p_dispose, false) then
    update amine.purchase_lines set disposed_at = now(), remaining = 0 where id = l.id returning * into l;
  end if;
  select * into pu from amine.purchases where id = l.purchase_id;
  v_label := coalesce(l.lot, to_char(pu.received_on, 'DD/MM/YYYY'));
  for x in select * from amine.lot_orders(l.id) loop
    v_params := jsonb_build_object('code', x.code, 'product', l.name, 'lot', v_label, 'reason', v_reason);
    if x.status = 'delivered' then
      perform amine.notify(x.customer_id, 'lot_recall', v_params, '#/orders/' || x.code);
    else
      perform amine.notify_store(s.id, 'lot_recall_open', v_params, '#/depot/orders/' || x.code || '?store=' || s.id::text);
    end if;
  end loop;
  if (v_impact ->> 'open')::int > 0 then
    perform amine.notify_admins('lot_recall_open',
      jsonb_build_object('product', l.name, 'lot', v_label, 'reason', v_reason), '#/depot/hygiene?store=' || s.id::text);
  end if;
  perform amine.audit('lot.recalled', 'store', s.id::text,
    jsonb_build_object('line_id', l.id, 'recall_id', r.id, 'lot', l.lot, 'product', l.name, 'reason', v_reason,
      'orders', r.orders_count, 'customers', r.customers_count, 'disposed', coalesce(p_dispose, false)));
  return jsonb_build_object('lot', amine.lot_json(l, pu), 'impact', v_impact);
end $$;

-- ── Allergènes et classe de température d'un produit ─────────────────────────────────────────
-- p_data : {"allergens": ["gluten", …], "temp_class": "ambient|chilled|frozen"}. Enregistrer une liste
-- (même vide) confirme que les allergènes ont été vérifiés.
create or replace function public.merchant_set_food_safety(p_store_id uuid, p_product_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  pr amine.products;
  v_allergens text[];
  v_class text;
begin
  perform amine.hit('catalog:' || auth.uid(), 600, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  select * into pr from amine.products where id = p_product_id and store_id = s.id and deleted_at is null for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if p_data ? 'allergens' then
    if jsonb_typeof(p_data -> 'allergens') <> 'array' or jsonb_array_length(p_data -> 'allergens') > 14 then
      perform amine.err('INVALID_INPUT', 'allergens');
    end if;
    select coalesce(array_agg(distinct a order by a), '{}') into v_allergens from jsonb_array_elements_text(p_data -> 'allergens') a;
    if not v_allergens <@ array['gluten', 'crustaceans', 'eggs', 'fish', 'peanuts', 'soy', 'milk', 'nuts', 'celery',
         'mustard', 'sesame', 'sulphites', 'lupin', 'molluscs']::text[] then
      perform amine.err('INVALID_INPUT', 'allergens');
    end if;
  else
    v_allergens := pr.allergens;
  end if;
  v_class := coalesce(nullif(btrim(p_data ->> 'temp_class'), ''), pr.temp_class);
  if v_class not in ('ambient', 'chilled', 'frozen') then
    perform amine.err('INVALID_INPUT', 'temp_class');
  end if;
  update amine.products set allergens = v_allergens, temp_class = v_class,
    allergens_reviewed_at = case when p_data ? 'allergens' then now() else allergens_reviewed_at end, updated_at = now()
  where id = pr.id returning * into pr;
  perform amine.audit('product.food_safety', 'product', pr.id::text,
    jsonb_build_object('store_id', s.id, 'allergens', to_jsonb(pr.allergens), 'temp_class', pr.temp_class));
  return amine.merchant_product_json(pr);
end $$;

-- ── Relevés de température ───────────────────────────────────────────────────────────────────
create or replace function amine.temp_log_json(t amine.temperature_logs) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', t.id, 'kind', t.kind, 'temp_class', t.temp_class, 'temperature', t.temperature,
    'within_limits', t.within_limits, 'location', t.location, 'corrective', t.corrective, 'created_at', t.created_at,
    'purchase_ref', (select coalesce(pu.reference, left(pu.id::text, 8)) from amine.purchases pu where pu.id = t.purchase_id),
    'product', (select p.name from amine.products p where p.id = t.product_id),
    'order_code', (select o.code from amine.orders o where o.id = t.order_id),
    'by', (select x.full_name from amine.profiles x where x.id = t.created_by))
$$;

-- p_data : {"kind": "reception|storage", "temp_class": "chilled|frozen", "temperature": -19.5, "location",
-- "purchase_id", "product_id", "corrective"}. Hors limites : l'action corrective est obligatoire.
create or replace function public.merchant_log_temperature(p_store_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  v_kind text;
  v_class text;
  v_temp numeric;
  v_ok boolean;
  v_corrective text;
  v_purchase uuid;
  v_product uuid;
  t amine.temperature_logs;
begin
  perform amine.hit('temps:' || auth.uid(), 300, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  v_kind := p_data ->> 'kind';
  if v_kind is null or v_kind not in ('reception', 'storage') then
    perform amine.err('INVALID_INPUT', 'kind');
  end if;
  v_class := p_data ->> 'temp_class';
  if v_class is null or v_class not in ('chilled', 'frozen') then
    perform amine.err('INVALID_INPUT', 'temp_class');
  end if;
  v_temp := amine.temp_in(p_data ->> 'temperature');
  v_ok := amine.temp_ok(v_class, v_temp);
  v_corrective := amine.txt(p_data ->> 'corrective', 'corrective', 200, false, 3);
  if not v_ok and v_corrective is null then
    perform amine.err('TEMP_ACTION_REQUIRED');
  end if;
  v_purchase := amine.uuid_in(p_data, 'purchase_id');
  if v_purchase is not null and not exists (select 1 from amine.purchases where id = v_purchase and store_id = s.id) then
    perform amine.err('INVALID_INPUT', 'purchase_id');
  end if;
  v_product := amine.uuid_in(p_data, 'product_id');
  if v_product is not null and not exists (select 1 from amine.products where id = v_product and store_id = s.id) then
    perform amine.err('INVALID_INPUT', 'product_id');
  end if;
  insert into amine.temperature_logs (store_id, kind, temp_class, temperature, within_limits, location, purchase_id,
    product_id, corrective, created_by)
  values (s.id, v_kind, v_class, v_temp, v_ok, amine.txt(p_data ->> 'location', 'location', 60), v_purchase, v_product,
    case when v_ok then null else v_corrective end, auth.uid())
  returning * into t;
  if not v_ok then
    perform amine.notify_admins('temp_alert', jsonb_build_object('store', s.name, 'where', v_kind,
      'temperature', v_temp, 'class', v_class), '#/depot/hygiene?store=' || s.id::text);
  end if;
  return amine.temp_log_json(t);
end $$;

-- Tableau de bord hygiène d'un dépôt : relevés récents, lots en quarantaine, rappels, produits à vérifier.
create or replace function public.merchant_haccp(p_store_id uuid, p_days int default 14) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  v_days int := least(greatest(coalesce(p_days, 14), 1), 180);
  v_since timestamptz;
begin
  v_since := now() - make_interval(days => v_days);
  return jsonb_build_object(
    'limits', jsonb_build_object('chilled', jsonb_build_object('min', 0, 'max', 5),
      'frozen', jsonb_build_object('max', -18)),
    'summary', jsonb_build_object(
      'readings', (select count(*) from amine.temperature_logs t where t.store_id = s.id and t.created_at >= v_since),
      'out_of_limits', (select count(*) from amine.temperature_logs t
                        where t.store_id = s.id and t.created_at >= v_since and not t.within_limits),
      'last_reading', (select max(t.created_at) from amine.temperature_logs t where t.store_id = s.id),
      'quarantined', (select count(*) from amine.purchase_lines l join amine.purchases pu on pu.id = l.purchase_id
                      where pu.store_id = s.id and l.quarantined_at is not null and l.disposed_at is null),
      'unreviewed', (select count(*) from amine.products p
                     where p.store_id = s.id and p.deleted_at is null and p.allergens_reviewed_at is null),
      'products', (select count(*) from amine.products p where p.store_id = s.id and p.deleted_at is null)),
    'logs', coalesce((
      select jsonb_agg(amine.temp_log_json(t) order by t.created_at desc)
      from (select * from amine.temperature_logs where store_id = s.id and created_at >= v_since
            order by created_at desc limit 200) t), '[]'::jsonb),
    'recalls', coalesce((
      select jsonb_agg(jsonb_build_object('id', r.id, 'product', r.product_name, 'lot', r.lot, 'expiry_on', r.expiry_on,
          'reason', r.reason, 'orders', r.orders_count, 'customers', r.customers_count, 'quantity', r.quantity,
          'disposed', r.disposed, 'created_at', r.created_at) order by r.created_at desc)
      from (select * from amine.lot_recalls where store_id = s.id order by created_at desc limit 20) r), '[]'::jsonb));
end $$;

-- ── Livraison : le livreur relève la température des produits frais ou surgelés ──────────────
-- Classe de la commande : surgelé si un article l'est, sinon frais si un article l'est, sinon rien.
create or replace function amine.cold_chain(p_order uuid) returns text
language sql stable set search_path = '' as $$
  select case when bool_or(p.temp_class = 'frozen') then 'frozen' when bool_or(p.temp_class = 'chilled') then 'chilled' end
  from amine.order_items i join amine.products p on p.id = i.product_id where i.order_id = p_order
$$;

create or replace function amine.cold_json(o amine.orders) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('cold_chain', amine.cold_chain(o.id),
    'delivery_temp', (select jsonb_build_object('temperature', t.temperature, 'within_limits', t.within_limits,
        'corrective', t.corrective, 'at', t.created_at)
      from amine.temperature_logs t where t.order_id = o.id and t.kind = 'delivery'))
$$;

create or replace function public.courier_log_temperature(p_code text, p_temperature text, p_corrective text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
  o amine.orders;
  v_class text;
  v_temp numeric;
  v_ok boolean;
  v_corrective text;
  t amine.temperature_logs;
begin
  perform amine.hit('courier_action:' || c.user_id, 120, 600);
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and courier_id = c.user_id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if o.status not in ('picked_up', 'delivered') or (o.status = 'delivered' and o.delivered_at < now() - interval '6 hours') then
    perform amine.err('INVALID_TRANSITION');
  end if;
  v_class := amine.cold_chain(o.id);
  if v_class is null then
    perform amine.err('NO_COLD_CHAIN');
  end if;
  v_temp := amine.temp_in(p_temperature);
  v_ok := amine.temp_ok(v_class, v_temp);
  v_corrective := amine.txt(p_corrective, 'corrective', 200, false, 3);
  if not v_ok and v_corrective is null then
    perform amine.err('TEMP_ACTION_REQUIRED');
  end if;
  delete from amine.temperature_logs where order_id = o.id and kind = 'delivery';
  insert into amine.temperature_logs (store_id, kind, temp_class, temperature, within_limits, order_id, corrective, created_by)
  values (o.store_id, 'delivery', v_class, v_temp, v_ok, o.id, case when v_ok then null else v_corrective end, c.user_id)
  returning * into t;
  if not v_ok then
    perform amine.notify_admins('temp_alert', jsonb_build_object('store', o.pickup_name, 'where', 'delivery',
      'temperature', v_temp, 'class', v_class, 'code', o.code), '#/depot/hygiene?store=' || o.store_id::text);
    perform amine.notify_store(o.store_id, 'temp_alert', jsonb_build_object('store', o.pickup_name, 'where', 'delivery',
      'temperature', v_temp, 'class', v_class, 'code', o.code), '#/depot/hygiene?store=' || o.store_id::text);
  end if;
  return amine.temp_log_json(t) || jsonb_build_object('cold_chain', v_class);
end $$;

-- Tournée du livreur : chaque commande indique si elle est à maintenir au frais et sa température relevée
-- (remplace les versions de 06_courier.sql).
create or replace function public.courier_jobs() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
begin
  perform amine.maintenance();
  return jsonb_build_object(
    'online', c.is_online,
    'max_active_jobs', greatest(1, coalesce((amine.setting('couriers') ->> 'max_active_jobs')::int, 2)),
    'available', case when not c.is_online then '[]'::jsonb else coalesce((
      select jsonb_agg(amine.order_json(x, 'courier_preview') order by x.ready_at nulls last, x.placed_at)
      from (select * from amine.orders o
            where o.courier_id is null and o.status in ('accepted', 'preparing', 'ready')
              and (c.zone_id is null or o.zone_id = c.zone_id) and amine.job_open(o)
            order by coalesce(amine.slot_start(o.deliver_on, o.delivery_slot), o.placed_at), o.placed_at
            limit 50) x), '[]'::jsonb) end,
    'mine', coalesce((
      select jsonb_agg(amine.order_json(o, 'courier') || amine.cold_json(o) order by o.route_seq nulls last, o.assigned_at)
      from amine.orders o
      where o.courier_id = c.user_id and o.status in ('accepted', 'preparing', 'ready', 'picked_up')), '[]'::jsonb));
end $$;

create or replace function public.courier_job(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c amine.couriers := amine.require_courier();
  o amine.orders;
begin
  select * into o from amine.orders where code = upper(btrim(coalesce(p_code, ''))) and courier_id = c.user_id;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  return amine.order_json(o, 'courier') || amine.cold_json(o);
end $$;

-- ── Droits ────────────────────────────────────────────────────────────────────────────────────
revoke all on function amine.temp_ok(text, numeric) from public, anon, authenticated;
revoke all on function amine.temp_in(text) from public, anon, authenticated;
revoke all on function amine.purchase_hold_guard() from public, anon, authenticated;
revoke all on function amine.lot_orders(uuid) from public, anon, authenticated;
revoke all on function amine.lot_impact_json(uuid) from public, anon, authenticated;
revoke all on function amine.lot_json(amine.purchase_lines, amine.purchases) from public, anon, authenticated;
revoke all on function amine.hold_lot(uuid, text) from public, anon, authenticated;
revoke all on function amine.temp_log_json(amine.temperature_logs) from public, anon, authenticated;
revoke all on function amine.cold_chain(uuid) from public, anon, authenticated;
revoke all on function amine.cold_json(amine.orders) from public, anon, authenticated;
revoke all on function amine.product_json(amine.products) from public, anon, authenticated;
revoke all on function amine.on_stock_change() from public, anon, authenticated;
revoke all on function public.merchant_lots(uuid, text, text, int) from public, anon, authenticated;
revoke all on function public.merchant_lot_impact(uuid, uuid) from public, anon, authenticated;
revoke all on function public.merchant_quarantine_lot(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.merchant_release_lot(uuid, uuid) from public, anon, authenticated;
revoke all on function public.merchant_dispose_lot(uuid, uuid) from public, anon, authenticated;
revoke all on function public.merchant_recall_lot(uuid, uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.merchant_set_food_safety(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.merchant_log_temperature(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.merchant_haccp(uuid, int) from public, anon, authenticated;
revoke all on function public.courier_log_temperature(text, text, text) from public, anon, authenticated;
revoke all on function public.courier_jobs() from public, anon, authenticated;
revoke all on function public.courier_job(text) from public, anon, authenticated;
grant execute on function public.merchant_lots(uuid, text, text, int) to authenticated;
grant execute on function public.merchant_lot_impact(uuid, uuid) to authenticated;
grant execute on function public.merchant_quarantine_lot(uuid, uuid, text) to authenticated;
grant execute on function public.merchant_release_lot(uuid, uuid) to authenticated;
grant execute on function public.merchant_dispose_lot(uuid, uuid) to authenticated;
grant execute on function public.merchant_recall_lot(uuid, uuid, text, boolean) to authenticated;
grant execute on function public.merchant_set_food_safety(uuid, uuid, jsonb) to authenticated;
grant execute on function public.merchant_log_temperature(uuid, jsonb) to authenticated;
grant execute on function public.merchant_haccp(uuid, int) to authenticated;
grant execute on function public.courier_log_temperature(text, text, text) to authenticated;
grant execute on function public.courier_jobs() to authenticated;
grant execute on function public.courier_job(text) to authenticated;

notify pgrst, 'reload schema';

-- =============================================================================================
--  Fidélité, parrainage, offre de bienvenue, ventes flash, relance des clients inactifs (version 8)
--
--  • Points : 1 point par dinar de marchandises livrées (réglable), crédités à la livraison, rendus si la
--    commande est annulée ou refusée, repris au prorata d'un avoir. Utilisables à la commande (valeur d'un
--    point et plafond réglables) : la remise est financée par AMINE, comme un code promo.
--  • Parrainage : chaque client a un code ; le filleul le saisit avant sa première commande ; les deux
--    reçoivent des points quand sa première commande livrée atteint le minimum fixé (contrôles anti-abus :
--    même téléphone ou même établissement refusés, nombre de filleuls limité).
--  • Offre de bienvenue : un code promo « appliqué automatiquement » (première commande seulement).
--  • Ventes flash : prix réduit sur un produit, pendant une durée et pour une quantité limitées ; le prix est
--    appliqué par le serveur (jamais par le navigateur) et le compte à rebours part de l'heure du serveur.
--  • Relance : un restaurant qui n'a pas commandé depuis N jours (15 par défaut) reçoit un rappel dans
--    l'application, une seule fois par période d'inactivité, et seulement s'il a accepté les messages.
--
--  Ce script complète les fichiers précédents (les fonctions de commande y font appel) ; il peut être
--  rejoué sans risque.
-- =============================================================================================

-- ── Tables et colonnes ───────────────────────────────────────────────────────────────────────
alter table amine.promotions add column if not exists auto_apply boolean not null default false;

alter table amine.orders add column if not exists loyalty_points int not null default 0;
alter table amine.orders add column if not exists loyalty_discount int not null default 0;
alter table amine.orders drop constraint if exists orders_loyalty_check;
alter table amine.orders add constraint orders_loyalty_check
  check (loyalty_points >= 0 and loyalty_discount >= 0 and loyalty_discount <= discount);

alter table amine.profiles add column if not exists referral_code text;
alter table amine.profiles add column if not exists reminded_at timestamptz;
alter table amine.profiles drop constraint if exists profiles_referral_code_check;
alter table amine.profiles add constraint profiles_referral_code_check
  check (referral_code is null or referral_code ~ '^AMI-[2-9A-HJ-NP-Z]{6}$');
create unique index if not exists profiles_referral_code_idx on amine.profiles (referral_code) where referral_code is not null;

create table if not exists amine.loyalty_ledger (
  id bigint generated always as identity primary key,
  customer_id uuid not null references amine.profiles (id) on delete cascade,
  delta int not null check (delta <> 0 and delta between -100000000 and 100000000),
  kind text not null check (kind in ('earn', 'redeem', 'refund', 'edit_refund', 'reversal', 'referral', 'adjust')),
  order_id uuid references amine.orders (id) on delete set null,
  ref text check (ref is null or char_length(ref) <= 80),
  note text check (note is null or char_length(note) <= 200),
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists loyalty_ledger_customer_idx on amine.loyalty_ledger (customer_id, id desc);
create index if not exists loyalty_ledger_order_idx on amine.loyalty_ledger (order_id) where order_id is not null;
-- Une commande rapporte, utilise et rend ses points une seule fois ; une récompense de parrainage n'est versée qu'une fois.
create unique index if not exists loyalty_once_idx on amine.loyalty_ledger (order_id, kind)
  where order_id is not null and kind in ('earn', 'redeem', 'refund');
create unique index if not exists loyalty_referral_idx on amine.loyalty_ledger (ref) where kind = 'referral';
alter table amine.loyalty_ledger enable row level security;

create table if not exists amine.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references amine.profiles (id) on delete cascade,
  referee_id uuid not null unique references amine.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'rewarded', 'void')),
  void_reason text check (void_reason is null or char_length(void_reason) <= 60),
  points int check (points is null or points >= 0),
  order_id uuid references amine.orders (id) on delete set null,
  created_at timestamptz not null default now(),
  rewarded_at timestamptz,
  check (referrer_id <> referee_id)
);
create index if not exists referrals_referrer_idx on amine.referrals (referrer_id, created_at desc);
alter table amine.referrals enable row level security;

create table if not exists amine.flash_sales (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references amine.stores (id) on delete cascade,
  product_id uuid not null references amine.products (id) on delete cascade,
  price int not null check (price between 1 and 100000000),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  max_units int check (max_units is null or max_units between 1 and 1000000),
  per_order_max int check (per_order_max is null or per_order_max between 1 and 999),
  is_active boolean not null default true,
  stopped_at timestamptz,
  notified_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at and ends_at <= starts_at + interval '15 days')
);
create index if not exists flash_sales_product_idx on amine.flash_sales (product_id, starts_at desc);
create index if not exists flash_sales_store_idx on amine.flash_sales (store_id, starts_at desc);
alter table amine.flash_sales enable row level security;

alter table amine.order_items add column if not exists flash_sale_id uuid references amine.flash_sales (id) on delete set null;
create index if not exists order_items_flash_idx on amine.order_items (flash_sale_id) where flash_sale_id is not null;

-- ── Points : écritures, solde, utilisation ───────────────────────────────────────────────────
create or replace function amine.loyalty_add(
  p_customer uuid, p_delta int, p_kind text, p_order uuid default null, p_ref text default null,
  p_note text default null, p_by uuid default null
) returns void
language plpgsql set search_path = '' as $$
begin
  if p_customer is null or coalesce(p_delta, 0) = 0 then
    return;
  end if;
  insert into amine.loyalty_ledger (customer_id, delta, kind, order_id, ref, note, created_by)
  values (p_customer, p_delta, p_kind, p_order, left(p_ref, 80), left(p_note, 200), p_by)
  on conflict do nothing;
end $$;

-- Points qu'un client peut utiliser sur une commande : {enabled, balance, point_value, min_redeem, points, discount}.
-- p_subtotal : marchandises ; p_payable : ce qui reste à payer avant les points (le plafond s'applique aux marchandises).
create or replace function amine.loyalty_redeem_calc(p_customer uuid, p_subtotal int, p_payable int) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  cfg jsonb := amine.setting('loyalty');
  v_balance int := greatest(0, amine.loyalty_balance(p_customer));
  v_value int := greatest(1, (cfg ->> 'point_value')::int);
  v_min int := greatest(1, (cfg ->> 'min_redeem')::int);
  v_cap int;
  v_points int := 0;
begin
  if coalesce((cfg ->> 'enabled')::boolean, false) then
    v_cap := least(greatest(0, p_payable), floor(greatest(0, p_subtotal)::numeric * (cfg ->> 'max_redeem_bps')::int / 10000)::int);
    v_points := least(v_balance, v_cap / v_value);
    if v_points < v_min then
      v_points := 0;
    end if;
  end if;
  return jsonb_build_object('enabled', coalesce((cfg ->> 'enabled')::boolean, false), 'balance', v_balance,
    'point_value', v_value, 'min_redeem', v_min, 'max_redeem_bps', (cfg ->> 'max_redeem_bps')::int,
    'earn_per_dt', greatest(0, coalesce((cfg ->> 'earn_per_dt')::int, 0)),
    'points', v_points, 'discount', v_points * v_value);
end $$;

-- Remise d'une commande modifiée (prix ou pesée) : code promo recalculé ; points conservés dans la limite de ce
-- qui reste à payer (si la commande baisse trop, les points en trop sont rendus).
create or replace function amine.reprice_discount(o amine.orders, p_sub int) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  pr amine.promotions;
  v_gross int := p_sub + o.delivery_fee + o.service_fee;
  v_promo int;
  v_loy int;
  v_points int := o.loyalty_points;
begin
  if o.promo_code is not null then
    select * into pr from amine.promotions where code = o.promo_code;
  end if;
  if pr.id is not null then
    v_promo := amine.promo_discount(pr, p_sub, o.delivery_fee, o.service_fee);
  else
    v_promo := greatest(0, o.discount - o.loyalty_discount);
  end if;
  v_promo := least(v_promo, v_gross);
  v_loy := least(o.loyalty_discount, greatest(0, v_gross - v_promo));
  if v_loy < o.loyalty_discount then
    v_points := case when o.loyalty_discount = 0 then 0
      else ceil(o.loyalty_points::numeric * v_loy / o.loyalty_discount)::int end;
  end if;
  return jsonb_build_object('discount', v_promo + v_loy, 'promo_discount', v_promo, 'loyalty_discount', v_loy,
    'loyalty_points', v_points, 'refund_points', o.loyalty_points - v_points);
end $$;

-- Points gagnés sur une commande : retirés au prorata d'un avoir (marchandise reprise).
create or replace function amine.loyalty_reverse(p_order uuid, p_amount int, p_ref text) returns void
language plpgsql set search_path = '' as $$
declare
  o amine.orders;
  v_rate int := greatest(0, (amine.setting('loyalty') ->> 'earn_per_dt')::int);
  v_earned int;
  v_reversed int;
  v_pts int;
begin
  if p_order is null then
    return;
  end if;
  select * into o from amine.orders where id = p_order;
  if not found or o.customer_id is null then
    return;
  end if;
  select coalesce(sum(l.delta) filter (where l.kind = 'earn'), 0), coalesce(-sum(l.delta) filter (where l.kind = 'reversal'), 0)
  into v_earned, v_reversed from amine.loyalty_ledger l where l.order_id = o.id;
  v_pts := least(v_earned - v_reversed, floor(greatest(0, p_amount)::numeric / 1000 * v_rate)::int);
  if v_pts > 0 then
    perform amine.loyalty_add(o.customer_id, -v_pts, 'reversal', o.id, p_ref, 'credit_note');
  end if;
end $$;

-- ── Parrainage ───────────────────────────────────────────────────────────────────────────────
create or replace function amine.referral_code_for(p_customer uuid) returns text
language plpgsql set search_path = '' as $$
declare
  alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  v text;
  i int;
  n int := 0;
begin
  select referral_code into v from amine.profiles where id = p_customer;
  if v is not null then
    return v;
  end if;
  loop
    v := 'AMI-';
    for i in 1..6 loop
      v := v || substr(alphabet, 1 + floor(random() * 32)::int, 1);
    end loop;
    n := n + 1;
    exit when not exists (select 1 from amine.profiles where referral_code = v) or n > 20;
  end loop;
  update amine.profiles set referral_code = v where id = p_customer and referral_code is null;
  select referral_code into v from amine.profiles where id = p_customer;
  return v;
end $$;

-- Rattache un filleul à son parrain (avant sa première commande). Erreurs : REFERRAL_DISABLED, REFERRAL_INVALID,
-- REFERRAL_SELF, REFERRAL_ALREADY, REFERRAL_TOO_LATE, REFERRAL_LIMIT.
create or replace function amine.link_referral(p_user uuid, p_code text) returns void
language plpgsql set search_path = '' as $$
declare
  cfg jsonb := amine.setting('loyalty');
  v_raw text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_code text;
  er amine.profiles;
begin
  if not coalesce((cfg ->> 'enabled')::boolean, false) or not coalesce((cfg ->> 'referral_enabled')::boolean, false) then
    perform amine.err('REFERRAL_DISABLED');
  end if;
  v_code := case when v_raw ~ '^AMI[2-9A-HJ-NP-Z]{6}$' then 'AMI-' || substr(v_raw, 4) end;
  if v_code is null then
    perform amine.err('REFERRAL_INVALID');
  end if;
  select * into er from amine.profiles where referral_code = v_code and status = 'active';
  if not found then
    perform amine.err('REFERRAL_INVALID');
  end if;
  if er.id = p_user then
    perform amine.err('REFERRAL_SELF');
  end if;
  if exists (select 1 from amine.referrals where referee_id = p_user) then
    perform amine.err('REFERRAL_ALREADY');
  end if;
  if exists (select 1 from amine.orders o where o.customer_id = p_user and o.kind = 'store'
             and o.status not in ('cancelled', 'rejected')) then
    perform amine.err('REFERRAL_TOO_LATE');
  end if;
  if (select count(*) from amine.referrals r where r.referrer_id = er.id and r.status <> 'void')
     >= greatest(1, (cfg ->> 'referral_max')::int) then
    perform amine.err('REFERRAL_LIMIT');
  end if;
  insert into amine.referrals (referrer_id, referee_id) values (er.id, p_user);
end $$;

-- ── À la livraison : points gagnés et récompense de parrainage ───────────────────────────────
create or replace function amine.loyalty_on_delivered(o amine.orders) returns void
language plpgsql set search_path = '' as $$
declare
  cfg jsonb := amine.setting('loyalty');
  v_goods int := greatest(0, o.subtotal - o.discount);
  v_pts int;
  v_reward int := greatest(0, (cfg ->> 'referral_points')::int);
  r amine.referrals;
  ee amine.profiles;
  er amine.profiles;
  v_void text;
begin
  if not coalesce((cfg ->> 'enabled')::boolean, false) then
    return;
  end if;
  v_pts := floor(v_goods::numeric / 1000 * greatest(0, (cfg ->> 'earn_per_dt')::int))::int;
  if v_pts > 0 then
    perform amine.loyalty_add(o.customer_id, v_pts, 'earn', o.id, o.code);
    perform amine.notify(o.customer_id, 'points_earned', jsonb_build_object('points', v_pts, 'code', o.code,
      'balance', amine.loyalty_balance(o.customer_id)), '#/account/rewards');
  end if;

  if not coalesce((cfg ->> 'referral_enabled')::boolean, false) then
    return;
  end if;
  select * into r from amine.referrals where referee_id = o.customer_id and status = 'pending' for update;
  if not found or v_goods < greatest(0, (cfg ->> 'referral_min_subtotal')::int) then
    return;
  end if;
  select * into ee from amine.profiles where id = r.referee_id;
  select * into er from amine.profiles where id = r.referrer_id;
  v_void := case
    when er.id is null or er.status <> 'active' then 'REFERRER_INACTIVE'
    when ee.phone is not null and ee.phone = er.phone then 'SAME_PHONE'
    when ee.tax_id is not null and er.tax_id is not null and lower(btrim(ee.tax_id)) = lower(btrim(er.tax_id)) then 'SAME_BUSINESS'
    when ee.business_name is not null and er.business_name is not null
      and lower(btrim(ee.business_name)) = lower(btrim(er.business_name)) then 'SAME_BUSINESS'
    else null end;
  if v_void is not null then
    update amine.referrals set status = 'void', void_reason = v_void where id = r.id;
    return;
  end if;
  if v_reward > 0 then
    perform amine.loyalty_add(er.id, v_reward, 'referral', null, r.id::text || ':referrer');
    perform amine.loyalty_add(ee.id, v_reward, 'referral', null, r.id::text || ':referee');
    perform amine.notify(er.id, 'referral_rewarded', jsonb_build_object('points', v_reward, 'name', ee.business_name),
      '#/account/rewards');
    perform amine.notify(ee.id, 'referral_rewarded', jsonb_build_object('points', v_reward, 'name', er.business_name),
      '#/account/rewards');
  end if;
  update amine.referrals set status = 'rewarded', points = v_reward, order_id = o.id, rewarded_at = now() where id = r.id;
end $$;

create or replace function amine.on_order_loyalty() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.status is not distinct from old.status or new.kind <> 'store' or new.customer_id is null then
    return new;
  end if;
  if new.status in ('cancelled', 'rejected') then
    -- Commande annulée ou refusée : les points utilisés sont rendus.
    if new.loyalty_points > 0 then
      perform amine.loyalty_add(new.customer_id, new.loyalty_points, 'refund', new.id, new.code);
    end if;
  elsif new.status = 'delivered' then
    perform amine.loyalty_on_delivered(new);
  end if;
  return new;
end $$;

drop trigger if exists amine_orders_loyalty on amine.orders;
create trigger amine_orders_loyalty
  after update of status on amine.orders
  for each row execute function amine.on_order_loyalty();

-- ── Offre de bienvenue (code promo appliqué automatiquement à la première commande) ───────────
create or replace function amine.auto_promo(
  p_customer uuid, p_store amine.stores, p_subtotal int, p_fee int, p_service int, p_lock boolean
) returns jsonb
language plpgsql set search_path = '' as $$
declare
  r record;
  v_try jsonb;
  v_best jsonb;
begin
  if p_customer is null then
    return null;
  end if;
  if exists (select 1 from amine.orders where customer_id = p_customer and status not in ('cancelled', 'rejected')) then
    return null;
  end if;
  for r in select pr.code from amine.promotions pr
           where pr.auto_apply and pr.is_active and pr.archived_at is null order by pr.created_at limit 5 loop
    v_try := amine.promo_eval(r.code, p_customer, p_store, p_subtotal, p_fee, p_service, p_lock) || jsonb_build_object('auto', true);
    if coalesce((v_try ->> 'ok')::boolean, false) then
      if v_best is null or not coalesce((v_best ->> 'ok')::boolean, false)
         or (v_try ->> 'discount')::int > (v_best ->> 'discount')::int then
        v_best := v_try;
      end if;
    elsif v_best is null and v_try ->> 'error' = 'PROMO_MIN_SUBTOTAL' then
      v_best := v_try;
    end if;
  end loop;
  return v_best;
end $$;

-- ── Ventes flash ─────────────────────────────────────────────────────────────────────────────
-- Unités vendues au prix flash (commandes non annulées ni refusées).
create or replace function amine.flash_sold(p_id uuid) returns int
language sql stable set search_path = '' as $$
  select coalesce(sum(i.quantity), 0)::int
  from amine.order_items i join amine.orders o on o.id = i.order_id
  where i.flash_sale_id = p_id and o.status not in ('cancelled', 'rejected')
$$;

-- Vente flash en cours sur un produit, avec ce qu'elle donne pour cette quantité :
-- {id, price, starts_at, ends_at, remaining, per_order_max, regular_price, applies}. null = aucune vente flash.
create or replace function amine.flash_for(p_product uuid, p_unit int, p_qty int) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  f amine.flash_sales;
  v_remaining int;
begin
  select * into f from amine.flash_sales fs
  where fs.product_id = p_product and fs.is_active and now() >= fs.starts_at and now() < fs.ends_at
  order by fs.price limit 1;
  if not found then
    return null;
  end if;
  if f.max_units is not null then
    v_remaining := greatest(0, f.max_units - amine.flash_sold(f.id));
    if v_remaining = 0 then
      return null;
    end if;
  end if;
  return jsonb_build_object('id', f.id, 'price', f.price, 'starts_at', f.starts_at, 'ends_at', f.ends_at,
    'remaining', v_remaining, 'per_order_max', f.per_order_max, 'regular_price', p_unit,
    'applies', f.price < p_unit and (v_remaining is null or p_qty <= v_remaining)
      and (f.per_order_max is null or p_qty <= f.per_order_max));
end $$;

-- Ce que le catalogue montre pour un produit : {} ou {flash: {...}} (jamais si le client a déjà un prix égal ou plus bas).
create or replace function amine.flash_card(p amine.products, p_customer uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_unit int := amine.unit_price(p, p_customer, 1);
  f jsonb := amine.flash_for(p.id, v_unit, 1);
begin
  if f is null or not coalesce((f ->> 'applies')::boolean, false) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('flash', f || jsonb_build_object('now', now(),
    'percent', greatest(1, round(100 - (f ->> 'price')::numeric * 100 / v_unit))::int));
end $$;

-- Réserve les unités flash d'un panier chiffré : lignes verrouillées puis recomptées (pas de dépassement
-- même si deux commandes arrivent ensemble). FLASH_UNAVAILABLE : la vente a pris fin ou n'a plus assez d'unités.
create or replace function amine.flash_claim(p_lines jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  l jsonb;
  f amine.flash_sales;
  v_qty int;
begin
  for l in select e.value from jsonb_array_elements(p_lines) e where e.value ->> 'flash_sale_id' is not null
           order by e.value ->> 'flash_sale_id' loop
    v_qty := (l ->> 'quantity')::int;
    select * into f from amine.flash_sales where id = (l ->> 'flash_sale_id')::uuid for update;
    if not found or not f.is_active or now() < f.starts_at or now() >= f.ends_at
       or (f.max_units is not null and amine.flash_sold(f.id) + v_qty > f.max_units)
       or (f.per_order_max is not null and v_qty > f.per_order_max) then
      perform amine.err('FLASH_UNAVAILABLE', l ->> 'product_id');
    end if;
  end loop;
end $$;

create or replace function amine.flash_json(f amine.flash_sales) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  pr amine.products;
  v_sold int := amine.flash_sold(f.id);
  v_state text;
begin
  select * into pr from amine.products where id = f.product_id;
  v_state := case
    when not f.is_active then 'stopped'
    when now() < f.starts_at then 'upcoming'
    when now() >= f.ends_at then 'ended'
    when f.max_units is not null and v_sold >= f.max_units then 'soldout'
    else 'live' end;
  return jsonb_build_object('id', f.id, 'product_id', f.product_id,
    'product', jsonb_build_object('name', pr.name, 'name_ar', pr.name_ar, 'name_en', pr.name_en, 'price', pr.price,
      'unit', pr.unit, 'image_url', pr.image_url, 'ref', pr.ref),
    'price', f.price, 'percent', case when pr.price > 0 then greatest(0, round(100 - f.price::numeric * 100 / pr.price))::int end,
    'starts_at', f.starts_at, 'ends_at', f.ends_at, 'max_units', f.max_units, 'per_order_max', f.per_order_max,
    'sold', v_sold, 'remaining', case when f.max_units is null then null else greatest(0, f.max_units - v_sold) end,
    'revenue', (select coalesce(sum(i.total), 0)::int from amine.order_items i join amine.orders o on o.id = i.order_id
                where i.flash_sale_id = f.id and o.status not in ('cancelled', 'rejected')),
    'state', v_state, 'notified_at', f.notified_at, 'created_at', f.created_at);
end $$;

create or replace function public.merchant_flash_sales(p_store_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
begin
  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(amine.flash_json(f) order by f.starts_at desc)
      from (select * from amine.flash_sales where store_id = s.id order by starts_at desc limit 100) f), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'name_ar', p.name_ar,
        'name_en', p.name_en, 'price', p.price, 'unit', p.unit) order by p.name)
      from amine.products p where p.store_id = s.id and p.deleted_at is null and p.is_available), '[]'::jsonb));
end $$;

-- p_data : {product_id, price, starts_at (vide = maintenant), ends_at, max_units, per_order_max}
create or replace function public.merchant_save_flash_sale(p_store_id uuid, p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  f amine.flash_sales;
  pr amine.products;
  v_product uuid;
  v_price int;
  v_starts timestamptz;
  v_ends timestamptz;
  v_max int;
  v_per int;
  v_sold int := 0;
begin
  perform amine.hit('flash:' || auth.uid(), 60, 3600);
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    perform amine.err('INVALID_INPUT', 'data');
  end if;
  if p_id is not null then
    select * into f from amine.flash_sales where id = p_id and store_id = s.id for update;
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
    v_sold := amine.flash_sold(f.id);
  end if;
  v_product := coalesce(f.product_id, amine.uuid_in(p_data, 'product_id', true));
  select * into pr from amine.products where id = v_product and store_id = s.id and deleted_at is null;
  if not found then
    perform amine.err('INVALID_INPUT', 'product_id');
  end if;
  v_price := coalesce(f.price, 0);
  v_starts := coalesce(f.starts_at, amine.ts_in(p_data, 'starts_at'), now());
  v_ends := amine.ts_in(p_data, 'ends_at');
  v_max := amine.int_in(p_data, 'max_units', 1, 1000000, false);
  v_per := amine.int_in(p_data, 'per_order_max', 1, 999, false);
  if p_id is null or v_sold = 0 then
    -- Le prix et le début ne changent plus dès qu'une unité a été vendue.
    v_price := amine.int_in(p_data, 'price', 1, 100000000, true);
    if p_id is not null then
      v_starts := coalesce(amine.ts_in(p_data, 'starts_at'), f.starts_at);
    end if;
  end if;
  if v_price >= pr.price then
    perform amine.err('FLASH_PRICE_TOO_HIGH', pr.price::text);
  end if;
  if v_ends is null or v_ends <= v_starts or v_ends <= now() then
    perform amine.err('INVALID_INPUT', 'ends_at');
  end if;
  if v_ends > v_starts + interval '15 days' then
    perform amine.err('INVALID_INPUT', 'ends_at');
  end if;
  if p_id is null and v_starts < now() - interval '5 minutes' then
    perform amine.err('INVALID_INPUT', 'starts_at');
  end if;
  if v_max is not null and v_max < v_sold then
    perform amine.err('INVALID_INPUT', 'max_units');
  end if;
  if exists (select 1 from amine.flash_sales x where x.product_id = v_product and x.is_active
             and x.id is distinct from p_id and x.ends_at > now()
             and tstzrange(x.starts_at, x.ends_at) && tstzrange(v_starts, v_ends)) then
    perform amine.err('FLASH_OVERLAP');
  end if;
  if p_id is null then
    insert into amine.flash_sales (store_id, product_id, price, starts_at, ends_at, max_units, per_order_max, created_by)
    values (s.id, v_product, v_price, v_starts, v_ends, v_max, v_per, auth.uid()) returning * into f;
  else
    update amine.flash_sales set price = v_price, starts_at = v_starts, ends_at = v_ends, max_units = v_max,
      per_order_max = v_per, updated_at = now()
    where id = f.id returning * into f;
  end if;
  perform amine.audit('flash.saved', 'flash_sale', f.id::text, jsonb_build_object('product', pr.name, 'price', v_price));
  return amine.flash_json(f);
end $$;

create or replace function public.merchant_stop_flash_sale(p_store_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  f amine.flash_sales;
begin
  update amine.flash_sales set is_active = false, stopped_at = now(), updated_at = now()
  where id = p_id and store_id = s.id and is_active returning * into f;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  perform amine.audit('flash.stopped', 'flash_sale', f.id::text, '{}'::jsonb);
  return amine.flash_json(f);
end $$;

create or replace function public.merchant_delete_flash_sale(p_store_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  f amine.flash_sales;
begin
  select * into f from amine.flash_sales where id = p_id and store_id = s.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if exists (select 1 from amine.order_items where flash_sale_id = f.id) then
    perform amine.err('FLASH_HAS_SALES');
  end if;
  delete from amine.flash_sales where id = f.id;
  perform amine.audit('flash.deleted', 'flash_sale', f.id::text, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;

-- Prévient les restaurants qui ont déjà commandé ici (6 derniers mois) et ont accepté les messages : une seule fois.
create or replace function public.merchant_notify_flash_sale(p_store_id uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores := amine.require_staff(p_store_id);
  f amine.flash_sales;
  pr amine.products;
  v_count int := 0;
  c record;
begin
  perform amine.hit('flash_notify:' || auth.uid(), 10, 3600);
  select * into f from amine.flash_sales where id = p_id and store_id = s.id for update;
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  if not f.is_active or f.ends_at <= now() then
    perform amine.err('FLASH_UNAVAILABLE');
  end if;
  if f.notified_at is not null then
    perform amine.err('FLASH_ALREADY_NOTIFIED');
  end if;
  select * into pr from amine.products where id = f.product_id;
  for c in
    select distinct o.customer_id from amine.orders o
    join amine.profiles cu on cu.id = o.customer_id
    where o.store_id = s.id and o.kind = 'store' and o.status = 'delivered' and o.placed_at > now() - interval '180 days'
      and cu.status = 'active' and cu.marketing_opt_in
    limit 500
  loop
    perform amine.notify(c.customer_id, 'flash_sale', jsonb_build_object('product', pr.name, 'price', f.price,
      'percent', greatest(1, round(100 - f.price::numeric * 100 / pr.price))::int, 'ends_at', f.ends_at), '#/catalog');
    v_count := v_count + 1;
  end loop;
  update amine.flash_sales set notified_at = now() where id = f.id;
  perform amine.audit('flash.notified', 'flash_sale', f.id::text, jsonb_build_object('count', v_count));
  return jsonb_build_object('ok', true, 'notified', v_count);
end $$;

-- ── Espace client : points, parrainage ───────────────────────────────────────────────────────
create or replace function public.my_loyalty() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
  cfg jsonb := amine.setting('loyalty');
  v_balance int := amine.loyalty_balance(p.id);
  v_value int := greatest(1, (cfg ->> 'point_value')::int);
  v_ref boolean := coalesce((cfg ->> 'enabled')::boolean, false) and coalesce((cfg ->> 'referral_enabled')::boolean, false);
  v_code text;
begin
  if v_ref then
    v_code := amine.referral_code_for(p.id);
  end if;
  return jsonb_build_object(
    'enabled', coalesce((cfg ->> 'enabled')::boolean, false),
    'balance', v_balance, 'value', v_balance * v_value, 'point_value', v_value,
    'earn_per_dt', (cfg ->> 'earn_per_dt')::int, 'min_redeem', (cfg ->> 'min_redeem')::int,
    'max_redeem_bps', (cfg ->> 'max_redeem_bps')::int,
    'marketing_opt_in', p.marketing_opt_in,
    'referral', jsonb_build_object(
      'enabled', v_ref, 'code', v_code, 'points', (cfg ->> 'referral_points')::int,
      'min_subtotal', (cfg ->> 'referral_min_subtotal')::int, 'max', (cfg ->> 'referral_max')::int,
      'used', (select count(*) from amine.referrals r where r.referrer_id = p.id and r.status <> 'void'),
      'list', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(x.business_name, '—'), 'status', r.status,
          'created_at', r.created_at, 'rewarded_at', r.rewarded_at, 'points', r.points) order by r.created_at desc)
        from amine.referrals r join amine.profiles x on x.id = r.referee_id where r.referrer_id = p.id), '[]'::jsonb),
      'mine', (select jsonb_build_object('name', coalesce(x.business_name, '—'), 'status', r.status)
        from amine.referrals r join amine.profiles x on x.id = r.referrer_id where r.referee_id = p.id),
      'can_apply', not exists (select 1 from amine.referrals r where r.referee_id = p.id)
        and not exists (select 1 from amine.orders o where o.customer_id = p.id and o.kind = 'store'
                        and o.status not in ('cancelled', 'rejected'))),
    'welcome', case when exists (select 1 from amine.orders o where o.customer_id = p.id and o.status not in ('cancelled', 'rejected'))
      then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('code', pr.code, 'description', pr.description,
          'kind', pr.kind, 'value', pr.value, 'max_discount', pr.max_discount, 'min_subtotal', pr.min_subtotal,
          'ends_at', pr.ends_at) order by pr.created_at)
        from amine.promotions pr where pr.auto_apply and pr.is_active and pr.archived_at is null
          and (pr.starts_at is null or now() >= pr.starts_at) and (pr.ends_at is null or now() < pr.ends_at)), '[]'::jsonb) end,
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'points', l.delta, 'kind', l.kind, 'ref', l.ref,
        'note', l.note, 'at', l.created_at) order by l.id desc)
      from (select * from amine.loyalty_ledger where customer_id = p.id order by id desc limit 60) l), '[]'::jsonb));
end $$;

create or replace function public.apply_referral_code(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  perform amine.hit('referral:' || p.id, 10, 3600);
  perform amine.link_referral(p.id, p_code);
  return public.my_loyalty();
end $$;

create or replace function public.set_my_marketing(p_opt_in boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p amine.profiles := amine.me();
begin
  if p_opt_in is null then
    perform amine.err('INVALID_INPUT', 'opt_in');
  end if;
  update amine.profiles set marketing_opt_in = p_opt_in, updated_at = now() where id = p.id;
  return jsonb_build_object('ok', true, 'marketing_opt_in', p_opt_in);
end $$;

-- ── Administration : tableau de bord fidélité, parrainages, points, clients inactifs ──────────
create or replace function public.admin_loyalty() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_value int := greatest(1, (amine.setting('loyalty') ->> 'point_value')::int);
  v_out bigint;
begin
  select coalesce(sum(b.bal), 0) into v_out from (
    select sum(delta) as bal from amine.loyalty_ledger group by customer_id having sum(delta) > 0) b;
  return jsonb_build_object(
    'settings', amine.setting('loyalty'),
    'stats', jsonb_build_object(
      'outstanding_points', v_out, 'outstanding_value', v_out * v_value,
      'customers', (select count(*) from (select 1 from amine.loyalty_ledger group by customer_id having sum(delta) > 0) x),
      'earned_30d', (select coalesce(sum(delta), 0) from amine.loyalty_ledger where kind = 'earn' and created_at > now() - interval '30 days'),
      'redeemed_value_30d', (select coalesce(sum(o.loyalty_discount), 0) from amine.orders o
        where o.loyalty_points > 0 and o.status not in ('cancelled', 'rejected') and o.placed_at > now() - interval '30 days'),
      'referrals', jsonb_build_object(
        'pending', (select count(*) from amine.referrals where status = 'pending'),
        'rewarded', (select count(*) from amine.referrals where status = 'rewarded'),
        'void', (select count(*) from amine.referrals where status = 'void')),
      'flash_live', (select count(*) from amine.flash_sales where is_active and now() >= starts_at and now() < ends_at)),
    'referrals', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'void_reason', r.void_reason,
        'points', r.points, 'created_at', r.created_at, 'rewarded_at', r.rewarded_at,
        'referrer', jsonb_build_object('id', er.id, 'name', coalesce(er.business_name, er.full_name)),
        'referee', jsonb_build_object('id', ee.id, 'name', coalesce(ee.business_name, ee.full_name))) order by r.created_at desc)
      from (select * from amine.referrals order by created_at desc limit 60) r
      join amine.profiles er on er.id = r.referrer_id join amine.profiles ee on ee.id = r.referee_id), '[]'::jsonb),
    'welcome', coalesce((select jsonb_agg(jsonb_build_object('id', pr.id, 'code', pr.code, 'description', pr.description,
        'kind', pr.kind, 'value', pr.value, 'is_active', pr.is_active) order by pr.created_at)
      from amine.promotions pr where pr.auto_apply and pr.archived_at is null), '[]'::jsonb));
end $$;

create or replace function public.admin_void_referral(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_reason text := amine.txt(p_reason, 'reason', 60, true, 3);
begin
  update amine.referrals set status = 'void', void_reason = v_reason where id = p_id and status = 'pending';
  if not found then
    perform amine.err('NOT_FOUND');
  end if;
  perform amine.audit('referral.void', 'referral', p_id::text, jsonb_build_object('reason', v_reason));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_adjust_points(p_customer uuid, p_points int, p_note text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_note text := amine.txt(p_note, 'note', 120, true, 3);
  v_balance int;
begin
  perform amine.hit('admin_points:' || a.id, 100, 3600);
  if p_points is null or p_points = 0 or abs(p_points) > 100000 then
    perform amine.err('INVALID_INPUT', 'points');
  end if;
  if not exists (select 1 from amine.profiles where id = p_customer) then
    perform amine.err('NOT_FOUND');
  end if;
  v_balance := amine.loyalty_balance(p_customer);
  if v_balance + p_points < 0 then
    perform amine.err('INSUFFICIENT_POINTS', greatest(0, v_balance)::text);
  end if;
  perform amine.loyalty_add(p_customer, p_points, 'adjust', null, null, v_note, a.id);
  perform amine.notify(p_customer, 'points_adjusted', jsonb_build_object('points', p_points, 'note', v_note,
    'balance', v_balance + p_points), '#/account/rewards');
  perform amine.audit('loyalty.adjust', 'profile', p_customer::text, jsonb_build_object('points', p_points, 'note', v_note));
  return jsonb_build_object('ok', true, 'balance', v_balance + p_points);
end $$;

-- Clients qui ont déjà commandé et n'ont pas commandé depuis au moins p_days jours (réglage par défaut : 15).
create or replace function amine.inactive_clients(p_days int, p_limit int default 200) returns table (
  id uuid, business_name text, full_name text, phone text, marketing_opt_in boolean, reminded_at timestamptz,
  last_order_at timestamptz, orders bigint, spent bigint, points int
) language sql stable set search_path = '' as $$
  select p.id, p.business_name, p.full_name, p.phone, p.marketing_opt_in, p.reminded_at, x.last_order_at, x.orders, x.spent,
    amine.loyalty_balance(p.id)
  from amine.profiles p
  join lateral (
    select max(o.placed_at) as last_order_at, count(*) filter (where o.status = 'delivered') as orders,
      coalesce(sum(o.total) filter (where o.status = 'delivered'), 0)::bigint as spent,
      bool_or(o.status in ('placed', 'accepted', 'preparing', 'ready', 'picked_up')) as has_active
    from amine.orders o where o.customer_id = p.id and o.kind = 'store' and o.status not in ('cancelled', 'rejected')) x on true
  where p.status = 'active' and not p.is_admin and x.orders > 0 and not coalesce(x.has_active, false)
    and x.last_order_at < now() - make_interval(days => greatest(1, p_days))
  order by x.last_order_at
  limit greatest(1, p_limit)
$$;

create or replace function public.admin_inactive_clients(p_days int default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  v_days int := coalesce(p_days, (amine.setting('loyalty') ->> 'remind_days')::int);
  v_cool int := greatest(1, (amine.setting('loyalty') ->> 'remind_days')::int);
begin
  if v_days < 1 or v_days > 365 then
    perform amine.err('INVALID_INPUT', 'days');
  end if;
  return jsonb_build_object('days', v_days, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id, 'business_name', c.business_name, 'full_name', c.full_name,
      'phone', c.phone, 'marketing_opt_in', c.marketing_opt_in, 'reminded_at', c.reminded_at,
      'last_order_at', c.last_order_at, 'inactive_days', floor(extract(epoch from now() - c.last_order_at) / 86400)::int,
      'orders', c.orders, 'spent', c.spent, 'points', c.points,
      'can_remind', c.marketing_opt_in and (c.reminded_at is null or c.reminded_at < now() - make_interval(days => 3)))
      order by c.last_order_at)
    from amine.inactive_clients(v_days) c), '[]'::jsonb));
end $$;

create or replace function amine.send_inactive_reminder(c amine.profiles, p_days int) returns void
language plpgsql set search_path = '' as $$
begin
  update amine.profiles set reminded_at = now() where id = c.id;
  perform amine.notify(c.id, 'inactive_reminder', jsonb_build_object('days', p_days,
    'points', greatest(0, amine.loyalty_balance(c.id))), '#/catalog');
end $$;

create or replace function public.admin_remind_client(p_customer uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a amine.profiles := amine.require_admin();
  c amine.profiles;
  v_last timestamptz;
begin
  perform amine.hit('admin_remind:' || a.id, 60, 3600);
  select * into c from amine.profiles where id = p_customer for update;
  if not found or c.status <> 'active' or c.is_admin then
    perform amine.err('NOT_FOUND');
  end if;
  if not c.marketing_opt_in then
    perform amine.err('NOT_OPTED_IN');
  end if;
  if c.reminded_at is not null and c.reminded_at > now() - interval '3 days' then
    perform amine.err('RECENTLY_REMINDED');
  end if;
  select max(o.placed_at) into v_last from amine.orders o
  where o.customer_id = c.id and o.kind = 'store' and o.status not in ('cancelled', 'rejected');
  perform amine.send_inactive_reminder(c, greatest(1, floor(extract(epoch from now() - coalesce(v_last, c.created_at)) / 86400)::int));
  perform amine.audit('client.reminded', 'profile', c.id::text, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;

-- Tâche de fond (au plus deux fois par jour) : rappel automatique, une seule fois par période d'inactivité.
create or replace function amine.remind_inactive_clients() returns void
language plpgsql set search_path = '' as $$
declare
  cfg jsonb := amine.setting('loyalty');
  v_last timestamptz;
  c record;
begin
  if not coalesce((cfg ->> 'remind_enabled')::boolean, false) then
    return;
  end if;
  select (value ->> 'last_run')::timestamptz into v_last from amine.settings where key = 'loyalty_state';
  if v_last is not null and v_last > now() - interval '12 hours' then
    return;
  end if;
  insert into amine.settings (key, value) values ('loyalty_state', jsonb_build_object('last_run', now()))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  for c in
    select i.id, floor(extract(epoch from now() - i.last_order_at) / 86400)::int as days
    from amine.inactive_clients(greatest(7, (cfg ->> 'remind_days')::int), 50) i
    where i.marketing_opt_in and (i.reminded_at is null or i.reminded_at < i.last_order_at)
  loop
    perform amine.send_inactive_reminder((select p from amine.profiles p where p.id = c.id), c.days);
  end loop;
end $$;

-- ── Droits ────────────────────────────────────────────────────────────────────────────────────
revoke all on all tables in schema amine from public, anon, authenticated;
revoke all on all sequences in schema amine from public, anon, authenticated;
revoke all on all functions in schema amine from public, anon, authenticated;

revoke all on function public.merchant_flash_sales(uuid) from public, anon, authenticated;
revoke all on function public.merchant_save_flash_sale(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.merchant_stop_flash_sale(uuid, uuid) from public, anon, authenticated;
revoke all on function public.merchant_delete_flash_sale(uuid, uuid) from public, anon, authenticated;
revoke all on function public.merchant_notify_flash_sale(uuid, uuid) from public, anon, authenticated;
revoke all on function public.my_loyalty() from public, anon, authenticated;
revoke all on function public.apply_referral_code(text) from public, anon, authenticated;
revoke all on function public.set_my_marketing(boolean) from public, anon, authenticated;
revoke all on function public.admin_loyalty() from public, anon, authenticated;
revoke all on function public.admin_void_referral(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_adjust_points(uuid, int, text) from public, anon, authenticated;
revoke all on function public.admin_inactive_clients(int) from public, anon, authenticated;
revoke all on function public.admin_remind_client(uuid) from public, anon, authenticated;
grant execute on function public.merchant_flash_sales(uuid) to authenticated;
grant execute on function public.merchant_save_flash_sale(uuid, uuid, jsonb) to authenticated;
grant execute on function public.merchant_stop_flash_sale(uuid, uuid) to authenticated;
grant execute on function public.merchant_delete_flash_sale(uuid, uuid) to authenticated;
grant execute on function public.merchant_notify_flash_sale(uuid, uuid) to authenticated;
grant execute on function public.my_loyalty() to authenticated;
grant execute on function public.apply_referral_code(text) to authenticated;
grant execute on function public.set_my_marketing(boolean) to authenticated;
grant execute on function public.admin_loyalty() to authenticated;
grant execute on function public.admin_void_referral(uuid, text) to authenticated;
grant execute on function public.admin_adjust_points(uuid, int, text) to authenticated;
grant execute on function public.admin_inactive_clients(int) to authenticated;
grant execute on function public.admin_remind_client(uuid) to authenticated;

notify pgrst, 'reload schema';
