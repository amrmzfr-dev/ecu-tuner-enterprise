# Phase 2 — C++ ECU Engine

> Goal: The application can physically connect to a car's ECU via OBD-II, read its ROM binary, validate it, and run a safe flash pipeline.
> This is the most safety-critical code in the entire project. A bug here can brick an ECU permanently.
> You are not building any UI yet. Pure C++ engine work.

---

## What You Will Have When Done

- OBD-II connection via ELM327 USB dongle (reads RPM, coolant temp, throttle etc.)
- ECU connector that establishes a session and reads the full ROM binary
- Checksum engine that validates data integrity before any write
- Flash manager with a 7-step safety pipeline — no shortcuts allowed
- Mock ECU server used by all automated tests (never real hardware in CI)
- gRPC server so the desktop app can call the ECU engine

---

## Before You Start — Key Concepts

What is OBD-II?
Every car made after 1996 has an OBD-II port (usually under the dashboard). You plug in an ELM327 USB dongle and it lets your computer talk to the car's computer (ECU). You send command codes (PIDs) and the car sends back values like RPM or coolant temperature.

What is a ROM?
The ECU stores its entire tuning program in ROM (Read-Only Memory) — a binary blob of bytes. A tuner reads this blob, edits the specific bytes that control fuel/ignition/boost maps, then writes (flashes) the modified blob back. This is what ECU tuning is.

Why C++17?
ECU communication is byte-level, time-critical work. You need direct control over memory and timing. JavaScript or Python cannot do this reliably.

What is gRPC?
A way for the desktop app (C++) to call functions in the ECU service as if they were local function calls. You define the function signatures in a .proto file and gRPC generates the code to call them over a network connection.

---

## Step 2.1 — Set Up the Build System

Install dependencies via vcpkg (Windows):
```bash
git clone https://github.com/microsoft/vcpkg.git C:\vcpkg
C:\vcpkg\bootstrap-vcpkg.bat
C:\vcpkg\vcpkg install gtest:x64-windows
C:\vcpkg\vcpkg install grpc:x64-windows
C:\vcpkg\vcpkg install protobuf:x64-windows
```

Install serial port library for OBD-II communication:
```bash
C:\vcpkg\vcpkg install boost-asio:x64-windows
```

Update services/ecu-service/CMakeLists.txt:
```cmake
cmake_minimum_required(VERSION 3.25)
project(ecu_service CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(GTest REQUIRED)
find_package(gRPC REQUIRED)
find_package(Protobuf REQUIRED)
find_package(Boost REQUIRED COMPONENTS system)

# Generate gRPC code from .proto file
get_filename_component(ECU_PROTO "api/ecu_service.proto" ABSOLUTE)
get_filename_component(ECU_PROTO_DIR "${ECU_PROTO}" DIRECTORY)

add_custom_command(
  OUTPUT ecu_service.grpc.pb.cc ecu_service.grpc.pb.h ecu_service.pb.cc ecu_service.pb.h
  COMMAND protobuf::protoc
  ARGS --grpc_out "${CMAKE_CURRENT_BINARY_DIR}"
       --cpp_out "${CMAKE_CURRENT_BINARY_DIR}"
       -I "${ECU_PROTO_DIR}"
       --plugin=protoc-gen-grpc="$<TARGET_FILE:gRPC::grpc_cpp_plugin>"
       "${ECU_PROTO}"
)

add_executable(ecu_service
  src/main.cpp
  src/ecu_connector.cpp
  src/checksum_engine.cpp
  src/obd_reader.cpp
  src/flash_manager.cpp
  ecu_service.grpc.pb.cc
  ecu_service.pb.cc
)

target_include_directories(ecu_service PRIVATE include ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(ecu_service PRIVATE gRPC::grpc++ protobuf::libprotobuf Boost::system)

enable_testing()
add_subdirectory(tests)
```

Build to verify it compiles:
```bash
cd services/ecu-service
mkdir build && cd build
cmake .. -DCMAKE_TOOLCHAIN_FILE=C:/vcpkg/scripts/buildsystems/vcpkg.cmake
cmake --build .
```

---

## Step 2.2 — OBD-II Reader

What this does: Connects to the ELM327 USB dongle over a serial port and reads live sensor data using OBD-II PID codes.

Create services/ecu-service/include/obd_reader.h:
```cpp
#pragma once
#include <string>
#include <vector>
#include <optional>
#include <chrono>

struct SensorReading {
  std::string pid;
  float value;
  std::string unit;
  std::chrono::system_clock::time_point timestamp;
};

class OBDReader {
public:
  // Connect to ELM327 on serial port (e.g. "COM3" on Windows)
  // Returns false if connection fails or times out
  bool connect(const std::string& port, int timeout_ms = 5000);
  void disconnect();
  bool is_connected() const;

  // Read one sensor by PID code
  // Returns empty if read fails or times out
  std::optional<SensorReading> read_pid(const std::string& pid, int timeout_ms = 2000);

  // Read all standard PIDs at once
  std::vector<SensorReading> read_all_pids(int timeout_ms = 5000);

private:
  bool send_command(const std::string& cmd, int timeout_ms);
  std::string read_response(int timeout_ms);
  float parse_response(const std::string& pid, const std::string& raw);
  bool connected_ = false;
};
```

OBD-II PID codes to support (mirror obd_pids.ts):
```cpp
// include/obd_pids.h
#pragma once
namespace OBDPids {
  constexpr const char* RPM          = "010C";
  constexpr const char* SPEED        = "010D";
  constexpr const char* COOLANT_TEMP = "0105";
  constexpr const char* THROTTLE     = "0111";
  constexpr const char* ENGINE_LOAD  = "0104";
  constexpr const char* MAF          = "0110";
}
```

The most important rule for all OBD-II code:
Every single read/write operation MUST have a timeout. If the car does not respond, return an error after the timeout. Never hang forever waiting. Use std::chrono for all timing.

---

## Step 2.3 — ECU Connector

What this does: While the OBD reader handles live sensor data, the ECU connector does the deeper work of reading the full ROM binary. This requires a longer session with the ECU.

Create services/ecu-service/include/ecu_connector.h:
```cpp
#pragma once
#include <string>
#include <vector>
#include <memory>
#include <optional>
#include "obd_reader.h"

struct RomData {
  std::vector<uint8_t> bytes;   // Raw ROM binary
  size_t size_bytes;
  uint32_t checksum;
  std::string ecu_id;
};

enum class ConnectionStatus {
  DISCONNECTED,
  CONNECTING,
  CONNECTED,
  ERROR
};

class ECUConnector {
public:
  explicit ECUConnector(const std::string& port);
  ~ECUConnector();  // auto-disconnects — RAII

  // No copying allowed (only one physical connection)
  ECUConnector(const ECUConnector&) = delete;
  ECUConnector& operator=(const ECUConnector&) = delete;

  bool connect(int timeout_ms = 10000);
  void disconnect();
  ConnectionStatus get_status() const;
  std::string get_ecu_id();

  // Read full ROM binary — takes 30-120 seconds on real ECU
  std::optional<RomData> read_rom(int timeout_ms = 120000);

private:
  std::string port_;
  ConnectionStatus status_ = ConnectionStatus::DISCONNECTED;
  std::unique_ptr<OBDReader> obd_reader_;  // owns the reader
};
```

RAII explained:
RAII means the ECUConnector automatically cleans up when it is destroyed — closes the serial port, disconnects from ECU. You never have to manually call cleanup. This prevents resource leaks where the port stays open even after an error.

Rule: Use std::unique_ptr and std::shared_ptr everywhere. Never use raw new or delete.

---

## Step 2.4 — Checksum Engine

What this does: Calculates and validates checksums for ROM data. If even one byte is corrupted, the checksum will not match and the flash is rejected. Flashing corrupted data can permanently brick an ECU.

Create services/ecu-service/include/checksum_engine.h:
```cpp
#pragma once
#include <vector>
#include <cstdint>

class ChecksumEngine {
public:
  // Calculate checksum for data
  static uint32_t calculate(const std::vector<uint8_t>& data);

  // Return true only if data matches expected checksum
  static bool validate(const std::vector<uint8_t>& data, uint32_t expected);

  // Recalculate and embed checksum after editing ROM data
  static std::vector<uint8_t> fix_checksum(std::vector<uint8_t> data);

private:
  static uint32_t calculate_crc32(const std::vector<uint8_t>& data);
};
```

CRC32 implementation in checksum_engine.cpp:
```cpp
uint32_t ChecksumEngine::calculate_crc32(const std::vector<uint8_t>& data) {
  uint32_t crc = 0xFFFFFFFF;
  for (uint8_t byte : data) {
    crc ^= byte;
    for (int i = 0; i < 8; i++) {
      if (crc & 1) crc = (crc >> 1) ^ 0xEDB88320;
      else crc >>= 1;
    }
  }
  return ~crc;
}
```

Tests to write for checksum engine:
- Valid data + correct checksum returns true
- Corrupt one byte — checksum returns false
- Empty data handled without crash
- fix_checksum produces data that validates correctly

---

## Step 2.5 — Flash Manager

The most safety-critical code in the entire project. Manages writing data to the ECU. Never skip or reorder any of these steps.

The 7-step flash pipeline — EVERY step must pass before the next begins:

```
Step 1: Validate checksum of new ROM data
        FAIL -> abort, return CHECKSUM_FAILED

Step 2: Verify all map values within sensor_limits bounds
        FAIL -> abort, return SAFETY_LIMIT_EXCEEDED

Step 3: Read and backup original ROM to AWS S3
        FAIL -> abort, return BACKUP_FAILED

Step 4: Show user confirmation dialog — require explicit confirm
        CANCEL -> abort, return USER_CANCELLED

Step 5: Write new ROM to ECU
        Monitor progress with callback

Step 6: Read back written data and compare to expected
        FAIL -> restore from S3 backup, return VERIFY_FAILED

Step 7: Publish flash event to Kafka topic tune.flash.events
        Log to audit trail (who, what vehicle, what tune, when)
```

Create services/ecu-service/include/flash_manager.h:
```cpp
#pragma once
#include <string>
#include <vector>
#include <functional>
#include "ecu_connector.h"
#include "checksum_engine.h"

enum class FlashResult {
  SUCCESS,
  CHECKSUM_FAILED,
  SAFETY_LIMIT_EXCEEDED,
  BACKUP_FAILED,
  USER_CANCELLED,
  WRITE_FAILED,
  VERIFY_FAILED
};

struct FlashProgress {
  int percent_complete;
  std::string current_step;
};

class FlashManager {
public:
  explicit FlashManager(ECUConnector& connector);

  FlashResult flash(
    const std::vector<uint8_t>& new_rom,
    const std::string& tune_id,
    const std::string& vehicle_id,
    const std::string& user_id,
    std::function<void(FlashProgress)> on_progress,
    std::function<bool()> user_confirm   // must return true to proceed
  );

private:
  ECUConnector& connector_;  // reference, not owner
  ChecksumEngine checksum_;

  bool validate_checksum(const std::vector<uint8_t>& data);
  bool validate_safety_limits(const std::vector<uint8_t>& data);
  bool backup_to_s3(const std::vector<uint8_t>& original, const std::string& vehicle_id);
  bool write_rom(const std::vector<uint8_t>& data, std::function<void(FlashProgress)> cb);
  bool verify_written(const std::vector<uint8_t>& expected);
  void publish_flash_event(const std::string& tune_id, bool success);
  void write_audit_log(const std::string& user_id, const std::string& vehicle_id, FlashResult result);
};
```

---

## Step 2.6 — Define the gRPC Interface

Create services/ecu-service/api/ecu_service.proto:
```protobuf
syntax = "proto3";
package ecu;

service EcuService {
  rpc Connect         (ConnectRequest)      returns (ConnectResponse);
  rpc Disconnect      (DisconnectRequest)   returns (DisconnectResponse);
  rpc GetStatus       (StatusRequest)       returns (StatusResponse);
  rpc ReadRom         (ReadRomRequest)      returns (ReadRomResponse);
  rpc FlashEcu        (FlashEcuRequest)     returns (FlashEcuResponse);
  rpc GetSensorReading(SensorRequest)       returns (SensorResponse);
  rpc GetAllReadings  (AllSensorsRequest)   returns (AllSensorsResponse);
}

message ConnectRequest  { string port = 1; string vehicle_id = 2; }
message ConnectResponse { bool success = 1; string ecu_id = 2; string error = 3; }

message DisconnectRequest {}
message DisconnectResponse { bool success = 1; }

message StatusRequest {}
message StatusResponse { string status = 1; string ecu_id = 2; string port = 3; }

message ReadRomRequest  { string vehicle_id = 1; }
message ReadRomResponse { bool success = 1; bytes rom_data = 2; uint32 checksum = 3; string error = 4; }

message FlashEcuRequest  { string vehicle_id = 1; string tune_id = 2; string user_id = 3; bytes rom_data = 4; }
message FlashEcuResponse { bool success = 1; string result_code = 2; string error = 3; }

message SensorRequest  { string pid = 1; }
message SensorResponse { bool success = 1; string pid = 2; float value = 3; string unit = 4; string error = 5; }

message AllSensorsRequest {}
message AllSensorsResponse { repeated SensorResponse readings = 1; }
```

gRPC server in src/main.cpp — starts and listens for calls from desktop app:
```cpp
#include <grpcpp/grpcpp.h>
#include "ecu_service.grpc.pb.h"

class EcuServiceImpl final : public ecu::EcuService::Service {
  // Implement each RPC method here
  // Each method calls the appropriate module (OBDReader, ECUConnector, etc.)
};

int main() {
  std::string address("0.0.0.0:50051");
  EcuServiceImpl service;
  grpc::ServerBuilder builder;
  builder.AddListeningPort(address, grpc::InsecureServerCredentials());
  builder.RegisterService(&service);
  auto server = builder.BuildAndStart();
  std::cout << "ECU Service listening on " << address << std::endl;
  server->Wait();
}
```

---

## Step 2.7 — Mock ECU Server

Every automated test uses the mock ECU. Never test against a real car in CI.

tests/mock-ecu/mock_ecu_server.cpp — what it must simulate:
- Respond to OBD-II PID requests with realistic fake values
  - RPM: 1750
  - Coolant: 82 degrees C
  - Throttle: 15%
  - Speed: 0 (car on dyno, not moving)
- Return a fake ROM binary (256KB of generated bytes)
- Accept a flash write and record it happened (do not actually do anything)
- Return a valid checksum for the fake ROM

How tests use it:
- Test binary links against mock server
- ECUConnector's port is set to the mock server address
- All flash pipeline tests use the mock and verify the 7 steps ran in order

---

## Step 2.8 — Write Tests (gtest)

tests/CMakeLists.txt:
```cmake
add_executable(ecu_tests
  test_checksum_engine.cpp
  test_obd_reader.cpp
  test_flash_manager.cpp
)
target_link_libraries(ecu_tests PRIVATE GTest::gtest_main ecu_lib)
add_test(NAME ecu_tests COMMAND ecu_tests)
```

tests/test_checksum_engine.cpp:
```cpp
#include <gtest/gtest.h>
#include "checksum_engine.h"

TEST(ChecksumEngine, ValidChecksumPassesValidation) {
  std::vector<uint8_t> data = {0x01, 0x02, 0x03, 0x04};
  uint32_t checksum = ChecksumEngine::calculate(data);
  EXPECT_TRUE(ChecksumEngine::validate(data, checksum));
}

TEST(ChecksumEngine, CorruptedDataFailsValidation) {
  std::vector<uint8_t> data = {0x01, 0x02, 0x03, 0x04};
  uint32_t checksum = ChecksumEngine::calculate(data);
  data[2] = 0xFF;  // corrupt one byte
  EXPECT_FALSE(ChecksumEngine::validate(data, checksum));
}

TEST(ChecksumEngine, EmptyDataDoesNotCrash) {
  std::vector<uint8_t> empty;
  EXPECT_NO_THROW(ChecksumEngine::calculate(empty));
}

TEST(FlashManager, FlashAbortsIfChecksumInvalid) {
  // Set up mock connector
  // Create ROM data with wrong checksum
  // Call flash
  // Verify result == FlashResult::CHECKSUM_FAILED
  // Verify write was never called
}

TEST(FlashManager, FlashAbortsIfSafetyLimitExceeded) {
  // Create ROM with a value above sensor_limits max
  // Call flash
  // Verify result == FlashResult::SAFETY_LIMIT_EXCEEDED
}
```

Run tests:
```bash
cd services/ecu-service/build
cmake --build . --target ecu_tests
ctest --verbose
```

---

## Done When — Full Checklist

- [ ] CMake builds with zero errors
- [ ] gRPC server starts on port 50051
- [ ] GetStatus gRPC call returns DISCONNECTED status
- [ ] Mock ECU server runs and responds to PID requests
- [ ] OBDReader connects to mock ECU and reads RPM value
- [ ] ECUConnector reads mock ROM binary
- [ ] ChecksumEngine correctly validates a good ROM
- [ ] ChecksumEngine rejects a ROM with one corrupted byte
- [ ] FlashManager aborts at step 1 if checksum invalid (never reaches write)
- [ ] FlashManager aborts at step 2 if sensor limit exceeded
- [ ] FlashManager aborts at step 4 if user confirmation returns false
- [ ] Flash pipeline all 7 steps complete on happy path with mock
- [ ] All gtest tests pass at 80%+ coverage
- [ ] No raw new or delete anywhere — only smart pointers
- [ ] Every read/write has timeout handling

---

## Common Errors

| Error | Cause | Fix |
|---|---|---|
| cmake: command not found | CMake not in PATH | Add CMake to Windows PATH in System Environment Variables |
| Could not find GTest | vcpkg not linked | Add -DCMAKE_TOOLCHAIN_FILE=C:/vcpkg/scripts/buildsystems/vcpkg.cmake |
| use of deleted function | Trying to copy ECUConnector | Pass by reference or use std::move |
| Segmentation fault | Raw pointer used incorrectly | Replace with std::unique_ptr |
| timeout after Nms | Mock ECU not running | Start mock ECU server before running tests |
| grpc: No such file or directory | gRPC not installed | Run: vcpkg install grpc:x64-windows |