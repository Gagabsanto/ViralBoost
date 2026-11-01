-- ViralBoost v2 — execute este arquivo inteiro no Supabase SQL Editor.
-- Seguro para uso com a chave publishable no navegador: RLS + RPCs transacionais.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  coins integer not null default 20 check (coins >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  username text not null,
  url text not null check (url ~* '^https?://([a-z0-9-]+\.)*tiktok\.com/'),
  title text not null check (char_length(title) between 2 and 65),
  category text not null,
  description text not null default '' check (char_length(description) <= 180),
  likes_count integer not null default 0 check (likes_count >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.coin_transactions (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount integer not null,
  reason text not null,
  reference text,
  created_at timestamptz not null default now()
);

create table if not exists public.post_reactions (
  user_id uuid not null references auth.users(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);

create unique index if not exists coin_transactions_once_idx
  on public.coin_transactions(user_id, reason, reference);
create index if not exists posts_created_at_idx on public.posts(created_at desc);

alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.coin_transactions enable row level security;
alter table public.post_reactions enable row level security;

-- Remova permissões amplas antigas, se houver.
revoke all on public.profiles from anon, authenticated;
revoke all on public.posts from anon, authenticated;
revoke all on public.coin_transactions from anon, authenticated;
revoke all on public.post_reactions from anon, authenticated;

grant select on public.posts to anon, authenticated;
grant select on public.profiles to authenticated;
grant select on public.coin_transactions to authenticated;
grant select on public.post_reactions to authenticated;

-- Leitura pública apenas do mural. Saldo e histórico ficam privados.
drop policy if exists "Public can read posts" on public.posts;
create policy "Public can read posts" on public.posts for select using (true);

drop policy if exists "Users read own profile" on public.profiles;
create policy "Users read own profile" on public.profiles for select to authenticated using (auth.uid() = id);

drop policy if exists "Users read own transactions" on public.coin_transactions;
create policy "Users read own transactions" on public.coin_transactions for select to authenticated using (auth.uid() = user_id);

drop policy if exists "Users read own reactions" on public.post_reactions;
create policy "Users read own reactions" on public.post_reactions for select to authenticated using (auth.uid() = user_id);

-- Cria perfil e saldo inicial de 20 moedas ao cadastrar.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  chosen_name text;
begin
  chosen_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'username'), ''),
    'criador_' || left(replace(new.id::text, '-', ''), 8)
  );
  insert into public.profiles(id, username, coins)
  values (new.id, chosen_name, 20);
  insert into public.coin_transactions(user_id, amount, reason, reference)
  values (new.id, 20, 'welcome', 'signup');
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_viralboost on auth.users;
create trigger on_auth_user_created_viralboost
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- Bônus diário: no máximo uma vez por usuário por dia, controlado no banco.
create or replace function public.claim_daily_coins()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  inserted_count integer;
  day_ref text := to_char((now() at time zone 'utc')::date, 'YYYY-MM-DD');
begin
  if uid is null then raise exception 'Faça login para receber moedas.'; end if;
  insert into public.coin_transactions(user_id, amount, reason, reference)
  values (uid, 2, 'daily_login', day_ref)
  on conflict (user_id, reason, reference) do nothing;
  get diagnostics inserted_count = row_count;
  if inserted_count = 0 then return false; end if;
  update public.profiles set coins = coins + 2 where id = uid;
  return true;
end;
$$;

-- Publicar custa 5 moedas. Débito e publicação acontecem na mesma transação.
create or replace function public.publish_video(
  p_url text, p_title text, p_category text, p_description text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  uname text;
  new_post_id uuid;
begin
  if uid is null then raise exception 'Faça login para publicar.'; end if;
  if p_url !~* '^https?://([a-z0-9-]+\.)*tiktok\.com/' then raise exception 'Informe um link válido do TikTok.'; end if;
  if char_length(trim(p_title)) < 2 or char_length(p_title) > 65 then raise exception 'O título deve ter entre 2 e 65 caracteres.'; end if;
  if char_length(coalesce(p_description, '')) > 180 then raise exception 'A descrição passou de 180 caracteres.'; end if;
  select username into uname from public.profiles where id = uid;
  update public.profiles set coins = coins - 5 where id = uid and coins >= 5;
  if not found then raise exception 'Você precisa de pelo menos 5 ViralCoins.'; end if;
  insert into public.posts(user_id, username, url, title, category, description)
  values (uid, uname, trim(p_url), trim(p_title), trim(p_category), coalesce(trim(p_description), ''))
  returning id into new_post_id;
  insert into public.coin_transactions(user_id, amount, reason, reference)
  values (uid, -5, 'publish_video', new_post_id::text);
  return new_post_id;
end;
$$;

-- Um apoio por pessoa em cada vídeo. Apoiar outro criador rende 2 moedas uma única vez.
create or replace function public.support_video(p_post_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  owner_id uuid;
  inserted_count integer;
begin
  if uid is null then raise exception 'Faça login para apoiar.'; end if;
  select user_id into owner_id from public.posts where id = p_post_id;
  if owner_id is null then raise exception 'Vídeo não encontrado.'; end if;
  if owner_id = uid then raise exception 'Você não pode apoiar seu próprio vídeo.'; end if;
  insert into public.post_reactions(user_id, post_id) values (uid, p_post_id)
  on conflict (user_id, post_id) do nothing;
  get diagnostics inserted_count = row_count;
  if inserted_count = 0 then return false; end if;
  update public.posts set likes_count = likes_count + 1 where id = p_post_id;
  update public.profiles set coins = coins + 2 where id = uid;
  insert into public.coin_transactions(user_id, amount, reason, reference)
  values (uid, 2, 'support_video', p_post_id::text);
  return true;
end;
$$;

revoke all on function public.claim_daily_coins() from public;
revoke all on function public.publish_video(text, text, text, text) from public;
revoke all on function public.support_video(uuid) from public;
grant execute on function public.claim_daily_coins() to authenticated;
grant execute on function public.publish_video(text, text, text, text) to authenticated;
grant execute on function public.support_video(uuid) to authenticated;

-- Nenhuma tabela aceita INSERT/UPDATE direto pelo navegador; ações passam pelas RPCs acima.
