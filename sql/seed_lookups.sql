--
-- PostgreSQL database dump
--

\restrict CFwVqEje32Hn0QBc9KqU92cLAcL84N4IbT5LNnx2nJzPzgrxrkLHZsOLLCGaNfi

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
-- Data for Name: activity_types; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.activity_types (id, name, description, applies_to_opportunities, applies_to_leads, active, sort_order, created_at, updated_at) FROM stdin;
1	Call	\N	t	t	t	10	2026-05-22 10:52:42.942165+00	2026-05-22 10:52:42.942165+00
2	Email	\N	t	t	t	20	2026-05-22 10:52:42.942165+00	2026-05-22 10:52:42.942165+00
3	Meeting	\N	t	t	t	30	2026-05-22 10:52:42.942165+00	2026-05-22 10:52:42.942165+00
4	Site Visit	\N	t	t	t	40	2026-05-22 10:52:42.942165+00	2026-05-22 10:52:42.942165+00
5	Demo	\N	t	f	t	50	2026-05-22 10:52:42.942165+00	2026-05-22 10:52:42.942165+00
6	Proposal Submitted	\N	t	f	t	60	2026-05-22 10:52:42.942165+00	2026-05-22 10:52:42.942165+00
7	Note	\N	f	t	t	70	2026-05-22 10:52:42.942165+00	2026-05-22 10:52:42.942165+00
8	Promotion	\N	t	f	t	0	2026-05-24 08:36:42.832485+00	2026-05-24 08:36:42.832485+00
\.


--
-- Data for Name: dmu_roles; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.dmu_roles (id, name, description, active, created_at) FROM stdin;
1	Economic Buyer	Controls the budget and gives final financial approval	t	2026-05-18 12:50:54.009079+00
2	Technical Buyer	Evaluates technical fit and compliance	t	2026-05-18 12:50:54.009079+00
3	User Buyer	Will use the product/service day-to-day	t	2026-05-18 12:50:54.009079+00
4	Decision Maker	Makes the final buying decision	t	2026-05-18 12:50:54.009079+00
5	Champion	Internal advocate who drives the deal forward	t	2026-05-18 12:50:54.009079+00
6	Influencer	Shapes opinions without formal authority	t	2026-05-18 12:50:54.009079+00
7	Gatekeeper	Controls access to other stakeholders	t	2026-05-18 12:50:54.009079+00
8	Saboteur	Actively works against the deal	t	2026-05-18 12:50:54.009079+00
\.


--
-- Data for Name: industry_sectors; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.industry_sectors (id, name, active, created_at) FROM stdin;
1	Mining	t	2026-05-16 12:51:56.552858+00
2	Agriculture & Forestry	t	2026-05-18 12:47:24.523686+00
3	Automotive	t	2026-05-18 12:47:24.523686+00
4	Banking & Financial Services	t	2026-05-18 12:47:24.523686+00
5	Construction & Infrastructure	t	2026-05-18 12:47:24.523686+00
6	Education	t	2026-05-18 12:47:24.523686+00
7	Energy & Utilities	t	2026-05-18 12:47:24.523686+00
8	FMCG & Retail	t	2026-05-18 12:47:24.523686+00
9	Government & Public Sector	t	2026-05-18 12:47:24.523686+00
10	Healthcare & Pharmaceuticals	t	2026-05-18 12:47:24.523686+00
11	Hospitality & Tourism	t	2026-05-18 12:47:24.523686+00
12	Insurance	t	2026-05-18 12:47:24.523686+00
13	Legal & Professional Services	t	2026-05-18 12:47:24.523686+00
14	Logistics & Supply Chain	t	2026-05-18 12:47:24.523686+00
15	Manufacturing	t	2026-05-18 12:47:24.523686+00
16	Media & Entertainment	t	2026-05-18 12:47:24.523686+00
17	Mining & Resources	t	2026-05-18 12:47:24.523686+00
18	Non-Profit & NGO	t	2026-05-18 12:47:24.523686+00
19	Property & Real Estate	t	2026-05-18 12:47:24.523686+00
20	Residential Estates	t	2026-05-18 12:47:24.523686+00
21	Technology & Telecoms	t	2026-05-18 12:47:24.523686+00
22	Transport	t	2026-05-18 12:47:24.523686+00
\.


--
-- Data for Name: lead_sources; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.lead_sources (id, name, active, created_at) FROM stdin;
1	Referral	t	2026-05-20 10:50:17.101897+00
2	Client Expansion	t	2026-05-20 10:50:17.101897+00
3	Research	t	2026-05-20 10:50:17.101897+00
4	Inbound	t	2026-05-20 10:50:17.101897+00
5	Outbound	t	2026-05-20 10:50:17.101897+00
6	Tender	t	2026-05-20 10:50:17.101897+00
7	Other	t	2026-05-20 10:50:17.101897+00
\.


--
-- Data for Name: party_categories; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.party_categories (id, name, active, created_at) FROM stdin;
1	Consultant	t	2026-05-16 12:52:26.596279+00
\.


--
-- Data for Name: permissions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.permissions (id, name, description) FROM stdin;
1	manage_people	Add, edit and delete people
2	manage_organisations	Add, edit and delete organisations
3	manage_eligibility	Toggle system user eligibility on organisations
4	manage_affiliations	Add, edit and delete person-organisation links
5	manage_parties	Add, edit and delete parties
6	manage_system_users	Add, edit and deactivate system users
7	manage_roles	Add, edit and delete roles
8	manage_permissions	Add, edit and delete permissions
9	manage_lookups	Add, edit and manage lookup tables
10	manage_opportunities	Create and manage opportunities
11	manage_settings	Manage application settings
12	manage_leads	\N
13	edit_all_records	\N
14	assign_owner	\N
15	promote_lead	\N
\.


--
-- Data for Name: red_flags; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.red_flags (id, name, description, active, sort_order, created_at, updated_at) FROM stdin;
2	Ethical Concerns	\N	t	\N	2026-05-22 11:16:36.487261+00	2026-05-22 11:16:36.487261+00
1	Payment History	Red Flag reasons (checked continuously, not just at one point)\n\nPayment risk — credit concerns, history of non-payment, financial instability\nEthical concerns — the prospect's business or conduct conflicts with your values\nConflict of interest with an existing client — e.g. you discover the prospect is being sued by, or competing aggressively with, one of your larger existing accounts\nCapacity issues — you genuinely can't serve them and won't be able to within a sensible horizon\n\nStrategic / executive reasons (the MD point you're asking about)\nThis was framed as: a lead might be perfectly qualified on F/T/A/C, but the MD doesn't want to pursue it. Examples we worked through:\n\nIt's a competitor's existing client and the MD has decided not to poach in that account\nThe MD has a relationship reason for not engaging — a personal history, a reciprocity arrangement, a quiet undertaking to another party\nThere's a strategic positioning reason — pursuing this client would compromise a bigger play\nAn exec-level red flag that hasn't been documented but the MD knows about	t	\N	2026-05-22 11:16:14.113143+00	2026-05-22 11:16:14.113143+00
\.


--
-- Data for Name: regions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.regions (id, name, active, created_at) FROM stdin;
1	Inland	t	2026-05-16 12:51:16.788291+00
2	Western Cape	t	2026-05-16 12:51:26.632875+00
\.


--
-- Data for Name: roles; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.roles (id, name, description, is_system, created_at) FROM stdin;
2	Sales Manager	Manage all opportunities and users	t	2026-05-15 07:12:00.098646+00
3	Sales User	Manage own opportunities	t	2026-05-15 07:12:00.098646+00
4	Read Only	View only access	t	2026-05-15 07:12:00.098646+00
7	Admin	Full access to all features	t	2026-05-15 09:04:09.543039+00
8	Operations	\N	f	2026-05-16 15:43:46.697929+00
\.


--
-- Data for Name: role_permissions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.role_permissions (role_id, permission_id) FROM stdin;
7	1
7	2
7	3
7	4
7	5
7	6
7	7
7	8
7	9
7	10
7	11
7	12
2	13
2	14
2	15
2	10
2	12
3	10
3	12
\.


--
-- Data for Name: service_major; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.service_major (id, name, active, created_at) FROM stdin;
1	Manpower	t	2026-05-16 12:48:50.41968+00
2	Technology Works	t	2026-05-16 12:49:03.163263+00
\.


--
-- Data for Name: service_sub; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.service_sub (id, major_id, name, is_recurring, default_margin, active, created_at, min_margin, default_duration) FROM stdin;
2	1	On-site Control Room	t	22.00	t	2026-05-16 12:50:15.300569+00	0.00	12
3	1	Off-site Control Room	t	25.00	t	2026-05-16 12:50:36.632761+00	0.00	12
1	1	Guarding Services	t	18.00	t	2026-05-16 12:49:46.321966+00	15.00	12
4	2	Project	f	25.00	t	2026-05-16 20:13:51.823043+00	22.00	\N
\.


--
-- Data for Name: settings; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.settings (id, key, value, updated_at) FROM stdin;
1	fy_start_month	July	2026-05-16 21:13:43.26+00
2	escalation_month	March	2026-05-16 21:13:43.26+00
3	similarity_threshold	80	2026-05-17 09:56:10.318136+00
4	eligible_collaborator_roles	Sales Manager,Sales User	2026-05-17 18:14:59.966502+00
5	engagement_edit_minutes	60	2026-05-18 16:29:03.180722+00
\.


--
-- Data for Name: stage_categories; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.stage_categories (id, name, sort_order) FROM stdin;
1	Opportunity-Open	1
2	Opportunity-Closed	2
3	Fulfilment-Active	3
4	Fulfilment-Complete	4
\.


--
-- Data for Name: stages; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.stages (id, category_id, name, probability, sort_order, active, created_at, min_probability, max_probability, probability_hint) FROM stdin;
2	1	Prospect	40	2	t	2026-05-16 12:21:40.747305+00	0	100	\N
3	1	Proposal	60	3	t	2026-05-16 12:21:40.747305+00	0	100	\N
4	1	Negotiation	80	4	t	2026-05-16 12:21:40.747305+00	0	100	\N
6	2	Lost	0	2	t	2026-05-16 12:21:40.747305+00	0	100	\N
7	3	In Progress	100	1	t	2026-05-16 12:21:40.747305+00	0	100	\N
5	2	Secured	100	1	t	2026-05-16 12:21:40.747305+00	100	100	Secured deals will always be shown at 100% probability
8	4	Complete	100	0	t	2026-05-16 12:21:40.747305+00	0	100	\N
\.


--
-- Data for Name: strategic_decisions; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.strategic_decisions (id, name, description, active, sort_order, created_at, updated_at) FROM stdin;
1	MD whim	\N	t	\N	2026-05-22 11:16:59.521237+00	2026-05-22 11:16:59.521237+00
2	Capacity	\N	t	\N	2026-05-22 11:31:20.799427+00	2026-05-22 11:31:20.799427+00
\.


--
-- Name: activity_types_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.activity_types_id_seq', 8, true);


--
-- Name: dmu_roles_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.dmu_roles_id_seq', 8, true);


--
-- Name: industry_sectors_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.industry_sectors_id_seq', 22, true);


--
-- Name: lead_sources_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.lead_sources_id_seq', 7, true);


--
-- Name: party_categories_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.party_categories_id_seq', 1, true);


--
-- Name: permissions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.permissions_id_seq', 15, true);


--
-- Name: red_flags_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.red_flags_id_seq', 2, true);


--
-- Name: regions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.regions_id_seq', 2, true);


--
-- Name: roles_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.roles_id_seq', 8, true);


--
-- Name: service_major_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.service_major_id_seq', 2, true);


--
-- Name: service_sub_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.service_sub_id_seq', 4, true);


--
-- Name: settings_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.settings_id_seq', 5, true);


--
-- Name: stage_categories_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.stage_categories_id_seq', 4, true);


--
-- Name: stages_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.stages_id_seq', 8, true);


--
-- Name: strategic_decisions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.strategic_decisions_id_seq', 2, true);


--
-- PostgreSQL database dump complete
--

\unrestrict CFwVqEje32Hn0QBc9KqU92cLAcL84N4IbT5LNnx2nJzPzgrxrkLHZsOLLCGaNfi

