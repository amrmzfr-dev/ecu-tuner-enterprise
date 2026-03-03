# ECU Tuner Enterprise — Development Roadmap (Desktop-First)

> **Primary Product:** A professional desktop application for automotive tuning workshops and OEM engineers.
> **Stack:** C++17 + Qt6 (desktop app) · NestJS backend services · PostgreSQL · Kafka · Docker

---

## Who Uses This Software

| User | Where | What they do |
|---|---|---|
| **Workshop Tuner** | Dyno room, laptop plugged into car | Reads ECU, edits tune maps, flashes ECU, watches live gauges |
| **Master Tuner / Shop Owner** | Workshop office | Reviews tune history, compares versions, signs off on flashes |
| **OEM / R&D Engineer** | Test cell / lab bench | Batch ECU testing, firmware regression, calibration logging |

**The desktop app is the product.** The backend services exist only to support it.

---

## Architecture (Desktop-Focused)

```
+-------------------------------------------------------------+
|                   DESKTOP APP (Qt6 / C++17)                  |
|  MapTableEditor · LiveDashboard · FlashManager · DynoView   |
|              TuneBrowser · GraphView                         |
+------------------------+------------------------------------+
                         | gRPC
          +--------------+---------------+
          v              v               v
    ecu-service    tune-service   datalog-service
    (C++17)        (NestJS)       (NestJS)
    OBD-II/CAN     Map storage    TimescaleDB
    ROM flash      Versioning     Live stream
          |              |               |
          +--------------+---------------+
                         v
                   PostgreSQL · Redis · Kafka
```

No mobile app. No public-facing web app.
The web dashboard (Phase 5) is an internal shop wall-monitor only.

---

## The 5 Phases

```
Phase 1      Phase 2      Phase 3      Phase 4      Phase 5
Project  ->  C++ ECU  ->  Desktop  ->  Live     ->  Dyno +
Setup +      Core         App UI       Gauges +     Reports +
Backend      Engine       (Maps +      Datalog      Polish
Infra        (OBD +       Flash)       Stream
             ROM)
```

---

## Phase 1 — Project Setup and Backend Infrastructure
Goal: All services running, database ready, desktop app skeleton compiles.

- Monorepo + git setup
- Docker infra (PostgreSQL, Redis, Kafka, Vault)
- Database schema (vehicles, ecus, tunes, tune_versions, datalogs)
- auth-service — JWT login for the desktop app session
- vehicle-service — vehicle + ECU profile database
- Desktop app Qt6 project compiles and shows a main window

Done when: Desktop app opens. You can add a vehicle. All Docker services green.

---

## Phase 2 — C++ ECU Engine
Goal: The app can physically talk to a car's ECU and read its ROM safely.

- OBD-II reader via ELM327 USB dongle
- ECU connector — establish session, read ROM binary
- Checksum engine — validate before ANY write
- Flash manager — full safety pipeline (backup -> validate -> confirm -> write -> verify)
- Mock ECU server for testing (never use real hardware in CI)
- gRPC interface so desktop app can call the ECU engine

Done when: ROM reads from mock ECU. Checksum validation works. Flash pipeline runs all safety gates.

---

## Phase 3 — Desktop App Core UI
Goal: A tuner can open a vehicle, load its tune map, edit it, and flash it.

- MapTableEditor — 2D/3D color-coded tune map grid (the main screen)
- TuneBrowser — browse and compare saved tune versions
- FlashManager UI — safety checklist, confirm dialog, progress bar
- tune-service — save/version tune maps, enforce sensor limits, S3 ROM storage
- Vehicle selector — pick vehicle + ECU on startup

Done when: Tuner opens a vehicle, edits AFR map cells, saves a version, flashes to mock ECU.

---

## Phase 4 — Live Dashboard and Datalog Streaming
Goal: Real-time sensor data streams into the desktop app during a dyno run.

- datalog-service — writes sensor readings to TimescaleDB, publishes to Kafka
- LiveDashboard Qt6 screen — live gauges (RPM, boost, AFR, knock, coolant)
- GraphView Qt6 screen — scrolling time-series charts
- Engine alert detection — knock / overboost triggers warning in the app
- Datalog session browser — review and replay past sessions

Done when: RPM, AFR and boost update live on desktop gauges during a simulated session.

---

## Phase 5 — Dyno View, Reports and Polish
Goal: Complete the professional toolset. Dyno results, PDF reports, shop dashboard.

- DynoView — HP/torque curve display from a dyno run
- reporting-service — PDF customer reports (dyno results + tune summary)
- Audit trail — who flashed what and when
- Internal shop web dashboard — wall monitor showing all active dyno sessions
- CI/CD — GitHub Actions automated testing

Done when: Full dyno session recorded, HP curve displayed, PDF report exported.

---

## Safety Rules — Never Violate

| # | Rule |
|---|---|
| 1 | Never flash without checksum validation |
| 2 | Never bypass sensor limits (sensor_limits.ts) |
| 3 | Always backup ROM to S3 before flashing |
| 4 | Always require user confirmation before flash |
| 5 | Always log flash to audit trail |
| 6 | Never store secrets in code |
| 7 | Never test against real hardware in CI |

---

## Tech Stack Per Layer

| Layer | Tech | Why |
|---|---|---|
| Desktop App | C++17 + Qt6 | Low-level ECU access, real-time performance, cross-platform GUI |
| ECU Engine | C++17, gRPC | Direct byte-level control, timeout-safe hardware comms |
| Backend Services | NestJS (TypeScript) | Structured APIs, good ORM support |
| Database | PostgreSQL 16 | Relational data — vehicles, tunes, users |
| Time-series | TimescaleDB | High-frequency sensor data (1000s of readings/sec) |
| Cache | Redis 7 | Vehicle profile caching |
| Messaging | Kafka | Async sensor stream, flash events, audit trail |
| File Storage | AWS S3 | ROM binaries, PDF reports |
| Secrets | HashiCorp Vault | Never hardcode passwords or keys |
| Infra | Docker Compose | Run all services locally in one command |

---

Last updated: 2026