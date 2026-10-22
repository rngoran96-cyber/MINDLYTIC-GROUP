-- Gôly Express : crée VOTRE compte gestionnaire et lui donne le droit de valider les paiements.
-- 1) Modifiez les 5 valeurs ci-dessous. 2) Collez tout dans Supabase > SQL Editor > Run.
-- Ce compte a un abonnement gratuit jusqu'en 2099 (c'est votre compte, il ne paie pas).
-- Si le script échoue à la création de l'utilisateur, créez le compte avec « Créer un compte »
-- dans l'application (même email), puis relancez ce script : il reprend le compte existant.
do $$
declare
  v_email    text := 'rngoran96@email.com';        -- MODIFIEZ
  v_password text := 'pharel';  -- MODIFIEZ (à changer ensuite dans « Mon profil »)
  v_prenom   text := 'Prénom';Romaric  -- MODIFIEZ
  v_nom      text := 'Nom'; N'GORAN' -- MODIFIEZ
  v_tel      text := '+225 0759206755';    -- MODIFIEZ
  v_uid uuid;
begin
  if v_email = 'rngoran96@email.com' then raise exception 'Modifiez d''abord v_email, v_password, v_prenom, v_nom et v_tel'; end if;
  v_email := lower(trim(v_email));
  select id into v_uid from auth.users where email = v_email;

  if v_uid is null then
    v_uid := gen_random_uuid();
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change,
      email_change_token_current, phone_change, phone_change_token, reauthentication_token)
    values (
      '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email,
      crypt(v_password, gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(),
      '', '', '', '', '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_uid, v_uid::text,
      jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true), 'email', now(), now(), now());
  end if;

  insert into public.profiles (id, role, prenom, nom, tel, entreprise, email)
  values (v_uid, 'admin', v_prenom, v_nom, v_tel, 'Gôly Express', v_email)
  on conflict (id) do nothing;

  insert into public.subscriptions (admin_id, setup_paid, paid_until)
  values (v_uid, true, date '2099-12-31')
  on conflict (admin_id) do update set setup_paid = true, paid_until = date '2099-12-31';

  insert into public.platform_admins (user_id) values (v_uid) on conflict do nothing;
  raise notice 'Compte gestionnaire prêt : % (droit de validation des paiements accordé)', v_email;
end $$;
