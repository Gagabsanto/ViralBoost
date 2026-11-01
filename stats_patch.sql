-- ViralBoost: estatísticas públicas globais do mural.
-- Execute uma única vez no Supabase SQL Editor.
create or replace function public.get_public_stats()
returns table(total_posts bigint, total_supports bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::bigint, coalesce(sum(likes_count), 0)::bigint
  from public.posts;
$$;
revoke all on function public.get_public_stats() from public;
grant execute on function public.get_public_stats() to anon, authenticated;
