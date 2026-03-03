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
