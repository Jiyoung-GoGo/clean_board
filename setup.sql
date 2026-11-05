-- 공지소통게시판: 새 Supabase 프로젝트에서 1회 실행
create schema if not exists private;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.board_posts (
  id bigint generated always as identity primary key,
  parent_id bigint references public.board_posts(id) on delete cascade,
  title text,
  body text not null,
  password_hash text not null,
  pinned boolean not null default false,
  views integer not null default 0,
  created_at timestamptz not null default now(),
  constraint valid_post check (char_length(body) between 1 and 5000),
  constraint valid_title check ((parent_id is null and title is not null and char_length(title) between 1 and 120) or (parent_id is not null and title is null))
);
create index if not exists board_posts_parent_idx on public.board_posts(parent_id);
create index if not exists board_posts_sort_idx on public.board_posts(pinned desc, created_at desc) where parent_id is null;
alter table public.board_posts enable row level security;
revoke all on public.board_posts from public, anon, authenticated;
revoke all on sequence public.board_posts_id_seq from public, anon, authenticated;

create table if not exists private.board_admin (id integer primary key default 1 check(id=1), password_hash text not null);
revoke all on private.board_admin from public, anon, authenticated;
-- 관리자 비밀번호는 첫 설치 또는 변경 시 설정합니다. 재실행하면 아래 값으로 갱신됩니다.
insert into private.board_admin(id, password_hash)
values (1, extensions.crypt('0075', extensions.gen_salt('bf', 12)))
on conflict (id) do update set password_hash = excluded.password_hash;


-- 사이트 입장 암호 (관리자 암호와 다르게 설정, 재실행 시 갱신)
create table if not exists private.board_access (id integer primary key check(id=1), password_hash text not null);
revoke all on private.board_access from public, anon, authenticated;
insert into private.board_access (id,password_hash)
values (1, extensions.crypt('2015', extensions.gen_salt('bf',12)))
on conflict (id) do update set password_hash=excluded.password_hash;

-- 서버 측 임시 세션: DB에는 원본 토큰이 아닌 해시만 저장
create table if not exists private.board_sessions (
 token_hash text primary key,
 expires_at timestamptz not null
);
create index if not exists board_sessions_expiry_idx on private.board_sessions(expires_at);
revoke all on private.board_sessions from public, anon, authenticated;
-- 이미 v0.1이 설치되어 있어도 비밀번호 없는 옛 RPC를 남기지 않습니다.
drop function if exists public.board_list(text);
drop function if exists public.board_open(bigint);
drop function if exists public.board_save(bigint,bigint,text,text,text,text);
drop function if exists public.board_delete(bigint,text,text);
drop function if exists public.board_pin(bigint,boolean,text);
drop function if exists public.board_admin_check(text);
-- 옛 private 함수는 먼저 public 의존성을 제거한 뒤 폐기
 drop function if exists private.board_list(text);
 drop function if exists private.board_open(bigint);
 drop function if exists private.board_save(bigint,bigint,text,text,text,text);
 drop function if exists private.board_delete(bigint,text,text);
 drop function if exists private.board_pin(bigint,boolean,text);

-- 인증정보는 서버에서만 검증: 암호를 클라이언트에 저장하지 않습니다.
create or replace function private.board_require_entry(p_token text) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if p_token is null or length(p_token) <> 36 or not exists (
   select 1 from private.board_sessions
   where token_hash = encode(extensions.digest(p_token,'sha256'),'hex') and expires_at > now()
 ) then
   raise exception '입장 인증이 필요하거나 세션이 만료되었습니다.';
 end if;
end $$;

create or replace function private.board_enter(p_password text) returns text
language plpgsql security definer set search_path = '' as $$
declare v_token text;
begin
 if p_password is null or not exists (
   select 1 from private.board_access a
   where a.id=1 and a.password_hash=extensions.crypt(p_password,a.password_hash)
 ) then
   raise exception '입장 비밀번호가 올바르지 않습니다.';
 end if;
 v_token := gen_random_uuid()::text;
 delete from private.board_sessions where expires_at <= now();
 insert into private.board_sessions(token_hash,expires_at)
 values (encode(extensions.digest(v_token,'sha256'),'hex'),now()+interval '12 hours');
 return v_token;
end $$;

create or replace function private.board_leave(p_token text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
 delete from private.board_sessions where token_hash=encode(extensions.digest(coalesce(p_token,''),'sha256'),'hex');
 return true;
end $$;

create or replace function private.board_is_admin(p_password text) returns boolean
language sql security definer set search_path = '' as $$
 select coalesce(exists(select 1 from private.board_admin
 where id=1 and password_hash = extensions.crypt(p_password, password_hash)), false);
$$;

create or replace function private.board_list(p_search text default '', p_token text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
 perform private.board_require_entry(p_token);
 return (select coalesce(jsonb_agg(to_jsonb(t) order by t.pinned desc, t.created_at desc, t.id desc), '[]'::jsonb)
 from (
  select p.id, p.title, p.body, p.pinned, p.views, p.created_at,
     (select count(*)::integer from public.board_posts a where a.parent_id = p.id) as answer_count
  from public.board_posts p
  where p.parent_id is null and (coalesce(trim(p_search),'') = ''
    or strpos(lower(p.title), lower(trim(p_search))) > 0
    or strpos(lower(p.body), lower(trim(p_search))) > 0)
  order by p.pinned desc, p.created_at desc, p.id desc limit 200
 ) t);
end $$;

create or replace function private.board_open(p_id bigint, p_token text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_question jsonb; v_answers jsonb;
begin
 perform private.board_require_entry(p_token);
 update public.board_posts set views = views + 1 where id=p_id and parent_id is null;
 if not found then raise exception '게시글이 없습니다.'; end if;
 select jsonb_build_object('id',id,'title',title,'body',body,'pinned',pinned,'views',views,'created_at',created_at)
 into v_question from public.board_posts where id=p_id;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'body',body,'created_at',created_at) order by created_at, id), '[]'::jsonb)
 into v_answers from public.board_posts where parent_id=p_id;
 return jsonb_build_object('question',v_question,'answers',v_answers);
end $$;

create or replace function private.board_save(p_id bigint, p_parent_id bigint, p_title text, p_body text, p_password text, p_admin_password text default null, p_token text default null) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v_old public.board_posts%rowtype; v_id bigint; v_admin boolean;
begin
 perform private.board_require_entry(p_token);
 if char_length(trim(coalesce(p_body,''))) not between 1 and 5000 then raise exception '내용은 1~5000자여야 합니다.'; end if;
 if p_id is null then
  if char_length(coalesce(p_password,'')) < 8 then raise exception '작성 비밀번호는 8자 이상이어야 합니다.'; end if;
  if p_parent_id is null then
   if char_length(trim(coalesce(p_title,''))) not between 1 and 120 then raise exception '제목은 1~120자여야 합니다.'; end if;
  else
   if not exists(select 1 from public.board_posts where id=p_parent_id and parent_id is null) then raise exception '원문 질문을 찾을 수 없습니다.'; end if;
  end if;
  insert into public.board_posts(parent_id,title,body,password_hash)
  values (p_parent_id, case when p_parent_id is null then trim(p_title) else null end, trim(p_body), extensions.crypt(p_password,extensions.gen_salt('bf', 12)))
  returning id into v_id;
  return v_id;
 end if;
 select * into v_old from public.board_posts where id=p_id for update;
 if not found then raise exception '게시글이 없습니다.'; end if;
 v_admin := private.board_is_admin(p_admin_password);
 if not v_admin and (p_password is null or v_old.password_hash <> extensions.crypt(p_password, v_old.password_hash)) then
  raise exception '수정 권한이 없습니다. 비밀번호를 확인하세요.';
 end if;
 if v_old.parent_id is null and char_length(trim(coalesce(p_title,''))) not between 1 and 120 then raise exception '제목은 1~120자여야 합니다.'; end if;
 update public.board_posts set title=case when v_old.parent_id is null then trim(p_title) else null end,
 body=trim(p_body) where id=p_id;
 return p_id;
end $$;

create or replace function private.board_delete(p_id bigint, p_password text, p_admin_password text default null, p_token text default null) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_hash text;
begin
 perform private.board_require_entry(p_token);
 select password_hash into v_hash from public.board_posts where id=p_id for update;
 if not found then raise exception '게시글이 없습니다.'; end if;
 if not private.board_is_admin(p_admin_password) and (p_password is null or v_hash <> extensions.crypt(p_password,v_hash)) then
  raise exception '삭제 권한이 없습니다. 비밀번호를 확인하세요.';
 end if;
 delete from public.board_posts where id=p_id;
 return true;
end $$;

create or replace function private.board_pin(p_id bigint, p_pin boolean, p_admin_password text, p_token text default null) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
 perform private.board_require_entry(p_token);
 if not private.board_is_admin(p_admin_password) then raise exception '관리자 비밀번호가 올바르지 않습니다.'; end if;
 update public.board_posts set pinned=p_pin where id=p_id and parent_id is null;
 if not found then raise exception '질문글을 찾을 수 없습니다.'; end if;
 return true;
end $$;


-- 공개 API는 모두 토큰 검증이 선행됩니다.
create or replace function public.board_enter(p_password text) returns text language sql security invoker set search_path = '' as $$ select private.board_enter(p_password); $$;
create or replace function public.board_leave(p_token text) returns boolean language sql security invoker set search_path = '' as $$ select private.board_leave(p_token); $$;
create or replace function public.board_list(p_search text default '', p_token text default null) returns jsonb language sql security invoker set search_path = '' as $$ select private.board_list(p_search,p_token); $$;
create or replace function public.board_open(p_id bigint, p_token text default null) returns jsonb language sql security invoker set search_path = '' as $$ select private.board_open(p_id,p_token); $$;
create or replace function public.board_save(p_id bigint, p_parent_id bigint, p_title text, p_body text, p_password text, p_admin_password text default null, p_token text default null) returns bigint language sql security invoker set search_path = '' as $$ select private.board_save(p_id,p_parent_id,p_title,p_body,p_password,p_admin_password,p_token); $$;
create or replace function public.board_delete(p_id bigint, p_password text, p_admin_password text default null, p_token text default null) returns boolean language sql security invoker set search_path = '' as $$ select private.board_delete(p_id,p_password,p_admin_password,p_token); $$;
create or replace function public.board_pin(p_id bigint, p_pin boolean, p_admin_password text, p_token text default null) returns boolean language sql security invoker set search_path = '' as $$ select private.board_pin(p_id,p_pin,p_admin_password,p_token); $$;
create or replace function public.board_admin_check(p_password text, p_token text default null) returns boolean language plpgsql security invoker set search_path = '' as $$
begin
 perform private.board_require_entry(p_token);
 return private.board_is_admin(p_password);
end $$;

-- Supabase의 API에 노출되지 않는 private 함수에도 최소한의 호출 권한만 부여
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to anon;
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.board_enter(text), private.board_leave(text), private.board_require_entry(text), private.board_is_admin(text), private.board_list(text,text), private.board_open(bigint,text), private.board_save(bigint,bigint,text,text,text,text,text), private.board_delete(bigint,text,text,text), private.board_pin(bigint,boolean,text,text) to anon;
-- 공개 API 함수 이외에는 직접 권한을 부여하지 않음
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.board_enter(text), public.board_leave(text), public.board_list(text,text), public.board_open(bigint,text), public.board_save(bigint,bigint,text,text,text,text,text), public.board_delete(bigint,text,text,text), public.board_pin(bigint,boolean,text,text), public.board_admin_check(text,text) to anon;
