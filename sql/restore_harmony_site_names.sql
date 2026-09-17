-- Restore the 8 Harmony lead site names wiped 2026-08-24 22:40-22:42 UTC
-- (Client Expansion primary-site default clobbered free-text sites; fixed in
-- code v7.8.81). Old values recovered from audit_log rows 5116-5124.
-- Guarded: only rows still in the wiped state (site_id=20, site_name null)
-- are touched, so any later manual fix survives. Idempotent.
-- Backup of pre-restore state: backups/site_wipe_restore_backup_20260825.csv
begin;
update leads l
set site_id = null, site_name = v.name
from (values
  (4104, 'Harmony Gold - Mponeng'),
  (4106, 'Harmony Gold - Kusalethu'),
  (4107, 'Harmony Gold - Tshepong N&S'),
  (4108, 'Harmony Gold - Joel'),
  (4109, 'Harmony Gold - Target 1'),
  (4110, 'Harmony Gold - Masimong'),
  (4111, 'Harmony Gold - Mine Waste Solutions'),
  (4112, 'Harmony Gold - Kalgold Open Pit')
) as v(id, name)
where l.id = v.id and l.site_id = 20 and l.site_name is null;
commit;

-- Verify: all 9 Harmony leads should show their site names again
-- (4105 Doornkop was never wiped).
select l.id, l.status, l.site_id, l.site_name
from leads l
where l.id in (4104,4105,4106,4107,4108,4109,4110,4111,4112)
order by l.id;
