-- Audit the service taxonomy (v7.8.53).
-- Run on BOTH databases.
--
-- WHY. service_major and service_sub were never audited, unlike the seventeen
-- tables covered by sql/add_audit_log.sql. That gap showed itself on 19 Aug 2026:
-- the taxonomy changed mid-investigation (two sub-types moved from Manpower to
-- Control Room), and there was no way to see who had done it or when — the
-- question could only be settled by asking. These two tables drive every margin,
-- every recurring-vs-project decision and therefore every revenue figure in
-- Focus; they are exactly the kind of lookup that should carry a trail.
--
-- Trigger function ships with sql/add_audit_log.sql.

CREATE TRIGGER audit_service_major
  AFTER INSERT OR UPDATE OR DELETE ON service_major
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

CREATE TRIGGER audit_service_sub
  AFTER INSERT OR UPDATE OR DELETE ON service_sub
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

-- ── Verify ───────────────────────────────────────────────────────────────────
-- SELECT c.relname, t.tgname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
--  WHERE NOT t.tgisinternal AND c.relname IN ('service_major','service_sub');
