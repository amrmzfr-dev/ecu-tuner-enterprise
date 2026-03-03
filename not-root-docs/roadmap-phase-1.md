# Phase 1 — Project Setup & Backend Infrastructure

> Goal: Get everything running so the desktop app has a backend to talk to.
> By the end, the Qt6 desktop app compiles and shows a window, all Docker services are green, and you can add a vehicle to the database.
> You are NOT building any ECU or tuning features yet.

---

## What You Will Have When Done

- Git repo set up and pushed to GitHub
- All Docker services running (PostgreSQL, Redis, Kafka, Vault)
- Database tables created
- auth-service running (desktop app can log in)
- vehicle-service running (can add/get vehicles)
- Qt6 desktop app compiles and shows a basic main window

---

## Step 1.1 — Git and Monorepo Setup

Run the scaffold script first (scaffold-ecu-tuner.ps1), then:

```bash
git init
git add .
git commit -m "chore: initial scaffold"
git remote add origin https://github.com/YOUR_USERNAME/ecu-tuner-enterprise.git
git push -u origin main
```

Create root tsconfig.json:
```json
{
  "compilerOptions": {
    "strict": true,
    "target": "ES2022",
    "module": "commonjs",
    "moduleResolution": "node",
    "esModuleInterop": true,
    "skipLibCheck": true
  }
}
```

Create root .eslintrc.js:
```js
module.exports = {
  parser: '@typescript-eslint/parser',
  plugins: ['@typescript-eslint'],
  extends: ['plugin:@typescript-eslint/recommended'],
  rules: {
    '@typescript-eslint/no-explicit-any': 'error',
  },
};
```

Install root dev tools:
```bash
npm init -y
npm install -D typescript @typescript-eslint/parser @typescript-eslint/eslint-plugin eslint prettier
```

---

## Step 1.2 — Start Docker Infrastructure

The docker-compose.yml is already in infrastructure/docker/ from the scaffold.

```bash
cd infrastructure/docker
docker-compose up -d
```

Verify every service:

| Service | How to check | Expected |
|---|---|---|
| PostgreSQL | docker exec -it docker-postgres-1 psql -U postgres | psql shell opens |
| Redis | docker exec -it docker-redis-1 redis-cli ping | PONG |
| Kafka UI | http://localhost:8080 | Kafka dashboard |
| Grafana | http://localhost:3100 | Login page |
| Vault | http://localhost:8200 | Vault UI |

If a service keeps restarting:
```bash
docker-compose logs <service-name>
```

---

## Step 1.3 — Create the Database Tables

```bash
docker exec -i docker-postgres-1 psql -U postgres -d postgres < databases/postgres/migrations/001_initial_schema.sql
```

Verify tables exist:
```bash
docker exec -it docker-postgres-1 psql -U postgres -d postgres -c "\dt"
```

You should see: users, vehicles, ecus, tunes, tune_versions, datalogs_meta, audit_logs

Set up TimescaleDB for sensor data (port 5433):
```bash
docker exec -it docker-timescaledb-1 psql -U postgres
```

Then run:
```sql
CREATE TABLE sensor_readings (
  time        TIMESTAMPTZ NOT NULL,
  vehicle_id  UUID NOT NULL,
  pid         TEXT NOT NULL,
  value       FLOAT NOT NULL,
  unit        TEXT NOT NULL
);
SELECT create_hypertable('sensor_readings', 'time');
```

Why TimescaleDB? It is PostgreSQL optimized for time-series data. The create_hypertable call tells it to partition data by time automatically, which makes queries like "give me all RPM readings from the last 30 seconds" extremely fast.

---

## Step 1.4 — Configure HashiCorp Vault

Vault is where all passwords and secrets live. Services read from Vault at startup — nothing is hardcoded.

Open Vault UI at http://localhost:8200
Token: dev-token

Enable the secrets engine:
```bash
docker exec -it docker-vault-1 vault secrets enable -path=secret kv-v2
```

Store secrets:
```bash
docker exec -it docker-vault-1 vault kv put secret/database \
  postgres_password="your-strong-password"

docker exec -it docker-vault-1 vault kv put secret/jwt \
  access_secret="$(node -e "console.log(require('crypto').randomBytes(64).toString('hex'))")" \
  refresh_secret="$(node -e "console.log(require('crypto').randomBytes(64).toString('hex'))")"
```

Create .env for local dev in each service (never commit this):
services/auth-service/.env:
```
DATABASE_URL=postgresql://postgres:your-strong-password@localhost:5432/postgres
REDIS_URL=redis://localhost:6379
JWT_ACCESS_SECRET=paste-from-vault
JWT_REFRESH_SECRET=paste-from-vault
PORT=3001
```

---

## Step 1.5 — Build auth-service (Port 3001)

The desktop app sends a username + password to auth-service on startup. If valid, it gets back a JWT token that it includes in all future requests.

Install dependencies:
```bash
cd services/auth-service
npm install @nestjs/core @nestjs/common @nestjs/jwt @nestjs/passport passport passport-jwt bcrypt class-validator class-transformer @nestjs/config
npm install -D @types/bcrypt jest @types/jest ts-jest
```

File structure to create inside services/auth-service/src/:
```
src/
  app.module.ts          <- Root module
  main.ts                <- Starts server on port 3001
  auth/
    auth.module.ts
    auth.controller.ts   <- POST /auth/login, POST /auth/register
    auth.service.ts      <- Validate user, create token
    dto/
      login.dto.ts       <- Validates login request body
      register.dto.ts    <- Validates register request body
    strategies/
      jwt.strategy.ts    <- How to validate a JWT
  users/
    users.module.ts
    users.service.ts     <- Talks to database
```

What main.ts must have:
```typescript
import { NestFactory } from '@nestjs/core';
import { ValidationPipe } from '@nestjs/common';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.useGlobalPipes(new ValidationPipe()); // validates all DTOs automatically
  await app.listen(3001);
}
bootstrap();
```

login.dto.ts:
```typescript
import { IsEmail, IsString, MinLength } from 'class-validator';

export class LoginDto {
  @IsEmail()
  email: string;

  @IsString()
  @MinLength(8)
  password: string;
}
```

Why DTOs? They validate incoming data automatically before your code even sees it. If someone sends a request without an email field, NestJS rejects it with a 400 error automatically.

Token rules:
- Access token: expires in 15 minutes
- Refresh token: expires in 7 days
- Never store plain text passwords — always hash with bcrypt

Roles to support:
- super_admin — full access
- master_tuner — read/write all tunes, can flash ECUs
- tuner — assigned vehicles only, needs approval to flash
- viewer — read-only

Test the auth service manually:
```bash
# Register
curl -X POST http://localhost:3001/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"tuner@shop.com","password":"password123"}'

# Login
curl -X POST http://localhost:3001/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"tuner@shop.com","password":"password123"}'
# Should return { "accessToken": "...", "refreshToken": "..." }
```

Write Jest tests (80% coverage minimum):
- Register with valid data returns tokens
- Register with duplicate email throws error
- Login with wrong password returns 401
- Login with valid credentials returns JWT

---

## Step 1.6 — Build vehicle-service (Port 3002)

Every tune belongs to a specific vehicle + ECU combination. This service stores all vehicle and ECU profiles.

Install dependencies:
```bash
cd services/vehicle-service
npm install @nestjs/core @nestjs/common @nestjs/typeorm typeorm pg class-validator ioredis
```

REST endpoints to build:

| Method | Path | What it does |
|---|---|---|
| GET | /vehicles | List all vehicles |
| POST | /vehicles | Add a new vehicle |
| GET | /vehicles/:id | Get one vehicle |
| GET | /vehicles/:id/ecu | Get ECU definition for this vehicle |

Vehicle JSON format to store in database:
```json
{
  "id": "uuid",
  "make": "Toyota",
  "model": "Supra MK4",
  "year": 1993,
  "engine": "2JZ-GTE",
  "ecuId": "2jz-gte"
}
```

Add Redis caching so you do not hit the database every time:
```typescript
async findOne(id: string) {
  // 1. Check Redis cache first (TTL = 10 minutes)
  const cached = await this.redis.get(`vehicle:${id}`);
  if (cached) return JSON.parse(cached);

  // 2. Not in cache — get from database
  const vehicle = await this.db.findOne(id);

  // 3. Store in cache
  await this.redis.setex(`vehicle:${id}`, 600, JSON.stringify(vehicle));
  return vehicle;
}
```

---

## Step 1.7 — Desktop App Skeleton (Qt6)

The goal here is just to get the Qt6 project compiling and showing a window. You are not building any screens yet.

Verify Qt6 is installed:
```bash
cmake --version   # must be 3.25+
```

Build the desktop app:
```bash
cd apps/desktop-app
mkdir build && cd build
cmake .. -DCMAKE_PREFIX_PATH=C:/Qt/6.x.x/msvc2019_64
cmake --build .
```

What main.cpp should do right now:
```cpp
#include <QApplication>
#include <QMainWindow>
#include <QLabel>

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);

    QMainWindow window;
    window.setWindowTitle("ECU Tuner Enterprise");
    window.resize(1400, 900);

    QLabel* label = new QLabel("ECU Tuner Enterprise - Loading...", &window);
    label->setAlignment(Qt::AlignCenter);
    window.setCentralWidget(label);

    window.show();
    return app.exec();
}
```

This just proves Qt6 works. Real screens come in Phase 3.

---

## All API Responses Must Follow This Shape

Every single endpoint across all services must return this format:
```json
{
  "success": true,
  "data": {},
  "error": null,
  "timestamp": "2026-01-01T00:00:00.00Z"
}
```

Create a helper in shared/utils/api-response.ts:
```typescript
export const apiResponse = <T>(data: T) => ({
  success: true,
  data,
  error: null,
  timestamp: new Date().toISOString(),
});

export const apiError = (message: string) => ({
  success: false,
  data: null,
  error: message,
  timestamp: new Date().toISOString(),
});
```

---

## Done When — Full Checklist

- [ ] docker-compose up starts with no errors
- [ ] http://localhost:8080 shows Kafka UI
- [ ] http://localhost:3100 shows Grafana login
- [ ] http://localhost:8200 shows Vault and you can log in
- [ ] Database has all 7 tables
- [ ] TimescaleDB sensor_readings hypertable created
- [ ] POST /auth/register creates a user and returns tokens
- [ ] POST /auth/login with correct password returns tokens
- [ ] POST /auth/login with wrong password returns 401
- [ ] GET /vehicles returns a list (even if empty)
- [ ] POST /vehicles adds a vehicle
- [ ] Desktop app compiles with no errors and shows a window
- [ ] No passwords anywhere in code files
- [ ] Jest tests pass at 80%+ coverage on auth-service
- [ ] Everything committed to git

---

## Common Errors

| Error | Cause | Fix |
|---|---|---|
| Port already in use | Another app using the port | Run: netstat -ano | findstr :5432 then kill the process |
| ECONNREFUSED | Container not running | Run: docker-compose up postgres |
| JsonWebTokenError | Wrong JWT secret | Check .env secret matches what was used to sign |
| class-validator not working | Missing ValidationPipe | Add app.useGlobalPipes(new ValidationPipe()) in main.ts |
| Qt6 not found by CMake | Qt6 not in PATH | Set CMAKE_PREFIX_PATH to your Qt6 install directory |