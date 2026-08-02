-- Engagement Milestones (v7.8.39). Run on BOTH databases, prod first.
--
-- A milestone tags an engagement as a significant event. Multiple per
-- engagement. Types are grouped; each GROUP is assigned to one or more of the
-- four engagement areas (Outreach / Sales / Contract / Project — the existing
-- category derivation), and an engagement's picker offers only types whose
-- group covers its area. Every designation is 'pending' until sales management
-- reviews it (self-approval collapse for managers); declined rows keep the
-- reason. Design locked with Richard 2026-08-03.

CREATE TABLE milestone_groups (
  id         BIGSERIAL PRIMARY KEY,
  name       TEXT NOT NULL,
  areas      TEXT[] NOT NULL DEFAULT '{}'::text[]
             CHECK (areas <@ ARRAY['Outreach','Sales','Contract','Project']),
  active     BOOLEAN NOT NULL DEFAULT true,
  sort_order INT NOT NULL DEFAULT 0,
  created_by BIGINT REFERENCES people(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE milestone_types (
  id         BIGSERIAL PRIMARY KEY,
  group_id   BIGINT NOT NULL REFERENCES milestone_groups(id),
  name       TEXT NOT NULL,
  active     BOOLEAN NOT NULL DEFAULT true,
  sort_order INT NOT NULL DEFAULT 0,
  created_by BIGINT REFERENCES people(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE engagement_milestones (
  id                BIGSERIAL PRIMARY KEY,
  engagement_id     BIGINT NOT NULL REFERENCES engagements(id) ON DELETE CASCADE,
  milestone_type_id BIGINT NOT NULL REFERENCES milestone_types(id),
  status            TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','approved','declined')),
  proposed_by       BIGINT REFERENCES people(id),
  proposed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_by        BIGINT REFERENCES people(id),
  decided_at        TIMESTAMPTZ,
  decline_reason    TEXT,
  -- One row per engagement+type: a re-proposal after decline RESETS the
  -- declined row back to pending (app behaviour) rather than adding a second.
  UNIQUE (engagement_id, milestone_type_id)
);
CREATE INDEX idx_eng_milestones_eng     ON engagement_milestones(engagement_id);
CREATE INDEX idx_eng_milestones_pending ON engagement_milestones(status) WHERE status = 'pending';

-- Audit everything: milestone definitions are admin lookups, designations are
-- reviewed decisions. Trigger function ships with sql/add_audit_log.sql.
CREATE TRIGGER audit_milestone_groups
  AFTER INSERT OR UPDATE OR DELETE ON milestone_groups
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();
CREATE TRIGGER audit_milestone_types
  AFTER INSERT OR UPDATE OR DELETE ON milestone_types
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();
CREATE TRIGGER audit_engagement_milestones
  AFTER INSERT OR UPDATE OR DELETE ON engagement_milestones
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

-- Verify:
--   select * from milestone_groups; select * from milestone_types;
--   select * from engagement_milestones;
