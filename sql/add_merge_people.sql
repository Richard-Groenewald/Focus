-- Focus v7.10.58 — Merge People (2026-11-22, Richard: "i have two Deidre tyson's. how did this
-- happen. how to prevent it from happening again" -> "go, merge gawie too").
--
-- One person, one record. When the same human is on file twice, fold the duplicate into the
-- record that should survive, in ONE transaction:
--   api('rpc/merge_people', 'POST', { p_keep_id, p_dup_id, p_actor_id, p_fields, p_dry_run })
--     -> { dry_run, keep: <people row afterwards>, dup: <people row before>,
--          moved:   { "<table>.<column>": n, ... },    rows now pointing at the kept person
--          removed: { "<table>.<column>": n, ... } }   rows the kept person already held
--
-- Rules
--   * Every single-column foreign key onto people(id) is found in the catalogue at run time, so a
--     table added after this file is covered without touching it.
--   * Where a table allows one row per person (an affiliation per organisation, a home-organisation
--     membership, a place on an engagement, a deal team, a project team, a campaign, presence, the
--     dashboard layout), the KEPT person's row stands and the duplicate's is removed. For an
--     affiliation both hold at the same organisation the kept row first takes what it lacks (job
--     title, start date, the primary tick, an open end date).
--     A contact entry both hold on the same deal is likewise kept once.
--   * Two sign-ins cannot be merged: the call is refused while both records have a login. A login
--     only the duplicate has moves to the kept person.
--   * References that carry no foreign key move too: audit_log.actor_id, forecast_snapshot_lines
--     .owner_id, a salesperson's targets (scope_type person), the settings that hold people ids
--     (delivery_owner_default_<family>, legacy_notes_viewers).
--   * The kept person's own details stand; blanks are filled from the duplicate; p_fields
--     ({ first_name | last_name | title | email | phone | initials: value }) then sets the values
--     the administrator chose on the screen.
--   * Not a touch, not a change of substance: the merge marks itself a system write (the Last Touch
--     triggers skip it), passes the timesheet lock as an internal write, and puts deals.updated_at
--     back as it was so a confirmed contract does not read "changed since".
--   * p_dry_run true does all of the above inside a sub-transaction, rolls it back and returns the
--     same summary — the preview is the merge itself, not a second copy of its rules.
--
-- The actor must hold manage_settings (or the Admin role / the "all" permission), as the Settings
-- page does. Audit rows are written by the ordinary triggers under the request's actor.
--
-- Additive and re-runnable; SQL-editor safe. The client detects an absent function (404 /
-- PGRST202) and says so on the Merge People card, so this file and the deploy ship independently.

BEGIN;

CREATE OR REPLACE FUNCTION public.merge_people(
  p_keep_id  bigint,
  p_dup_id   bigint,
  p_actor_id bigint,
  p_fields   jsonb   DEFAULT NULL,
  p_dry_run  boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  k         public.people%ROWTYPE;
  d         public.people%ROWTYPE;
  r         record;
  rid       tid;
  n         bigint;
  m         bigint;
  x         bigint;
  v_key     text;
  v_moved   jsonb := '{}'::jsonb;
  v_removed jsonb := '{}'::jsonb;
  v_stamps  jsonb := '{}'::jsonb;
  v_part    jsonb;
  v_result  jsonb;
  v_sys     text := coalesce(current_setting('focus.system', true), '');
  v_ts      text := coalesce(current_setting('focus.ts_internal', true), '');
  f         text;
  v_val     text;
BEGIN
  IF p_keep_id IS NULL OR p_dup_id IS NULL OR p_keep_id = p_dup_id THEN
    RAISE EXCEPTION 'Pick two different people';
  END IF;
  IF NOT (public.person_has_permission(p_actor_id, 'manage_settings')
          OR public.person_has_permission(p_actor_id, 'all')) THEN
    RAISE EXCEPTION 'You do not have permission to merge people';
  END IF;

  PERFORM 1 FROM public.people WHERE id IN (p_keep_id, p_dup_id) ORDER BY id FOR UPDATE;
  SELECT * INTO k FROM public.people WHERE id = p_keep_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'The person to keep was not found — reload and try again'; END IF;
  SELECT * INTO d FROM public.people WHERE id = p_dup_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'The duplicate was not found — reload and try again'; END IF;

  IF EXISTS (SELECT 1 FROM public.system_users WHERE person_id = p_keep_id)
     AND EXISTS (SELECT 1 FROM public.system_users WHERE person_id = p_dup_id) THEN
    RAISE EXCEPTION 'Both records have a login. Remove one of the two under System Users first, then merge.';
  END IF;

  IF p_fields IS NOT NULL THEN
    IF jsonb_typeof(p_fields) <> 'object' THEN RAISE EXCEPTION 'p_fields must be an object'; END IF;
    FOR f IN SELECT jsonb_object_keys(p_fields) LOOP
      IF f NOT IN ('first_name', 'last_name', 'title', 'email', 'phone', 'initials') THEN
        RAISE EXCEPTION 'A merge cannot set the field %', f;
      END IF;
    END LOOP;
  END IF;

  BEGIN
    PERFORM set_config('focus.system', 'merge-people', true);
    PERFORM set_config('focus.ts_internal', '1', true);

    -- 1. An affiliation both hold at the same organisation: the kept row takes what it lacks.
    SELECT count(*) INTO n
      FROM public.person_organisation_roles dr
      JOIN public.person_organisation_roles kr ON kr.org_id = dr.org_id AND kr.person_id = p_keep_id
     WHERE dr.person_id = p_dup_id;
    IF n > 0 THEN
      UPDATE public.person_organisation_roles kr
         SET job_title  = coalesce(nullif(btrim(kr.job_title), ''), dr.job_title),
             start_date = coalesce(kr.start_date, dr.start_date),
             is_primary = (kr.is_primary IS TRUE OR dr.is_primary IS TRUE),
             end_date   = CASE WHEN kr.end_date IS NULL OR dr.end_date IS NULL THEN NULL
                               ELSE greatest(kr.end_date, dr.end_date) END
        FROM public.person_organisation_roles dr
       WHERE kr.person_id = p_keep_id AND dr.person_id = p_dup_id AND dr.org_id = kr.org_id;
      DELETE FROM public.person_organisation_roles dr
       WHERE dr.person_id = p_dup_id
         AND EXISTS (SELECT 1 FROM public.person_organisation_roles kr
                      WHERE kr.person_id = p_keep_id AND kr.org_id = dr.org_id);
      v_removed := v_removed || jsonb_build_object('person_organisation_roles.person_id', n);
    END IF;

    -- 1b. A contact entry both hold on the same deal (or lead): no constraint forbids two, so the
    --     generic pass below would leave the survivor listed twice.
    IF to_regclass('public.deal_contacts') IS NOT NULL THEN
      EXECUTE 'DELETE FROM public.deal_contacts dc
                WHERE dc.person_id = $2
                  AND EXISTS (SELECT 1 FROM public.deal_contacts kc
                               WHERE kc.person_id = $1
                                 AND kc.deal_id IS NOT DISTINCT FROM dc.deal_id
                                 AND kc.lead_id IS NOT DISTINCT FROM dc.lead_id)'
        USING p_keep_id, p_dup_id;
      GET DIAGNOSTICS n = ROW_COUNT;
      IF n > 0 THEN v_removed := v_removed || jsonb_build_object('deal_contacts.person_id', n); END IF;
    END IF;

    -- 2. Every foreign key onto people(id), as the catalogue lists them today.
    FOR r IN
      SELECT c.conrelid::regclass AS tbl, c.conrelid AS reloid, a.attname AS col
        FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
       WHERE c.contype = 'f'
         AND c.confrelid = 'public.people'::regclass
         AND c.connamespace = 'public'::regnamespace
         AND array_length(c.conkey, 1) = 1
       GROUP BY c.conrelid, a.attname
       ORDER BY c.conrelid::regclass::text, a.attname
    LOOP
      EXECUTE format('SELECT count(*) FROM %s WHERE %I = $1', r.tbl, r.col) INTO n USING p_dup_id;
      CONTINUE WHEN n = 0;
      v_key := r.tbl::text || '.' || r.col;

      -- deals: remember updated_at so the stamp can be put back (see 4).
      IF r.reloid = 'public.deals'::regclass THEN
        EXECUTE format('SELECT coalesce(jsonb_object_agg(id::text, updated_at), ''{}''::jsonb) FROM public.deals WHERE %I = $1', r.col)
           INTO v_part USING p_dup_id;
        v_stamps := v_part || v_stamps;      -- the first stamp seen for a deal wins
      END IF;

      BEGIN
        EXECUTE format('UPDATE %s SET %I = $1 WHERE %I = $2', r.tbl, r.col, r.col) USING p_keep_id, p_dup_id;
        v_moved := v_moved || jsonb_build_object(v_key, n);
      EXCEPTION WHEN unique_violation THEN
        -- One row per person here and the kept person already holds some: row by row, the
        -- kept person's row stands and the duplicate's goes.
        m := 0; x := 0;
        FOR rid IN EXECUTE format('SELECT ctid FROM %s WHERE %I = $1', r.tbl, r.col) USING p_dup_id LOOP
          BEGIN
            EXECUTE format('UPDATE %s SET %I = $1 WHERE ctid = $2', r.tbl, r.col) USING p_keep_id, rid;
            m := m + 1;
          EXCEPTION WHEN unique_violation THEN
            EXECUTE format('DELETE FROM %s WHERE ctid = $1', r.tbl) USING rid;
            x := x + 1;
          END;
        END LOOP;
        IF m > 0 THEN v_moved := v_moved || jsonb_build_object(v_key, m); END IF;
        IF x > 0 THEN v_removed := v_removed || jsonb_build_object(v_key, coalesce((v_removed ->> v_key)::bigint, 0) + x); END IF;
      END;
    END LOOP;

    -- 3. References that carry no foreign key.
    UPDATE public.audit_log SET actor_id = p_keep_id WHERE actor_id = p_dup_id;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN v_moved := v_moved || jsonb_build_object('audit_log.actor_id', n); END IF;

    IF to_regclass('public.forecast_snapshot_lines') IS NOT NULL THEN
      EXECUTE 'UPDATE public.forecast_snapshot_lines SET owner_id = $1 WHERE owner_id = $2' USING p_keep_id, p_dup_id;
      GET DIAGNOSTICS n = ROW_COUNT;
      IF n > 0 THEN v_moved := v_moved || jsonb_build_object('forecast_snapshot_lines.owner_id', n); END IF;
    END IF;

    IF to_regclass('public.targets') IS NOT NULL THEN
      m := 0; x := 0;
      FOR rid IN EXECUTE 'SELECT ctid FROM public.targets WHERE scope_type = ''person'' AND scope_id = $1' USING p_dup_id LOOP
        BEGIN
          EXECUTE 'UPDATE public.targets SET scope_id = $1 WHERE ctid = $2' USING p_keep_id, rid;
          m := m + 1;
        EXCEPTION WHEN unique_violation THEN      -- the kept person has a target for that period already
          EXECUTE 'DELETE FROM public.targets WHERE ctid = $1' USING rid;
          x := x + 1;
        END;
      END LOOP;
      IF m > 0 THEN v_moved := v_moved || jsonb_build_object('targets.scope_id', m); END IF;
      IF x > 0 THEN v_removed := v_removed || jsonb_build_object('targets.scope_id', x); END IF;
    END IF;

    UPDATE public.settings SET value = p_keep_id::text
     WHERE key LIKE 'delivery\_owner\_default\_%' AND btrim(value) = p_dup_id::text;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN v_moved := v_moved || jsonb_build_object('settings.delivery_owner_default', n); END IF;

    UPDATE public.settings s
       SET value = (SELECT coalesce(string_agg(z.t, ',' ORDER BY z.ord), '')
                      FROM (SELECT q.t, min(q.ord) AS ord
                              FROM (SELECT CASE WHEN btrim(u.e) = p_dup_id::text THEN p_keep_id::text ELSE btrim(u.e) END AS t, u.ord
                                      FROM unnest(string_to_array(s.value, ',')) WITH ORDINALITY AS u(e, ord)) q
                             WHERE q.t <> ''
                             GROUP BY q.t) z)
     WHERE s.key = 'legacy_notes_viewers'
       AND p_dup_id::text = ANY (string_to_array(replace(coalesce(s.value, ''), ' ', ''), ','));
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN v_moved := v_moved || jsonb_build_object('settings.legacy_notes_viewers', n); END IF;

    -- 4. deals.updated_at back as it was: the same human under one id is not a change to the
    --    contract (the stamp trigger leaves an update of updated_at alone).
    IF v_stamps <> '{}'::jsonb THEN
      UPDATE public.deals dl
         SET updated_at = (v_stamps ->> dl.id::text)::timestamptz
       WHERE v_stamps ? dl.id::text;
    END IF;

    -- 5. The kept person's own details: theirs stand, blanks from the duplicate, then the
    --    values chosen on the screen.
    UPDATE public.people p
       SET last_name = coalesce(nullif(btrim(p.last_name), ''), d.last_name),
           title     = coalesce(nullif(btrim(p.title), ''),     d.title),
           email     = coalesce(nullif(btrim(p.email), ''),     d.email),
           phone     = coalesce(nullif(btrim(p.phone), ''),     d.phone),
           initials  = coalesce(nullif(btrim(p.initials), ''),  d.initials)
     WHERE p.id = p_keep_id;
    IF p_fields IS NOT NULL THEN
      FOR f, v_val IN SELECT e.key, nullif(btrim(e.value), '') FROM jsonb_each_text(p_fields) e LOOP
        IF f = 'first_name' AND v_val IS NULL THEN RAISE EXCEPTION 'First name cannot be blank'; END IF;
        EXECUTE format('UPDATE public.people SET %I = $1 WHERE id = $2', f) USING v_val, p_keep_id;
      END LOOP;
    END IF;

    -- 6. The duplicate goes. Anything still pointing at it stops the whole merge here.
    DELETE FROM public.people WHERE id = p_dup_id;

    SELECT to_jsonb(p) INTO v_part FROM public.people p WHERE p.id = p_keep_id;
    v_result := jsonb_build_object('dry_run', coalesce(p_dry_run, false), 'keep', v_part,
                                   'dup', to_jsonb(d), 'moved', v_moved, 'removed', v_removed);

    PERFORM set_config('focus.system', v_sys, true);
    PERFORM set_config('focus.ts_internal', v_ts, true);

    IF p_dry_run THEN
      RAISE EXCEPTION USING ERRCODE = 'FCS01', MESSAGE = 'merge_people preview';
    END IF;
  EXCEPTION WHEN SQLSTATE 'FCS01' THEN
    NULL;      -- the preview: everything above is rolled back, the summary is kept
  END;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.merge_people(bigint, bigint, bigint, jsonb, boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merge_people(bigint, bigint, bigint, jsonb, boolean) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verify:
--   SELECT public.merge_people(<keep>, <duplicate>, <an admin's people id>, NULL, true);   -- preview, changes nothing
