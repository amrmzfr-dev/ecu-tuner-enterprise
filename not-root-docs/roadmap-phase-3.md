# Phase 3 — Desktop App Core UI

> Goal: A tuner can sit down at the workstation, select their vehicle, open its tune map, edit fuel and ignition cells, save a versioned copy, and flash it to the (mock) ECU.
> This is the phase where the product becomes real. The desktop app goes from a blank window to a fully functional tuning tool.

---

## What You Will Have When Done

- Vehicle selector on startup — pick the car you are about to tune
- MapTableEditor — the main screen, a color-coded 2D/3D grid of tune values
- TuneBrowser — list of all saved tune versions with compare and rollback
- FlashManager screen — safety checklist UI, confirm dialog, progress bar
- tune-service backend — saves and versions all tune maps, enforces safety limits
- Complete flow: open vehicle -> edit map -> save version -> flash to mock ECU

---

## Step 3.1 — Build tune-service

What this does: Stores all tune maps in the database. Every time a tuner hits save, a new version is created. Old versions are never deleted — a tuner can always roll back.

Install dependencies:
```bash
cd services/tune-service
npm install @nestjs/core @nestjs/common @nestjs/typeorm typeorm pg @aws-sdk/client-s3 class-validator uuid
npm install -D @types/uuid
```

File structure:
```
services/tune-service/src/
  tunes/
    tunes.module.ts
    tunes.controller.ts      <- REST endpoints
    tunes.service.ts         <- Business logic
    dto/
      create-tune.dto.ts
      save-version.dto.ts
  maps/
    maps.validator.ts        <- Safety limit checks on every cell
  storage/
    s3.service.ts            <- Upload/download ROM binaries
```

REST endpoints to build:

| Method | Path | What it does |
|---|---|---|
| POST | /tunes | Create a new tune for a vehicle |
| GET | /tunes?vehicleId=X | List all tunes for a vehicle |
| GET | /tunes/:id | Get a tune with its latest map data |
| POST | /tunes/:id/versions | Save a new version (validates all cells first) |
| GET | /tunes/:id/versions | List all saved versions |
| GET | /tunes/:id/versions/:vid | Get a specific version |

The most important method — saving a version:
```typescript
async saveVersion(tuneId: string, mapTables: MapTable[], userId: string): Promise<TuneVersion> {
  // Step 1: Validate EVERY cell against sensor_limits
  for (const table of mapTables) {
    const result = this.mapsValidator.validate(table);
    if (!result.valid) {
      throw new BadRequestException(`Safety limit violation: ${result.errors.join(', ')}`);
    }
  }

  // Step 2: Serialize map data to binary ROM format
  const romBinary = this.serializeToRom(mapTables);

  // Step 3: Upload ROM binary to S3
  const s3Key = await this.s3.upload('ecu-tuner-roms', `roms/${tuneId}/${Date.now()}.bin`, romBinary);

  // Step 4: Save version record to database
  const version = await this.db.createTuneVersion({
    tuneId,
    mapData: mapTables,
    romS3Key: s3Key,
    createdBy: userId,
    version: await this.getNextVersionNumber(tuneId),
  });

  return version;
}
```

Safety validation in maps/maps.validator.ts:
```typescript
import { SENSOR_LIMITS } from '../../../shared/constants/sensor_limits';

export function validateMapTable(table: MapTable): { valid: boolean; errors: string[] } {
  const errors: string[] = [];

  for (let row = 0; row < table.cells.length; row++) {
    for (let col = 0; col < table.cells[row].length; col++) {
      const value = table.cells[row][col].value;
      const limit = SENSOR_LIMITS[table.sensorType as keyof typeof SENSOR_LIMITS];

      if (limit && (value < limit.min || value > limit.max)) {
        errors.push(`[${table.name}] Cell [${row}][${col}]: ${value} is outside safe range ${limit.min}-${limit.max}`);
      }
    }
  }

  return { valid: errors.length === 0, errors };
}
```

Rule: If ANY cell fails validation, the entire save is rejected. Return the full list of bad cells so the tuner knows exactly what to fix.

---

## Step 3.2 — Desktop App: Main Window Layout

Now you build the real Qt6 application. The main window has a sidebar and a central content area that swaps between screens.

Update apps/desktop-app/src/main.cpp:
```cpp
#include <QApplication>
#include "MainWindow.h"

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);
    app.setStyle("Fusion");  // consistent look on all platforms

    MainWindow window;
    window.setWindowTitle("ECU Tuner Enterprise");
    window.resize(1600, 1000);
    window.show();

    return app.exec();
}
```

Create apps/desktop-app/include/MainWindow.h:
```cpp
#pragma once
#include <QMainWindow>
#include <QStackedWidget>
#include <QListWidget>
#include "MapTableEditor.h"
#include "LiveDashboard.h"
#include "TuneBrowser.h"
#include "FlashManager.h"
#include "ServiceClient.h"

class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(QWidget* parent = nullptr);

private slots:
    void on_nav_item_clicked(QListWidgetItem* item);
    void on_vehicle_selected(const QString& vehicle_id);

private:
    void setup_ui();
    void setup_sidebar();

    QListWidget* sidebar_;
    QStackedWidget* content_area_;

    // Screens
    MapTableEditor* map_editor_;
    LiveDashboard* live_dashboard_;
    TuneBrowser* tune_browser_;
    FlashManager* flash_manager_;

    std::unique_ptr<ServiceClient> service_client_;
    QString current_vehicle_id_;
};
```

MainWindow layout:
```
+------------------+------------------------------------------+
|    ECU Tuner     |                                          |
|    Enterprise    |                                          |
+------------------+         Content Area                     |
|  Sidebar nav:    |    (swaps between screens)               |
|                  |                                          |
|  Map Editor      |                                          |
|  Live Dashboard  |                                          |
|  Tune Browser    |                                          |
|  Flash Manager   |                                          |
|  Dyno View       |                                          |
|                  |                                          |
+------------------+------------------------------------------+
|  Status bar: Connected | ECU: 2JZ-GTE | COM3 | Session: 00:12:34 |
+------------------------------------------------------------------------+
```

---

## Step 3.3 — MapTableEditor (The Main Screen)

This is the heart of the whole product. A grid where every cell is a value in the tune map, color-coded so the tuner can instantly see the shape of the map.

Color coding rules (from the project spec):
- AFR table: Blue = lean (high AFR = more air, less fuel), Red = rich (low AFR)
- Ignition timing: Cool colors (blue/green) = low advance, Hot colors (red/orange) = high advance
- Modified cells: Yellow highlight ring around the cell

Create apps/desktop-app/include/MapTableEditor.h:
```cpp
#pragma once
#include <QWidget>
#include <QTableWidget>
#include <QComboBox>
#include <QLabel>
#include <QPushButton>
#include <vector>
#include <string>

enum class MapType { AFR, IGNITION, BOOST, FUEL };

struct MapCell {
  float value;
  bool is_modified = false;
};

class MapTableEditor : public QWidget {
    Q_OBJECT

public:
    explicit MapTableEditor(QWidget* parent = nullptr);

    void load_vehicle(const QString& vehicle_id);
    void load_map(const std::vector<std::vector<MapCell>>& cells,
                  const std::vector<float>& rpm_axis,
                  const std::vector<float>& load_axis,
                  MapType type,
                  const QString& table_name);

    std::vector<std::vector<MapCell>> get_current_map() const;
    bool has_unsaved_changes() const { return has_changes_; }

signals:
    void cell_edited(int row, int col, float old_val, float new_val);
    void save_requested();
    void flash_requested();

private slots:
    void on_cell_changed(int row, int col);
    void on_map_selector_changed(int index);
    void on_save_clicked();
    void on_flash_clicked();

private:
    void setup_ui();
    void refresh_all_colors();
    QColor get_cell_color(float value, float min_val, float max_val, MapType type) const;

    QComboBox* map_selector_;       // dropdown to pick which map table to show
    QTableWidget* table_;
    QLabel* cell_info_label_;       // shows current cell value + position
    QPushButton* save_btn_;
    QPushButton* flash_btn_;

    MapType current_map_type_;
    bool has_changes_ = false;
    QString vehicle_id_;
};
```

Implement color calculation in MapTableEditor.cpp:
```cpp
QColor MapTableEditor::get_cell_color(float value, float min_val, float max_val, MapType type) const {
    float t = (max_val == min_val) ? 0.5f : (value - min_val) / (max_val - min_val);
    t = std::clamp(t, 0.0f, 1.0f);

    if (type == MapType::AFR) {
        // High AFR = lean = blue. Low AFR = rich = red. Flip the scale.
        float hue = (1.0f - t) * 0.67f;  // 0.67 = blue, 0 = red
        return QColor::fromHsvF(hue, 0.75f, 0.90f);
    } else {
        // Ignition/boost: cool to hot
        float hue = (1.0f - t) * 0.67f;
        return QColor::fromHsvF(hue, 0.75f, 0.90f);
    }
}

void MapTableEditor::on_cell_changed(int row, int col) {
    QTableWidgetItem* item = table_->item(row, col);
    if (!item) return;

    float new_value = item->text().toFloat();

    // Highlight modified cell with yellow border
    item->setBackground(get_cell_color(new_value, get_table_min(), get_table_max(), current_map_type_));
    // Add yellow ring to show it is modified
    item->setForeground(QColor(255, 230, 0));

    has_changes_ = true;
    save_btn_->setEnabled(true);
    emit cell_edited(row, col, 0.0f, new_value);
}
```

The map selector dropdown should show:
- Fuel Map (AFR targets)
- Ignition Timing Map
- Boost Map (wastegate duty)
- VVT Map (variable valve timing)

When the tuner switches maps, the grid reloads with the new table and recolors all cells.

---

## Step 3.4 — TuneBrowser

What this does: Shows a list of all saved tune versions for the selected vehicle. The tuner can open any version, compare two versions side by side, or set a version as the current active tune.

Create apps/desktop-app/include/TuneBrowser.h:
```cpp
#pragma once
#include <QWidget>
#include <QTableWidget>
#include <QPushButton>
#include <QLabel>

struct TuneVersionInfo {
  QString version_id;
  int version_number;
  QString tune_name;
  QString saved_by;
  QString saved_at;
  QString notes;
};

class TuneBrowser : public QWidget {
    Q_OBJECT

public:
    explicit TuneBrowser(QWidget* parent = nullptr);
    void load_vehicle(const QString& vehicle_id);

signals:
    void open_version_requested(const QString& version_id);
    void compare_requested(const QString& version_a_id, const QString& version_b_id);
    void flash_version_requested(const QString& version_id);

private slots:
    void on_open_clicked();
    void on_compare_clicked();
    void on_flash_clicked();
    void on_selection_changed();
    void load_versions();

private:
    void setup_ui();
    void populate_table(const std::vector<TuneVersionInfo>& versions);

    QTableWidget* versions_table_;
    QPushButton* open_btn_;
    QPushButton* compare_btn_;
    QPushButton* flash_btn_;
    QLabel* details_label_;
    QString vehicle_id_;
};
```

The versions table columns:
- Version number (v1, v2, v3...)
- Date saved
- Saved by (tuner name)
- Notes / comment
- Checksum status (green tick or red X)

---

## Step 3.5 — FlashManager Screen

The FlashManager screen is shown just before a flash. It walks the tuner through every safety check before allowing the flash to proceed.

Create apps/desktop-app/include/FlashManager.h:
```cpp
#pragma once
#include <QWidget>
#include <QLabel>
#include <QProgressBar>
#include <QPushButton>
#include <QLineEdit>

class FlashManager : public QWidget {
    Q_OBJECT

public:
    explicit FlashManager(QWidget* parent = nullptr);
    void prepare_flash(const QString& vehicle_id, const QString& tune_id, const QString& version_id);

signals:
    void flash_completed(bool success);
    void flash_cancelled();

private slots:
    void on_confirm_text_changed(const QString& text);
    void on_flash_button_clicked();
    void on_cancel_clicked();
    void update_progress(int percent, const QString& step);

private:
    void setup_ui();
    void run_safety_checks();
    void set_check_status(QLabel* label, bool passed);

    // Safety check indicators (green = pass, red = fail, grey = not checked yet)
    QLabel* checksum_indicator_;
    QLabel* limits_indicator_;
    QLabel* backup_indicator_;
    QLabel* ecu_connected_indicator_;

    // Vehicle and tune info display
    QLabel* vehicle_label_;
    QLabel* tune_label_;
    QLabel* version_label_;

    // Confirmation — tuner must type CONFIRM to enable flash button
    QLineEdit* confirm_input_;
    QPushButton* flash_btn_;
    QPushButton* cancel_btn_;

    QProgressBar* progress_bar_;
    QLabel* progress_label_;

    QString vehicle_id_;
    QString tune_id_;
    QString version_id_;
    bool all_checks_passed_ = false;
};
```

What the screen looks like:
```
+-----------------------------------------------+
|  FLASH ECU                                    |
|                                               |
|  Vehicle: 1993 Toyota Supra MK4              |
|  Tune:    Stage 2 — 400hp                    |
|  Version: v7 (saved 2026-03-01 by John)      |
|                                               |
|  Safety Checks:                               |
|  [GREEN] Checksum valid                       |
|  [GREEN] All values within safe limits        |
|  [GREEN] ROM backup saved to S3               |
|  [GREEN] ECU connected on COM3                |
|                                               |
|  Type CONFIRM to enable flash:                |
|  [________________]                           |
|                                               |
|  [CANCEL]           [FLASH ECU]  <- disabled until typed |
|                                               |
|  Progress: ________________________________   |
|  Step: Waiting for confirmation...            |
+-----------------------------------------------+
```

---

## Step 3.6 — ServiceClient (Desktop App to Backend)

The desktop app talks to the backend services via gRPC. This class wraps all the gRPC calls.

Create apps/desktop-app/include/ServiceClient.h:
```cpp
#pragma once
#include <string>
#include <vector>
#include <memory>
#include <grpcpp/grpcpp.h>
#include "ecu_service.grpc.pb.h"

// Wraps all backend gRPC calls
class ServiceClient {
public:
    ServiceClient();

    // ECU operations
    bool connect_ecu(const std::string& port, const std::string& vehicle_id);
    void disconnect_ecu();
    std::string get_ecu_status();
    std::optional<std::vector<uint8_t>> read_rom(const std::string& vehicle_id);
    bool flash_ecu(const std::string& vehicle_id, const std::string& tune_id,
                   const std::string& user_id, const std::vector<uint8_t>& rom_data);

    // Sensor readings
    std::vector<SensorReading> get_all_readings();

private:
    std::unique_ptr<ecu::EcuService::Stub> ecu_stub_;
};
```

Connection setup in ServiceClient.cpp:
```cpp
ServiceClient::ServiceClient() {
    // ecu-service runs on port 50051
    auto ecu_channel = grpc::CreateChannel("localhost:50051", grpc::InsecureChannelCredentials());
    ecu_stub_ = ecu::EcuService::NewStub(ecu_channel);
}
```

---

## Done When — Full Checklist

- [ ] tune-service starts and accepts requests
- [ ] POST /tunes creates a tune record
- [ ] POST /tunes/:id/versions with valid map data creates a version and uploads ROM to S3
- [ ] POST /tunes/:id/versions with an out-of-range cell value returns a 400 error listing the bad cells
- [ ] Desktop app main window opens with sidebar navigation
- [ ] Clicking nav items switches the content area to the correct screen
- [ ] MapTableEditor loads a 16x16 cell grid with color-coded cells
- [ ] Editing a cell changes its color and marks it modified (yellow highlight)
- [ ] Clicking Save calls tune-service and creates a new version
- [ ] TuneBrowser shows a list of saved versions
- [ ] FlashManager screen shows all 4 safety check indicators
- [ ] Flash button stays disabled until CONFIRM is typed
- [ ] Flash button triggers the 7-step flash pipeline via gRPC
- [ ] Flash completes successfully against mock ECU

---

## Common Errors

| Error | Cause | Fix |
|---|---|---|
| S3: NoSuchBucket | S3 bucket not created | Create ecu-tuner-roms bucket in AWS console |
| Qt: cannot find -lQt6Widgets | Qt6 libs not found | Set CMAKE_PREFIX_PATH=C:/Qt/6.x.x/msvc2019_64 |
| gRPC connection refused | ecu-service not running | Start ecu-service before launching desktop app |
| 400: safety limit violation | Cell value out of range | Check sensor_limits.ts for allowed min/max values |
| QTableWidget cell not updating | Wrong signal connected | Use itemChanged not cellChanged for QTableWidget |