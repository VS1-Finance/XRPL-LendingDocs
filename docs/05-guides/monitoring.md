---
label: Monitoring
order: 30
---

# Monitoring

`packages/monitoring` is a self-contained Prometheus + Grafana stack that observes the **ingester's
history store** — it does not scrape the engine process. There is no TypeScript source in this
package; it is a `docker-compose.yml`, a `queries.yaml` for `postgres_exporter`, and Grafana
provisioning files (`packages/monitoring/README.md:1-6`).

> [!NOTE]
> This stack reads derived state that the ingester already projected into Postgres (transactions
> captured, vault assets and shares, broker cover and debt, loans by status, outbox backlog). It
> never queries the engine's operational store or the XRPL ledger directly. See
> [Persistence](../03-architecture/persistence.md) for the two-store split this depends on — the
> ingester's history store is the one being observed here.

## Components

Three services, wired in `packages/monitoring/docker-compose.yml`:

| Service | Image | Host port | Role |
|---|---|---|---|
| `postgres-exporter` | `quay.io/prometheuscommunity/postgres-exporter:v0.15.0` | `9187` | Runs the SQL in `queries.yaml` against the history store (`DATA_SOURCE_NAME=${DATABASE_URL}`) and exposes results as Prometheus metrics (`docker-compose.yml:11-19`) |
| `prometheus` | `prom/prometheus:v2.54.1` | `9090` | Scrapes `postgres-exporter` per `prometheus.yml` (`docker-compose.yml:21-28`) |
| `grafana` | `grafana/grafana:11.2.0` | `3000` | Provisioned with a Prometheus datasource and a dashboard under `grafana/` (`docker-compose.yml:30-42`) |

`postgres-exporter` mounts `queries.yaml` read-only at `/etc/queries.yaml` via
`PG_EXPORTER_EXTEND_QUERY_PATH` (`docker-compose.yml:14-17`). Prometheus's only scrape target is
`postgres-exporter:9187`, job name `lending-history-store`, at a 15s scrape/evaluation interval
(`prometheus.yml:1-9`). Grafana is configured for anonymous viewer access
(`GF_AUTH_ANONYMOUS_ENABLED`, `GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer`) and allows embedding
(`GF_SECURITY_ALLOW_EMBEDDING`), with its datasource and dashboard provisioned from
`grafana/provisioning/` and `grafana/dashboards/` (`docker-compose.yml:32-38`). The Grafana
datasource provisioning points at `http://prometheus:9090` and is marked `isDefault: true`
(`grafana/provisioning/datasources/prometheus.yml:4-8`); the dashboard provider loads any dashboard
JSON from `/var/lib/grafana/dashboards` (`grafana/provisioning/dashboards/dashboards.yml:3-8`).

```mermaid
flowchart LR
    HDB[(Ingester Postgres\ntransactions, events, outbox,\nstate_vault, state_broker, state_loan)]
    PE[postgres-exporter :9187]
    PROM[Prometheus :9090]
    GRAF[Grafana :3000]
    HDB -->|queries.yaml SQL| PE
    PE -->|scrape, 15s| PROM
    PROM -->|datasource| GRAF
```

## Metrics

Each entry in `queries.yaml` is one SQL query against the history store, turned into one metric
family by `postgres_exporter`. Every family carries `setup_id` as a label so a dashboard can filter
by run (`queries.yaml:1-2`).

| Metric family | Source table | Type | Labels | Value(s) |
|---|---|---|---|---|
| `lending_transactions_total` | `transactions` | GAUGE | `setup_id` | `total` — count of transactions captured (`queries.yaml:4-15`) |
| `lending_events_by_type_total` | `events` | GAUGE | `setup_id`, `event_type` | `total` — count of events by normalized type (`queries.yaml:17-31`) |
| `lending_vault` | `state_vault` | GAUGE | `setup_id` | `assets_total`, `assets_available`, `shares_outstanding`, `updated_ledger` (`queries.yaml:33-56`) |
| `lending_broker_cover` | `state_broker` | GAUGE | `setup_id` | `cover_available`, `debt_total` (`queries.yaml:58-73`) |
| `lending_loans_by_status_total` | `state_loan` | GAUGE | `setup_id`, `status` | `total` — count of loans in this status (`queries.yaml:75-89`) |
| `lending_outbox_pending` | `outbox` | GAUGE | — | `pending` — outbox rows with `persistedAt IS NULL` (`queries.yaml:91-99`) |

Notes on the underlying queries:

- `lending_vault` and `lending_broker_cover` cast `BigInt` base-unit columns (`assetsTotal`,
  `assetsAvailable`, `shareOutstanding`, `coverAvailable`, `debtTotal`) to `float8` for export
  (`queries.yaml:36-38,60-62`); values are in base units, not display units, matching how the
  ingester stores them (see [Persistence](../03-architecture/persistence.md)).
- `updated_ledger` on the vault query is the ledger index at which that projection was last written,
  not a metrics timestamp (`queries.yaml:39,54-56`).
- `lending_loans_by_status_total` groups by the raw `status` column on `state_loan` — the README
  lists the observed values as active, repaid, closed, defaulted (`README.md:37`); this page does
  not assert that set is exhaustive beyond what the ingester writes.
- `lending_outbox_pending` has no `setup_id` label — it is a single global count across all runs
  (`queries.yaml:91-99`), so a nonzero value flags a stuck outbox row somewhere in the store, not in
  a specific run.

> [!NOTE]
> "Should trend to zero" for `lending_outbox_pending` is the README's own framing (`README.md:38`):
> the outbox is an at-least-once delivery marker (see [Persistence](../03-architecture/persistence.md#ingester-store--history-and-projected-state)),
> and a persistently nonzero value indicates a backlog in whatever worker stamps `persistedAt`, not
> a metric this stack computes independently.

## Running it

Point `DATABASE_URL` at the ingester's history-store Postgres and start the stack from
`packages/monitoring`:

```sh
DATABASE_URL=postgresql://user:pass@host:5432/db docker compose up
```

(`README.md:16-22`, `docker-compose.yml:1-8` comment block)

- Grafana: `http://localhost:3000` (anonymous viewer access enabled) — open the "Permissioned
  Lending — History Store" dashboard and pick a run (`README.md:24-25`).
- Prometheus: `http://localhost:9090` (`README.md:26`).

The dashboard JSON lives at `packages/monitoring/grafana/dashboards/lending.json` and is loaded by
the file-based dashboard provider; no manual import step is required (`grafana/provisioning/dashboards/dashboards.yml:1-8`).

> [!WARNING]
> `DATABASE_URL` here must point at the **ingester's** Postgres (default port `5432`), not the
> engine's operational store (port `5434`). Pointing this stack at the engine's database will not
> error cleanly — `queries.yaml`'s SQL references tables (`transactions`, `events`, `outbox`,
> `state_vault`, `state_broker`, `state_loan`) that only exist in the ingester's schema. See
> [Persistence](../03-architecture/persistence.md) for which store is which.
