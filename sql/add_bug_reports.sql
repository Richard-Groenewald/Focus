-- In-app bug reports (2026-07-05, Dev first).
-- Filed from the floating red-bug button: user description + severity, plus
-- auto-captured diagnostics (console ring buffer, API trail, version/build,
-- page, user, browser). Reviewed on Admin → Settings → Bug Reports
-- (manage_settings) with a New → Acknowledged → Fixed workflow.
-- Idempotent.

create table if not exists bug_reports (
  id           bigserial primary key,
  created_at   timestamptz not null default now(),
  reporter_id  bigint references people(id),
  severity     text not null default 'Annoying'
               check (severity in ('Low','Annoying','Time Wasting','Blocking')),
  description  text not null,

  -- Auto-captured context
  page         text,          -- app page/route when filed
  record_ref   text,          -- open record, e.g. 'lead #4000' / 'deal #4430'
  app_version  text,          -- FOCUS vX.Y.Z stamp
  build        text,          -- branch·commit build stamp
  environment  text,          -- Production / Development label
  user_agent   text,
  viewport     text,
  online       boolean,
  console_log  jsonb,         -- [{t, level, msg}, …] ring buffer at click time
  api_log      jsonb,         -- [{t, method, table, status, ms}, …]

  -- Triage workflow
  status       text not null default 'New'
               check (status in ('New','Acknowledged','Fixed','Dismissed')),
  admin_notes  text,
  resolved_by  bigint references people(id),
  resolved_at  timestamptz
);

create index if not exists bug_reports_status_idx on bug_reports (status, created_at desc);
