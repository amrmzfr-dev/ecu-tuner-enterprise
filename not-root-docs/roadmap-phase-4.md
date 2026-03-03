# Phase 4 — Live Dashboard & Datalog Streaming

> Goal: Real-time sensor data flows from the ECU into the desktop app while the car is running on the dyno. The tuner watches RPM, boost, AFR and coolant temp updating live. Dangerous readings trigger instant warnings.
> This is what makes ECU tuning software useful during an actual dyno session.

---

## What You Will Have When Done

- LiveDashboard screen — live gauges updating every 100ms
- GraphView screen — scrolling time-series charts of all sensors
- datalog-service — records every sensor reading to TimescaleDB
- Engine alert system — knock and overboost trigger warnings in the app
- Datalog session browser — review and analyze past dyno sessions

---

## Understanding the Data Flow

When the car is running and connected:

```
[Car ECU]
  | OBD-II serial (ELM327 USB dongle)
[ecu-service C++]
  | reads all PIDs every 100ms
  | sends via gRPC stream
[datalog-service NestJS]
  | saves every reading to TimescaleDB (permanent record)
  | publishes to Kafka topic: ecu.datalog.stream
  | checks for dangerous values, publishes to: alerts.engine
[Kafka]
  | consumed by desktop app via gRPC subscription
[Desktop App Qt6]
  | LiveDashboard updates gauges
  | GraphView adds point to chart
  | AlertBanner shows warning if knock or overboost
```

Why save to TimescaleDB first, then Kafka?
TimescaleDB is the permanent record — you can query any session months later.
Kafka is the live feed — fast, real-time, but not meant for long-term storage.

---

## Step 4.1 — Add Streaming to ecu-service

The OBDReader already reads PIDs. Now you need to stream those readings continuously to the datalog-service.

Add a streaming gRPC method to ecu_service.proto:
```protobuf
// Add to EcuService in ecu_service.proto
rpc StreamSensorData(StreamRequest) returns (stream SensorResponse);

message StreamRequest {
  string vehicle_id   = 1;
  int32  interval_ms  = 2;   // how often to read, e.g. 100
}
```

Implement streaming in EcuServiceImpl:
```cpp
grpc::Status StreamSensorData(
    grpc::ServerContext* context,
    const ecu::StreamRequest* request,
    grpc::ServerWriter<ecu::SensorResponse>* writer) override {

    while (!context->IsCancelled()) {
        auto readings = obd_reader_->read_all_pids(2000);

        for (const auto& reading : readings) {
            ecu::SensorResponse response;
            response.set_pid(reading.pid);
            response.set_value(reading.value);
            response.set_unit(reading.unit);
            response.set_timestamp(std::to_string(
                std::chrono::system_clock::now().time_since_epoch().count()
            ));

            if (!writer->Write(response)) break;  // client disconnected
        }

        std::this_thread::sleep_for(
            std::chrono::milliseconds(request->interval_ms())
        );
    }

    return grpc::Status::OK;
}
```

---

## Step 4.2 — Build datalog-service

What this does: Receives the live sensor stream, saves every reading permanently to TimescaleDB, and publishes to Kafka for any other consumers.

Install dependencies:
```bash
cd services/datalog-service
npm install @nestjs/core @nestjs/common kafkajs pg uuid
npm install -D @types/pg
```

File structure:
```
services/datalog-service/src/
  main.ts                       <- Port 3003
  streaming/
    grpc-consumer.service.ts    <- Subscribes to ecu-service gRPC stream
  storage/
    timescale.service.ts        <- Writes to TimescaleDB
  kafka/
    producer.service.ts         <- Publishes to Kafka
  alerts/
    alert.service.ts            <- Detects dangerous readings
  sessions/
    sessions.service.ts         <- Start/stop datalog sessions
    sessions.controller.ts      <- GET /sessions, GET /sessions/:id/readings
```

timescale.service.ts — write every reading:
```typescript
async writeSensorReading(vehicleId: string, pid: string, value: number, unit: string): Promise<void> {
  await this.pool.query(
    'INSERT INTO sensor_readings (time, vehicle_id, pid, value, unit) VALUES (NOW(), $1, $2, $3, $4)',
    [vehicleId, pid, value, unit]
  );
}

async getReadingsInRange(vehicleId: string, pid: string, from: Date, to: Date) {
  const result = await this.pool.query(
    `SELECT time, pid, value, unit
     FROM sensor_readings
     WHERE vehicle_id = $1 AND pid = $2 AND time BETWEEN $3 AND $4
     ORDER BY time ASC`,
    [vehicleId, pid, from, to]
  );
  return result.rows;
}
```

Create Kafka topics (run once):
```bash
docker exec -it docker-kafka-1 bash
kafka-topics --create --topic ecu.datalog.stream --bootstrap-server localhost:9092 --partitions 3
kafka-topics --create --topic alerts.engine       --bootstrap-server localhost:9092 --partitions 1
kafka-topics --create --topic tune.flash.events   --bootstrap-server localhost:9092 --partitions 1
kafka-topics --create --topic audit.events        --bootstrap-server localhost:9092 --partitions 1
```

alert.service.ts — detect dangerous values:
```typescript
import { SENSOR_LIMITS } from '../../../shared/constants/sensor_limits';

async checkAndAlert(vehicleId: string, pid: string, value: number): Promise<void> {
  const pidToLimitKey: Record<string, string> = {
    '010C': 'RPM',
    '0105': 'COOLANT_TEMP',
  };

  const limitKey = pidToLimitKey[pid];
  if (!limitKey) return;

  const limit = SENSOR_LIMITS[limitKey as keyof typeof SENSOR_LIMITS];
  if (value > limit.max) {
    console.warn(`ALERT: ${limitKey} = ${value} exceeds max ${limit.max}`);
    await this.kafkaProducer.publishAlert(vehicleId, limitKey, value, limit.max);
  }
}
```

---

## Step 4.3 — Desktop App: LiveDashboard Screen

The LiveDashboard shows the current value of every sensor as a large, readable gauge. Values update every 100ms. If a value enters a warning zone, the gauge turns red.

Create apps/desktop-app/include/LiveDashboard.h:
```cpp
#pragma once
#include <QWidget>
#include <QTimer>
#include <QLCDNumber>
#include <QProgressBar>
#include <QLabel>
#include "ServiceClient.h"

class LiveDashboard : public QWidget {
    Q_OBJECT

public:
    explicit LiveDashboard(ServiceClient* client, QWidget* parent = nullptr);
    void start_session(const QString& vehicle_id);
    void stop_session();

private slots:
    void refresh_readings();  // called by timer every 100ms

private:
    void setup_ui();
    void update_gauge(QLCDNumber* display, QProgressBar* bar, QLabel* status,
                      float value, float warn_at, float max);
    QString format_elapsed_time();

    ServiceClient* service_client_;
    QTimer* refresh_timer_;

    // RPM gauge
    QLCDNumber* rpm_display_;
    QProgressBar* rpm_bar_;
    QLabel* rpm_status_;

    // Boost gauge
    QLCDNumber* boost_display_;
    QProgressBar* boost_bar_;
    QLabel* boost_status_;

    // AFR gauge
    QLCDNumber* afr_display_;
    QProgressBar* afr_bar_;
    QLabel* afr_status_;

    // Coolant temp
    QLCDNumber* coolant_display_;
    QLabel* coolant_status_;

    // Knock count
    QLCDNumber* knock_display_;
    QLabel* knock_warning_;

    // Session timer
    QLabel* elapsed_label_;
    QElapsedTimer session_timer_;

    // Alert banner (hidden by default, shows red when alert fires)
    QLabel* alert_banner_;
};
```

Dashboard layout:
```
+------------------------------------------------------------------+
|  LIVE DASHBOARD          Session: 00:03:47    [STOP SESSION]     |
+------------------------------------------------------------------+
|  [RPM]          [BOOST]         [AFR]          [COOLANT]         |
|   3250           12.4 psi        13.8            87 C            |
|  |====    |     |====     |     |=======  |     |======   |      |
|  0    8000       -14   30        10    20        0    120         |
|                                                                   |
|  [KNOCK]     [THROTTLE]     [ENGINE LOAD]                        |
|    0 events    43%             62%                                |
|                                                                   |
+------------------------------------------------------------------+
|  [!] ALERT: RPM exceeded 7000 at 00:02:14                        |  <- red banner
+------------------------------------------------------------------+
```

Update gauge colors:
```cpp
void LiveDashboard::update_gauge(QLCDNumber* display, QProgressBar* bar,
                                  QLabel* status, float value, float warn_at, float max) {
    display->display(static_cast<double>(value));
    bar->setValue(static_cast<int>((value / max) * 100));

    QPalette p = display->palette();
    if (value >= warn_at) {
        // Red — warning zone
        p.setColor(QPalette::WindowText, QColor(220, 50, 50));
        status->setText("WARNING");
        status->setStyleSheet("color: red; font-weight: bold;");
    } else if (value >= warn_at * 0.85f) {
        // Orange — approaching warning
        p.setColor(QPalette::WindowText, QColor(220, 140, 0));
        status->setText("CAUTION");
        status->setStyleSheet("color: orange;");
    } else {
        // Green — normal
        p.setColor(QPalette::WindowText, QColor(50, 200, 50));
        status->setText("OK");
        status->setStyleSheet("color: green;");
    }
    display->setPalette(p);
}
```

---

## Step 4.4 — Desktop App: GraphView Screen

Shows all sensor values as scrolling time-series line charts. The X axis scrolls to show the last 60 seconds. The tuner can see how values changed over a run.

Create apps/desktop-app/include/GraphView.h:
```cpp
#pragma once
#include <QWidget>
#include <QtCharts/QChartView>
#include <QtCharts/QLineSeries>
#include <QtCharts/QDateTimeAxis>
#include <QtCharts/QValueAxis>
#include <QTabWidget>
#include "ServiceClient.h"

class GraphView : public QWidget {
    Q_OBJECT

public:
    explicit GraphView(ServiceClient* client, QWidget* parent = nullptr);
    void start_recording(const QString& vehicle_id);
    void stop_recording();
    void clear();

private slots:
    void add_data_point();  // called every 100ms

private:
    void setup_ui();
    void setup_chart(QLineSeries* series, const QString& title,
                     float y_min, float y_max, const QColor& color);
    void scroll_to_latest();

    ServiceClient* service_client_;
    QTimer* update_timer_;
    QTabWidget* chart_tabs_;

    // One chart per sensor
    QChartView* rpm_chart_;
    QLineSeries* rpm_series_;

    QChartView* boost_chart_;
    QLineSeries* boost_series_;

    QChartView* afr_chart_;
    QLineSeries* afr_series_;

    static constexpr int WINDOW_SECONDS = 60;  // show last 60 seconds
};
```

Add data point and scroll:
```cpp
void GraphView::add_data_point() {
    auto readings = service_client_->get_all_readings();
    qint64 now = QDateTime::currentMSecsSinceEpoch();

    for (const auto& reading : readings) {
        QLineSeries* series = nullptr;
        if (reading.pid == "010C") series = rpm_series_;
        else if (reading.pid == "0110") series = boost_series_;
        // etc.

        if (series) {
            series->append(now, reading.value);

            // Remove points older than WINDOW_SECONDS
            qint64 cutoff = now - (WINDOW_SECONDS * 1000);
            while (!series->points().isEmpty() && series->points().first().x() < cutoff) {
                series->remove(0);
            }
        }
    }

    scroll_to_latest();
}

void GraphView::scroll_to_latest() {
    qint64 now = QDateTime::currentMSecsSinceEpoch();
    qint64 window_start = now - (WINDOW_SECONDS * 1000);

    // Update X axis on all charts to show the rolling window
    for (auto* chart_view : { rpm_chart_, boost_chart_, afr_chart_ }) {
        auto* chart = chart_view->chart();
        auto* x_axis = qobject_cast<QDateTimeAxis*>(chart->axes(Qt::Horizontal).first());
        if (x_axis) {
            x_axis->setRange(QDateTime::fromMSecsSinceEpoch(window_start),
                             QDateTime::fromMSecsSinceEpoch(now));
        }
    }
}
```

---

## Step 4.5 — Datalog Session Browser

After a session, the tuner can review it. This is a read-only view of the historical data in TimescaleDB.

This is an additional tab in GraphView or a separate DatalogBrowser screen:
- Shows a list of all past sessions (vehicle, date, duration, peak RPM)
- Click a session to load its data into the charts
- Can filter by date range
- Can export to CSV for external analysis

REST endpoint in datalog-service to support this:
```typescript
// GET /sessions?vehicleId=X
// Returns list of sessions with metadata

// GET /sessions/:id/readings?pid=010C&from=ISO&to=ISO
// Returns all readings for that PID in that session time range
```

---

## Done When — Full Checklist

- [ ] datalog-service starts on port 3003 and connects to TimescaleDB
- [ ] Kafka topics all exist (check Kafka UI at http://localhost:8080)
- [ ] When ecu-service streams data, readings appear in TimescaleDB
- [ ] When RPM exceeds 8000, an alert event appears in Kafka alerts.engine topic
- [ ] Desktop LiveDashboard shows gauge values updating in real time
- [ ] RPM gauge turns red when value exceeds 7000
- [ ] GraphView shows a scrolling line chart for RPM
- [ ] GraphView adds a new data point every 100ms
- [ ] Stopping the session stops the charts from updating
- [ ] Past session appears in the session list
- [ ] Clicking a past session loads its data into the charts

---

## Common Errors

| Error | Cause | Fix |
|---|---|---|
| KafkaJS connection refused | Kafka not running | Run: docker-compose up kafka zookeeper |
| TimescaleDB writes failing | Wrong port | TimescaleDB is port 5433, not 5432 |
| Charts not updating | Timer not started | Call start_recording() which starts the QTimer |
| QtCharts not found | Qt Charts module missing | Add find_package(Qt6 REQUIRED COMPONENTS Charts) to CMakeLists |
| gRPC stream disconnects | Timeout too short | Increase keepalive on gRPC channel options |