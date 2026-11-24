-- SPDX-License-Identifier: Apache-2.0
-- Fresh-volume bootstrap for extensions Postgres.
-- Replaces case-management-system-migrate for tazama-stack demo boots.
-- Schema and Prisma migration history captured from
-- tazamaorg/case-management-system-migrate:rc
-- (sha256:1b2a3e092848cc47d6acaf96b3f90ff091bdfa342b2ad8b337912f5df9fb0c6a),
-- 28 migrations through 20261026000000_rename_blacklist_to_blocklist.
-- Creates the empty flowable database; Flowable builds its own tables on startup.
-- DDL is skipped when public.alerts already exists. Seed inserts always run and are idempotent.

SELECT 'CREATE DATABASE flowable'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'flowable')\gexec

SELECT 'CREATE DATABASE tazama_cms'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'tazama_cms')\gexec

\connect tazama_cms

SELECT CASE WHEN to_regclass('public.alerts') IS NULL THEN 0 ELSE 1 END AS cms_schema_ready \gset
\if :cms_schema_ready
\echo CMS schema already present; skipping DDL
\else
--
-- PostgreSQL database dump
--

\restrict 6BoBf8JM6IFnqfSdVsYrSLYwrpRr14rAaH4rcwLy7TLzhDpy79jpEbB3objiKqz

-- Dumped from database version 18.6 (Debian 18.6-1.pgdg13+2)
-- Dumped by pg_dump version 18.6 (Debian 18.6-1.pgdg13+2)

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
-- Name: AssignmentRuleType; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."AssignmentRuleType" AS ENUM (
    'PRIORITY_BASED',
    'CASE_TYPE_BASED',
    'ROUND_ROBIN',
    'LOAD_BALANCED',
    'MANUAL'
);


--
-- Name: AssignmentType; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."AssignmentType" AS ENUM (
    'MANUAL',
    'AUTOMATIC',
    'OVERRIDE'
);


--
-- Name: AsyncTaskStatus; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."AsyncTaskStatus" AS ENUM (
    'PENDING',
    'PROCESSING',
    'COMPLETED',
    'FAILED',
    'CANCELLED'
);


--
-- Name: CaseCreationType; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."CaseCreationType" AS ENUM (
    'MANUAL',
    'AUTOMATIC_SYSTEM'
);


--
-- Name: CaseInvestigatorMembership; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."CaseInvestigatorMembership" AS ENUM (
    'LEAD',
    'OBSERVER'
);


--
-- Name: CaseStatus; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."CaseStatus" AS ENUM (
    'STATUS_00_DRAFT',
    'STATUS_01_PENDING_CASE_CREATION_APPROVAL',
    'STATUS_02_READY_FOR_ASSIGNMENT',
    'STATUS_03_RETURNED',
    'STATUS_10_ASSIGNED',
    'STATUS_20_IN_PROGRESS',
    'STATUS_21_SUSPENDED',
    'STATUS_22_PENDING_FINAL_APPROVAL',
    'STATUS_31_PENDING_CASE_REOPENING_APPROVAL',
    'STATUS_71_AUTOCLOSED_CONFIRMED',
    'STATUS_72_AUTOCLOSED_REFUTED',
    'STATUS_81_CLOSED_REFUTED',
    'STATUS_82_CLOSED_CONFIRMED',
    'STATUS_83_CLOSED_INCONCLUSIVE',
    'STATUS_99_ABANDONED'
);


--
-- Name: CaseType; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."CaseType" AS ENUM (
    'FRAUD',
    'AML',
    'FRAUD_AND_AML'
);


--
-- Name: DeliveryStatus; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."DeliveryStatus" AS ENUM (
    'PENDING',
    'SENT',
    'FAILED',
    'RETRYING',
    'PERMANENT_FAILURE'
);


--
-- Name: NotificationChannel; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."NotificationChannel" AS ENUM (
    'EMAIL',
    'IN_APP',
    'SMS',
    'DASHBOARD'
);


--
-- Name: NotificationType; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."NotificationType" AS ENUM (
    'TASK_ASSIGNED',
    'TASK_REASSIGNED',
    'TASK_UNASSIGNED',
    'TASK_DUE_SOON',
    'TASK_OVERDUE',
    'SLA_WARNING',
    'SLA_BREACH',
    'WORK_QUEUE_ADDED',
    'WORK_QUEUE_REMOVED'
);


--
-- Name: PredictionOutcome; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."PredictionOutcome" AS ENUM (
    'FALSE_POSITIVE',
    'TRUE_POSITIVE',
    'FALSE_NEGATIVE',
    'TRUE_NEGATIVE'
);


--
-- Name: Priority; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."Priority" AS ENUM (
    'LOW',
    'MEDIUM',
    'HIGH'
);


--
-- Name: ReportType; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."ReportType" AS ENUM (
    'SUMMARY',
    'DETAILED',
    'FINAL'
);


--
-- Name: SlaState; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."SlaState" AS ENUM (
    'ON_TRACK',
    'AT_RISK',
    'DUE_SOON',
    'BREACHED'
);


--
-- Name: TaskStatus; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."TaskStatus" AS ENUM (
    'STATUS_01_UNASSIGNED',
    'STATUS_10_ASSIGNED',
    'STATUS_20_IN_PROGRESS',
    'STATUS_30_COMPLETED',
    'STATUS_21_BLOCKED'
);


--
-- Name: TaskType; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."TaskType" AS ENUM (
    'INVESTIGATION',
    'APPROVAL',
    'REVIEW',
    'EVIDENCE_COLLECTION',
    'REPORT_GENERATION',
    'CASE_CLOSURE',
    'ESCALATION',
    'SAR_STR_FILING'
);


--
-- Name: UserRole; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public."UserRole" AS ENUM (
    'ADMIN',
    'INVESTIGATOR',
    'SUPERVISOR',
    'ANALYST'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: TransactionProfile; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."TransactionProfile" (
    profile_id text NOT NULL,
    case_id integer NOT NULL,
    generated_by uuid NOT NULL,
    generated_at timestamp(3) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    filters jsonb,
    metrics jsonb,
    outliers jsonb,
    summary_table jsonb,
    notes text,
    visualization text,
    detected_anomalies jsonb
);


--
-- Name: _prisma_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public._prisma_migrations (
    id character varying(36) NOT NULL,
    checksum character varying(64) NOT NULL,
    finished_at timestamp with time zone,
    migration_name character varying(255) NOT NULL,
    logs text,
    rolled_back_at timestamp with time zone,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    applied_steps_count integer DEFAULT 0 NOT NULL
);


--
-- Name: alerts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.alerts (
    alert_id integer NOT NULL,
    tenant_id text NOT NULL,
    priority public."Priority" DEFAULT 'LOW'::public."Priority",
    priority_score double precision,
    alert_type public."CaseType",
    prediction_outcome public."PredictionOutcome" DEFAULT 'TRUE_POSITIVE'::public."PredictionOutcome",
    source character varying(50),
    txtp character varying(50) NOT NULL,
    message character varying(100) NOT NULL,
    alert_data jsonb NOT NULL,
    transaction jsonb NOT NULL,
    network_map jsonb NOT NULL,
    confidence_per integer NOT NULL,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    case_id integer,
    updated_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    msg_id character varying(140),
    orgnl_end_to_end_id character varying(140),
    orgnl_instr_id character varying(140),
    dbtr_acct_id character varying(140),
    cdtr_acct_id character varying(140)
);


--
-- Name: alerts_alert_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.alerts_alert_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: alerts_alert_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.alerts_alert_id_seq OWNED BY public.alerts.alert_id;


--
-- Name: async_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.async_tasks (
    task_id integer NOT NULL,
    task_type character varying(50) NOT NULL,
    status public."AsyncTaskStatus" DEFAULT 'PENDING'::public."AsyncTaskStatus" NOT NULL,
    payload jsonb NOT NULL,
    max_retries integer DEFAULT 5 NOT NULL,
    retry_count integer DEFAULT 0 NOT NULL,
    next_retry_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    created_by character varying(100)
);


--
-- Name: async_tasks_task_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.async_tasks_task_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: async_tasks_task_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.async_tasks_task_id_seq OWNED BY public.async_tasks.task_id;


--
-- Name: case_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_history (
    case_history_id integer NOT NULL,
    user_id uuid NOT NULL,
    operation character varying(50) NOT NULL,
    entity_name character varying(50) NOT NULL,
    action_performed character varying(1000) NOT NULL,
    case_id integer NOT NULL,
    performed_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    tenant_id text NOT NULL
);


--
-- Name: case_history_case_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.case_history_case_history_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: case_history_case_history_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.case_history_case_history_id_seq OWNED BY public.case_history.case_history_id;


--
-- Name: case_investigators; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_investigators (
    id integer NOT NULL,
    case_id integer NOT NULL,
    tenant_id text NOT NULL,
    user_id uuid NOT NULL,
    membership public."CaseInvestigatorMembership" DEFAULT 'OBSERVER'::public."CaseInvestigatorMembership" NOT NULL,
    granted_by uuid NOT NULL,
    granted_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    revoked_at timestamp(6) without time zone,
    revoked_by uuid,
    revoke_reason character varying(1000)
);


--
-- Name: case_investigators_blocklist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_investigators_blocklist (
    id integer CONSTRAINT case_investigators_blacklist_id_not_null NOT NULL,
    case_id integer CONSTRAINT case_investigators_blacklist_case_id_not_null NOT NULL,
    tenant_id text CONSTRAINT case_investigators_blacklist_tenant_id_not_null NOT NULL,
    user_id uuid CONSTRAINT case_investigators_blacklist_user_id_not_null NOT NULL,
    blocked_by uuid CONSTRAINT case_investigators_blacklist_blocked_by_not_null NOT NULL,
    blocked_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP CONSTRAINT case_investigators_blacklist_blocked_at_not_null NOT NULL,
    block_reason character varying(1000) CONSTRAINT case_investigators_blacklist_block_reason_not_null NOT NULL,
    unblocked_at timestamp(6) without time zone,
    unblocked_by uuid,
    unblock_reason character varying(1000)
);


--
-- Name: case_investigators_blocklist_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.case_investigators_blocklist_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: case_investigators_blocklist_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.case_investigators_blocklist_id_seq OWNED BY public.case_investigators_blocklist.id;


--
-- Name: case_investigators_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.case_investigators_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: case_investigators_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.case_investigators_id_seq OWNED BY public.case_investigators.id;


--
-- Name: case_priority_thresholds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_priority_thresholds (
    id integer NOT NULL,
    tenant_id text NOT NULL,
    high_threshold double precision NOT NULL,
    medium_threshold double precision NOT NULL,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: case_priority_thresholds_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.case_priority_thresholds_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: case_priority_thresholds_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.case_priority_thresholds_id_seq OWNED BY public.case_priority_thresholds.id;


--
-- Name: cases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cases (
    case_id integer NOT NULL,
    case_creator_user_id uuid NOT NULL,
    case_owner_user_id uuid,
    tenant_id text NOT NULL,
    status public."CaseStatus" NOT NULL,
    priority public."Priority" DEFAULT 'LOW'::public."Priority" NOT NULL,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    parent_id integer,
    case_type public."CaseType",
    case_creation_type public."CaseCreationType" NOT NULL,
    final_outcome public."CaseStatus",
    group_id integer,
    sla_due_at timestamp(6) without time zone,
    sla_started_at timestamp(6) without time zone
);


--
-- Name: cases_case_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cases_case_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cases_case_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cases_case_id_seq OWNED BY public.cases.case_id;


--
-- Name: cms_usernames; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cms_usernames (
    id integer NOT NULL,
    user_id uuid NOT NULL,
    tenant_id text NOT NULL,
    name text NOT NULL,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: cms_usernames_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cms_usernames_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cms_usernames_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cms_usernames_id_seq OWNED BY public.cms_usernames.id;


--
-- Name: comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.comments (
    comment_id integer NOT NULL,
    user_id uuid NOT NULL,
    tenant_id text NOT NULL,
    note text NOT NULL,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    case_id integer,
    task_id integer
);


--
-- Name: comments_comment_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.comments_comment_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: comments_comment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.comments_comment_id_seq OWNED BY public.comments.comment_id;


--
-- Name: configuration_change_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.configuration_change_logs (
    id integer NOT NULL,
    config_id integer NOT NULL,
    config_key text NOT NULL,
    old_value jsonb,
    new_value jsonb NOT NULL,
    change_type text NOT NULL,
    changed_by text NOT NULL,
    change_reason text,
    ip_address text,
    user_agent text,
    requires_2fa boolean DEFAULT false NOT NULL,
    approved_by text,
    approval_date timestamp(3) without time zone,
    change_status text NOT NULL,
    created_at timestamp(3) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: configuration_change_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.configuration_change_logs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: configuration_change_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.configuration_change_logs_id_seq OWNED BY public.configuration_change_logs.id;


--
-- Name: event_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_log (
    event_log_id integer NOT NULL,
    user_id uuid NOT NULL,
    operation character varying(50) NOT NULL,
    entity_name character varying(50) NOT NULL,
    action_performed character varying(1000) NOT NULL,
    outcome character varying(255) NOT NULL,
    performed_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    tenant_id text NOT NULL
);


--
-- Name: event_log_event_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.event_log_event_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: event_log_event_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.event_log_event_log_id_seq OWNED BY public.event_log.event_log_id;


--
-- Name: evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evidence (
    evidence_id character varying(255) NOT NULL,
    task_id integer NOT NULL,
    case_id integer NOT NULL,
    uploader_user_id uuid NOT NULL,
    tenant_id text NOT NULL,
    name character varying(255) NOT NULL,
    description character varying(1000),
    type character varying(50) NOT NULL,
    file_path text NOT NULL,
    file_size bigint,
    file_type character varying(255),
    evidence_hash text NOT NULL,
    metadata jsonb,
    uploaded_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: filters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.filters (
    "filter_Id" integer NOT NULL,
    "user_Id" uuid NOT NULL,
    filter_type character varying(50) NOT NULL,
    user_filters text NOT NULL,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: filters_filter_Id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public."filters_filter_Id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: filters_filter_Id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public."filters_filter_Id_seq" OWNED BY public.filters."filter_Id";


--
-- Name: integration_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_configs (
    id integer NOT NULL,
    system_name text NOT NULL,
    endpoint_url text,
    api_key text,
    api_secret text,
    config_data jsonb,
    auth_type text,
    is_enabled boolean DEFAULT true NOT NULL,
    last_tested_at timestamp(3) without time zone,
    test_status text,
    created_by text NOT NULL,
    updated_by text NOT NULL,
    created_at timestamp(3) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: integration_configs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.integration_configs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: integration_configs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.integration_configs_id_seq OWNED BY public.integration_configs.id;


--
-- Name: investigation_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.investigation_groups (
    id integer NOT NULL,
    alert_id integer NOT NULL,
    tenant_id text NOT NULL,
    created_at timestamp(3) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: investigation_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.investigation_groups_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: investigation_groups_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.investigation_groups_id_seq OWNED BY public.investigation_groups.id;


--
-- Name: notification_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_logs (
    notification_log_id integer NOT NULL,
    user_id uuid NOT NULL,
    tenant_id text NOT NULL,
    task_id integer,
    case_id integer,
    notification_type public."NotificationType" NOT NULL,
    channel public."NotificationChannel" NOT NULL,
    delivery_status public."DeliveryStatus" DEFAULT 'PENDING'::public."DeliveryStatus" NOT NULL,
    retry_count integer DEFAULT 0 NOT NULL,
    max_retries integer DEFAULT 5 NOT NULL,
    payload jsonb NOT NULL,
    error_message text,
    sent_at timestamp(6) without time zone,
    read_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: notification_logs_notification_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notification_logs_notification_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notification_logs_notification_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notification_logs_notification_log_id_seq OWNED BY public.notification_logs.notification_log_id;


--
-- Name: reference_ids; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reference_ids (
    id integer NOT NULL,
    "txTp" character varying(50) NOT NULL,
    "referenceIdName" character varying(50) NOT NULL,
    "createdAt" timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    tenant_id text
);


--
-- Name: reference_ids_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reference_ids_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reference_ids_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reference_ids_id_seq OWNED BY public.reference_ids.id;


--
-- Name: reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reports (
    report_id integer NOT NULL,
    task_id integer NOT NULL,
    name text NOT NULL,
    report_type public."ReportType" NOT NULL,
    report_file_path text NOT NULL,
    report_hash character varying(255) NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    locked boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: reports_report_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reports_report_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reports_report_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reports_report_id_seq OWNED BY public.reports.report_id;


--
-- Name: role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_permissions (
    id integer NOT NULL,
    role_name text NOT NULL,
    permissions jsonb NOT NULL,
    description text,
    is_system_role boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by text NOT NULL,
    updated_by text NOT NULL,
    created_at timestamp(3) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL
);


--
-- Name: role_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.role_permissions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: role_permissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.role_permissions_id_seq OWNED BY public.role_permissions.id;


--
-- Name: sla_escalation_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sla_escalation_records (
    id integer NOT NULL,
    case_id integer NOT NULL,
    sla_state public."SlaState" NOT NULL,
    notified_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    tenant_id text NOT NULL
);


--
-- Name: sla_escalation_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sla_escalation_records_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sla_escalation_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sla_escalation_records_id_seq OWNED BY public.sla_escalation_records.id;


--
-- Name: sla_escalation_thresholds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sla_escalation_thresholds (
    id integer NOT NULL,
    tenant_id text NOT NULL,
    due_soon_ratio double precision NOT NULL,
    at_risk_ratio double precision NOT NULL,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: sla_escalation_thresholds_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sla_escalation_thresholds_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sla_escalation_thresholds_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sla_escalation_thresholds_id_seq OWNED BY public.sla_escalation_thresholds.id;


--
-- Name: sla_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sla_policies (
    id integer NOT NULL,
    tenant_id text NOT NULL,
    priority public."Priority" NOT NULL,
    target_seconds integer CONSTRAINT sla_policies_target_hours_not_null NOT NULL,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: sla_policies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sla_policies_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sla_policies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sla_policies_id_seq OWNED BY public.sla_policies.id;


--
-- Name: system_configurations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_configurations (
    id integer NOT NULL,
    config_key text NOT NULL,
    config_value jsonb NOT NULL,
    config_type text NOT NULL,
    description text,
    is_active boolean DEFAULT true NOT NULL,
    created_by text NOT NULL,
    updated_by text NOT NULL,
    created_at timestamp(3) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    version integer DEFAULT 1 NOT NULL
);


--
-- Name: system_configurations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.system_configurations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: system_configurations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.system_configurations_id_seq OWNED BY public.system_configurations.id;


--
-- Name: task_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_history (
    task_history_id integer NOT NULL,
    user_id uuid NOT NULL,
    operation character varying(50) NOT NULL,
    entity_name character varying(50) NOT NULL,
    action_performed character varying(1000) NOT NULL,
    case_id integer NOT NULL,
    task_id integer NOT NULL,
    performed_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    tenant_id text NOT NULL
);


--
-- Name: task_history_task_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.task_history_task_history_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: task_history_task_history_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.task_history_task_history_id_seq OWNED BY public.task_history.task_history_id;


--
-- Name: tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tasks (
    task_id integer NOT NULL,
    case_id integer NOT NULL,
    tenant_id text NOT NULL,
    status public."TaskStatus" DEFAULT 'STATUS_01_UNASSIGNED'::public."TaskStatus" NOT NULL,
    assigned_user_id uuid,
    name text,
    description text,
    "investigationNotes" text,
    task_type public."TaskType",
    "candidateGroup" character varying(50),
    sla_deadline timestamp(6) without time zone,
    sla_duration_hours integer,
    completed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: tasks_task_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tasks_task_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tasks_task_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tasks_task_id_seq OWNED BY public.tasks.task_id;


--
-- Name: transaction_data; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.transaction_data (
    "transactionId" integer NOT NULL,
    "tenantId" text NOT NULL,
    "endToEndId" character varying(50) NOT NULL,
    "transactionData" jsonb NOT NULL,
    "createdAt" timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: transaction_data_transactionId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public."transaction_data_transactionId_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: transaction_data_transactionId_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public."transaction_data_transactionId_seq" OWNED BY public.transaction_data."transactionId";


--
-- Name: user_notification_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_notification_preferences (
    preference_id integer NOT NULL,
    user_id uuid NOT NULL,
    tenant_id text NOT NULL,
    email_enabled boolean DEFAULT true NOT NULL,
    in_app_enabled boolean DEFAULT true NOT NULL,
    sms_enabled boolean DEFAULT false NOT NULL,
    dashboard_enabled boolean DEFAULT true NOT NULL,
    phone_number character varying(20),
    suppression_settings jsonb,
    default_channel public."NotificationChannel" DEFAULT 'EMAIL'::public."NotificationChannel" NOT NULL,
    created_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: user_notification_preferences_preference_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_notification_preferences_preference_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_notification_preferences_preference_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_notification_preferences_preference_id_seq OWNED BY public.user_notification_preferences.preference_id;


--
-- Name: alerts alert_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts ALTER COLUMN alert_id SET DEFAULT nextval('public.alerts_alert_id_seq'::regclass);


--
-- Name: async_tasks task_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.async_tasks ALTER COLUMN task_id SET DEFAULT nextval('public.async_tasks_task_id_seq'::regclass);


--
-- Name: case_history case_history_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_history ALTER COLUMN case_history_id SET DEFAULT nextval('public.case_history_case_history_id_seq'::regclass);


--
-- Name: case_investigators id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_investigators ALTER COLUMN id SET DEFAULT nextval('public.case_investigators_id_seq'::regclass);


--
-- Name: case_investigators_blocklist id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_investigators_blocklist ALTER COLUMN id SET DEFAULT nextval('public.case_investigators_blocklist_id_seq'::regclass);


--
-- Name: case_priority_thresholds id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_priority_thresholds ALTER COLUMN id SET DEFAULT nextval('public.case_priority_thresholds_id_seq'::regclass);


--
-- Name: cases case_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cases ALTER COLUMN case_id SET DEFAULT nextval('public.cases_case_id_seq'::regclass);


--
-- Name: cms_usernames id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cms_usernames ALTER COLUMN id SET DEFAULT nextval('public.cms_usernames_id_seq'::regclass);


--
-- Name: comments comment_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments ALTER COLUMN comment_id SET DEFAULT nextval('public.comments_comment_id_seq'::regclass);


--
-- Name: configuration_change_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_change_logs ALTER COLUMN id SET DEFAULT nextval('public.configuration_change_logs_id_seq'::regclass);


--
-- Name: event_log event_log_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_log ALTER COLUMN event_log_id SET DEFAULT nextval('public.event_log_event_log_id_seq'::regclass);


--
-- Name: filters filter_Id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filters ALTER COLUMN "filter_Id" SET DEFAULT nextval('public."filters_filter_Id_seq"'::regclass);


--
-- Name: integration_configs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_configs ALTER COLUMN id SET DEFAULT nextval('public.integration_configs_id_seq'::regclass);


--
-- Name: investigation_groups id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investigation_groups ALTER COLUMN id SET DEFAULT nextval('public.investigation_groups_id_seq'::regclass);


--
-- Name: notification_logs notification_log_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_logs ALTER COLUMN notification_log_id SET DEFAULT nextval('public.notification_logs_notification_log_id_seq'::regclass);


--
-- Name: reference_ids id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reference_ids ALTER COLUMN id SET DEFAULT nextval('public.reference_ids_id_seq'::regclass);


--
-- Name: reports report_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports ALTER COLUMN report_id SET DEFAULT nextval('public.reports_report_id_seq'::regclass);


--
-- Name: role_permissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions ALTER COLUMN id SET DEFAULT nextval('public.role_permissions_id_seq'::regclass);


--
-- Name: sla_escalation_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_escalation_records ALTER COLUMN id SET DEFAULT nextval('public.sla_escalation_records_id_seq'::regclass);


--
-- Name: sla_escalation_thresholds id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_escalation_thresholds ALTER COLUMN id SET DEFAULT nextval('public.sla_escalation_thresholds_id_seq'::regclass);


--
-- Name: sla_policies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_policies ALTER COLUMN id SET DEFAULT nextval('public.sla_policies_id_seq'::regclass);


--
-- Name: system_configurations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_configurations ALTER COLUMN id SET DEFAULT nextval('public.system_configurations_id_seq'::regclass);


--
-- Name: task_history task_history_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_history ALTER COLUMN task_history_id SET DEFAULT nextval('public.task_history_task_history_id_seq'::regclass);


--
-- Name: tasks task_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks ALTER COLUMN task_id SET DEFAULT nextval('public.tasks_task_id_seq'::regclass);


--
-- Name: transaction_data transactionId; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transaction_data ALTER COLUMN "transactionId" SET DEFAULT nextval('public."transaction_data_transactionId_seq"'::regclass);


--
-- Name: user_notification_preferences preference_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_notification_preferences ALTER COLUMN preference_id SET DEFAULT nextval('public.user_notification_preferences_preference_id_seq'::regclass);


--
-- Name: TransactionProfile TransactionProfile_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."TransactionProfile"
    ADD CONSTRAINT "TransactionProfile_pkey" PRIMARY KEY (profile_id);


--
-- Name: _prisma_migrations _prisma_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public._prisma_migrations
    ADD CONSTRAINT _prisma_migrations_pkey PRIMARY KEY (id);


--
-- Name: alerts alerts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT alerts_pkey PRIMARY KEY (alert_id);


--
-- Name: async_tasks async_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.async_tasks
    ADD CONSTRAINT async_tasks_pkey PRIMARY KEY (task_id);


--
-- Name: case_history case_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_history
    ADD CONSTRAINT case_history_pkey PRIMARY KEY (case_history_id);


--
-- Name: case_investigators_blocklist case_investigators_blocklist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_investigators_blocklist
    ADD CONSTRAINT case_investigators_blocklist_pkey PRIMARY KEY (id);


--
-- Name: case_investigators case_investigators_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_investigators
    ADD CONSTRAINT case_investigators_pkey PRIMARY KEY (id);


--
-- Name: case_priority_thresholds case_priority_thresholds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_priority_thresholds
    ADD CONSTRAINT case_priority_thresholds_pkey PRIMARY KEY (id);


--
-- Name: cases cases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cases
    ADD CONSTRAINT cases_pkey PRIMARY KEY (case_id);


--
-- Name: cms_usernames cms_usernames_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cms_usernames
    ADD CONSTRAINT cms_usernames_pkey PRIMARY KEY (id);


--
-- Name: comments comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_pkey PRIMARY KEY (comment_id);


--
-- Name: configuration_change_logs configuration_change_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configuration_change_logs
    ADD CONSTRAINT configuration_change_logs_pkey PRIMARY KEY (id);


--
-- Name: event_log event_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_log
    ADD CONSTRAINT event_log_pkey PRIMARY KEY (event_log_id);


--
-- Name: evidence evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT evidence_pkey PRIMARY KEY (evidence_id);


--
-- Name: filters filters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filters
    ADD CONSTRAINT filters_pkey PRIMARY KEY ("filter_Id");


--
-- Name: integration_configs integration_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_configs
    ADD CONSTRAINT integration_configs_pkey PRIMARY KEY (id);


--
-- Name: investigation_groups investigation_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investigation_groups
    ADD CONSTRAINT investigation_groups_pkey PRIMARY KEY (id);


--
-- Name: notification_logs notification_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_logs
    ADD CONSTRAINT notification_logs_pkey PRIMARY KEY (notification_log_id);


--
-- Name: reference_ids reference_ids_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reference_ids
    ADD CONSTRAINT reference_ids_pkey PRIMARY KEY (id);


--
-- Name: reports reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_pkey PRIMARY KEY (report_id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (id);


--
-- Name: sla_escalation_records sla_escalation_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_escalation_records
    ADD CONSTRAINT sla_escalation_records_pkey PRIMARY KEY (id);


--
-- Name: sla_escalation_thresholds sla_escalation_thresholds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_escalation_thresholds
    ADD CONSTRAINT sla_escalation_thresholds_pkey PRIMARY KEY (id);


--
-- Name: sla_policies sla_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT sla_policies_pkey PRIMARY KEY (id);


--
-- Name: system_configurations system_configurations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_configurations
    ADD CONSTRAINT system_configurations_pkey PRIMARY KEY (id);


--
-- Name: task_history task_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_history
    ADD CONSTRAINT task_history_pkey PRIMARY KEY (task_history_id);


--
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (task_id);


--
-- Name: transaction_data transaction_data_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transaction_data
    ADD CONSTRAINT transaction_data_pkey PRIMARY KEY ("transactionId");


--
-- Name: user_notification_preferences user_notification_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_notification_preferences
    ADD CONSTRAINT user_notification_preferences_pkey PRIMARY KEY (preference_id);


--
-- Name: alerts_case_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX alerts_case_id_key ON public.alerts USING btree (case_id);


--
-- Name: alerts_cdtr_acct_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX alerts_cdtr_acct_id_idx ON public.alerts USING btree (cdtr_acct_id);


--
-- Name: alerts_dbtr_acct_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX alerts_dbtr_acct_id_idx ON public.alerts USING btree (dbtr_acct_id);


--
-- Name: alerts_msg_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX alerts_msg_id_idx ON public.alerts USING btree (msg_id);


--
-- Name: alerts_orgnl_end_to_end_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX alerts_orgnl_end_to_end_id_idx ON public.alerts USING btree (orgnl_end_to_end_id);


--
-- Name: alerts_orgnl_instr_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX alerts_orgnl_instr_id_idx ON public.alerts USING btree (orgnl_instr_id);


--
-- Name: async_tasks_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX async_tasks_created_at_idx ON public.async_tasks USING btree (created_at);


--
-- Name: async_tasks_next_retry_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX async_tasks_next_retry_at_idx ON public.async_tasks USING btree (next_retry_at);


--
-- Name: async_tasks_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX async_tasks_status_idx ON public.async_tasks USING btree (status);


--
-- Name: async_tasks_status_task_type_next_retry_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX async_tasks_status_task_type_next_retry_at_idx ON public.async_tasks USING btree (status, task_type, next_retry_at);


--
-- Name: async_tasks_task_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX async_tasks_task_type_idx ON public.async_tasks USING btree (task_type);


--
-- Name: case_investigators_blocklist_case_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_investigators_blocklist_case_id_user_id_idx ON public.case_investigators_blocklist USING btree (case_id, user_id);


--
-- Name: case_investigators_blocklist_case_id_user_id_live_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX case_investigators_blocklist_case_id_user_id_live_key ON public.case_investigators_blocklist USING btree (case_id, user_id) WHERE (unblocked_at IS NULL);


--
-- Name: case_investigators_blocklist_tenant_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_investigators_blocklist_tenant_id_idx ON public.case_investigators_blocklist USING btree (tenant_id);


--
-- Name: case_investigators_blocklist_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_investigators_blocklist_user_id_idx ON public.case_investigators_blocklist USING btree (user_id);


--
-- Name: case_investigators_case_id_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_investigators_case_id_user_id_idx ON public.case_investigators USING btree (case_id, user_id);


--
-- Name: case_investigators_case_id_user_id_live_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX case_investigators_case_id_user_id_live_key ON public.case_investigators USING btree (case_id, user_id) WHERE (revoked_at IS NULL);


--
-- Name: case_investigators_tenant_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_investigators_tenant_id_idx ON public.case_investigators USING btree (tenant_id);


--
-- Name: case_investigators_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_investigators_user_id_idx ON public.case_investigators USING btree (user_id);


--
-- Name: case_priority_thresholds_tenant_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX case_priority_thresholds_tenant_id_key ON public.case_priority_thresholds USING btree (tenant_id);


--
-- Name: cases_group_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cases_group_id_idx ON public.cases USING btree (group_id);


--
-- Name: cms_usernames_user_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cms_usernames_user_id_key ON public.cms_usernames USING btree (user_id);


--
-- Name: evidence_case_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX evidence_case_id_idx ON public.evidence USING btree (case_id);


--
-- Name: evidence_evidence_hash_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX evidence_evidence_hash_idx ON public.evidence USING btree (evidence_hash);


--
-- Name: integration_configs_system_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX integration_configs_system_name_key ON public.integration_configs USING btree (system_name);


--
-- Name: investigation_groups_alert_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX investigation_groups_alert_id_key ON public.investigation_groups USING btree (alert_id);


--
-- Name: notification_logs_case_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notification_logs_case_id_idx ON public.notification_logs USING btree (case_id);


--
-- Name: notification_logs_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notification_logs_created_at_idx ON public.notification_logs USING btree (created_at);


--
-- Name: notification_logs_delivery_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notification_logs_delivery_status_idx ON public.notification_logs USING btree (delivery_status);


--
-- Name: notification_logs_task_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notification_logs_task_id_idx ON public.notification_logs USING btree (task_id);


--
-- Name: notification_logs_user_id_notification_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notification_logs_user_id_notification_type_idx ON public.notification_logs USING btree (user_id, notification_type);


--
-- Name: notification_logs_user_id_read_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notification_logs_user_id_read_at_idx ON public.notification_logs USING btree (user_id, read_at);


--
-- Name: reference_ids_txTp_tenant_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX "reference_ids_txTp_tenant_id_key" ON public.reference_ids USING btree ("txTp", tenant_id);


--
-- Name: role_permissions_role_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX role_permissions_role_name_key ON public.role_permissions USING btree (role_name);


--
-- Name: sla_escalation_records_case_id_sla_state_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sla_escalation_records_case_id_sla_state_key ON public.sla_escalation_records USING btree (case_id, sla_state);


--
-- Name: sla_escalation_records_tenant_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sla_escalation_records_tenant_id_idx ON public.sla_escalation_records USING btree (tenant_id);


--
-- Name: sla_escalation_thresholds_tenant_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sla_escalation_thresholds_tenant_id_key ON public.sla_escalation_thresholds USING btree (tenant_id);


--
-- Name: sla_policies_tenant_id_priority_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sla_policies_tenant_id_priority_key ON public.sla_policies USING btree (tenant_id, priority);


--
-- Name: system_configurations_config_key_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX system_configurations_config_key_key ON public.system_configurations USING btree (config_key);


--
-- Name: tasks_assigned_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tasks_assigned_user_id_idx ON public.tasks USING btree (assigned_user_id);


--
-- Name: tasks_sla_deadline_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tasks_sla_deadline_idx ON public.tasks USING btree (sla_deadline);


--
-- Name: tasks_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tasks_status_idx ON public.tasks USING btree (status);


--
-- Name: user_notification_preferences_tenant_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_notification_preferences_tenant_id_idx ON public.user_notification_preferences USING btree (tenant_id);


--
-- Name: user_notification_preferences_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_notification_preferences_user_id_idx ON public.user_notification_preferences USING btree (user_id);


--
-- Name: user_notification_preferences_user_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_notification_preferences_user_id_key ON public.user_notification_preferences USING btree (user_id);


--
-- Name: TransactionProfile TransactionProfile_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."TransactionProfile"
    ADD CONSTRAINT "TransactionProfile_case_id_fkey" FOREIGN KEY (case_id) REFERENCES public.cases(case_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: alerts alerts_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alerts
    ADD CONSTRAINT alerts_case_id_fkey FOREIGN KEY (case_id) REFERENCES public.cases(case_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: case_investigators_blocklist case_investigators_blocklist_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_investigators_blocklist
    ADD CONSTRAINT case_investigators_blocklist_case_id_fkey FOREIGN KEY (case_id) REFERENCES public.cases(case_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: case_investigators case_investigators_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_investigators
    ADD CONSTRAINT case_investigators_case_id_fkey FOREIGN KEY (case_id) REFERENCES public.cases(case_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: cases cases_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cases
    ADD CONSTRAINT cases_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.investigation_groups(id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: comments comments_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_case_id_fkey FOREIGN KEY (case_id) REFERENCES public.cases(case_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: comments comments_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(task_id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: evidence evidence_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT evidence_case_id_fkey FOREIGN KEY (case_id) REFERENCES public.cases(case_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: evidence evidence_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence
    ADD CONSTRAINT evidence_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(task_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: investigation_groups investigation_groups_alert_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.investigation_groups
    ADD CONSTRAINT investigation_groups_alert_id_fkey FOREIGN KEY (alert_id) REFERENCES public.alerts(alert_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: reports reports_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(task_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: sla_escalation_records sla_escalation_records_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_escalation_records
    ADD CONSTRAINT sla_escalation_records_case_id_fkey FOREIGN KEY (case_id) REFERENCES public.cases(case_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: tasks tasks_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_case_id_fkey FOREIGN KEY (case_id) REFERENCES public.cases(case_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--

\unrestrict 6BoBf8JM6IFnqfSdVsYrSLYwrpRr14rAaH4rcwLy7TLzhDpy79jpEbB3objiKqz
--
-- PostgreSQL database dump
--

\restrict vZlvOcQZB25mYr4BKj2yHfHl64ZgW3VPx1mwrvE4ZAHqghVL1ufotmYT6oeimxt

-- Dumped from database version 18.6 (Debian 18.6-1.pgdg13+2)
-- Dumped by pg_dump version 18.6 (Debian 18.6-1.pgdg13+2)

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
-- Data for Name: _prisma_migrations; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('6ca9fd6a-311f-44a8-bab3-a378f5f77440', '2ce5a37866781b3c67aab68ba1d5b5af22caf3bc15bd1e94da0b3f0685f7a7db', '2026-11-12 20:23:24.60723+00', '20260213071958_add_tenant_id_to_tasks', NULL, NULL, '2026-11-12 20:23:24.477205+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('41c5c12b-96a9-4194-b44a-8afcdb6cd9ca', 'f23259b5faf10144f8204e43a8c31e67cb0b620811bfb2b4234dc5a36d37146b', '2026-11-12 20:23:25.26394+00', '20260702100100_priority_severity_drop_breach', NULL, NULL, '2026-11-12 20:23:25.220146+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('38f86ba5-e998-4cee-8b18-28bab03b1478', '96dae8ccf527ed2309f34382a821c29c00992468726573cc104a35072ed73818', '2026-11-12 20:23:24.644007+00', '20260216063017_tenant_isolation', NULL, NULL, '2026-11-12 20:23:24.610925+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('3fcc2dd6-f76c-4031-a141-212e688679b1', '51bfe5e661065567aef05dc7e14f716bd162095b9a640452f0947cc7a9d7e20b', '2026-11-12 20:23:24.704224+00', '20260219104518_history_logs', NULL, NULL, '2026-11-12 20:23:24.66966+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('438d6d9d-5fac-4018-afb0-9227a3665e2e', '8833a180bee061ac211c579189579c904d6d30d7f152feb981728f79c78b31ed', '2026-11-12 20:23:25.684244+00', '20260707120000_case_sla_started_at', NULL, NULL, '2026-11-12 20:23:25.647901+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('a81a6be3-2295-4771-9e74-96ab7ce41894', 'fcfe61cdedbf54d0780ce6d5c592c2a9683a9c13a520474bbf0fad5dfd68d4d0', '2026-11-12 20:23:24.768782+00', '20260416200412_final_outcome', NULL, NULL, '2026-11-12 20:23:24.708507+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('583575ff-d5cb-4512-ab07-79724cfe6126', 'cdc04489be50bcdea468f94499e5993bec2e65dceccbafc995cca7acbca371d0', '2026-11-12 20:23:25.338412+00', '20260702110000_case_sla_due_at', NULL, NULL, '2026-11-12 20:23:25.273838+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('7b22e6cb-a055-4cc4-a954-c18246527416', '7bd30e6626cd9be733e05e9a3bef899897f41d8c17f9f1684baacea27227cb29', '2026-11-12 20:23:24.811618+00', '20260601091334', NULL, NULL, '2026-11-12 20:23:24.771881+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('b6e35dc0-4bf2-4050-8492-02416eaf2f8d', '2dc7d1aea5c2fa1479acf4cc6f3f3f88e046aaacc31ee0a2e8026704628b69a0', '2026-11-12 20:23:24.871861+00', '20260601105534_add_tenant_id_to_event_log', NULL, NULL, '2026-11-12 20:23:24.835522+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('eaeae550-aa12-4a61-b98a-08e681e91b5b', '2f368e5499d282e6db5e4f027db57cbba2136f2ebe3a5f8851ba0f45a8e6a0e1', '2026-11-12 20:23:24.90654+00', '20260602080454_remove_dead_code_columns', NULL, NULL, '2026-11-12 20:23:24.874926+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('110cf79d-2a68-45b2-81e1-e13f2d7c0c6f', 'aa380e06fc03f4de2d436c810f4ea3578bc1fea551eb9c3a3715ec41c181b223', '2026-11-12 20:23:25.38384+00', '20260702120000_remove_case_status_completed', NULL, NULL, '2026-11-12 20:23:25.341814+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('4904fe08-9d60-461a-8ccd-aeb5c920846b', '565850ca3f7d4d26aaee2dcaf5f3d810665427fc6fef13ca7bcd90bf3e41eaf3', '2026-11-12 20:23:24.972276+00', '20260616124311_username', NULL, NULL, '2026-11-12 20:23:24.910015+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('3906fcab-b574-4910-b7cf-ee560f64278d', '3b5ccac51644082d2369a9e585bcee57c62f8d3ba0af520bbe4609a556908293', '2026-11-12 20:23:25.008946+00', '20260618055232_tenant_id_admin', NULL, NULL, '2026-11-12 20:23:24.976104+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('d7425673-933e-46a9-abc3-de50982a969b', '3dcabb4c9df5438746459990142d29576532a4459094b9cc911c466ecf491421', '2026-11-12 20:23:25.974892+00', '20260928120000_add_iso20022_identifiers_to_alerts', NULL, NULL, '2026-11-12 20:23:25.93739+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('65ecfad4-e910-4d43-864a-9d21a82d01b9', 'b93e8ebe1b72348ea9e6ef327b4236aa3e26c4bac996fd771f18521bb351c8d9', '2026-11-12 20:23:25.045666+00', '20260618071604_remove_unique_reference_ids', NULL, NULL, '2026-11-12 20:23:25.013036+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('33b50229-1edb-4f25-b7dd-84b618b3177e', '3eec6f97d38b5202d485e55ec0d1d816af0e1b39ac3cfcb509e4602b0df1b112', '2026-11-12 20:23:25.427478+00', '20260702120000_sla_escalation_records', NULL, NULL, '2026-11-12 20:23:25.38742+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('e97419af-fb87-48fb-9639-622e61224393', 'f05dcc4b83d41b205cdf3d76562e32c01c00feabed62036144c9864d592a2c25', '2026-11-12 20:23:25.107588+00', '20260619054750_add_reference_ids_txtp_tenant_unique', NULL, NULL, '2026-11-12 20:23:25.073592+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('0f80cdbd-0040-4ab0-9e20-175388cd10a9', '554d3f584f8c3dc0c5c74d7f44c85e10034e9a428ffd0693ccb188342b1203b2', '2026-11-12 20:23:25.145312+00', '20260701000001_add_investigation_group', NULL, NULL, '2026-11-12 20:23:25.111127+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('45a6ea51-2d87-4ed8-b05a-0e144c1f0d96', '832036f1a79575a857631f8b25e00d6d6f670ee54b49840e22a378c0694993f6', '2026-11-12 20:23:25.723894+00', '20260709000000_add_created_updated_at_to_sla_escalation_records', NULL, NULL, '2026-11-12 20:23:25.687904+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('1c4b5701-9146-40e9-a5da-007e55322b62', '418bdaa684c436250a2e9056e6713925d7cdd50ccb2bd159ffd6f9f754609f91', '2026-11-12 20:23:25.190286+00', '20260702100000_priority_severity_rename', NULL, NULL, '2026-11-12 20:23:25.150341+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('fff60cea-1ecb-4afe-b9ef-57bc863f7e1e', '298d253fab59bcdd157da0d2d00c19dc9cbc965796c7f2df342c6247e185701e', '2026-11-12 20:23:25.494803+00', '20260702140000_add_investigation_group_relations', NULL, NULL, '2026-11-12 20:23:25.455644+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('b0f01ef7-e1c3-4ca1-9a49-508b5440dd5f', '76c86bb802d2464a14ba0f921e7d9b63a73377db89e4c1452a205715170485eb', '2026-11-12 20:23:25.537022+00', '20260705161141_add_sla_escalation_thresholds', NULL, NULL, '2026-11-12 20:23:25.498756+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('707267ee-6ad2-43d2-ace5-4043de4e146f', '3faa28db449a62ae9972b6fc194379a77f63e95ce5cf2c7d3043562420f85711', '2026-11-12 20:23:25.581359+00', '20260705170000_add_case_priority_thresholds', NULL, NULL, '2026-11-12 20:23:25.540531+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('c1fb2dbe-94c0-489d-8a33-eec15d6fcc47', '7cf9417745680685df682255268d47fc434ba70048b2fa077436b9db5c14903d', '2026-11-12 20:23:25.790945+00', '20260716120000_add_tenant_id_to_sla_escalation_records', NULL, NULL, '2026-11-12 20:23:25.751923+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('4a04c6c1-5dfb-47e3-8135-b194fa11aefd', 'fd4770db2bcd9a151b80d98b1872f3db2d039a5a0aa1b163205c5419975fac4f', '2026-11-12 20:23:25.643298+00', '20260706120000_sla_policy_target_seconds', NULL, NULL, '2026-11-12 20:23:25.608979+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('9baabc29-9710-48e3-aa6c-cc67064dba07', '1d663f9c43851163daf1c03e0736183e2026e93c2faa87fc4df13f78224f5e9d', '2026-11-12 20:23:25.83014+00', '20260812000000_add_updated_at_to_alerts', NULL, NULL, '2026-11-12 20:23:25.794262+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('53eb7977-b5fd-4041-8917-88c9b1e39c2d', '8c40d7c85dddc2451ae65f6662b979f50577cf0de77ae089ef22869269a5b3fc', '2026-11-12 20:23:26.018302+00', '20261026000000_rename_blacklist_to_blocklist', NULL, NULL, '2026-11-12 20:23:25.978611+00', 1);
INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES ('c0c8b5a4-855a-45e3-87a0-7e679ff5eabe', '95ea25e3bd222712024b40038e568aec1f2aa066a8615b6b3a957e6692365684', '2026-11-12 20:23:25.934348+00', '20260914000000_add_case_investigator_acl', NULL, NULL, '2026-11-12 20:23:25.836252+00', 1);


--
-- PostgreSQL database dump complete
--

\unrestrict vZlvOcQZB25mYr4BKj2yHfHl64ZgW3VPx1mwrvE4ZAHqghVL1ufotmYT6oeimxt
\endif

SELECT pg_catalog.set_config('search_path', 'public', false);

INSERT INTO public.reference_ids ("txTp", "referenceIdName", tenant_id)
VALUES
  ('pacs.008.001.10', 'EndToEndId', 'TAZAMA'),
  ('pacs.002.001.12', 'OrgnlEndToEndId', 'TAZAMA')
ON CONFLICT ("txTp", tenant_id)
DO UPDATE SET "referenceIdName" = EXCLUDED."referenceIdName";

INSERT INTO public.sla_policies (tenant_id, priority, target_seconds, updated_at)
VALUES
  ('DEFAULT', 'HIGH', 86400, CURRENT_TIMESTAMP),
  ('DEFAULT', 'MEDIUM', 259200, CURRENT_TIMESTAMP),
  ('DEFAULT', 'LOW', 604800, CURRENT_TIMESTAMP)
ON CONFLICT (tenant_id, priority)
DO NOTHING;

INSERT INTO public.sla_escalation_thresholds (tenant_id, due_soon_ratio, at_risk_ratio, updated_at)
VALUES ('DEFAULT', 0.2, 0.5, CURRENT_TIMESTAMP)
ON CONFLICT (tenant_id)
DO NOTHING;

INSERT INTO public.case_priority_thresholds (tenant_id, high_threshold, medium_threshold, updated_at)
VALUES ('DEFAULT', 0.7, 0.4, CURRENT_TIMESTAMP)
ON CONFLICT (tenant_id)
DO NOTHING;
