# Phase 5 — Dyno View, Reports & Polish

> Goal: Complete the professional toolset. Add the DynoView screen for HP/torque curves, generate PDF customer reports, build the internal shop dashboard, and set up CI/CD so every code push is automatically tested.
> After this phase the product is feature-complete.

---

## What You Will Have When Done

- DynoView screen in the desktop app — HP/torque curves from a dyno run
- PDF report export — customer takes home a printout of their tune results
- Full audit trail — every flash logged permanently
- reporting-service — PDF generation and audit log storage
- Internal shop web dashboard — wall monitor showing active sessions across the workshop
- GitHub Actions CI/CD — every commit automatically linted, tested, and deployed

---

## Step 5.1 — Desktop App: DynoView Screen

What this is: During a dyno run, the car accelerates through its RPM range while the dynamometer measures the output power. DynoView plots the HP and torque curves from that run.

A dyno run produces:
- A series of RPM + power (HP) measurements
- A series of RPM + torque (Nm) measurements
- These are plotted as smooth curves on the same chart

Create apps/desktop-app/include/DynoView.h:
```cpp
#pragma once
#include <QWidget>
#include <QtCharts/QChartView>
#include <QtCharts/QLineSeries>
#include <QtCharts/QValueAxis>
#include <QPushButton>
#include <QLabel>
#include <vector>

struct DynoDataPoint {
  float rpm;
  float hp;
  float torque_nm;
};

struct DynoRun {
  QString run_id;
  QString vehicle_id;
  QString tune_version_id;
  QString run_date;
  std::vector<DynoDataPoint> data;
  float peak_hp;
  float peak_torque;
  float peak_hp_rpm;
  float peak_torque_rpm;
};

class DynoView : public QWidget {
    Q_OBJECT

public:
    explicit DynoView(QWidget* parent = nullptr);

    void load_run(const DynoRun& run);
    void start_live_capture(const QString& vehicle_id, const QString& tune_version_id);
    void stop_capture();
    void compare_runs(const DynoRun& run_a, const DynoRun& run_b);

signals:
    void export_pdf_requested(const QString& run_id);
    void save_run_requested(const DynoRun& run);

private slots:
    void on_export_clicked();
    void on_save_clicked();
    void on_compare_clicked();

private:
    void setup_ui();
    void plot_run(const DynoRun& run, const QColor& hp_color, const QColor& torque_color);
    void update_peak_labels(const DynoRun& run);

    QChartView* chart_view_;
    QLineSeries* hp_series_;
    QLineSeries* torque_series_;

    // Peak info labels
    QLabel* peak_hp_label_;
    QLabel* peak_torque_label_;
    QLabel* peak_hp_rpm_label_;
    QLabel* peak_torque_rpm_label_;

    QPushButton* export_btn_;
    QPushButton* save_btn_;
    QPushButton* compare_btn_;

    DynoRun current_run_;
    bool is_capturing_ = false;
};
```

Chart setup in DynoView.cpp:
```cpp
void DynoView::setup_ui() {
    auto* chart = new QChart();
    chart->setTitle("Dyno Run Results");
    chart->setTheme(QChart::ChartThemeDark);

    hp_series_ = new QLineSeries();
    hp_series_->setName("Power (HP)");
    hp_series_->setPen(QPen(QColor(255, 100, 50), 3));  // orange

    torque_series_ = new QLineSeries();
    torque_series_->setName("Torque (Nm)");
    torque_series_->setPen(QPen(QColor(50, 150, 255), 3));  // blue

    chart->addSeries(hp_series_);
    chart->addSeries(torque_series_);

    // X axis: RPM
    auto* x_axis = new QValueAxis();
    x_axis->setTitleText("RPM");
    x_axis->setRange(0, 8000);
    x_axis->setTickCount(9);

    // Y axis: HP and torque share axis but different scales
    auto* y_axis = new QValueAxis();
    y_axis->setTitleText("Power / Torque");
    y_axis->setRange(0, 600);

    chart->addAxis(x_axis, Qt::AlignBottom);
    chart->addAxis(y_axis, Qt::AlignLeft);
    hp_series_->attachAxis(x_axis);
    hp_series_->attachAxis(y_axis);
    torque_series_->attachAxis(x_axis);
    torque_series_->attachAxis(y_axis);

    chart_view_ = new QChartView(chart, this);
    chart_view_->setRenderHint(QPainter::Antialiasing);
}

void DynoView::load_run(const DynoRun& run) {
    current_run_ = run;
    hp_series_->clear();
    torque_series_->clear();

    for (const auto& point : run.data) {
        hp_series_->append(point.rpm, point.hp);
        torque_series_->append(point.rpm, point.torque_nm);
    }

    peak_hp_label_->setText(QString("Peak Power: %1 HP").arg(run.peak_hp, 0, 'f', 1));
    peak_torque_label_->setText(QString("Peak Torque: %1 Nm").arg(run.peak_torque, 0, 'f', 1));
    peak_hp_rpm_label_->setText(QString("@ %1 RPM").arg(static_cast<int>(run.peak_hp_rpm)));
    peak_torque_rpm_label_->setText(QString("@ %1 RPM").arg(static_cast<int>(run.peak_torque_rpm)));

    export_btn_->setEnabled(true);
}
```

How a dyno run is captured:
- Tuner clicks "Start Dyno Run" — begins recording
- datalog-service timestamps every sensor reading
- When tuner clicks "Stop" — calculates HP from torque and RPM: HP = (Torque_Nm x RPM) / 9549
- DynoView.load_run() plots the results

---

## Step 5.2 — reporting-service (Port 3004)

What this does: Two jobs — generate PDF reports and store the audit trail.

Install dependencies:
```bash
cd services/reporting-service
npm install @nestjs/core @nestjs/common pdfkit @aws-sdk/client-s3 kafkajs pg
npm install -D @types/pdfkit
```

File structure:
```
services/reporting-service/src/
  main.ts                      <- Port 3004
  reports/
    reports.controller.ts      <- POST /reports/generate, GET /reports
    reports.service.ts
    pdf/
      pdf.service.ts           <- Generates PDF with pdfkit
  audit/
    audit.consumer.ts          <- Kafka consumer for audit.events
    audit.service.ts           <- Stores audit records
```

pdf.service.ts — generate the customer report PDF:
```typescript
import PDFDocument from 'pdfkit';

async generateTuneReport(data: {
  customerName: string;
  vehicleMake: string;
  vehicleModel: string;
  vehicleYear: number;
  tuneName: string;
  tuneDate: string;
  tunerName: string;
  peakHp?: number;
  peakTorque?: number;
  hpCurve?: { rpm: number; hp: number }[];
  beforeAfter?: { metric: string; before: number; after: number }[];
  notes?: string;
}): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 50 });
    const chunks: Buffer[] = [];

    doc.on('data', chunk => chunks.push(chunk));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);

    // Header
    doc.fontSize(28).font('Helvetica-Bold')
       .text('ECU Tune Report', { align: 'center' });
    doc.fontSize(10).font('Helvetica').fillColor('#666666')
       .text(`Generated: ${new Date().toLocaleDateString()}`, { align: 'center' });
    doc.moveDown(2);

    // Horizontal rule
    doc.moveTo(50, doc.y).lineTo(545, doc.y).stroke();
    doc.moveDown();

    // Customer and vehicle section
    doc.fontSize(14).font('Helvetica-Bold').fillColor('#000000').text('Vehicle Information');
    doc.moveDown(0.5);
    doc.fontSize(11).font('Helvetica')
       .text(`Customer: ${data.customerName}`)
       .text(`Vehicle: ${data.vehicleYear} ${data.vehicleMake} ${data.vehicleModel}`)
       .text(`Tune: ${data.tuneName}`)
       .text(`Date: ${data.tuneDate}`)
       .text(`Tuner: ${data.tunerName}`);
    doc.moveDown();

    // Dyno results
    if (data.peakHp && data.peakTorque) {
      doc.fontSize(14).font('Helvetica-Bold').text('Dyno Results');
      doc.moveDown(0.5);
      doc.fontSize(22).font('Helvetica-Bold').fillColor('#CC4400')
         .text(`${data.peakHp.toFixed(0)} HP`, { continued: true })
         .fontSize(11).font('Helvetica').fillColor('#000000')
         .text('  peak power');
      doc.fontSize(22).font('Helvetica-Bold').fillColor('#0044CC')
         .text(`${data.peakTorque.toFixed(0)} Nm`, { continued: true })
         .fontSize(11).font('Helvetica').fillColor('#000000')
         .text('  peak torque');
      doc.moveDown();
    }

    // Before/after comparison table
    if (data.beforeAfter && data.beforeAfter.length > 0) {
      doc.fontSize(14).font('Helvetica-Bold').text('Before vs After');
      doc.moveDown(0.5);

      const tableTop = doc.y;
      const colWidths = [200, 100, 100, 100];
      const headers = ['Metric', 'Before', 'After', 'Gain'];

      // Draw header row
      doc.fontSize(10).font('Helvetica-Bold');
      let x = 50;
      headers.forEach((h, i) => {
        doc.text(h, x, tableTop, { width: colWidths[i] });
        x += colWidths[i];
      });

      // Draw data rows
      doc.font('Helvetica');
      data.beforeAfter.forEach((row, idx) => {
        const y = tableTop + 20 + (idx * 18);
        const gain = row.after - row.before;
        const gainStr = gain >= 0 ? `+${gain.toFixed(1)}` : gain.toFixed(1);

        doc.text(row.metric, 50, y, { width: colWidths[0] });
        doc.text(row.before.toFixed(1), 250, y, { width: colWidths[1] });
        doc.text(row.after.toFixed(1), 350, y, { width: colWidths[2] });
        doc.fillColor(gain >= 0 ? '#006600' : '#CC0000')
           .text(gainStr, 450, y, { width: colWidths[3] });
        doc.fillColor('#000000');
      });
      doc.moveDown();
    }

    // Tuner notes
    if (data.notes) {
      doc.moveTo(50, doc.y).lineTo(545, doc.y).stroke().moveDown();
      doc.fontSize(14).font('Helvetica-Bold').text('Tuner Notes');
      doc.fontSize(11).font('Helvetica').text(data.notes);
    }

    // Footer
    doc.fontSize(8).fillColor('#999999')
       .text('ECU Tuner Enterprise — Professional Engine Calibration', 50, 780, { align: 'center' });

    doc.end();
  });
}
```

After generating the PDF, upload to S3:
```typescript
const s3Key = `reports/${vehicleId}/${Date.now()}.pdf`;
await this.s3.putObject({ Bucket: 'ecu-tuner-reports', Key: s3Key, Body: pdfBuffer });
```

audit.consumer.ts — listen for audit events and save them:
```typescript
// Every action that gets audited publishes to Kafka topic: audit.events
// This consumer saves each event to the audit_logs table

// Events to audit:
// ECU_FLASH        { vehicleId, tuneId, versionId, result, userId }
// TUNE_SAVED       { vehicleId, tuneId, versionId, userId }
// USER_LOGIN       { userId, ip }
// REPORT_GENERATED { vehicleId, tuneId, s3Key, userId }

await consumer.run({
  eachMessage: async ({ message }) => {
    const event = JSON.parse(message.value!.toString());
    await this.db.query(
      'INSERT INTO audit_logs (id, user_id, action, details, created_at) VALUES ($1, $2, $3, $4, NOW())',
      [uuid(), event.payload.userId, event.eventType, JSON.stringify(event.payload)]
    );
  }
});
```

---

## Step 5.3 — Internal Shop Web Dashboard

This is NOT a customer-facing product. It is a web page shown on a wall monitor in the workshop, giving the shop owner a bird's-eye view of all active tuning sessions.

What it shows:
- Which dyno bays are active
- Which vehicle is on each bay
- Current RPM and boost for each active session
- Any alerts firing across the shop
- Recent flashes completed today

This is built as the apps/web-app React application. It connects to api-gateway via WebSocket to receive live data.

Key pages:
- /dashboard — shop overview, all active sessions
- /sessions/:id — drill into one session's live data
- /reports — browse and download PDF reports
- /audit — admin view of all flash operations (master_tuner and above only)

This is much simpler than the previous roadmap assumed — it is an internal operations tool, not a product.

---

## Step 5.4 — CI/CD with GitHub Actions

Set up automated testing so every commit is checked before it can be merged.

Create .github/workflows/pr.yml:
```yaml
name: PR Checks
on:
  pull_request:
    branches: [main]

jobs:
  lint-typescript:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }

      - name: Lint and test auth-service
        working-directory: services/auth-service
        run: |
          npm ci
          npm run lint
          npm run test -- --coverage --coverageThreshold='{"global":{"lines":80}}'

      - name: Lint and test vehicle-service
        working-directory: services/vehicle-service
        run: |
          npm ci
          npm run lint
          npm run test -- --coverage

      - name: Lint and test tune-service
        working-directory: services/tune-service
        run: |
          npm ci
          npm run lint
          npm run test -- --coverage

  lint-cpp:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install tools
        run: sudo apt-get install -y clang-tidy cmake
      - name: Run clang-tidy
        run: clang-tidy services/ecu-service/src/*.cpp -- -std=c++17 -I services/ecu-service/include

  build-docker:
    runs-on: ubuntu-latest
    needs: [lint-typescript]
    steps:
      - uses: actions/checkout@v4
      - name: Build all Docker images
        run: docker-compose -f infrastructure/docker/docker-compose.yml build
```

Create .github/workflows/main.yml:
```yaml
name: Deploy Staging
on:
  push:
    branches: [main]

jobs:
  integration-tests:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env: { POSTGRES_PASSWORD: testpassword }
        ports: ['5432:5432']
      redis:
        image: redis:7
        ports: ['6379:6379']
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - name: Run integration tests
        working-directory: services/auth-service
        run: npm ci && npm run test:integration
        env:
          DATABASE_URL: postgresql://postgres:testpassword@localhost:5432/postgres

  deploy-staging:
    needs: integration-tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Deploy
        run: echo "Add your staging deploy command here"
```

---

## Done When — Full Checklist

- [ ] DynoView screen shows HP and torque curves as smooth colored lines
- [ ] Dyno run captures live from a simulated session and plots in real time
- [ ] Peak HP and peak torque labels update correctly
- [ ] reporting-service starts on port 3004
- [ ] POST /reports/generate produces a PDF file — open it and verify it looks correct
- [ ] PDF is uploaded to S3 ecu-tuner-reports bucket
- [ ] PDF contains vehicle info, peak HP/torque, and tuner notes
- [ ] Audit logs appear in the audit_logs table after a flash
- [ ] Web dashboard /dashboard shows active session count
- [ ] GitHub Actions PR workflow runs on every pull request
- [ ] All TypeScript services lint and test with no errors in CI
- [ ] Pushing to main triggers staging deploy workflow

---

## Common Errors

| Error | Cause | Fix |
|---|---|---|
| PDF is empty or corrupted | doc.end() called before data written | Move doc.end() to after all content is added |
| QtCharts smooth curve looks jagged | Too few data points | Add more intermediate data points, or use QSplineSeries instead of QLineSeries |
| S3 upload fails | Missing AWS credentials | Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables |
| GitHub Action: npm ci fails | package-lock.json not committed | Run npm install locally and commit the lock file |
| Audit events not appearing | Kafka consumer not subscribed | Check that audit.consumer.ts is registered in the NestJS module |