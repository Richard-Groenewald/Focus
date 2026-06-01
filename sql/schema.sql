--
-- PostgreSQL database dump
--

\restrict VO7aH9vre3guRzweQeziduCwfwKVuBNc6LWcwkVxMfugBCAwBseVfca0lUb5QBs

-- Dumped from database version 17.6
-- Dumped by pg_dump version 18.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: refresh_lead_next_action(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_lead_next_action(p_lead_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_next_action      TEXT;
  v_next_action_date DATE;
BEGIN
  IF p_lead_id IS NULL THEN
    RETURN;
  END IF;

  SELECT next_action, next_action_date
    INTO v_next_action, v_next_action_date
  FROM lead_interactions
  WHERE lead_id          = p_lead_id
    AND next_action_done = false
    AND next_action      IS NOT NULL
    AND next_action_date IS NOT NULL
  ORDER BY next_action_date ASC, id DESC
  LIMIT 1;

  UPDATE leads
     SET next_action      = v_next_action,
         next_action_date = v_next_action_date,
         updated_at       = now()
   WHERE id = p_lead_id;
END;
$$;


--
-- Name: refresh_lead_status(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_lead_status(p_lead_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_status      TEXT;
  v_lead        leads%ROWTYPE;
  v_has_int     BOOLEAN;
  v_has_redflag BOOLEAN;
BEGIN
  IF p_lead_id IS NULL THEN RETURN; END IF;
  SELECT * INTO v_lead FROM leads WHERE id = p_lead_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT EXISTS (SELECT 1 FROM lead_interactions WHERE lead_id = p_lead_id) INTO v_has_int;
  SELECT EXISTS (SELECT 1 FROM lead_red_flags    WHERE lead_id = p_lead_id) INTO v_has_redflag;

  IF v_lead.promoted_at IS NOT NULL THEN
    v_status := 'Promoted';
  ELSIF v_has_redflag OR v_lead.dead_reason IS NOT NULL THEN
    v_status := 'Dead';
  ELSIF v_lead.wake_date IS NOT NULL THEN
    v_status := 'Dormant';
  ELSIF COALESCE(v_lead.fit,0) = 2
    AND COALESCE(v_lead.trigger_score,0) = 2
    AND COALESCE(v_lead.access,0) = 2
    AND COALESCE(v_lead.capacity,0) = 2 THEN
    v_status := 'Qualified';
  ELSIF v_has_int THEN
    v_status := 'Working';
  ELSE
    v_status := 'New';
  END IF;

  IF v_lead.status IS DISTINCT FROM v_status THEN
    UPDATE leads SET status = v_status, updated_at = now() WHERE id = p_lead_id;
  END IF;
END;
$$;


--
-- Name: sync_home_member_to_affiliation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_home_member_to_affiliation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO person_organisation_roles (person_id, org_id, role_type, is_primary)
  VALUES (NEW.person_id, NEW.org_id, 'Staff', FALSE)
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;


--
-- Name: trg_lead_interactions_refresh_next_action(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_lead_interactions_refresh_next_action() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM refresh_lead_next_action(OLD.lead_id);
    RETURN OLD;
  END IF;

  PERFORM refresh_lead_next_action(NEW.lead_id);

  -- If a row was re-parented to a different lead, refresh the old one too
  IF TG_OP = 'UPDATE' AND OLD.lead_id IS DISTINCT FROM NEW.lead_id THEN
    PERFORM refresh_lead_next_action(OLD.lead_id);
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: trg_lead_interactions_refresh_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_lead_interactions_refresh_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM refresh_lead_status(OLD.lead_id);
    RETURN OLD;
  END IF;
  PERFORM refresh_lead_status(NEW.lead_id);
  IF TG_OP = 'UPDATE' AND OLD.lead_id IS DISTINCT FROM NEW.lead_id THEN
    PERFORM refresh_lead_status(OLD.lead_id);
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: trg_lead_red_flags_refresh_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_lead_red_flags_refresh_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM refresh_lead_status(OLD.lead_id);
    RETURN OLD;
  END IF;
  PERFORM refresh_lead_status(NEW.lead_id);
  IF TG_OP = 'UPDATE' AND OLD.lead_id IS DISTINCT FROM NEW.lead_id THEN
    PERFORM refresh_lead_status(OLD.lead_id);
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: trg_leads_refresh_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_leads_refresh_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.fit            IS DISTINCT FROM OLD.fit
   OR NEW.trigger_score  IS DISTINCT FROM OLD.trigger_score
   OR NEW.access         IS DISTINCT FROM OLD.access
   OR NEW.capacity       IS DISTINCT FROM OLD.capacity
   OR NEW.dead_reason    IS DISTINCT FROM OLD.dead_reason
   OR NEW.wake_date      IS DISTINCT FROM OLD.wake_date
   OR NEW.promoted_at    IS DISTINCT FROM OLD.promoted_at
  THEN
    PERFORM refresh_lead_status(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: trg_orgs_link_freetext_leads(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_orgs_link_freetext_leads() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE leads
  SET target_org_id   = NEW.id,
      target_org_name = NULL,
      updated_at      = now()
  WHERE target_org_id IS NULL
    AND target_org_name IS NOT NULL
    AND (
      lower(trim(target_org_name)) = lower(trim(NEW.name))
      OR (
        NEW.legal_name IS NOT NULL
        AND lower(trim(target_org_name)) = lower(trim(NEW.legal_name))
      )
    );
  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: activity_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_types (
    id bigint NOT NULL,
    name text NOT NULL,
    description text,
    applies_to_opportunities boolean DEFAULT true NOT NULL,
    applies_to_leads boolean DEFAULT true NOT NULL,
    active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: activity_types_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.activity_types_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_types_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.activity_types_id_seq OWNED BY public.activity_types.id;


--
-- Name: deal_collaborators; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deal_collaborators (
    id bigint NOT NULL,
    deal_id bigint NOT NULL,
    person_id bigint NOT NULL,
    role text DEFAULT 'Collaborator'::text,
    is_owner boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: deal_collaborators_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.deal_collaborators_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: deal_collaborators_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.deal_collaborators_id_seq OWNED BY public.deal_collaborators.id;


--
-- Name: deals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deals (
    id bigint NOT NULL,
    name text NOT NULL,
    org_id bigint,
    region_id bigint,
    stage_id bigint,
    service_major_id bigint,
    service_sub_id bigint,
    margin_pct numeric(5,2) DEFAULT 25.00,
    probability integer DEFAULT 50,
    order_date date,
    start_date date,
    lost_date date,
    lost_to text,
    lost_reason text,
    lost_notes text,
    owner_id bigint,
    created_by bigint,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    notes text,
    ext_notes text,
    CONSTRAINT deals_probability_check CHECK (((probability >= 0) AND (probability <= 100)))
);


--
-- Name: deals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.deals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: deals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.deals_id_seq OWNED BY public.deals.id;


--
-- Name: dmu_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dmu_roles (
    id bigint NOT NULL,
    name text NOT NULL,
    description text,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: dmu_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.dmu_roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: dmu_roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.dmu_roles_id_seq OWNED BY public.dmu_roles.id;


--
-- Name: engagement_people; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.engagement_people (
    id bigint NOT NULL,
    engagement_id bigint NOT NULL,
    person_id bigint NOT NULL
);


--
-- Name: engagement_people_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.engagement_people_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: engagement_people_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.engagement_people_id_seq OWNED BY public.engagement_people.id;


--
-- Name: engagements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.engagements (
    id bigint NOT NULL,
    deal_id bigint NOT NULL,
    engagement_date date NOT NULL,
    engagement_type text,
    notes text,
    next_action text,
    next_action_date date,
    created_at timestamp with time zone DEFAULT now(),
    created_by bigint,
    next_action_done boolean DEFAULT false NOT NULL,
    next_action_completion_note text,
    next_action_completed_at timestamp with time zone,
    next_action_id bigint,
    action_details text,
    activity_type_id bigint
);


--
-- Name: engagements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.engagements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: engagements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.engagements_id_seq OWNED BY public.engagements.id;


--
-- Name: home_organisation_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.home_organisation_members (
    id bigint NOT NULL,
    person_id bigint NOT NULL,
    org_id bigint NOT NULL,
    role_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: home_organisation_members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.home_organisation_members_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: home_organisation_members_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.home_organisation_members_id_seq OWNED BY public.home_organisation_members.id;


--
-- Name: industry_sectors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.industry_sectors (
    id bigint NOT NULL,
    name text NOT NULL,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: industry_sectors_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.industry_sectors_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: industry_sectors_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.industry_sectors_id_seq OWNED BY public.industry_sectors.id;


--
-- Name: lead_interactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lead_interactions (
    id bigint NOT NULL,
    lead_id bigint NOT NULL,
    engagement_date date NOT NULL,
    engagement_type text NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    next_action_done boolean DEFAULT false NOT NULL,
    next_action_id bigint,
    next_action text,
    next_action_date date,
    next_action_completed_at timestamp with time zone,
    next_action_completion_note text,
    action_details text,
    activity_type_id bigint
);


--
-- Name: lead_interactions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.lead_interactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: lead_interactions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.lead_interactions_id_seq OWNED BY public.lead_interactions.id;


--
-- Name: lead_red_flags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lead_red_flags (
    lead_id bigint NOT NULL,
    red_flag_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: lead_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lead_sources (
    id bigint NOT NULL,
    name text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: lead_sources_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.lead_sources_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: lead_sources_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.lead_sources_id_seq OWNED BY public.lead_sources.id;


--
-- Name: lead_strategic_decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lead_strategic_decisions (
    lead_id bigint NOT NULL,
    strategic_decision_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: leads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.leads (
    id bigint NOT NULL,
    source_id bigint NOT NULL,
    source_person_id bigint,
    source_org_id bigint,
    source_detail text,
    research_campaign_id bigint,
    target_org_id bigint,
    target_org_name text,
    target_person_id bigint,
    target_person_name text,
    description text NOT NULL,
    region_id bigint,
    service_major_id bigint,
    est_value numeric,
    fit smallint DEFAULT 0 NOT NULL,
    trigger_score smallint DEFAULT 0 NOT NULL,
    access smallint DEFAULT 0 NOT NULL,
    capacity smallint DEFAULT 0 NOT NULL,
    status text DEFAULT 'New'::text NOT NULL,
    dead_reason text,
    owner_id bigint,
    next_action text,
    next_action_date date,
    last_touch_date date,
    promoted_deal_id bigint,
    promoted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    wake_date date,
    dead_notes text,
    service_sub_id bigint,
    promotion_requested_at timestamp with time zone,
    promotion_requested_by bigint,
    CONSTRAINT leads_access_check CHECK (((access >= 0) AND (access <= 2))),
    CONSTRAINT leads_capacity_check CHECK (((capacity >= 0) AND (capacity <= 2))),
    CONSTRAINT leads_dead_reason_valid CHECK (((dead_reason IS NULL) OR (dead_reason = ANY (ARRAY['not_qualified'::text, 'declined'::text])))),
    CONSTRAINT leads_fit_check CHECK (((fit >= 0) AND (fit <= 2))),
    CONSTRAINT leads_status_check CHECK ((status = ANY (ARRAY['New'::text, 'Working'::text, 'Qualified'::text, 'Promoted'::text, 'Dormant'::text, 'Dead'::text]))),
    CONSTRAINT leads_trigger_score_check CHECK (((trigger_score >= 0) AND (trigger_score <= 2)))
);


--
-- Name: leads_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.leads_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: leads_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.leads_id_seq OWNED BY public.leads.id;


--
-- Name: next_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.next_actions (
    id bigint NOT NULL,
    name text NOT NULL,
    description text,
    active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    applies_to_opportunities boolean DEFAULT true NOT NULL,
    applies_to_leads boolean DEFAULT true NOT NULL
);


--
-- Name: next_actions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.next_actions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: next_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.next_actions_id_seq OWNED BY public.next_actions.id;


--
-- Name: opportunity_contacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.opportunity_contacts (
    id bigint NOT NULL,
    deal_id bigint NOT NULL,
    person_id bigint NOT NULL,
    dmu_role_id bigint,
    note text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: opportunity_contacts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.opportunity_contacts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: opportunity_contacts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.opportunity_contacts_id_seq OWNED BY public.opportunity_contacts.id;


--
-- Name: organisations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organisations (
    id bigint NOT NULL,
    name text NOT NULL,
    legal_name text,
    website text,
    address text,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    allows_system_users boolean DEFAULT false,
    active boolean DEFAULT true,
    home_organisation boolean DEFAULT false
);


--
-- Name: organisations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.organisations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: organisations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.organisations_id_seq OWNED BY public.organisations.id;


--
-- Name: parties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parties (
    id bigint NOT NULL,
    party_type text NOT NULL,
    ref_id bigint NOT NULL,
    category text,
    status text DEFAULT 'active'::text,
    created_at timestamp with time zone DEFAULT now(),
    category_id bigint,
    CONSTRAINT parties_party_type_check CHECK ((party_type = ANY (ARRAY['person'::text, 'organisation'::text])))
);


--
-- Name: parties_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.parties_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: parties_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.parties_id_seq OWNED BY public.parties.id;


--
-- Name: party_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.party_categories (
    id bigint NOT NULL,
    name text NOT NULL,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: party_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.party_categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: party_categories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.party_categories_id_seq OWNED BY public.party_categories.id;


--
-- Name: people; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.people (
    id bigint NOT NULL,
    first_name text NOT NULL,
    last_name text,
    title text,
    email text,
    phone text,
    initials text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: people_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.people_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: people_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.people_id_seq OWNED BY public.people.id;


--
-- Name: permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.permissions (
    id bigint NOT NULL,
    name text NOT NULL,
    description text
);


--
-- Name: permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: permissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.permissions_id_seq OWNED BY public.permissions.id;


--
-- Name: person_organisation_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.person_organisation_roles (
    id bigint NOT NULL,
    person_id bigint,
    org_id bigint,
    role_type text NOT NULL,
    is_primary boolean DEFAULT false,
    start_date date,
    end_date date
);


--
-- Name: person_organisation_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.person_organisation_roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: person_organisation_roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.person_organisation_roles_id_seq OWNED BY public.person_organisation_roles.id;


--
-- Name: red_flags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.red_flags (
    id bigint NOT NULL,
    name text NOT NULL,
    description text,
    active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: red_flags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.red_flags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: red_flags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.red_flags_id_seq OWNED BY public.red_flags.id;


--
-- Name: regions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.regions (
    id bigint NOT NULL,
    name text NOT NULL,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: regions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.regions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: regions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.regions_id_seq OWNED BY public.regions.id;


--
-- Name: research_campaigns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.research_campaigns (
    id bigint NOT NULL,
    name text NOT NULL,
    segment text,
    region_id bigint,
    service_major_id bigint,
    status text DEFAULT 'Active'::text NOT NULL,
    notes text,
    owner_id bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint,
    CONSTRAINT research_campaigns_status_check CHECK ((status = ANY (ARRAY['Active'::text, 'Paused'::text, 'Completed'::text, 'Abandoned'::text])))
);


--
-- Name: research_campaigns_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.research_campaigns_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: research_campaigns_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.research_campaigns_id_seq OWNED BY public.research_campaigns.id;


--
-- Name: revenue_stream_months; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.revenue_stream_months (
    id bigint NOT NULL,
    stream_id bigint NOT NULL,
    month text NOT NULL,
    opportunity_revenue numeric(14,2) DEFAULT 0,
    opportunity_margin numeric(14,2) DEFAULT 0,
    fulfilment_revenue numeric(14,2),
    fulfilment_margin numeric(14,2),
    actual_revenue numeric(14,2),
    is_actual_revenue boolean DEFAULT false,
    actual_margin numeric(14,2),
    is_actual_margin boolean DEFAULT false
);


--
-- Name: revenue_stream_months_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.revenue_stream_months_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: revenue_stream_months_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.revenue_stream_months_id_seq OWNED BY public.revenue_stream_months.id;


--
-- Name: revenue_streams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.revenue_streams (
    id bigint NOT NULL,
    deal_id bigint NOT NULL,
    stream_type text NOT NULL,
    locked boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT revenue_streams_stream_type_check CHECK ((stream_type = ANY (ARRAY['opportunity'::text, 'fulfilment'::text])))
);


--
-- Name: revenue_streams_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.revenue_streams_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: revenue_streams_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.revenue_streams_id_seq OWNED BY public.revenue_streams.id;


--
-- Name: role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_permissions (
    role_id bigint NOT NULL,
    permission_id bigint NOT NULL
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    id bigint NOT NULL,
    name text NOT NULL,
    description text,
    is_system boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.roles_id_seq OWNED BY public.roles.id;


--
-- Name: service_major; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_major (
    id bigint NOT NULL,
    name text NOT NULL,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: service_major_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.service_major_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: service_major_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.service_major_id_seq OWNED BY public.service_major.id;


--
-- Name: service_sub; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_sub (
    id bigint NOT NULL,
    major_id bigint,
    name text NOT NULL,
    is_recurring boolean DEFAULT true,
    default_margin numeric(5,2) DEFAULT 25.00,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    min_margin numeric(5,2) DEFAULT 0,
    default_duration integer DEFAULT 12
);


--
-- Name: service_sub_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.service_sub_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: service_sub_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.service_sub_id_seq OWNED BY public.service_sub.id;


--
-- Name: settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.settings (
    id bigint NOT NULL,
    key text NOT NULL,
    value text,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.settings_id_seq OWNED BY public.settings.id;


--
-- Name: stage_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stage_categories (
    id bigint NOT NULL,
    name text NOT NULL,
    sort_order integer DEFAULT 0
);


--
-- Name: stage_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stage_categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stage_categories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stage_categories_id_seq OWNED BY public.stage_categories.id;


--
-- Name: stages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stages (
    id bigint NOT NULL,
    category_id bigint,
    name text NOT NULL,
    probability integer DEFAULT 50,
    sort_order integer DEFAULT 0,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    min_probability integer DEFAULT 0,
    max_probability integer DEFAULT 100,
    probability_hint text,
    CONSTRAINT stages_probability_check CHECK (((probability >= 0) AND (probability <= 100)))
);


--
-- Name: stages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stages_id_seq OWNED BY public.stages.id;


--
-- Name: strategic_decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.strategic_decisions (
    id bigint NOT NULL,
    name text NOT NULL,
    description text,
    active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: strategic_decisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.strategic_decisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: strategic_decisions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.strategic_decisions_id_seq OWNED BY public.strategic_decisions.id;


--
-- Name: system_user_regions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_user_regions (
    id bigint NOT NULL,
    system_user_id bigint NOT NULL,
    region_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by bigint
);


--
-- Name: system_user_regions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.system_user_regions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: system_user_regions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.system_user_regions_id_seq OWNED BY public.system_user_regions.id;


--
-- Name: system_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_users (
    id bigint NOT NULL,
    person_id bigint,
    username text NOT NULL,
    password text NOT NULL,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: system_users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.system_users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: system_users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.system_users_id_seq OWNED BY public.system_users.id;


--
-- Name: user_permission_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_permission_overrides (
    id bigint NOT NULL,
    user_id bigint,
    permission_id bigint,
    granted boolean NOT NULL
);


--
-- Name: user_permission_overrides_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_permission_overrides_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_permission_overrides_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_permission_overrides_id_seq OWNED BY public.user_permission_overrides.id;


--
-- Name: user_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_roles (
    user_id bigint NOT NULL,
    role_id bigint NOT NULL
);


--
-- Name: activity_types id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_types ALTER COLUMN id SET DEFAULT nextval('public.activity_types_id_seq'::regclass);


--
-- Name: deal_collaborators id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deal_collaborators ALTER COLUMN id SET DEFAULT nextval('public.deal_collaborators_id_seq'::regclass);


--
-- Name: deals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deals ALTER COLUMN id SET DEFAULT nextval('public.deals_id_seq'::regclass);


--
-- Name: dmu_roles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dmu_roles ALTER COLUMN id SET DEFAULT nextval('public.dmu_roles_id_seq'::regclass);


--
-- Name: engagement_people id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_people ALTER COLUMN id SET DEFAULT nextval('public.engagement_people_id_seq'::regclass);


--
-- Name: engagements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagements ALTER COLUMN id SET DEFAULT nextval('public.engagements_id_seq'::regclass);


--
-- Name: home_organisation_members id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.home_organisation_members ALTER COLUMN id SET DEFAULT nextval('public.home_organisation_members_id_seq'::regclass);


--
-- Name: industry_sectors id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.industry_sectors ALTER COLUMN id SET DEFAULT nextval('public.industry_sectors_id_seq'::regclass);


--
-- Name: lead_interactions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_interactions ALTER COLUMN id SET DEFAULT nextval('public.lead_interactions_id_seq'::regclass);


--
-- Name: lead_sources id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_sources ALTER COLUMN id SET DEFAULT nextval('public.lead_sources_id_seq'::regclass);


--
-- Name: leads id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads ALTER COLUMN id SET DEFAULT nextval('public.leads_id_seq'::regclass);


--
-- Name: next_actions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.next_actions ALTER COLUMN id SET DEFAULT nextval('public.next_actions_id_seq'::regclass);


--
-- Name: opportunity_contacts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_contacts ALTER COLUMN id SET DEFAULT nextval('public.opportunity_contacts_id_seq'::regclass);


--
-- Name: organisations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisations ALTER COLUMN id SET DEFAULT nextval('public.organisations_id_seq'::regclass);


--
-- Name: parties id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parties ALTER COLUMN id SET DEFAULT nextval('public.parties_id_seq'::regclass);


--
-- Name: party_categories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_categories ALTER COLUMN id SET DEFAULT nextval('public.party_categories_id_seq'::regclass);


--
-- Name: people id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.people ALTER COLUMN id SET DEFAULT nextval('public.people_id_seq'::regclass);


--
-- Name: permissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permissions ALTER COLUMN id SET DEFAULT nextval('public.permissions_id_seq'::regclass);


--
-- Name: person_organisation_roles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_organisation_roles ALTER COLUMN id SET DEFAULT nextval('public.person_organisation_roles_id_seq'::regclass);


--
-- Name: red_flags id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.red_flags ALTER COLUMN id SET DEFAULT nextval('public.red_flags_id_seq'::regclass);


--
-- Name: regions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regions ALTER COLUMN id SET DEFAULT nextval('public.regions_id_seq'::regclass);


--
-- Name: research_campaigns id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_campaigns ALTER COLUMN id SET DEFAULT nextval('public.research_campaigns_id_seq'::regclass);


--
-- Name: revenue_stream_months id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.revenue_stream_months ALTER COLUMN id SET DEFAULT nextval('public.revenue_stream_months_id_seq'::regclass);


--
-- Name: revenue_streams id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.revenue_streams ALTER COLUMN id SET DEFAULT nextval('public.revenue_streams_id_seq'::regclass);


--
-- Name: roles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles ALTER COLUMN id SET DEFAULT nextval('public.roles_id_seq'::regclass);


--
-- Name: service_major id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_major ALTER COLUMN id SET DEFAULT nextval('public.service_major_id_seq'::regclass);


--
-- Name: service_sub id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_sub ALTER COLUMN id SET DEFAULT nextval('public.service_sub_id_seq'::regclass);


--
-- Name: settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings ALTER COLUMN id SET DEFAULT nextval('public.settings_id_seq'::regclass);


--
-- Name: stage_categories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_categories ALTER COLUMN id SET DEFAULT nextval('public.stage_categories_id_seq'::regclass);


--
-- Name: stages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stages ALTER COLUMN id SET DEFAULT nextval('public.stages_id_seq'::regclass);


--
-- Name: strategic_decisions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.strategic_decisions ALTER COLUMN id SET DEFAULT nextval('public.strategic_decisions_id_seq'::regclass);


--
-- Name: system_user_regions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_user_regions ALTER COLUMN id SET DEFAULT nextval('public.system_user_regions_id_seq'::regclass);


--
-- Name: system_users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_users ALTER COLUMN id SET DEFAULT nextval('public.system_users_id_seq'::regclass);


--
-- Name: user_permission_overrides id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_permission_overrides ALTER COLUMN id SET DEFAULT nextval('public.user_permission_overrides_id_seq'::regclass);


--
-- Name: activity_types activity_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_types
    ADD CONSTRAINT activity_types_pkey PRIMARY KEY (id);


--
-- Name: deal_collaborators deal_collaborators_deal_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deal_collaborators
    ADD CONSTRAINT deal_collaborators_deal_id_person_id_key UNIQUE (deal_id, person_id);


--
-- Name: deal_collaborators deal_collaborators_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deal_collaborators
    ADD CONSTRAINT deal_collaborators_pkey PRIMARY KEY (id);


--
-- Name: deals deals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deals
    ADD CONSTRAINT deals_pkey PRIMARY KEY (id);


--
-- Name: dmu_roles dmu_roles_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dmu_roles
    ADD CONSTRAINT dmu_roles_name_key UNIQUE (name);


--
-- Name: dmu_roles dmu_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dmu_roles
    ADD CONSTRAINT dmu_roles_pkey PRIMARY KEY (id);


--
-- Name: engagement_people engagement_people_engagement_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_people
    ADD CONSTRAINT engagement_people_engagement_id_person_id_key UNIQUE (engagement_id, person_id);


--
-- Name: engagement_people engagement_people_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_people
    ADD CONSTRAINT engagement_people_pkey PRIMARY KEY (id);


--
-- Name: engagements engagements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagements
    ADD CONSTRAINT engagements_pkey PRIMARY KEY (id);


--
-- Name: home_organisation_members home_organisation_members_person_id_org_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.home_organisation_members
    ADD CONSTRAINT home_organisation_members_person_id_org_id_key UNIQUE (person_id, org_id);


--
-- Name: home_organisation_members home_organisation_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.home_organisation_members
    ADD CONSTRAINT home_organisation_members_pkey PRIMARY KEY (id);


--
-- Name: industry_sectors industry_sectors_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.industry_sectors
    ADD CONSTRAINT industry_sectors_name_key UNIQUE (name);


--
-- Name: industry_sectors industry_sectors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.industry_sectors
    ADD CONSTRAINT industry_sectors_pkey PRIMARY KEY (id);


--
-- Name: lead_interactions lead_interactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_interactions
    ADD CONSTRAINT lead_interactions_pkey PRIMARY KEY (id);


--
-- Name: lead_red_flags lead_red_flags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_red_flags
    ADD CONSTRAINT lead_red_flags_pkey PRIMARY KEY (lead_id, red_flag_id);


--
-- Name: lead_sources lead_sources_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_sources
    ADD CONSTRAINT lead_sources_name_key UNIQUE (name);


--
-- Name: lead_sources lead_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_sources
    ADD CONSTRAINT lead_sources_pkey PRIMARY KEY (id);


--
-- Name: lead_strategic_decisions lead_strategic_decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_strategic_decisions
    ADD CONSTRAINT lead_strategic_decisions_pkey PRIMARY KEY (lead_id, strategic_decision_id);


--
-- Name: leads leads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_pkey PRIMARY KEY (id);


--
-- Name: next_actions next_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.next_actions
    ADD CONSTRAINT next_actions_pkey PRIMARY KEY (id);


--
-- Name: opportunity_contacts opportunity_contacts_deal_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_contacts
    ADD CONSTRAINT opportunity_contacts_deal_id_person_id_key UNIQUE (deal_id, person_id);


--
-- Name: opportunity_contacts opportunity_contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_contacts
    ADD CONSTRAINT opportunity_contacts_pkey PRIMARY KEY (id);


--
-- Name: organisations organisations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisations
    ADD CONSTRAINT organisations_pkey PRIMARY KEY (id);


--
-- Name: parties parties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_pkey PRIMARY KEY (id);


--
-- Name: party_categories party_categories_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_categories
    ADD CONSTRAINT party_categories_name_key UNIQUE (name);


--
-- Name: party_categories party_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_categories
    ADD CONSTRAINT party_categories_pkey PRIMARY KEY (id);


--
-- Name: people people_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.people
    ADD CONSTRAINT people_pkey PRIMARY KEY (id);


--
-- Name: permissions permissions_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_name_key UNIQUE (name);


--
-- Name: permissions permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_pkey PRIMARY KEY (id);


--
-- Name: person_organisation_roles person_organisation_roles_person_id_org_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_organisation_roles
    ADD CONSTRAINT person_organisation_roles_person_id_org_id_key UNIQUE (person_id, org_id);


--
-- Name: person_organisation_roles person_organisation_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_organisation_roles
    ADD CONSTRAINT person_organisation_roles_pkey PRIMARY KEY (id);


--
-- Name: red_flags red_flags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.red_flags
    ADD CONSTRAINT red_flags_pkey PRIMARY KEY (id);


--
-- Name: regions regions_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regions
    ADD CONSTRAINT regions_name_key UNIQUE (name);


--
-- Name: regions regions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regions
    ADD CONSTRAINT regions_pkey PRIMARY KEY (id);


--
-- Name: research_campaigns research_campaigns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_campaigns
    ADD CONSTRAINT research_campaigns_pkey PRIMARY KEY (id);


--
-- Name: revenue_stream_months revenue_stream_months_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.revenue_stream_months
    ADD CONSTRAINT revenue_stream_months_pkey PRIMARY KEY (id);


--
-- Name: revenue_stream_months revenue_stream_months_stream_id_month_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.revenue_stream_months
    ADD CONSTRAINT revenue_stream_months_stream_id_month_key UNIQUE (stream_id, month);


--
-- Name: revenue_streams revenue_streams_deal_id_stream_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.revenue_streams
    ADD CONSTRAINT revenue_streams_deal_id_stream_type_key UNIQUE (deal_id, stream_type);


--
-- Name: revenue_streams revenue_streams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.revenue_streams
    ADD CONSTRAINT revenue_streams_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (role_id, permission_id);


--
-- Name: roles roles_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_name_key UNIQUE (name);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: service_major service_major_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_major
    ADD CONSTRAINT service_major_name_key UNIQUE (name);


--
-- Name: service_major service_major_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_major
    ADD CONSTRAINT service_major_pkey PRIMARY KEY (id);


--
-- Name: service_sub service_sub_major_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_sub
    ADD CONSTRAINT service_sub_major_id_name_key UNIQUE (major_id, name);


--
-- Name: service_sub service_sub_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_sub
    ADD CONSTRAINT service_sub_pkey PRIMARY KEY (id);


--
-- Name: settings settings_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_key_key UNIQUE (key);


--
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (id);


--
-- Name: stage_categories stage_categories_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_categories
    ADD CONSTRAINT stage_categories_name_key UNIQUE (name);


--
-- Name: stage_categories stage_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_categories
    ADD CONSTRAINT stage_categories_pkey PRIMARY KEY (id);


--
-- Name: stages stages_category_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stages
    ADD CONSTRAINT stages_category_id_name_key UNIQUE (category_id, name);


--
-- Name: stages stages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stages
    ADD CONSTRAINT stages_pkey PRIMARY KEY (id);


--
-- Name: strategic_decisions strategic_decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.strategic_decisions
    ADD CONSTRAINT strategic_decisions_pkey PRIMARY KEY (id);


--
-- Name: system_user_regions system_user_regions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_user_regions
    ADD CONSTRAINT system_user_regions_pkey PRIMARY KEY (id);


--
-- Name: system_user_regions system_user_regions_system_user_id_region_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_user_regions
    ADD CONSTRAINT system_user_regions_system_user_id_region_id_key UNIQUE (system_user_id, region_id);


--
-- Name: system_users system_users_person_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_users
    ADD CONSTRAINT system_users_person_id_key UNIQUE (person_id);


--
-- Name: system_users system_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_users
    ADD CONSTRAINT system_users_pkey PRIMARY KEY (id);


--
-- Name: system_users system_users_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_users
    ADD CONSTRAINT system_users_username_key UNIQUE (username);


--
-- Name: user_permission_overrides user_permission_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_permission_overrides
    ADD CONSTRAINT user_permission_overrides_pkey PRIMARY KEY (id);


--
-- Name: user_roles user_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_pkey PRIMARY KEY (user_id, role_id);


--
-- Name: idx_lead_interactions_lead; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lead_interactions_lead ON public.lead_interactions USING btree (lead_id);


--
-- Name: idx_leads_next_action_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_leads_next_action_date ON public.leads USING btree (next_action_date);


--
-- Name: idx_leads_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_leads_owner_id ON public.leads USING btree (owner_id);


--
-- Name: idx_leads_research_campaign; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_leads_research_campaign ON public.leads USING btree (research_campaign_id);


--
-- Name: idx_leads_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_leads_source_id ON public.leads USING btree (source_id);


--
-- Name: idx_leads_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_leads_status ON public.leads USING btree (status);


--
-- Name: idx_system_user_regions_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_system_user_regions_user ON public.system_user_regions USING btree (system_user_id);


--
-- Name: lead_interactions lead_interactions_refresh_next_action; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER lead_interactions_refresh_next_action AFTER INSERT OR DELETE OR UPDATE ON public.lead_interactions FOR EACH ROW EXECUTE FUNCTION public.trg_lead_interactions_refresh_next_action();


--
-- Name: lead_interactions lead_interactions_refresh_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER lead_interactions_refresh_status AFTER INSERT OR DELETE OR UPDATE ON public.lead_interactions FOR EACH ROW EXECUTE FUNCTION public.trg_lead_interactions_refresh_status();


--
-- Name: lead_red_flags lead_red_flags_refresh_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER lead_red_flags_refresh_status AFTER INSERT OR DELETE OR UPDATE ON public.lead_red_flags FOR EACH ROW EXECUTE FUNCTION public.trg_lead_red_flags_refresh_status();


--
-- Name: leads leads_refresh_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER leads_refresh_status AFTER UPDATE ON public.leads FOR EACH ROW EXECUTE FUNCTION public.trg_leads_refresh_status();


--
-- Name: organisations orgs_link_freetext_leads; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER orgs_link_freetext_leads AFTER INSERT OR UPDATE OF name, legal_name ON public.organisations FOR EACH ROW EXECUTE FUNCTION public.trg_orgs_link_freetext_leads();


--
-- Name: home_organisation_members trg_home_member_to_affiliation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_home_member_to_affiliation AFTER INSERT ON public.home_organisation_members FOR EACH ROW EXECUTE FUNCTION public.sync_home_member_to_affiliation();


--
-- Name: deal_collaborators deal_collaborators_deal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deal_collaborators
    ADD CONSTRAINT deal_collaborators_deal_id_fkey FOREIGN KEY (deal_id) REFERENCES public.deals(id) ON DELETE CASCADE;


--
-- Name: deal_collaborators deal_collaborators_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deal_collaborators
    ADD CONSTRAINT deal_collaborators_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE RESTRICT;


--
-- Name: deals deals_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deals
    ADD CONSTRAINT deals_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.people(id) ON DELETE SET NULL;


--
-- Name: deals deals_org_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deals
    ADD CONSTRAINT deals_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;


--
-- Name: deals deals_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deals
    ADD CONSTRAINT deals_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.people(id) ON DELETE SET NULL;


--
-- Name: deals deals_region_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deals
    ADD CONSTRAINT deals_region_id_fkey FOREIGN KEY (region_id) REFERENCES public.regions(id) ON DELETE SET NULL;


--
-- Name: deals deals_service_major_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deals
    ADD CONSTRAINT deals_service_major_id_fkey FOREIGN KEY (service_major_id) REFERENCES public.service_major(id) ON DELETE SET NULL;


--
-- Name: deals deals_service_sub_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deals
    ADD CONSTRAINT deals_service_sub_id_fkey FOREIGN KEY (service_sub_id) REFERENCES public.service_sub(id) ON DELETE SET NULL;


--
-- Name: deals deals_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deals
    ADD CONSTRAINT deals_stage_id_fkey FOREIGN KEY (stage_id) REFERENCES public.stages(id) ON DELETE RESTRICT;


--
-- Name: engagement_people engagement_people_engagement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_people
    ADD CONSTRAINT engagement_people_engagement_id_fkey FOREIGN KEY (engagement_id) REFERENCES public.engagements(id) ON DELETE CASCADE;


--
-- Name: engagement_people engagement_people_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_people
    ADD CONSTRAINT engagement_people_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE RESTRICT;


--
-- Name: engagements engagements_activity_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagements
    ADD CONSTRAINT engagements_activity_type_id_fkey FOREIGN KEY (activity_type_id) REFERENCES public.activity_types(id);


--
-- Name: engagements engagements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagements
    ADD CONSTRAINT engagements_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.people(id) ON DELETE SET NULL;


--
-- Name: engagements engagements_deal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagements
    ADD CONSTRAINT engagements_deal_id_fkey FOREIGN KEY (deal_id) REFERENCES public.deals(id) ON DELETE CASCADE;


--
-- Name: engagements engagements_next_action_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagements
    ADD CONSTRAINT engagements_next_action_id_fkey FOREIGN KEY (next_action_id) REFERENCES public.next_actions(id);


--
-- Name: home_organisation_members home_organisation_members_org_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.home_organisation_members
    ADD CONSTRAINT home_organisation_members_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organisations(id) ON DELETE CASCADE;


--
-- Name: home_organisation_members home_organisation_members_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.home_organisation_members
    ADD CONSTRAINT home_organisation_members_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE CASCADE;


--
-- Name: home_organisation_members home_organisation_members_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.home_organisation_members
    ADD CONSTRAINT home_organisation_members_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE RESTRICT;


--
-- Name: lead_interactions lead_interactions_activity_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_interactions
    ADD CONSTRAINT lead_interactions_activity_type_id_fkey FOREIGN KEY (activity_type_id) REFERENCES public.activity_types(id);


--
-- Name: lead_interactions lead_interactions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_interactions
    ADD CONSTRAINT lead_interactions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.people(id) ON DELETE SET NULL;


--
-- Name: lead_interactions lead_interactions_lead_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_interactions
    ADD CONSTRAINT lead_interactions_lead_id_fkey FOREIGN KEY (lead_id) REFERENCES public.leads(id) ON DELETE CASCADE;


--
-- Name: lead_interactions lead_interactions_next_action_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_interactions
    ADD CONSTRAINT lead_interactions_next_action_id_fkey FOREIGN KEY (next_action_id) REFERENCES public.next_actions(id);


--
-- Name: lead_red_flags lead_red_flags_lead_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_red_flags
    ADD CONSTRAINT lead_red_flags_lead_id_fkey FOREIGN KEY (lead_id) REFERENCES public.leads(id) ON DELETE CASCADE;


--
-- Name: lead_red_flags lead_red_flags_red_flag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_red_flags
    ADD CONSTRAINT lead_red_flags_red_flag_id_fkey FOREIGN KEY (red_flag_id) REFERENCES public.red_flags(id) ON DELETE CASCADE;


--
-- Name: lead_strategic_decisions lead_strategic_decisions_lead_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_strategic_decisions
    ADD CONSTRAINT lead_strategic_decisions_lead_id_fkey FOREIGN KEY (lead_id) REFERENCES public.leads(id) ON DELETE CASCADE;


--
-- Name: lead_strategic_decisions lead_strategic_decisions_strategic_decision_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_strategic_decisions
    ADD CONSTRAINT lead_strategic_decisions_strategic_decision_id_fkey FOREIGN KEY (strategic_decision_id) REFERENCES public.strategic_decisions(id) ON DELETE CASCADE;


--
-- Name: leads leads_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.people(id) ON DELETE SET NULL;


--
-- Name: leads leads_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.people(id) ON DELETE SET NULL;


--
-- Name: leads leads_promoted_deal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_promoted_deal_id_fkey FOREIGN KEY (promoted_deal_id) REFERENCES public.deals(id) ON DELETE SET NULL;


--
-- Name: leads leads_promotion_requested_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_promotion_requested_by_fkey FOREIGN KEY (promotion_requested_by) REFERENCES public.people(id);


--
-- Name: leads leads_region_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_region_id_fkey FOREIGN KEY (region_id) REFERENCES public.regions(id) ON DELETE SET NULL;


--
-- Name: leads leads_research_campaign_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_research_campaign_id_fkey FOREIGN KEY (research_campaign_id) REFERENCES public.research_campaigns(id) ON DELETE SET NULL;


--
-- Name: leads leads_service_major_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_service_major_id_fkey FOREIGN KEY (service_major_id) REFERENCES public.service_major(id) ON DELETE SET NULL;


--
-- Name: leads leads_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.lead_sources(id) ON DELETE RESTRICT;


--
-- Name: leads leads_source_org_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_source_org_id_fkey FOREIGN KEY (source_org_id) REFERENCES public.organisations(id) ON DELETE SET NULL;


--
-- Name: leads leads_source_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_source_person_id_fkey FOREIGN KEY (source_person_id) REFERENCES public.people(id) ON DELETE SET NULL;


--
-- Name: leads leads_target_org_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_target_org_id_fkey FOREIGN KEY (target_org_id) REFERENCES public.organisations(id) ON DELETE SET NULL;


--
-- Name: leads leads_target_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_target_person_id_fkey FOREIGN KEY (target_person_id) REFERENCES public.people(id) ON DELETE SET NULL;


--
-- Name: opportunity_contacts opportunity_contacts_deal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_contacts
    ADD CONSTRAINT opportunity_contacts_deal_id_fkey FOREIGN KEY (deal_id) REFERENCES public.deals(id) ON DELETE CASCADE;


--
-- Name: opportunity_contacts opportunity_contacts_dmu_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_contacts
    ADD CONSTRAINT opportunity_contacts_dmu_role_id_fkey FOREIGN KEY (dmu_role_id) REFERENCES public.dmu_roles(id) ON DELETE SET NULL;


--
-- Name: opportunity_contacts opportunity_contacts_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_contacts
    ADD CONSTRAINT opportunity_contacts_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE RESTRICT;


--
-- Name: parties parties_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.party_categories(id) ON DELETE SET NULL;


--
-- Name: person_organisation_roles person_organisation_roles_org_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_organisation_roles
    ADD CONSTRAINT person_organisation_roles_org_id_fkey FOREIGN KEY (org_id) REFERENCES public.organisations(id) ON DELETE CASCADE;


--
-- Name: person_organisation_roles person_organisation_roles_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_organisation_roles
    ADD CONSTRAINT person_organisation_roles_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE CASCADE;


--
-- Name: research_campaigns research_campaigns_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_campaigns
    ADD CONSTRAINT research_campaigns_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.people(id) ON DELETE SET NULL;


--
-- Name: research_campaigns research_campaigns_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_campaigns
    ADD CONSTRAINT research_campaigns_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.people(id) ON DELETE SET NULL;


--
-- Name: research_campaigns research_campaigns_region_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_campaigns
    ADD CONSTRAINT research_campaigns_region_id_fkey FOREIGN KEY (region_id) REFERENCES public.regions(id) ON DELETE SET NULL;


--
-- Name: research_campaigns research_campaigns_service_major_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_campaigns
    ADD CONSTRAINT research_campaigns_service_major_id_fkey FOREIGN KEY (service_major_id) REFERENCES public.service_major(id) ON DELETE SET NULL;


--
-- Name: revenue_stream_months revenue_stream_months_stream_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.revenue_stream_months
    ADD CONSTRAINT revenue_stream_months_stream_id_fkey FOREIGN KEY (stream_id) REFERENCES public.revenue_streams(id) ON DELETE CASCADE;


--
-- Name: role_permissions role_permissions_permission_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES public.permissions(id) ON DELETE CASCADE;


--
-- Name: role_permissions role_permissions_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;


--
-- Name: service_sub service_sub_major_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_sub
    ADD CONSTRAINT service_sub_major_id_fkey FOREIGN KEY (major_id) REFERENCES public.service_major(id) ON DELETE CASCADE;


--
-- Name: stages stages_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stages
    ADD CONSTRAINT stages_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.stage_categories(id) ON DELETE RESTRICT;


--
-- Name: system_user_regions system_user_regions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_user_regions
    ADD CONSTRAINT system_user_regions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.people(id);


--
-- Name: system_user_regions system_user_regions_region_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_user_regions
    ADD CONSTRAINT system_user_regions_region_id_fkey FOREIGN KEY (region_id) REFERENCES public.regions(id) ON DELETE CASCADE;


--
-- Name: system_user_regions system_user_regions_system_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_user_regions
    ADD CONSTRAINT system_user_regions_system_user_id_fkey FOREIGN KEY (system_user_id) REFERENCES public.system_users(id) ON DELETE CASCADE;


--
-- Name: system_users system_users_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_users
    ADD CONSTRAINT system_users_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE CASCADE;


--
-- Name: user_permission_overrides user_permission_overrides_permission_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_permission_overrides
    ADD CONSTRAINT user_permission_overrides_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES public.permissions(id) ON DELETE CASCADE;


--
-- Name: user_permission_overrides user_permission_overrides_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_permission_overrides
    ADD CONSTRAINT user_permission_overrides_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.system_users(id) ON DELETE CASCADE;


--
-- Name: user_roles user_roles_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;


--
-- Name: user_roles user_roles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.system_users(id) ON DELETE CASCADE;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION refresh_lead_next_action(p_lead_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.refresh_lead_next_action(p_lead_id bigint) TO anon;
GRANT ALL ON FUNCTION public.refresh_lead_next_action(p_lead_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.refresh_lead_next_action(p_lead_id bigint) TO service_role;


--
-- Name: FUNCTION refresh_lead_status(p_lead_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.refresh_lead_status(p_lead_id bigint) TO anon;
GRANT ALL ON FUNCTION public.refresh_lead_status(p_lead_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.refresh_lead_status(p_lead_id bigint) TO service_role;


--
-- Name: FUNCTION sync_home_member_to_affiliation(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_home_member_to_affiliation() TO anon;
GRANT ALL ON FUNCTION public.sync_home_member_to_affiliation() TO authenticated;
GRANT ALL ON FUNCTION public.sync_home_member_to_affiliation() TO service_role;


--
-- Name: FUNCTION trg_lead_interactions_refresh_next_action(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.trg_lead_interactions_refresh_next_action() TO anon;
GRANT ALL ON FUNCTION public.trg_lead_interactions_refresh_next_action() TO authenticated;
GRANT ALL ON FUNCTION public.trg_lead_interactions_refresh_next_action() TO service_role;


--
-- Name: FUNCTION trg_lead_interactions_refresh_status(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.trg_lead_interactions_refresh_status() TO anon;
GRANT ALL ON FUNCTION public.trg_lead_interactions_refresh_status() TO authenticated;
GRANT ALL ON FUNCTION public.trg_lead_interactions_refresh_status() TO service_role;


--
-- Name: FUNCTION trg_lead_red_flags_refresh_status(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.trg_lead_red_flags_refresh_status() TO anon;
GRANT ALL ON FUNCTION public.trg_lead_red_flags_refresh_status() TO authenticated;
GRANT ALL ON FUNCTION public.trg_lead_red_flags_refresh_status() TO service_role;


--
-- Name: FUNCTION trg_leads_refresh_status(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.trg_leads_refresh_status() TO anon;
GRANT ALL ON FUNCTION public.trg_leads_refresh_status() TO authenticated;
GRANT ALL ON FUNCTION public.trg_leads_refresh_status() TO service_role;


--
-- Name: FUNCTION trg_orgs_link_freetext_leads(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.trg_orgs_link_freetext_leads() TO anon;
GRANT ALL ON FUNCTION public.trg_orgs_link_freetext_leads() TO authenticated;
GRANT ALL ON FUNCTION public.trg_orgs_link_freetext_leads() TO service_role;


--
-- Name: TABLE activity_types; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.activity_types TO anon;
GRANT ALL ON TABLE public.activity_types TO authenticated;
GRANT ALL ON TABLE public.activity_types TO service_role;


--
-- Name: SEQUENCE activity_types_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.activity_types_id_seq TO anon;
GRANT ALL ON SEQUENCE public.activity_types_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.activity_types_id_seq TO service_role;


--
-- Name: TABLE deal_collaborators; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.deal_collaborators TO anon;
GRANT ALL ON TABLE public.deal_collaborators TO authenticated;
GRANT ALL ON TABLE public.deal_collaborators TO service_role;


--
-- Name: SEQUENCE deal_collaborators_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.deal_collaborators_id_seq TO anon;
GRANT ALL ON SEQUENCE public.deal_collaborators_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.deal_collaborators_id_seq TO service_role;


--
-- Name: TABLE deals; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.deals TO anon;
GRANT ALL ON TABLE public.deals TO authenticated;
GRANT ALL ON TABLE public.deals TO service_role;


--
-- Name: SEQUENCE deals_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.deals_id_seq TO anon;
GRANT ALL ON SEQUENCE public.deals_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.deals_id_seq TO service_role;


--
-- Name: TABLE dmu_roles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.dmu_roles TO anon;
GRANT ALL ON TABLE public.dmu_roles TO authenticated;
GRANT ALL ON TABLE public.dmu_roles TO service_role;


--
-- Name: SEQUENCE dmu_roles_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.dmu_roles_id_seq TO anon;
GRANT ALL ON SEQUENCE public.dmu_roles_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.dmu_roles_id_seq TO service_role;


--
-- Name: TABLE engagement_people; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.engagement_people TO anon;
GRANT ALL ON TABLE public.engagement_people TO authenticated;
GRANT ALL ON TABLE public.engagement_people TO service_role;


--
-- Name: SEQUENCE engagement_people_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.engagement_people_id_seq TO anon;
GRANT ALL ON SEQUENCE public.engagement_people_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.engagement_people_id_seq TO service_role;


--
-- Name: TABLE engagements; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.engagements TO anon;
GRANT ALL ON TABLE public.engagements TO authenticated;
GRANT ALL ON TABLE public.engagements TO service_role;


--
-- Name: SEQUENCE engagements_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.engagements_id_seq TO anon;
GRANT ALL ON SEQUENCE public.engagements_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.engagements_id_seq TO service_role;


--
-- Name: TABLE home_organisation_members; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.home_organisation_members TO anon;
GRANT ALL ON TABLE public.home_organisation_members TO authenticated;
GRANT ALL ON TABLE public.home_organisation_members TO service_role;


--
-- Name: SEQUENCE home_organisation_members_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.home_organisation_members_id_seq TO anon;
GRANT ALL ON SEQUENCE public.home_organisation_members_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.home_organisation_members_id_seq TO service_role;


--
-- Name: TABLE industry_sectors; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.industry_sectors TO anon;
GRANT ALL ON TABLE public.industry_sectors TO authenticated;
GRANT ALL ON TABLE public.industry_sectors TO service_role;


--
-- Name: SEQUENCE industry_sectors_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.industry_sectors_id_seq TO anon;
GRANT ALL ON SEQUENCE public.industry_sectors_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.industry_sectors_id_seq TO service_role;


--
-- Name: TABLE lead_interactions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.lead_interactions TO anon;
GRANT ALL ON TABLE public.lead_interactions TO authenticated;
GRANT ALL ON TABLE public.lead_interactions TO service_role;


--
-- Name: SEQUENCE lead_interactions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.lead_interactions_id_seq TO anon;
GRANT ALL ON SEQUENCE public.lead_interactions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.lead_interactions_id_seq TO service_role;


--
-- Name: TABLE lead_red_flags; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.lead_red_flags TO anon;
GRANT ALL ON TABLE public.lead_red_flags TO authenticated;
GRANT ALL ON TABLE public.lead_red_flags TO service_role;


--
-- Name: TABLE lead_sources; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.lead_sources TO anon;
GRANT ALL ON TABLE public.lead_sources TO authenticated;
GRANT ALL ON TABLE public.lead_sources TO service_role;


--
-- Name: SEQUENCE lead_sources_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.lead_sources_id_seq TO anon;
GRANT ALL ON SEQUENCE public.lead_sources_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.lead_sources_id_seq TO service_role;


--
-- Name: TABLE lead_strategic_decisions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.lead_strategic_decisions TO anon;
GRANT ALL ON TABLE public.lead_strategic_decisions TO authenticated;
GRANT ALL ON TABLE public.lead_strategic_decisions TO service_role;


--
-- Name: TABLE leads; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.leads TO anon;
GRANT ALL ON TABLE public.leads TO authenticated;
GRANT ALL ON TABLE public.leads TO service_role;


--
-- Name: SEQUENCE leads_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.leads_id_seq TO anon;
GRANT ALL ON SEQUENCE public.leads_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.leads_id_seq TO service_role;


--
-- Name: TABLE next_actions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.next_actions TO anon;
GRANT ALL ON TABLE public.next_actions TO authenticated;
GRANT ALL ON TABLE public.next_actions TO service_role;


--
-- Name: SEQUENCE next_actions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.next_actions_id_seq TO anon;
GRANT ALL ON SEQUENCE public.next_actions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.next_actions_id_seq TO service_role;


--
-- Name: TABLE opportunity_contacts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.opportunity_contacts TO anon;
GRANT ALL ON TABLE public.opportunity_contacts TO authenticated;
GRANT ALL ON TABLE public.opportunity_contacts TO service_role;


--
-- Name: SEQUENCE opportunity_contacts_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.opportunity_contacts_id_seq TO anon;
GRANT ALL ON SEQUENCE public.opportunity_contacts_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.opportunity_contacts_id_seq TO service_role;


--
-- Name: TABLE organisations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.organisations TO anon;
GRANT ALL ON TABLE public.organisations TO authenticated;
GRANT ALL ON TABLE public.organisations TO service_role;


--
-- Name: SEQUENCE organisations_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.organisations_id_seq TO anon;
GRANT ALL ON SEQUENCE public.organisations_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.organisations_id_seq TO service_role;


--
-- Name: TABLE parties; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.parties TO anon;
GRANT ALL ON TABLE public.parties TO authenticated;
GRANT ALL ON TABLE public.parties TO service_role;


--
-- Name: SEQUENCE parties_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.parties_id_seq TO anon;
GRANT ALL ON SEQUENCE public.parties_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.parties_id_seq TO service_role;


--
-- Name: TABLE party_categories; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.party_categories TO anon;
GRANT ALL ON TABLE public.party_categories TO authenticated;
GRANT ALL ON TABLE public.party_categories TO service_role;


--
-- Name: SEQUENCE party_categories_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.party_categories_id_seq TO anon;
GRANT ALL ON SEQUENCE public.party_categories_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.party_categories_id_seq TO service_role;


--
-- Name: TABLE people; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.people TO anon;
GRANT ALL ON TABLE public.people TO authenticated;
GRANT ALL ON TABLE public.people TO service_role;


--
-- Name: SEQUENCE people_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.people_id_seq TO anon;
GRANT ALL ON SEQUENCE public.people_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.people_id_seq TO service_role;


--
-- Name: TABLE permissions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.permissions TO anon;
GRANT ALL ON TABLE public.permissions TO authenticated;
GRANT ALL ON TABLE public.permissions TO service_role;


--
-- Name: SEQUENCE permissions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.permissions_id_seq TO anon;
GRANT ALL ON SEQUENCE public.permissions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.permissions_id_seq TO service_role;


--
-- Name: TABLE person_organisation_roles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.person_organisation_roles TO anon;
GRANT ALL ON TABLE public.person_organisation_roles TO authenticated;
GRANT ALL ON TABLE public.person_organisation_roles TO service_role;


--
-- Name: SEQUENCE person_organisation_roles_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.person_organisation_roles_id_seq TO anon;
GRANT ALL ON SEQUENCE public.person_organisation_roles_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.person_organisation_roles_id_seq TO service_role;


--
-- Name: TABLE red_flags; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.red_flags TO anon;
GRANT ALL ON TABLE public.red_flags TO authenticated;
GRANT ALL ON TABLE public.red_flags TO service_role;


--
-- Name: SEQUENCE red_flags_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.red_flags_id_seq TO anon;
GRANT ALL ON SEQUENCE public.red_flags_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.red_flags_id_seq TO service_role;


--
-- Name: TABLE regions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.regions TO anon;
GRANT ALL ON TABLE public.regions TO authenticated;
GRANT ALL ON TABLE public.regions TO service_role;


--
-- Name: SEQUENCE regions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.regions_id_seq TO anon;
GRANT ALL ON SEQUENCE public.regions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.regions_id_seq TO service_role;


--
-- Name: TABLE research_campaigns; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.research_campaigns TO anon;
GRANT ALL ON TABLE public.research_campaigns TO authenticated;
GRANT ALL ON TABLE public.research_campaigns TO service_role;


--
-- Name: SEQUENCE research_campaigns_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.research_campaigns_id_seq TO anon;
GRANT ALL ON SEQUENCE public.research_campaigns_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.research_campaigns_id_seq TO service_role;


--
-- Name: TABLE revenue_stream_months; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.revenue_stream_months TO anon;
GRANT ALL ON TABLE public.revenue_stream_months TO authenticated;
GRANT ALL ON TABLE public.revenue_stream_months TO service_role;


--
-- Name: SEQUENCE revenue_stream_months_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.revenue_stream_months_id_seq TO anon;
GRANT ALL ON SEQUENCE public.revenue_stream_months_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.revenue_stream_months_id_seq TO service_role;


--
-- Name: TABLE revenue_streams; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.revenue_streams TO anon;
GRANT ALL ON TABLE public.revenue_streams TO authenticated;
GRANT ALL ON TABLE public.revenue_streams TO service_role;


--
-- Name: SEQUENCE revenue_streams_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.revenue_streams_id_seq TO anon;
GRANT ALL ON SEQUENCE public.revenue_streams_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.revenue_streams_id_seq TO service_role;


--
-- Name: TABLE role_permissions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.role_permissions TO anon;
GRANT ALL ON TABLE public.role_permissions TO authenticated;
GRANT ALL ON TABLE public.role_permissions TO service_role;


--
-- Name: TABLE roles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.roles TO anon;
GRANT ALL ON TABLE public.roles TO authenticated;
GRANT ALL ON TABLE public.roles TO service_role;


--
-- Name: SEQUENCE roles_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.roles_id_seq TO anon;
GRANT ALL ON SEQUENCE public.roles_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.roles_id_seq TO service_role;


--
-- Name: TABLE service_major; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.service_major TO anon;
GRANT ALL ON TABLE public.service_major TO authenticated;
GRANT ALL ON TABLE public.service_major TO service_role;


--
-- Name: SEQUENCE service_major_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.service_major_id_seq TO anon;
GRANT ALL ON SEQUENCE public.service_major_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.service_major_id_seq TO service_role;


--
-- Name: TABLE service_sub; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.service_sub TO anon;
GRANT ALL ON TABLE public.service_sub TO authenticated;
GRANT ALL ON TABLE public.service_sub TO service_role;


--
-- Name: SEQUENCE service_sub_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.service_sub_id_seq TO anon;
GRANT ALL ON SEQUENCE public.service_sub_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.service_sub_id_seq TO service_role;


--
-- Name: TABLE settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.settings TO anon;
GRANT ALL ON TABLE public.settings TO authenticated;
GRANT ALL ON TABLE public.settings TO service_role;


--
-- Name: SEQUENCE settings_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.settings_id_seq TO anon;
GRANT ALL ON SEQUENCE public.settings_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.settings_id_seq TO service_role;


--
-- Name: TABLE stage_categories; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.stage_categories TO anon;
GRANT ALL ON TABLE public.stage_categories TO authenticated;
GRANT ALL ON TABLE public.stage_categories TO service_role;


--
-- Name: SEQUENCE stage_categories_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.stage_categories_id_seq TO anon;
GRANT ALL ON SEQUENCE public.stage_categories_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.stage_categories_id_seq TO service_role;


--
-- Name: TABLE stages; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.stages TO anon;
GRANT ALL ON TABLE public.stages TO authenticated;
GRANT ALL ON TABLE public.stages TO service_role;


--
-- Name: SEQUENCE stages_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.stages_id_seq TO anon;
GRANT ALL ON SEQUENCE public.stages_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.stages_id_seq TO service_role;


--
-- Name: TABLE strategic_decisions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.strategic_decisions TO anon;
GRANT ALL ON TABLE public.strategic_decisions TO authenticated;
GRANT ALL ON TABLE public.strategic_decisions TO service_role;


--
-- Name: SEQUENCE strategic_decisions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.strategic_decisions_id_seq TO anon;
GRANT ALL ON SEQUENCE public.strategic_decisions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.strategic_decisions_id_seq TO service_role;


--
-- Name: TABLE system_user_regions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.system_user_regions TO anon;
GRANT ALL ON TABLE public.system_user_regions TO authenticated;
GRANT ALL ON TABLE public.system_user_regions TO service_role;


--
-- Name: SEQUENCE system_user_regions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.system_user_regions_id_seq TO anon;
GRANT ALL ON SEQUENCE public.system_user_regions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.system_user_regions_id_seq TO service_role;


--
-- Name: TABLE system_users; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.system_users TO anon;
GRANT ALL ON TABLE public.system_users TO authenticated;
GRANT ALL ON TABLE public.system_users TO service_role;


--
-- Name: SEQUENCE system_users_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.system_users_id_seq TO anon;
GRANT ALL ON SEQUENCE public.system_users_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.system_users_id_seq TO service_role;


--
-- Name: TABLE user_permission_overrides; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_permission_overrides TO anon;
GRANT ALL ON TABLE public.user_permission_overrides TO authenticated;
GRANT ALL ON TABLE public.user_permission_overrides TO service_role;


--
-- Name: SEQUENCE user_permission_overrides_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.user_permission_overrides_id_seq TO anon;
GRANT ALL ON SEQUENCE public.user_permission_overrides_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.user_permission_overrides_id_seq TO service_role;


--
-- Name: TABLE user_roles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_roles TO anon;
GRANT ALL ON TABLE public.user_roles TO authenticated;
GRANT ALL ON TABLE public.user_roles TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--

\unrestrict VO7aH9vre3guRzweQeziduCwfwKVuBNc6LWcwkVxMfugBCAwBseVfca0lUb5QBs

