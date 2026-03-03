# ECU Tuner Enterprise — Project Scaffold Script (PowerShell)
# Run: .\scaffold-ecu-tuner.ps1

$ErrorActionPreference = "Stop"
$ROOT = "."

Write-Host "Scaffolding ECU Tuner Enterprise..." -ForegroundColor Cyan

function New-Dir($path) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}
function New-File($path, $content) {
    New-Dir (Split-Path $path)
    Set-Content -Path $path -Value $content -Encoding UTF8
}

# ── TypeScript services ─────────────────────────────────────
$TS_SERVICES = @("api-gateway","auth-service","vehicle-service","tune-service","datalog-service","notification-service","reporting-service")

foreach ($SERVICE in $TS_SERVICES) {
    $BASE = "$ROOT/services/$SERVICE"
    New-Dir "$BASE/src"
    New-Dir "$BASE/api"
    New-Dir "$BASE/test"

    New-File "$BASE/Dockerfile" @'
# Multi-stage build - builder + runtime
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-alpine AS runtime
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "dist/main.js"]
'@

    $pkgJson = '{
  "name": "@ecu-tuner/' + $SERVICE + '",
  "version": "0.1.0",
  "scripts": {
    "build": "nest build",
    "start:dev": "nest start --watch",
    "test": "jest",
    "lint": "eslint src/**/*.ts"
  }
}'
    New-File "$BASE/package.json" $pkgJson

    New-File "$BASE/src/health.controller.ts" @'
import { Controller, Get } from "@nestjs/common";

@Controller("health")
export class HealthController {
  @Get()
  check() {
    return { status: "ok", timestamp: new Date().toISOString() };
  }
}
'@

    New-File "$BASE/api/service.proto" ('syntax = "proto3";' + "`npackage $SERVICE;`n`n// Define gRPC methods here")

    Write-Host "  OK $SERVICE" -ForegroundColor Green
}

# ── ecu-service (C++17) ─────────────────────────────────────
$ECU = "$ROOT/services/ecu-service"
foreach ($d in @("src","include","tests","api")) { New-Dir "$ECU/$d" }

New-File "$ECU/CMakeLists.txt" @'
cmake_minimum_required(VERSION 3.25)
project(ecu_service CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(GTest REQUIRED)

add_executable(ecu_service
  src/main.cpp
  src/ecu_connector.cpp
  src/checksum_engine.cpp
  src/obd_reader.cpp
  src/flash_manager.cpp
)

target_include_directories(ecu_service PRIVATE include)

enable_testing()
add_subdirectory(tests)
'@

New-File "$ECU/src/main.cpp" @'
#include <iostream>
#include "ecu_connector.h"

int main() {
    std::cout << "ECU Service starting..." << std::endl;
    return 0;
}
'@

$CPP_MODULES = @("ecu_connector","checksum_engine","obd_reader","flash_manager")
foreach ($MOD in $CPP_MODULES) {
    $CLASS = (Get-Culture).TextInfo.ToTitleCase($MOD.Replace("_"," ")).Replace(" ","")

    New-File "$ECU/include/$MOD.h" ("// $MOD -- ECU Tuner Enterprise`n" +
        "// Follow RAII: use std::unique_ptr / std::shared_ptr`n" +
        "#pragma once`n`nclass $CLASS {`npublic:`n    // TODO: implement`n};")

    New-File "$ECU/src/$MOD.cpp" "// $MOD implementation"

    New-File "$ECU/tests/test_$MOD.cpp" ('#include <gtest/gtest.h>' + "`n" +
        "#include `"$MOD.h`"`n`n" +
        "TEST(${CLASS}Test, Placeholder) {`n    EXPECT_TRUE(true);`n}")
}

New-File "$ROOT/tests/mock-ecu/mock_ecu_server.cpp" @'
// Mock ECU server for CI -- never test against real hardware in CI
#include <iostream>
int main() {
    std::cout << "Mock ECU server running..." << std::endl;
}
'@

Write-Host "  OK ecu-service (C++17)" -ForegroundColor Green

# ── apps/desktop-app (Qt6 C++17) ────────────────────────────
Write-Host ""
Write-Host "Scaffolding apps..." -ForegroundColor Cyan

$DESKTOP = "$ROOT/apps/desktop-app"
foreach ($d in @("src","include","resources","tests")) { New-Dir "$DESKTOP/$d" }

New-File "$DESKTOP/CMakeLists.txt" @'
cmake_minimum_required(VERSION 3.25)
project(ECUTunerDesktop CXX)

set(CMAKE_CXX_STANDARD 17)
find_package(Qt6 REQUIRED COMPONENTS Widgets Charts)

qt_add_executable(ECUTunerDesktop
  src/main.cpp
  src/MapTableEditor.cpp
  src/LiveDashboard.cpp
  src/GraphView.cpp
  src/DynoView.cpp
  src/TuneBrowser.cpp
  src/FlashManager.cpp
)

target_link_libraries(ECUTunerDesktop PRIVATE Qt6::Widgets Qt6::Charts)
'@

$QT_SCREENS = @("MapTableEditor","LiveDashboard","GraphView","DynoView","TuneBrowser","FlashManager")
foreach ($SCREEN in $QT_SCREENS) {
    New-File "$DESKTOP/include/$SCREEN.h" (
        "#pragma once`n#include <QWidget>`n`n" +
        "class $SCREEN : public QWidget {`n    Q_OBJECT`npublic:`n" +
        "    explicit $SCREEN(QWidget* parent = nullptr);`n};")

    New-File "$DESKTOP/src/$SCREEN.cpp" (
        "#include `"$SCREEN.h`"`n// $SCREEN -- Qt6 C++17`n// Target OS: Windows, macOS, Linux")
}
Write-Host "  OK desktop-app" -ForegroundColor Green

# ── apps/web-app (React 18 + Vite) ──────────────────────────
$WEB = "$ROOT/apps/web-app"
foreach ($d in @("src/pages","src/components","src/store","src/hooks","src/utils")) { New-Dir "$WEB/$d" }

New-File "$WEB/package.json" @'
{
  "name": "@ecu-tuner/web-app",
  "version": "0.1.0",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "test": "playwright test",
    "lint": "eslint src/**/*.{ts,tsx}"
  },
  "dependencies": {
    "react": "^18.0.0",
    "react-dom": "^18.0.0",
    "@reduxjs/toolkit": "^2.0.0",
    "react-redux": "^9.0.0",
    "@tanstack/react-query": "^5.0.0",
    "recharts": "^2.0.0"
  },
  "devDependencies": {
    "vite": "^5.0.0",
    "typescript": "^5.0.0",
    "tailwindcss": "^3.0.0",
    "@playwright/test": "^1.0.0"
  }
}
'@

$PAGES = @("Dashboard","TuneEditor","Datalogs","Vehicles","Reports","Admin")
foreach ($PAGE in $PAGES) {
    New-File "$WEB/src/pages/$PAGE.tsx" (
        "import React from 'react';`n`n" +
        "const $PAGE`: React.FC = () => {`n" +
        "  return (`n    <div className=`"p-4`">`n" +
        "      <h1 className=`"text-2xl font-bold`">$PAGE</h1>`n" +
        "    </div>`n  );`n};`n`nexport default $PAGE;")
}
Write-Host "  OK web-app" -ForegroundColor Green

# ── apps/mobile-app (React Native) ──────────────────────────
$MOBILE = "$ROOT/apps/mobile-app"
New-Dir "$MOBILE/src/screens"
foreach ($SCREEN in @("LiveMonitor","TuneHistory","Alerts")) {
    New-File "$MOBILE/src/screens/$SCREEN.tsx" (
        "import React from 'react';`nimport { View, Text } from 'react-native';`n`n" +
        "const $SCREEN`: React.FC = () => (<View><Text>$SCREEN</Text></View>);`n`n" +
        "export default $SCREEN;")
}
Write-Host "  OK mobile-app" -ForegroundColor Green

# ── shared/ ─────────────────────────────────────────────────
Write-Host ""
Write-Host "Scaffolding shared module..." -ForegroundColor Cyan

New-File "$ROOT/shared/types/vehicle.types.ts" @'
export interface Vehicle { id: string; make: string; model: string; year: number; ecuId: string; }
export interface EcuProfile { id: string; brand: string; name: string; romSize: number; }
'@

New-File "$ROOT/shared/types/tune.types.ts" @'
export interface MapCell { value: number; isModified: boolean; }
export interface MapTable { id: string; name: string; rows: number; cols: number; cells: MapCell[][]; }
export interface TuneMap { id: string; vehicleId: string; tables: MapTable[]; version: number; }
'@

New-File "$ROOT/shared/types/datalog.types.ts" @'
export interface SensorReading { pid: string; value: number; unit: string; timestamp: string; }
export interface DatalogSession { id: string; vehicleId: string; startTime: string; readings: SensorReading[]; }
'@

New-File "$ROOT/shared/types/user.types.ts" @'
export type Role = 'super_admin' | 'master_tuner' | 'tuner' | 'viewer' | 'customer';
export interface User { id: string; email: string; role: Role; }
'@

New-File "$ROOT/shared/types/events.types.ts" @'
export interface KafkaEvent<T> { eventId: string; timestamp: string; serviceOrigin: string; payload: T; }
export interface FlashEvent { vehicleId: string; tuneId: string; status: 'started' | 'complete' | 'failed'; }
export interface AlertEvent { vehicleId: string; sensor: string; value: number; threshold: number; }
'@

New-File "$ROOT/shared/constants/obd_pids.ts" @'
export const OBD_PIDS = { RPM: '010C', SPEED: '010D', COOLANT_TEMP: '0105', THROTTLE: '0111' } as const;
'@

New-File "$ROOT/shared/constants/sensor_limits.ts" @'
// ALWAYS enforce, never bypass
export const SENSOR_LIMITS = {
  RPM:          { min: 0,   max: 8000 },
  BOOST_PSI:    { min: -14, max: 30   },
  AFR:          { min: 10,  max: 20   },
  COOLANT_TEMP: { min: -40, max: 120  },
} as const;
'@

New-File "$ROOT/shared/constants/kafka_topics.ts" @'
export const KAFKA_TOPICS = {
  ECU_DATALOG_STREAM: 'ecu.datalog.stream',
  TUNE_FLASH_EVENTS:  'tune.flash.events',
  ALERTS_ENGINE:      'alerts.engine',
  AUDIT_EVENTS:       'audit.events',
} as const;
'@

New-File "$ROOT/shared/utils/unit_converter.ts" @'
export const psiToBar = (psi: number): number => psi * 0.0689476;
export const fToC     = (f: number): number => (f - 32) * 5 / 9;
'@

New-File "$ROOT/shared/utils/checksum.ts" @'
export const validateChecksum = (data: Buffer, expected: number): boolean => {
  const sum = data.reduce((acc, byte) => acc + byte, 0) & 0xFF;
  return sum === expected;
};
'@

Write-Host "  OK shared/" -ForegroundColor Green

# ── databases/ ──────────────────────────────────────────────
Write-Host ""
Write-Host "Scaffolding databases..." -ForegroundColor Cyan

New-File "$ROOT/databases/postgres/migrations/001_initial_schema.sql" @'
CREATE TABLE users         (id UUID PRIMARY KEY, email TEXT UNIQUE NOT NULL, role TEXT NOT NULL, created_at TIMESTAMPTZ DEFAULT NOW());
CREATE TABLE vehicles      (id UUID PRIMARY KEY, make TEXT, model TEXT, year INT, owner_id UUID REFERENCES users(id));
CREATE TABLE ecus          (id UUID PRIMARY KEY, vehicle_id UUID REFERENCES vehicles(id), brand TEXT, name TEXT);
CREATE TABLE tunes         (id UUID PRIMARY KEY, vehicle_id UUID REFERENCES vehicles(id), name TEXT, created_by UUID REFERENCES users(id));
CREATE TABLE tune_versions (id UUID PRIMARY KEY, tune_id UUID REFERENCES tunes(id), version INT, rom_s3_key TEXT, created_at TIMESTAMPTZ DEFAULT NOW());
CREATE TABLE datalogs_meta (id UUID PRIMARY KEY, vehicle_id UUID REFERENCES vehicles(id), session_start TIMESTAMPTZ, s3_key TEXT);
CREATE TABLE audit_logs    (id UUID PRIMARY KEY, user_id UUID REFERENCES users(id), action TEXT, details JSONB, created_at TIMESTAMPTZ DEFAULT NOW());
'@

Write-Host "  OK databases/" -ForegroundColor Green

# ── infrastructure/ ─────────────────────────────────────────
Write-Host ""
Write-Host "Scaffolding infrastructure..." -ForegroundColor Cyan

New-File "$ROOT/infrastructure/docker/docker-compose.yml" @'
version: '3.9'
services:
  postgres:
    image: postgres:16
    ports: ["5432:5432"]
    environment: { POSTGRES_PASSWORD: secret }

  timescaledb:
    image: timescale/timescaledb:latest-pg16
    ports: ["5433:5432"]
    environment: { POSTGRES_PASSWORD: secret }

  zookeeper:
    image: confluentinc/cp-zookeeper:latest
    environment: { ZOOKEEPER_CLIENT_PORT: 2181 }

  kafka:
    image: confluentinc/cp-kafka:latest
    ports: ["9092:9092"]
    depends_on: [zookeeper]
    environment:
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092

  kafka-ui:
    image: provectuslabs/kafka-ui:latest
    ports: ["8080:8080"]
    environment: { KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: kafka:9092 }

  redis:
    image: redis:7
    ports: ["6379:6379"]

  prometheus:
    image: prom/prometheus:latest
    ports: ["9090:9090"]

  grafana:
    image: grafana/grafana:latest
    ports: ["3100:3000"]

  vault:
    image: hashicorp/vault:latest
    ports: ["8200:8200"]
    environment: { VAULT_DEV_ROOT_TOKEN_ID: dev-token }
'@

Write-Host "  OK infrastructure/" -ForegroundColor Green

# ── root files ───────────────────────────────────────────────
New-File "$ROOT/.gitignore" @'
node_modules/
dist/
build/
.env
.env.*
*.secret
'@

New-File "$ROOT/README.md" @'
# ECU Tuner Enterprise

## Quick Start
cd infrastructure/docker
docker-compose up

## Stack
- Backend:   NestJS (TypeScript) + C++17 (ECU service)
- Frontend:  React 18 + Vite + Tailwind CSS
- Mobile:    React Native
- Desktop:   Qt6 C++17
- DB:        PostgreSQL 16 + TimescaleDB + Redis 7
- Messaging: Apache Kafka
- Secrets:   HashiCorp Vault
'@

Write-Host ""
Write-Host "Done! Project scaffolded in current directory." -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. cd infrastructure\docker"
Write-Host "  2. docker-compose up"
Write-Host "  3. Open this folder in Cursor AI"