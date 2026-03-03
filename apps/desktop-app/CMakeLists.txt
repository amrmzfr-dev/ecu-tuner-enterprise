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
