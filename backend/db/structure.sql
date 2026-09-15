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
-- Name: paradedb; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA paradedb;


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: pg_search; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_search WITH SCHEMA paradedb;


--
-- Name: EXTENSION pg_search; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_search IS 'pg_search: Full text search for PostgreSQL using BM25';


--
-- Name: kioku_reject_revision_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.kioku_reject_revision_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION
    'memory_revisions is append-only: revision % of memory % cannot be % (plan invariant 4)',
    COALESCE(OLD.revision, NEW.revision),
    COALESCE(OLD.memory_key, NEW.memory_key),
    lower(TG_OP);
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agents (
    agent_key text NOT NULL,
    session_key text NOT NULL,
    provider_agent_id text,
    agent_kind text NOT NULL,
    agent_type text,
    parent_agent_key text,
    lineage_state text NOT NULL,
    identity_source text NOT NULL,
    CONSTRAINT agents_identity_source_vocabulary CHECK ((identity_source = ANY (ARRAY['hook'::text, 'telemetry'::text, 'transcript'::text, 'bridge'::text, 'unresolved'::text]))),
    CONSTRAINT agents_kind_vocabulary CHECK ((agent_kind = ANY (ARRAY['main'::text, 'subagent'::text, 'fork'::text, 'teammate'::text, 'unknown'::text]))),
    CONSTRAINT agents_lineage_matches_parent CHECK ((((lineage_state = 'known'::text) AND (parent_agent_key IS NOT NULL)) OR ((lineage_state = ANY (ARRAY['root'::text, 'unresolved'::text])) AND (parent_agent_key IS NULL)))),
    CONSTRAINT agents_lineage_state_vocabulary CHECK ((lineage_state = ANY (ARRAY['root'::text, 'known'::text, 'unresolved'::text]))),
    CONSTRAINT agents_parent_is_not_self CHECK (((parent_agent_key IS NULL) OR (parent_agent_key <> agent_key)))
);


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events (
    event_key text NOT NULL,
    installation_key text NOT NULL,
    store_kind text NOT NULL,
    project_key text,
    producer_key text NOT NULL,
    producer_epoch text NOT NULL,
    producer_sequence bigint NOT NULL,
    session_key text,
    agent_key text,
    attribution_state text NOT NULL,
    event_type text NOT NULL,
    origin_role text NOT NULL,
    tool_use_id text,
    payload_object_key text,
    observed_at timestamp with time zone NOT NULL,
    recorded_at timestamp with time zone NOT NULL,
    identity_source text DEFAULT 'unresolved'::text NOT NULL,
    CONSTRAINT events_attribution_matches_agent CHECK ((((attribution_state = 'resolved'::text) AND (agent_key IS NOT NULL)) OR ((attribution_state = ANY (ARRAY['unresolved'::text, 'not_applicable'::text])) AND (agent_key IS NULL)))),
    CONSTRAINT events_attribution_state_vocabulary CHECK ((attribution_state = ANY (ARRAY['resolved'::text, 'unresolved'::text, 'not_applicable'::text]))),
    CONSTRAINT events_identity_source_vocabulary CHECK ((identity_source = ANY (ARRAY['hook'::text, 'telemetry'::text, 'transcript'::text, 'bridge'::text, 'unresolved'::text]))),
    CONSTRAINT events_origin_role_vocabulary CHECK ((origin_role = ANY (ARRAY['user'::text, 'assistant'::text, 'tool'::text, 'system'::text, 'imported'::text]))),
    CONSTRAINT events_producer_sequence_non_negative CHECK ((producer_sequence >= 0)),
    CONSTRAINT events_project_store_requires_owner CHECK (((store_kind <> 'project'::text) OR (project_key IS NOT NULL))),
    CONSTRAINT events_store_kind_vocabulary CHECK ((store_kind = ANY (ARRAY['global'::text, 'project'::text])))
);


--
-- Name: evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evidence (
    evidence_key text NOT NULL,
    scope_key text NOT NULL,
    evidence_kind text NOT NULL,
    origin_event_key text,
    object_key text,
    source_anchor jsonb NOT NULL,
    CONSTRAINT evidence_requires_an_anchor CHECK (((origin_event_key IS NOT NULL) OR (object_key IS NOT NULL)))
);


--
-- Name: feedback; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.feedback (
    feedback_key text NOT NULL,
    memory_key text NOT NULL,
    revision bigint NOT NULL,
    author_event_key text NOT NULL,
    action text NOT NULL,
    reason text NOT NULL,
    disposition text NOT NULL,
    CONSTRAINT feedback_action_vocabulary CHECK ((action = ANY (ARRAY['dispute'::text, 'useful'::text, 'irrelevant'::text]))),
    CONSTRAINT feedback_disposition_vocabulary CHECK ((disposition = ANY (ARRAY['open'::text, 'resolved'::text, 'withdrawn'::text])))
);


--
-- Name: idempotency_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.idempotency_receipts (
    receipt_id text NOT NULL,
    idempotency_key text NOT NULL,
    request_digest text NOT NULL,
    memory_key text,
    revision bigint,
    committed_at timestamp with time zone NOT NULL,
    installation_key text NOT NULL,
    actor_principal_id text NOT NULL,
    CONSTRAINT idempotency_receipts_outcome_complete CHECK (((memory_key IS NULL) = (revision IS NULL)))
);


--
-- Name: installations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.installations (
    installation_key text NOT NULL
);


--
-- Name: memories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memories (
    memory_key text NOT NULL,
    scope_key text NOT NULL,
    store_kind text NOT NULL,
    project_key text,
    origin_project_key text,
    category text,
    current_revision bigint NOT NULL,
    CONSTRAINT memories_category_vocabulary CHECK (((category IS NULL) OR (category = ANY (ARRAY['coding_style'::text, 'engineering_decision'::text, 'architecture'::text, 'preferred_library'::text])))),
    CONSTRAINT memories_current_revision_at_least_one CHECK ((current_revision >= 1)),
    CONSTRAINT memories_one_destination CHECK ((((store_kind = 'global'::text) AND (project_key IS NULL)) OR ((store_kind = 'project'::text) AND (project_key IS NOT NULL)))),
    CONSTRAINT memories_store_kind_vocabulary CHECK ((store_kind = ANY (ARRAY['global'::text, 'project'::text])))
);


--
-- Name: memory_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_evidence (
    memory_key text NOT NULL,
    revision bigint NOT NULL,
    evidence_key text NOT NULL,
    relation text NOT NULL,
    CONSTRAINT memory_evidence_relation_vocabulary CHECK ((relation = ANY (ARRAY['supports'::text, 'contradicts'::text, 'context'::text])))
);


--
-- Name: memory_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_revisions (
    memory_key text NOT NULL,
    revision bigint NOT NULL,
    kind text NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    lifecycle text NOT NULL,
    authority text NOT NULL,
    author_event_key text NOT NULL,
    author_agent_key text,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone,
    recorded_at timestamp with time zone NOT NULL,
    CONSTRAINT memory_revisions_authority_vocabulary CHECK ((authority = ANY (ARRAY['user'::text, 'assistant'::text, 'tool'::text, 'system'::text, 'imported'::text]))),
    CONSTRAINT memory_revisions_kind_vocabulary CHECK ((kind = ANY (ARRAY['decision'::text, 'constraint'::text, 'correction'::text, 'attempt'::text, 'observation'::text, 'procedure'::text, 'task_checkpoint'::text]))),
    CONSTRAINT memory_revisions_lifecycle_vocabulary CHECK ((lifecycle = ANY (ARRAY['proposed'::text, 'active'::text, 'superseded'::text, 'retracted'::text]))),
    CONSTRAINT memory_revisions_revision_at_least_one CHECK ((revision >= 1)),
    CONSTRAINT memory_revisions_validity_interval_ordered CHECK (((valid_until IS NULL) OR (valid_until > valid_from)))
);


--
-- Name: memory_search_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_search_documents (
    id bigint NOT NULL,
    memory_key text NOT NULL,
    revision bigint NOT NULL,
    store_kind text NOT NULL,
    project_key text,
    title text NOT NULL,
    body text NOT NULL,
    lifecycle text NOT NULL,
    CONSTRAINT memory_search_documents_lifecycle_vocabulary CHECK ((lifecycle = ANY (ARRAY['proposed'::text, 'active'::text, 'superseded'::text, 'retracted'::text])))
);


--
-- Name: memory_search_documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.memory_search_documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: memory_search_documents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.memory_search_documents_id_seq OWNED BY public.memory_search_documents.id;


--
-- Name: outbox_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbox_events (
    outbox_event_id text NOT NULL,
    work_key text NOT NULL,
    event_type text NOT NULL,
    payload jsonb NOT NULL,
    project_key text,
    dispatch_state text NOT NULL,
    recorded_at timestamp with time zone NOT NULL,
    CONSTRAINT outbox_events_dispatch_state_vocabulary CHECK ((dispatch_state = ANY (ARRAY['pending'::text, 'dispatched'::text, 'completed'::text])))
);


--
-- Name: projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projects (
    project_key text NOT NULL,
    display_name text NOT NULL,
    lifecycle text DEFAULT 'active'::text NOT NULL,
    CONSTRAINT projects_lifecycle_vocabulary CHECK ((lifecycle = ANY (ARRAY['active'::text, 'archived'::text])))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: scopes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scopes (
    scope_key text NOT NULL,
    installation_key text NOT NULL,
    scope_kind text NOT NULL,
    project_key text,
    subject_key text NOT NULL,
    CONSTRAINT scopes_global_owns_no_project CHECK (((scope_kind <> 'global'::text) OR (project_key IS NULL))),
    CONSTRAINT scopes_kind_vocabulary CHECK ((scope_kind = ANY (ARRAY['global'::text, 'project'::text, 'installation'::text, 'repository'::text, 'worktree'::text, 'task'::text]))),
    CONSTRAINT scopes_project_requires_owner CHECK (((scope_kind <> 'project'::text) OR (project_key IS NOT NULL)))
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    session_key text NOT NULL,
    installation_key text NOT NULL,
    provider_session_id text NOT NULL
);


--
-- Name: source_objects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.source_objects (
    object_key text NOT NULL,
    content_hash text NOT NULL,
    hash_algorithm text DEFAULT 'sha256'::text NOT NULL,
    byte_length bigint NOT NULL,
    availability text NOT NULL,
    stored_at timestamp with time zone NOT NULL,
    CONSTRAINT source_objects_availability_vocabulary CHECK ((availability = ANY (ARRAY['available'::text, 'purged'::text]))),
    CONSTRAINT source_objects_byte_length_non_negative CHECK ((byte_length >= 0))
);


--
-- Name: memory_search_documents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_search_documents ALTER COLUMN id SET DEFAULT nextval('public.memory_search_documents_id_seq'::regclass);


--
-- Name: agents agents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_pkey PRIMARY KEY (agent_key);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (event_key);


--
-- Name: evidence evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT evidence_pkey PRIMARY KEY (evidence_key);


--
-- Name: feedback feedback_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feedback
    ADD CONSTRAINT feedback_pkey PRIMARY KEY (feedback_key);


--
-- Name: idempotency_receipts idempotency_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.idempotency_receipts
    ADD CONSTRAINT idempotency_receipts_pkey PRIMARY KEY (receipt_id);


--
-- Name: installations installations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.installations
    ADD CONSTRAINT installations_pkey PRIMARY KEY (installation_key);


--
-- Name: memories memories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories
    ADD CONSTRAINT memories_pkey PRIMARY KEY (memory_key);


--
-- Name: memory_evidence memory_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_evidence
    ADD CONSTRAINT memory_evidence_pkey PRIMARY KEY (memory_key, revision, evidence_key, relation);


--
-- Name: memory_revisions memory_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_revisions
    ADD CONSTRAINT memory_revisions_pkey PRIMARY KEY (memory_key, revision);


--
-- Name: memory_search_documents memory_search_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_search_documents
    ADD CONSTRAINT memory_search_documents_pkey PRIMARY KEY (id);


--
-- Name: outbox_events outbox_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_events
    ADD CONSTRAINT outbox_events_pkey PRIMARY KEY (outbox_event_id);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (project_key);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: scopes scopes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scopes
    ADD CONSTRAINT scopes_pkey PRIMARY KEY (scope_key);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (session_key);


--
-- Name: source_objects source_objects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_objects
    ADD CONSTRAINT source_objects_pkey PRIMARY KEY (object_key);


--
-- Name: agents_provider_identity_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agents_provider_identity_unique ON public.agents USING btree (session_key, provider_agent_id);


--
-- Name: events_producer_sequence_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX events_producer_sequence_unique ON public.events USING btree (installation_key, producer_key, producer_epoch, producer_sequence);


--
-- Name: events_tool_join; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX events_tool_join ON public.events USING btree (session_key, tool_use_id, event_type);


--
-- Name: feedback_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX feedback_target ON public.feedback USING btree (memory_key, revision, action, disposition);


--
-- Name: idempotency_receipts_actor_key_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idempotency_receipts_actor_key_unique ON public.idempotency_receipts USING btree (installation_key, actor_principal_id, idempotency_key);


--
-- Name: idempotency_receipts_outcome; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idempotency_receipts_outcome ON public.idempotency_receipts USING btree (memory_key, revision);


--
-- Name: index_agents_on_parent_agent_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agents_on_parent_agent_key ON public.agents USING btree (parent_agent_key);


--
-- Name: index_events_on_agent_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_agent_key ON public.events USING btree (agent_key);


--
-- Name: index_events_on_payload_object_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_payload_object_key ON public.events USING btree (payload_object_key);


--
-- Name: index_events_on_project_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_events_on_project_key ON public.events USING btree (project_key);


--
-- Name: index_evidence_on_object_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_evidence_on_object_key ON public.evidence USING btree (object_key);


--
-- Name: index_evidence_on_origin_event_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_evidence_on_origin_event_key ON public.evidence USING btree (origin_event_key);


--
-- Name: index_evidence_on_scope_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_evidence_on_scope_key ON public.evidence USING btree (scope_key);


--
-- Name: index_feedback_on_author_event_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_feedback_on_author_event_key ON public.feedback USING btree (author_event_key);


--
-- Name: index_memories_on_origin_project_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memories_on_origin_project_key ON public.memories USING btree (origin_project_key);


--
-- Name: index_memories_on_project_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memories_on_project_key ON public.memories USING btree (project_key);


--
-- Name: index_memories_on_scope_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memories_on_scope_key ON public.memories USING btree (scope_key);


--
-- Name: index_memory_revisions_on_author_agent_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_revisions_on_author_agent_key ON public.memory_revisions USING btree (author_agent_key);


--
-- Name: index_memory_revisions_on_author_event_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_revisions_on_author_event_key ON public.memory_revisions USING btree (author_event_key);


--
-- Name: index_memory_search_documents_on_memory_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memory_search_documents_on_memory_key ON public.memory_search_documents USING btree (memory_key);


--
-- Name: index_memory_search_documents_on_project_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memory_search_documents_on_project_key ON public.memory_search_documents USING btree (project_key);


--
-- Name: index_outbox_events_on_project_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_outbox_events_on_project_key ON public.outbox_events USING btree (project_key);


--
-- Name: index_outbox_events_on_work_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_outbox_events_on_work_key ON public.outbox_events USING btree (work_key);


--
-- Name: index_scopes_on_project_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_scopes_on_project_key ON public.scopes USING btree (project_key);


--
-- Name: index_source_objects_on_content_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_source_objects_on_content_hash ON public.source_objects USING btree (content_hash);


--
-- Name: memories_head_reference; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memories_head_reference ON public.memories USING btree (memory_key, current_revision);


--
-- Name: memory_evidence_reverse; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memory_evidence_reverse ON public.memory_evidence USING btree (evidence_key);


--
-- Name: memory_search_documents_bm25; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memory_search_documents_bm25 ON public.memory_search_documents USING bm25 (id, title, body) WITH (key_field=id);


--
-- Name: memory_search_documents_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memory_search_documents_revision ON public.memory_search_documents USING btree (memory_key, revision);


--
-- Name: one_main_agent_per_session; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX one_main_agent_per_session ON public.agents USING btree (session_key) WHERE (agent_kind = 'main'::text);


--
-- Name: scopes_subject_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scopes_subject_unique ON public.scopes USING btree (installation_key, scope_kind, subject_key);


--
-- Name: sessions_provider_identity_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sessions_provider_identity_unique ON public.sessions USING btree (installation_key, provider_session_id);


--
-- Name: memory_revisions memory_revisions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memory_revisions_append_only BEFORE DELETE OR UPDATE ON public.memory_revisions FOR EACH ROW EXECUTE FUNCTION public.kioku_reject_revision_mutation();


--
-- Name: feedback fk_rails_00093ab6f6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feedback
    ADD CONSTRAINT fk_rails_00093ab6f6 FOREIGN KEY (author_event_key) REFERENCES public.events(event_key);


--
-- Name: events fk_rails_023962438a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_023962438a FOREIGN KEY (installation_key) REFERENCES public.installations(installation_key);


--
-- Name: sessions fk_rails_071d0a3f07; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_071d0a3f07 FOREIGN KEY (installation_key) REFERENCES public.installations(installation_key);


--
-- Name: evidence fk_rails_196bd638e7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT fk_rails_196bd638e7 FOREIGN KEY (origin_event_key) REFERENCES public.events(event_key);


--
-- Name: memory_evidence fk_rails_24cc779b24; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_evidence
    ADD CONSTRAINT fk_rails_24cc779b24 FOREIGN KEY (memory_key, revision) REFERENCES public.memory_revisions(memory_key, revision);


--
-- Name: idempotency_receipts fk_rails_3110ede0d1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.idempotency_receipts
    ADD CONSTRAINT fk_rails_3110ede0d1 FOREIGN KEY (installation_key) REFERENCES public.installations(installation_key);


--
-- Name: events fk_rails_37a19935a7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_37a19935a7 FOREIGN KEY (agent_key) REFERENCES public.agents(agent_key);


--
-- Name: agents fk_rails_415ccdb70e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT fk_rails_415ccdb70e FOREIGN KEY (parent_agent_key) REFERENCES public.agents(agent_key);


--
-- Name: memories fk_rails_4c04c31f88; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories
    ADD CONSTRAINT fk_rails_4c04c31f88 FOREIGN KEY (origin_project_key) REFERENCES public.projects(project_key);


--
-- Name: events fk_rails_58df69ff3d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_58df69ff3d FOREIGN KEY (project_key) REFERENCES public.projects(project_key);


--
-- Name: idempotency_receipts fk_rails_5b40a1acfc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.idempotency_receipts
    ADD CONSTRAINT fk_rails_5b40a1acfc FOREIGN KEY (memory_key, revision) REFERENCES public.memory_revisions(memory_key, revision);


--
-- Name: memory_evidence fk_rails_618b3e07bf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_evidence
    ADD CONSTRAINT fk_rails_618b3e07bf FOREIGN KEY (evidence_key) REFERENCES public.evidence(evidence_key);


--
-- Name: agents fk_rails_704139f42d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT fk_rails_704139f42d FOREIGN KEY (session_key) REFERENCES public.sessions(session_key);


--
-- Name: feedback fk_rails_8f8ba8acb5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.feedback
    ADD CONSTRAINT fk_rails_8f8ba8acb5 FOREIGN KEY (memory_key, revision) REFERENCES public.memory_revisions(memory_key, revision);


--
-- Name: memory_revisions fk_rails_9e5be7d4b5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_revisions
    ADD CONSTRAINT fk_rails_9e5be7d4b5 FOREIGN KEY (memory_key) REFERENCES public.memories(memory_key);


--
-- Name: evidence fk_rails_a22d54517e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT fk_rails_a22d54517e FOREIGN KEY (object_key) REFERENCES public.source_objects(object_key);


--
-- Name: scopes fk_rails_a9d0095479; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scopes
    ADD CONSTRAINT fk_rails_a9d0095479 FOREIGN KEY (installation_key) REFERENCES public.installations(installation_key);


--
-- Name: memory_revisions fk_rails_ab9195ee1f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_revisions
    ADD CONSTRAINT fk_rails_ab9195ee1f FOREIGN KEY (author_agent_key) REFERENCES public.agents(agent_key);


--
-- Name: memories fk_rails_b91932076c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories
    ADD CONSTRAINT fk_rails_b91932076c FOREIGN KEY (scope_key) REFERENCES public.scopes(scope_key);


--
-- Name: memory_revisions fk_rails_b97506cc4d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_revisions
    ADD CONSTRAINT fk_rails_b97506cc4d FOREIGN KEY (author_event_key) REFERENCES public.events(event_key);


--
-- Name: evidence fk_rails_bb691790b8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT fk_rails_bb691790b8 FOREIGN KEY (scope_key) REFERENCES public.scopes(scope_key);


--
-- Name: memory_search_documents fk_rails_bca951676b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_search_documents
    ADD CONSTRAINT fk_rails_bca951676b FOREIGN KEY (project_key) REFERENCES public.projects(project_key);


--
-- Name: outbox_events fk_rails_d6f1c61f1c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_events
    ADD CONSTRAINT fk_rails_d6f1c61f1c FOREIGN KEY (project_key) REFERENCES public.projects(project_key);


--
-- Name: events fk_rails_e6b31b4d0c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_e6b31b4d0c FOREIGN KEY (payload_object_key) REFERENCES public.source_objects(object_key);


--
-- Name: events fk_rails_e85f480361; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT fk_rails_e85f480361 FOREIGN KEY (session_key) REFERENCES public.sessions(session_key);


--
-- Name: memories fk_rails_f426ffbcdc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories
    ADD CONSTRAINT fk_rails_f426ffbcdc FOREIGN KEY (project_key) REFERENCES public.projects(project_key);


--
-- Name: memory_search_documents fk_rails_f4961e528a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_search_documents
    ADD CONSTRAINT fk_rails_f4961e528a FOREIGN KEY (memory_key, revision) REFERENCES public.memory_revisions(memory_key, revision);


--
-- Name: scopes fk_rails_ffd4b0c07f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scopes
    ADD CONSTRAINT fk_rails_ffd4b0c07f FOREIGN KEY (project_key) REFERENCES public.projects(project_key);


--
-- Name: memories memories_head_revision_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories
    ADD CONSTRAINT memories_head_revision_fk FOREIGN KEY (memory_key, current_revision) REFERENCES public.memory_revisions(memory_key, revision) DEFERRABLE INITIALLY DEFERRED;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260915120012'),
('20260915120011'),
('20260915120010'),
('20260915120009'),
('20260915120008'),
('20260915120007'),
('20260915120006'),
('20260915120005'),
('20260915120004'),
('20260915120003'),
('20260915120002'),
('20260915120001');

