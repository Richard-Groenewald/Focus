-- Focus v7.9.42 — Proposal Generator, Increment 2: issue, number, version, ledger
-- (2026-09-10). Design: docs/proposal-generator/DESIGN.md (sections 5.1, 6, 7, 9).
-- Run AFTER sql/proposal_generator_inc1.sql. Idempotent. Dev first, then prod.
--
-- Issuing a proposal is one transaction in the database so two users cannot
-- take the same number and a half-issued document cannot exist:
--   api('rpc/issue_proposal', 'POST', { p_document_id, p_actor_id, p_content, p_html })
--     → the issued proposal_documents row (numbered P-<year>-<nnnn>, frozen
--       content_json + rendered_html, the quote's latest snapshot pinned,
--       earlier issued versions marked superseded, the quote set to 'sent'
--       with valid_until).
--   api('rpc/withdraw_proposal', 'POST', { p_document_id, p_actor_id })
--     → the withdrawn row (number kept, quote back to 'draft' if it was 'sent').
-- Both check the actor's issue_proposal permission (or the Admin role) the way
-- the client's can() does, through user_roles → role_permissions. The client
-- detects an absent function (404 / PGRST202) and keeps the Issue button
-- disabled with a message, so this file and the deploy ship independently.

BEGIN;

-- ── 1. Permission check shared by both functions ───────────────────────
CREATE OR REPLACE FUNCTION public.person_has_permission(p_person_id bigint, p_permission text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.system_users su
    JOIN public.user_roles ur ON ur.user_id = su.id
    JOIN public.roles r        ON r.id = ur.role_id
    LEFT JOIN public.role_permissions rp ON rp.role_id = r.id
    LEFT JOIN public.permissions p       ON p.id = rp.permission_id
    WHERE su.person_id = p_person_id
      AND (r.name = 'Admin' OR p.name = p_permission)
  );
$$;

-- ── 2. issue_proposal ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.issue_proposal(
  p_document_id bigint, p_actor_id bigint, p_content jsonb, p_html text)
RETURNS SETOF public.proposal_documents
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  d           public.proposal_documents%ROWTYPE;
  q           public.quote_quotes%ROWTYPE;
  v_snapshot  bigint;
  v_ref       text;
  v_valid     date;
  v_days      int;
BEGIN
  IF NOT public.person_has_permission(p_actor_id, 'issue_proposal') THEN
    RAISE EXCEPTION 'You do not have permission to issue proposals';
  END IF;

  SELECT * INTO d FROM public.proposal_documents WHERE id = p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proposal document % not found', p_document_id; END IF;
  IF d.status <> 'draft' THEN RAISE EXCEPTION 'Only a draft can be issued (this one is %)', d.status; END IF;

  SELECT * INTO q FROM public.quote_quotes WHERE id = d.quote_id FOR UPDATE;
  IF q.is_sandbox THEN RAISE EXCEPTION 'Sandbox quotes cannot be issued'; END IF;

  -- The figures on the page must come from a calculation snapshot.
  SELECT id INTO v_snapshot FROM public.quote_snapshots
   WHERE quote_id = q.id ORDER BY snapshot_at DESC LIMIT 1;
  IF v_snapshot IS NULL THEN
    RAISE EXCEPTION 'Calculate the quote first — a proposal cannot be issued without a pricing snapshot';
  END IF;

  SELECT COALESCE(NULLIF(value, '')::int, 30) INTO v_days
    FROM public.settings WHERE key = 'proposal_default_validity_days';
  v_valid := COALESCE(q.valid_until, CURRENT_DATE + COALESCE(v_days, 30));

  v_ref := 'P-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.proposal_ref_seq')::text, 4, '0');

  UPDATE public.proposal_documents
     SET status = 'superseded', updated_at = now()
   WHERE quote_id = d.quote_id AND status = 'issued';

  UPDATE public.proposal_documents
     SET status = 'issued', proposal_ref = v_ref, issued_at = now(), issued_by = p_actor_id,
         valid_until = v_valid, snapshot_id = v_snapshot,
         content_json = COALESCE(p_content, '{}'::jsonb), rendered_html = p_html,
         updated_at = now()
   WHERE id = d.id;

  UPDATE public.quote_quotes
     SET status = 'sent', valid_until = v_valid, updated_at = now()
   WHERE id = q.id;

  RETURN QUERY SELECT * FROM public.proposal_documents WHERE id = d.id;
END;
$$;

-- ── 3. withdraw_proposal ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.withdraw_proposal(p_document_id bigint, p_actor_id bigint)
RETURNS SETOF public.proposal_documents
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  d public.proposal_documents%ROWTYPE;
BEGIN
  IF NOT public.person_has_permission(p_actor_id, 'issue_proposal') THEN
    RAISE EXCEPTION 'You do not have permission to withdraw proposals';
  END IF;
  SELECT * INTO d FROM public.proposal_documents WHERE id = p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proposal document % not found', p_document_id; END IF;
  IF d.status <> 'issued' THEN RAISE EXCEPTION 'Only the current issued version can be withdrawn'; END IF;

  UPDATE public.proposal_documents SET status = 'withdrawn', updated_at = now() WHERE id = d.id;
  UPDATE public.quote_quotes SET status = 'draft', updated_at = now()
   WHERE id = d.quote_id AND status = 'sent';

  RETURN QUERY SELECT * FROM public.proposal_documents WHERE id = d.id;
END;
$$;

-- ── 4. Permission grant: managers issue; sales management decides the rest
--       through Admin → Roles (open decision 1 in the design brief).
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM public.roles r CROSS JOIN public.permissions p
WHERE p.name = 'issue_proposal' AND r.name IN ('Admin', 'Manager')
  AND NOT EXISTS (SELECT 1 FROM public.role_permissions rp WHERE rp.role_id = r.id AND rp.permission_id = p.id);

COMMIT;

-- Verification:
-- SELECT proname FROM pg_proc WHERE proname IN ('issue_proposal','withdraw_proposal','person_has_permission');
-- SELECT r.name FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.id = rp.permission_id WHERE p.name = 'issue_proposal';
