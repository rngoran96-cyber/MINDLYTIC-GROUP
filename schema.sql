-- Gôly Express : schéma Supabase (à coller dans SQL Editor, puis « Run »)

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('admin','livreur')),
  admin_id uuid references public.profiles(id) on delete cascade,
  prenom text, nom text, tel text, entreprise text, email text,
  created_at timestamptz not null default now()
);

create table public.orders (
  id bigint generated always as identity primary key,
  admin_id uuid not null references public.profiles(id) on delete cascade,
  client_nom text not null, client_tel text not null, lieu text not null, produit text not null,
  prix_produit integer not null default 0 check (prix_produit >= 0),
  prix_livraison integer not null default 0 check (prix_livraison >= 0),
  mode_paiement text not null default 'COD' check (mode_paiement in ('COD','ELEC')),
  livreur_id uuid references public.profiles(id) on delete set null,
  statut text not null default 'En cours' check (statut in ('En cours','Livrée','Problème')),
  created_at timestamptz not null default now()
);

create table public.feedback (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  type text not null, message text not null, created_at timestamptz not null default now()
);

create or replace function public.is_admin(uid uuid) returns boolean
language sql security definer stable set search_path = public as
$$ select exists (select 1 from profiles where id = uid and role = 'admin') $$;

create or replace function public.is_driver_of(drv uuid, adm uuid) returns boolean
language sql security definer stable set search_path = public as
$$ select exists (select 1 from profiles where id = drv and role = 'livreur' and admin_id = adm) $$;

-- ===== Abonnement (prix modifiables dans price_of) =====
create table public.subscriptions (
  admin_id uuid primary key references public.profiles(id) on delete cascade,
  setup_paid boolean not null default false,
  paid_until date,
  created_at timestamptz not null default now()
);
create table public.payments (
  id bigint generated always as identity primary key,
  admin_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('ACTIVATION','MENSUEL')),
  amount integer not null,
  method text not null, reference text not null, wave_session_id text,
  status text not null default 'En attente' check (status in ('En attente','Validé','Refusé')),
  created_at timestamptz not null default now(), validated_at timestamptz,
  unique (method, reference)
);
create table public.platform_admins (user_id uuid primary key references auth.users(id) on delete cascade);

create or replace function public.price_of(k text) returns integer language sql immutable as
$$ select case k when 'ACTIVATION' then 120000 else 40000 end $$;
create or replace function public.sub_active(adm uuid) returns boolean
language sql security definer stable set search_path = public as
$$ select exists (select 1 from subscriptions where admin_id = adm and paid_until is not null and paid_until >= current_date) $$;
create or replace function public.is_platform_admin() returns boolean
language sql security definer stable set search_path = public as
$$ select exists (select 1 from platform_admins where user_id = auth.uid()) $$;

create or replace function public.new_sub() returns trigger language plpgsql security definer set search_path = public as
$$ begin if new.role = 'admin' then insert into subscriptions(admin_id) values (new.id); end if; return new; end $$;
create trigger profiles_new_sub after insert on public.profiles for each row execute function public.new_sub();

-- validation d'un paiement par l'équipe Gôly Express
create or replace function public.review_payment(pid bigint, ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare p payments; s subscriptions;
begin
  if not is_platform_admin() then raise exception 'Réservé à l''équipe Gôly Express'; end if;
  select * into p from payments where id = pid for update;
  if p.id is null or p.status <> 'En attente' then raise exception 'Paiement introuvable ou déjà traité'; end if;
  if not ok then update payments set status = 'Refusé', validated_at = now() where id = pid; return; end if;
  select * into s from subscriptions where admin_id = p.admin_id for update;
  if p.kind = 'MENSUEL' and not s.setup_paid then raise exception 'Activation requise avant le paiement mensuel'; end if;
  update subscriptions set setup_paid = setup_paid or p.kind = 'ACTIVATION',
    paid_until = greatest(coalesce(paid_until, current_date), current_date) + 30 where admin_id = p.admin_id;
  update payments set status = 'Validé', validated_at = now() where id = pid;
end $$;

-- appelée uniquement par la fonction serveur wave-webhook (clé service_role)
create or replace function public.apply_wave_payment(adm uuid, k text, amt integer, tx text, sess text) returns text
language plpgsql security definer set search_path = public as $$
declare s subscriptions;
begin
  if k not in ('ACTIVATION','MENSUEL') or amt <> price_of(k) then return 'montant-invalide'; end if;
  select * into s from subscriptions where admin_id = adm for update;
  if s.admin_id is null then return 'compte-introuvable'; end if;
  begin
    insert into payments (admin_id, kind, amount, method, reference, wave_session_id, status, validated_at)
    values (adm, k, amt, 'Wave', tx, sess, 'Validé', now());
  exception when unique_violation then return 'deja-traite'; end;
  update subscriptions set setup_paid = setup_paid or k = 'ACTIVATION',
    paid_until = greatest(coalesce(paid_until, current_date), current_date) + 30 where admin_id = adm;
  return 'ok';
end $$;
revoke all on function public.apply_wave_payment(uuid, text, integer, text, text) from public, anon, authenticated;
grant execute on function public.apply_wave_payment(uuid, text, integer, text, text) to service_role;

create or replace function public.payments_to_review() returns table(
  id bigint, entreprise text, email text, tel text, kind text, amount integer, method text, reference text, status text, created_at timestamptz)
language sql security definer stable set search_path = public as $$
  select p.id, f.entreprise, f.email, f.tel, p.kind, p.amount, p.method, p.reference, p.status, p.created_at
  from payments p join profiles f on f.id = p.admin_id
  where is_platform_admin() order by (p.status = 'En attente') desc, p.created_at desc limit 200 $$;

alter table public.profiles enable row level security;
alter table public.orders enable row level security;
alter table public.feedback enable row level security;

-- profiles : chacun voit son profil ; le gestionnaire voit ses livreurs
create policy p_select on public.profiles for select using (id = auth.uid() or admin_id = auth.uid());
create policy p_insert on public.profiles for insert with check (
  id = auth.uid() and ((role = 'admin' and admin_id is null) or (role = 'livreur' and is_admin(admin_id) and sub_active(admin_id))));
create policy p_delete on public.profiles for delete using (admin_id = auth.uid());
create policy p_update on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated;
grant update (prenom, nom, tel, entreprise) on public.profiles to authenticated;

-- commandes : le gestionnaire gère les siennes ; le livreur voit celles qui lui sont attribuées
create policy o_select on public.orders for select using (admin_id = auth.uid() or livreur_id = auth.uid());
create policy o_insert on public.orders for insert with check (
  admin_id = auth.uid() and is_admin(auth.uid()) and sub_active(admin_id) and (livreur_id is null or is_driver_of(livreur_id, admin_id)));
create policy o_update on public.orders for update using (admin_id = auth.uid() or livreur_id = auth.uid())
  with check ((admin_id = auth.uid() or livreur_id = auth.uid()) and sub_active(admin_id) and (livreur_id is null or is_driver_of(livreur_id, admin_id)));
create policy o_delete on public.orders for delete using (admin_id = auth.uid());

-- un livreur ne peut modifier que le statut de ses commandes
create or replace function public.orders_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is distinct from old.admin_id then
    if (new.admin_id, new.livreur_id, new.client_nom, new.client_tel, new.lieu, new.produit, new.prix_produit, new.prix_livraison, new.mode_paiement)
       is distinct from
       (old.admin_id, old.livreur_id, old.client_nom, old.client_tel, old.lieu, old.produit, old.prix_produit, old.prix_livraison, old.mode_paiement)
    then raise exception 'Un livreur ne peut modifier que le statut'; end if;
  end if;
  return new;
end $$;
create trigger orders_guard before update on public.orders for each row execute function public.orders_guard();

create policy f_insert on public.feedback for insert with check (user_id = auth.uid());
create policy f_select on public.feedback for select using (user_id = auth.uid());

-- mises à jour en direct
alter table public.subscriptions enable row level security;
alter table public.payments enable row level security;
alter table public.platform_admins enable row level security;
create policy s_select on public.subscriptions for select using (admin_id = auth.uid());
create policy pay_select on public.payments for select using (admin_id = auth.uid());
create policy pay_insert on public.payments for insert with check (
  admin_id = auth.uid() and is_admin(auth.uid()) and status = 'En attente' and amount = price_of(kind));

alter publication supabase_realtime add table public.orders, public.profiles, public.subscriptions, public.payments;

-- Après avoir créé VOTRE compte gestionnaire dans l'application, donnez-vous le droit de valider les paiements :
-- insert into public.platform_admins select id from auth.users where email = 'votre@email.com';
