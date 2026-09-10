#!/usr/bin/env python3
"""Dump the tables the equivalence tests need, plus the real output of the new
server-side shapes, from a Supabase project into ./snap (default: the Dev project).

Uses the Supabase Management API (POST /v1/projects/{ref}/database/query) with the
access token in SUPABASE_ACCESS_TOKEN (or a proxy that attaches it). Never commit
the snapshot: it is business data. Usage:
    SUPABASE_ACCESS_TOKEN=... python3 tests/perf/dump_snapshot.py [project-ref] [out-dir]
"""
import json, os, subprocess, sys
ref = sys.argv[1] if len(sys.argv) > 1 else 'rfazsomogitdhkrmsfcy'
out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'snap')
os.makedirs(out, exist_ok=True)
tok = os.environ.get('SUPABASE_ACCESS_TOKEN')
def q(sql):
    args = ['curl', '-sS', '--max-time', '180', '-X', 'POST', f'https://api.supabase.com/v1/projects/{ref}/database/query',
            '-H', 'Content-Type: application/json', '--data-binary', '@-']
    if tok: args += ['-H', 'Authorization: Bearer ' + tok]
    r = subprocess.run(args, input=json.dumps({'query': sql}), capture_output=True, text=True)
    return json.loads(r.stdout)
tables = ['leads', 'deals', 'organisations', 'sites', 'engagements', 'engagement_milestones', 'milestone_groups', 'milestone_types',
          'promotion_requests', 'lead_stage_requests', 'red_flags', 'lead_red_flags', 'research_campaigns', 'bug_reports',
          'revenue_streams', 'revenue_stream_months', 'service_sub', 'stages', 'industry_sectors', 'people', 'settings',
          'engagement_people', 'work_projects']
for t in tables:
    rows = q(f"select coalesce(json_agg(t), '[]'::json) as j from public.{t} t")[0]['j']
    json.dump(rows, open(os.path.join(out, t + '.json'), 'w')); print(f'{t}: {len(rows)} rows')
b = q('select public.dashboard_summary() as j')[0]['j']
json.dump(b, open(os.path.join(out, 'bundle.json'), 'w')); print('bundle keys:', len(b))
v = q("select coalesce(json_agg(v order by v.engagement_date desc, v.id desc), '[]'::json) as j from public.engagements_labelled v")[0]['j']
json.dump(v, open(os.path.join(out, 'engagements_labelled.json'), 'w')); print('engagements_labelled rows:', len(v))
