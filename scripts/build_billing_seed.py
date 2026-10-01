"""Turn parse_billing_workbooks.py's JSON into SQL that seeds billing_schedules (Focus v7.9.89).

Each schedule is matched to a Focus contract (a secured deal):
  1. the Pastel customer code equals the deal's organisation account_no → if one secured deal, it;
  2. several → the one whose name/site shares the most words with the schedule and whose monthly
     value is nearest the schedule's total (a tie stays unmatched);
  3. none, and the schedule comes from the Harmony workbook → the Harmony contract;
  4. otherwise unmatched (deal_id NULL) with a note — the Billing Schedules page lets a person pick.
The SQL attributes every row to Claude Code acting for Richard (audit headers) and is re-runnable:
schedules already present (same source file + sheet) are skipped.

Usage: python scripts/build_billing_seed.py <schedules.json> <deals.csv> <claude_person_id> <out.sql>
deals.csv = id,name,org_name,account_no,site_name,month_value (secured deals of the target database).
"""
import csv, json, re, sys

MONTHS = 'jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec'


def q(v):
    if v is None or v == '':
        return 'NULL'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        return repr(round(v, 6)) if isinstance(v, float) else str(v)
    return "'" + str(v).replace("'", "''") + "'"


def words(s):
    return {w for w in re.findall(r'[a-z0-9]+', (s or '').lower()) if len(w) > 2 and w not in
            {'manpower', 'services', 'the', 'and', 'pty', 'ltd', 'october', 'monitoring', 'alarm', 'mon'}}


def name_of(s):
    n = s.get('index_name') or ''
    n = re.sub(r'^INV\d+\s*-\s*', '', n)
    n = re.sub(r"\s*-?\s*October'\s*\d{2,4}\s*-?", ' - ', n)
    n = re.sub(r'\s*-\s*-\s*', ' - ', n).strip(' -')
    return n or s.get('title') or s['sheet']


def main(src, deals_csv, claude_id, out):
    data = json.load(open(src, encoding='utf8'))['schedules']
    deals = []
    for r in csv.reader(open(deals_csv, encoding='utf-8-sig')):
        if len(r) >= 6 and r[0].isdigit():
            deals.append({'id': int(r[0]), 'name': r[1], 'org': r[2], 'acc': r[3], 'site': r[4], 'value': float(r[5] or 0)})
    harmony = [d for d in deals if d['org'].lower().startswith('harmony')]
    sql = ['\\set ON_ERROR_STOP on', 'BEGIN;',
           "SELECT set_config('request.headers', json_build_object('x-actor-id', '%s', 'x-real-actor-id', '1')::text, true);" % int(claude_id)]
    stats = {'account': 0, 'name+amount': 0, 'harmony': 0, 'unmatched': 0}
    for i, s in enumerate(data):
        p = s.get('pastel', {})
        cust = p.get('customer') or s['customer_code']
        total = s['sheet_total'] or 0
        cands = [d for d in deals if d['acc'] and d['acc'] == cust.upper()]
        deal, note = None, None
        if len(cands) == 1:
            deal, note = cands[0], 'Matched by Pastel account ' + cust
            stats['account'] += 1
        elif len(cands) > 1:
            w = words(name_of(s) + ' ' + s.get('title', ''))
            scored = sorted(cands, key=lambda d: (-len(w & words(d['name'] + ' ' + d['site'])), abs(d['value'] - total)))
            a, b = scored[0], scored[1]
            if (len(w & words(a['name'] + ' ' + a['site'])), abs(a['value'] - total)) != (len(w & words(b['name'] + ' ' + b['site'])), abs(b['value'] - total)):
                deal, note = a, 'Matched by account %s, then name and amount among %d contracts — please confirm' % (cust, len(cands))
                stats['name+amount'] += 1
            else:
                note = 'Account %s has %d contracts — choose one' % (cust, len(cands))
                stats['unmatched'] += 1
        elif 'Harmony' in s['source_file'] and len(harmony) == 1:
            deal, note = harmony[0], 'Harmony group site — billed under the Harmony contract'
            stats['harmony'] += 1
        else:
            note = 'No contract in Focus carries Pastel account ' + cust
            stats['unmatched'] += 1
        stem = re.sub(r'(%s)\.?\s*\d{2,4}$' % MONTHS, '', p.get('desc', ''), flags=re.I).rstrip()
        date_rule = 'last_of_previous' if p.get('date', '').startswith(('28/', '29/', '30/', '31/')) else 'first_of_month'
        notes = '; '.join(x for x in [s.get('note'), 'Business unit: ' + s['business_unit'] if s.get('business_unit') else ''] if x)
        cols = {
            'deal_id': deal['id'] if deal else None, 'match_note': note, 'name': name_of(s), 'title': s['title'],
            'bill_to_name': s['bill_to_name'], 'bill_to_address': s['bill_to_address'], 'client_vat_no': s['client_vat_no'],
            'order_no': s['order_no'] if s['order_no'] not in ('N/A',) else s['order_no'], 'ref_label': s['ref_label'],
            'ref_value': s['ref_value'], 'project_no': s['project_no'], 'client_cost_code': s.get('client_cost_code'),
            'pastel_customer_code': cust, 'pastel_gl_code': p.get('gl'), 'pastel_cost_centre': p.get('cost_centre'),
            'pastel_branch': p.get('branch'), 'pastel_desc_stem': stem, 'date_rule': date_rule,
            'escalation_psira_pct': s.get('psira_pct'), 'escalation_cpi_pct': s.get('cpi_pct'),
            'escalation_month': s.get('escalation_month'), 'notes': notes, 'total_adjust': s['total_adjust'],
            'sort_order': i + 1, 'source_file': s['source_file'], 'source_sheet': s['sheet'],
            'source_invoice_no': s['invoice_no'], 'created_by': int(claude_id),
        }
        sql.append('WITH s AS (INSERT INTO billing_schedules (%s) SELECT %s WHERE NOT EXISTS (SELECT 1 FROM billing_schedules '
                   'WHERE source_file = %s AND source_sheet = %s) RETURNING id)' % (
                       ', '.join(cols), ', '.join(q(v) for v in cols.values()), q(s['source_file']), q(s['sheet'])))
        rows = []
        for n, l in enumerate(s['lines']):
            rows.append('(%d, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)' % (
                n + 1, q(l['kind']), q(l.get('item_no')), q(l.get('qty')), q(l.get('description')), q(l.get('unit_price')),
                q(l.get('amount')), q(bool(l.get('in_total'))), q(l.get('unit_formula')), q(l.get('amount_formula')), 'NULL'))
        sql.append('INSERT INTO billing_schedule_lines (schedule_id, sort_order, kind, item_no, qty, description, unit_price, '
                   'amount, in_total, unit_formula, amount_formula) SELECT s.id, v.* FROM s, (VALUES %s) AS v(sort_order, kind, '
                   'item_no, qty, description, unit_price, amount, in_total, unit_formula, amount_formula, _x);'
                   % ',\n  '.join(rows) if rows else 'SELECT 1 FROM s;')
    sql.append('COMMIT;')
    sql.append('SELECT count(*) AS schedules, count(deal_id) AS matched FROM billing_schedules;')
    # the VALUES list carries one spare NULL column (_x) so v.* lines up; drop it from the select
    text = '\n'.join(sql).replace('SELECT s.id, v.* FROM s,', 'SELECT s.id, v.sort_order, v.kind, v.item_no::int, v.qty::numeric, '
                                  'v.description, v.unit_price::numeric, v.amount::numeric, v.in_total, v.unit_formula, '
                                  'v.amount_formula FROM s,')
    open(out, 'w', encoding='utf8').write(text)
    print('schedules', len(data), stats)


if __name__ == '__main__':
    main(*sys.argv[1:5])
