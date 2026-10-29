-- ============================================================
--  Zündstoff CBRN – Einrichtung der Datenbank in Supabase
--  © 2026 Sondereinheit CBRN · Feuerwehr Kleve
--
--  Einmal komplett im SQL Editor ausführen (New query → einfügen → Run).
--  Legt an: Mitgliederprofile mit Freigabe, Kategorien, Inhalte,
--  Dateien, Lesezeichen, Protokoll, Dateispeicher und alle
--  Zugriffsregeln (Row Level Security).
-- ============================================================


-- ------------------------------------------------------------
-- 1. Tabellen
-- ------------------------------------------------------------

create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  vorname       text not null default '',
  nachname      text not null default '',
  geburtsdatum  date,
  rolle         text not null default 'mitglied' check (rolle in ('mitglied','admin')),
  status        text not null default 'wartet'   check (status in ('wartet','aktiv','gesperrt')),
  erstellt_am   timestamptz not null default now()
);

create table if not exists public.kategorien (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  kurz         text not null default '',
  sortierung   int  not null default 0,
  erstellt_am  timestamptz not null default now()
);

create table if not exists public.inhalte (
  id             uuid primary key default gen_random_uuid(),
  kategorie_id   uuid references public.kategorien(id) on delete restrict,
  titel          text not null,
  kurz           text not null default '',
  text           text not null default '',
  art            text not null default 'text' check (art in ('text','warntafel')),
  erstellt_von   uuid references auth.users(id) on delete set null default auth.uid(),
  erstellt_am    timestamptz not null default now(),
  geaendert_am   timestamptz not null default now()
);

create table if not exists public.dateien (
  id           uuid primary key default gen_random_uuid(),
  inhalt_id    uuid not null references public.inhalte(id) on delete cascade,
  pfad         text not null unique,          -- Pfad im Speicher-Bucket "unterlagen"
  name         text not null,
  typ          text not null default 'Datei',  -- Bild, Video, PDF, Datei
  groesse      bigint not null default 0,
  erstellt_am  timestamptz not null default now()
);

create table if not exists public.lesezeichen (
  user_id      uuid not null references auth.users(id) on delete cascade default auth.uid(),
  inhalt_id    uuid not null references public.inhalte(id) on delete cascade,
  erstellt_am  timestamptz not null default now(),
  primary key (user_id, inhalt_id)
);

create table if not exists public.protokoll (
  id       bigint generated always as identity primary key,
  zeit     timestamptz not null default now(),
  user_id  uuid default auth.uid(),
  aktion   text not null
);

create index if not exists inhalte_kategorie_idx on public.inhalte(kategorie_id);
create index if not exists dateien_inhalt_idx    on public.dateien(inhalt_id);
create index if not exists protokoll_zeit_idx    on public.protokoll(zeit desc);


-- ------------------------------------------------------------
-- 2. Hilfsfunktionen für die Zugriffsregeln
-- ------------------------------------------------------------

create or replace function public.ist_aktiv()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'aktiv');
$$;

create or replace function public.ist_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'aktiv' and rolle = 'admin');
$$;

revoke execute on function public.ist_aktiv() from anon;
revoke execute on function public.ist_admin() from anon;


-- ------------------------------------------------------------
-- 3. Profil automatisch bei Registrierung anlegen
--    Rolle und Status werden NIE aus der Registrierung übernommen:
--    jedes neue Konto ist "mitglied" und "wartet" auf Freigabe.
-- ------------------------------------------------------------

create or replace function public.neues_konto()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  geb date;
begin
  begin
    geb := (new.raw_user_meta_data->>'geburtsdatum')::date;
  exception when others then
    geb := null;
  end;

  insert into public.profiles (id, vorname, nachname, geburtsdatum)
  values (
    new.id,
    left(coalesce(new.raw_user_meta_data->>'vorname',''), 80),
    left(coalesce(new.raw_user_meta_data->>'nachname',''), 80),
    geb
  )
  on conflict (id) do nothing;

  insert into public.protokoll (user_id, aktion)
  values (new.id, 'Neues Konto registriert, wartet auf Freigabe');
  return new;
end;
$$;

drop trigger if exists bei_registrierung on auth.users;
create trigger bei_registrierung
  after insert on auth.users
  for each row execute function public.neues_konto();


-- ------------------------------------------------------------
-- 4. Protokoll: Änderungen durch den Admin automatisch festhalten
-- ------------------------------------------------------------

create or replace function public.protokolliere()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t text;
begin
  if tg_table_name = 'inhalte' then
    t := case tg_op
      when 'INSERT' then 'Inhalt „' || new.titel || '“ veröffentlicht'
      when 'UPDATE' then 'Inhalt „' || new.titel || '“ geändert'
      else               'Inhalt „' || old.titel || '“ entfernt' end;
  elsif tg_table_name = 'kategorien' then
    t := case tg_op
      when 'INSERT' then 'Kategorie „' || new.name || '“ angelegt'
      when 'UPDATE' then 'Kategorie „' || new.name || '“ geändert'
      else               'Kategorie „' || old.name || '“ gelöscht' end;
  elsif tg_table_name = 'profiles' then
    if new.status is distinct from old.status or new.rolle is distinct from old.rolle then
      t := 'Konto ' || new.vorname || ' ' || new.nachname || ': Status ' || new.status || ', Rolle ' || new.rolle;
    end if;
  end if;

  if t is not null then
    insert into public.protokoll (aktion) values (t);
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists protokoll_inhalte on public.inhalte;
create trigger protokoll_inhalte after insert or update or delete on public.inhalte
  for each row execute function public.protokolliere();

drop trigger if exists protokoll_kategorien on public.kategorien;
create trigger protokoll_kategorien after insert or update or delete on public.kategorien
  for each row execute function public.protokolliere();

drop trigger if exists protokoll_profiles on public.profiles;
create trigger protokoll_profiles after update on public.profiles
  for each row execute function public.protokolliere();

create or replace function public.geaendert_jetzt()
returns trigger language plpgsql as $$
begin
  new.geaendert_am := now();
  return new;
end;
$$;

drop trigger if exists inhalte_geaendert on public.inhalte;
create trigger inhalte_geaendert before update on public.inhalte
  for each row execute function public.geaendert_jetzt();


-- ------------------------------------------------------------
-- 5. Zugriffsregeln (Row Level Security)
--    Grundsatz: Ohne Login sieht niemand etwas.
--    Freigegebene Mitglieder lesen. Nur der Admin schreibt.
-- ------------------------------------------------------------

alter table public.profiles    enable row level security;
alter table public.kategorien  enable row level security;
alter table public.inhalte     enable row level security;
alter table public.dateien     enable row level security;
alter table public.lesezeichen enable row level security;
alter table public.protokoll   enable row level security;

-- Profile: jeder sieht sein eigenes, der Admin alle. Ändern darf nur der Admin.
drop policy if exists "Profil lesen" on public.profiles;
create policy "Profil lesen" on public.profiles for select to authenticated
  using (id = auth.uid() or public.ist_admin());

drop policy if exists "Profil verwalten (Admin)" on public.profiles;
create policy "Profil verwalten (Admin)" on public.profiles for update to authenticated
  using (public.ist_admin()) with check (public.ist_admin());

drop policy if exists "Profil löschen (Admin)" on public.profiles;
create policy "Profil löschen (Admin)" on public.profiles for delete to authenticated
  using (public.ist_admin() and id <> auth.uid());

-- Kategorien
drop policy if exists "Kategorien lesen" on public.kategorien;
create policy "Kategorien lesen" on public.kategorien for select to authenticated
  using (public.ist_aktiv());

drop policy if exists "Kategorien verwalten (Admin)" on public.kategorien;
create policy "Kategorien verwalten (Admin)" on public.kategorien for all to authenticated
  using (public.ist_admin()) with check (public.ist_admin());

-- Inhalte
drop policy if exists "Inhalte lesen" on public.inhalte;
create policy "Inhalte lesen" on public.inhalte for select to authenticated
  using (public.ist_aktiv());

drop policy if exists "Inhalte verwalten (Admin)" on public.inhalte;
create policy "Inhalte verwalten (Admin)" on public.inhalte for all to authenticated
  using (public.ist_admin()) with check (public.ist_admin());

-- Dateien (Verzeichnis der hochgeladenen Dateien)
drop policy if exists "Dateien lesen" on public.dateien;
create policy "Dateien lesen" on public.dateien for select to authenticated
  using (public.ist_aktiv());

drop policy if exists "Dateien verwalten (Admin)" on public.dateien;
create policy "Dateien verwalten (Admin)" on public.dateien for all to authenticated
  using (public.ist_admin()) with check (public.ist_admin());

-- Lesezeichen: nur die eigenen
drop policy if exists "Eigene Lesezeichen" on public.lesezeichen;
create policy "Eigene Lesezeichen" on public.lesezeichen for all to authenticated
  using (user_id = auth.uid() and public.ist_aktiv())
  with check (user_id = auth.uid() and public.ist_aktiv());

-- Protokoll: nur der Admin liest, geschrieben wird nur über die Trigger oben
drop policy if exists "Protokoll lesen (Admin)" on public.protokoll;
create policy "Protokoll lesen (Admin)" on public.protokoll for select to authenticated
  using (public.ist_admin());

-- Nicht angemeldete Besucher bekommen keinerlei Tabellenrechte
revoke all on public.profiles, public.kategorien, public.inhalte,
              public.dateien, public.lesezeichen, public.protokoll from anon;


-- ------------------------------------------------------------
-- 6. Dateispeicher "unterlagen" (privat)
--    Max. 50 MB pro Datei (Grenze im kostenlosen Supabase-Tarif).
-- ------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('unterlagen', 'unterlagen', false, 52428800,
        array['image/jpeg','image/png','image/webp','image/gif','application/pdf','video/mp4','video/webm','video/quicktime'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Unterlagen lesen" on storage.objects;
create policy "Unterlagen lesen" on storage.objects for select to authenticated
  using (bucket_id = 'unterlagen' and public.ist_aktiv());

drop policy if exists "Unterlagen hochladen (Admin)" on storage.objects;
create policy "Unterlagen hochladen (Admin)" on storage.objects for insert to authenticated
  with check (bucket_id = 'unterlagen' and public.ist_admin());

drop policy if exists "Unterlagen ändern (Admin)" on storage.objects;
create policy "Unterlagen ändern (Admin)" on storage.objects for update to authenticated
  using (bucket_id = 'unterlagen' and public.ist_admin())
  with check (bucket_id = 'unterlagen' and public.ist_admin());

drop policy if exists "Unterlagen löschen (Admin)" on storage.objects;
create policy "Unterlagen löschen (Admin)" on storage.objects for delete to authenticated
  using (bucket_id = 'unterlagen' and public.ist_admin());


-- ------------------------------------------------------------
-- 7. Startinhalte (nur wenn noch keine Kategorien existieren)
-- ------------------------------------------------------------

do $$
declare
  k_gefahrgut uuid; k_taktik uuid; k_strahlen uuid;
begin
  if not exists (select 1 from public.kategorien) then
    insert into public.kategorien (name, kurz, sortierung) values
      ('Gefahrgut & Warntafeln', 'Kennzeichnung lesen und deuten', 1) returning id into k_gefahrgut;
    insert into public.kategorien (name, kurz, sortierung) values
      ('Einsatztaktik', 'GAMS, Bereiche, Abläufe', 2) returning id into k_taktik;
    insert into public.kategorien (name, kurz, sortierung) values
      ('Strahlenschutz', 'Grundregeln und Dosimetrie', 3) returning id into k_strahlen;
    insert into public.kategorien (name, kurz, sortierung) values
      ('Messtechnik', 'Geräte und Messwerte', 4),
      ('Dekontamination', 'Dekon-Platz und Abläufe', 5);

    insert into public.inhalte (kategorie_id, titel, kurz, text, art, erstellt_von) values
      (k_gefahrgut, 'Warntafel: Gefahrnummer und UN-Nummer',
       'Was die beiden Zahlen auf der orangefarbenen Tafel bedeuten.',
       E'Oben steht die Gefahrnummer (Kemler-Zahl), unten die UN-Nummer des Stoffes. Die Gefahrnummer beschreibt die Hauptgefahr, die UN-Nummer identifiziert den Stoff eindeutig, zum Beispiel über ERI-Cards oder Datenbanken.\n\nEine verdoppelte Ziffer verstärkt die Gefahr. Ein vorangestelltes X heißt: Stoff reagiert gefährlich mit Wasser. Eine 0 an zweiter Stelle hat keine weitere Bedeutung.',
       'warntafel', null),
      (k_taktik, 'GAMS-Regel',
       'Erstmaßnahmen, bis Spezialkräfte vor Ort sind.',
       E'G – Gefahr erkennen\nA – Absperren\nM – Menschenrettung durchführen\nS – Spezialkräfte alarmieren\n\nDie Regel gilt für die ersteintreffenden Kräfte, solange noch keine Messwerte und keine Fachberatung vorliegen.',
       'text', null),
      (k_strahlen, 'Schutz vor äußerer Strahlung',
       'Die drei Grundregeln für den Einsatz.',
       E'Abstand: Die Dosisleistung nimmt mit dem Quadrat der Entfernung ab.\nAufenthaltsdauer: So kurz wie möglich im Gefahrenbereich.\nAbschirmung: Massive Gegenstände zwischen Quelle und Körper nutzen.\n\nDazu kommt: Aufnahme radioaktiver Stoffe in den Körper verhindern.',
       'text', null);
  end if;
end;
$$;


-- ============================================================
--  FERTIG.
--
--  Den ersten Admin festlegen (erst NACHDEM du dich in der App
--  registriert hast). E-Mail-Adresse einsetzen und diese zwei
--  Zeilen allein ausführen:
--
--  update public.profiles set rolle = 'admin', status = 'aktiv'
--  where id = (select id from auth.users where email = 'deine@email.de');
-- ============================================================
