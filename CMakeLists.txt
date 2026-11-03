cmake_minimum_required(VERSION 3.21)
project(agterm-qt VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Widgets Network DBus Svg Test)
find_package(KF6CoreAddons REQUIRED)
find_package(KF6XmlGui REQUIRED)
set(CMAKE_AUTORCC ON)

# KParts: the real package when libkf6parts-dev is installed, else headers unpacked by
# scripts/fetch-kparts-headers.sh linked against the runtime library (no root needed).
find_package(KF6Parts QUIET)
if(NOT TARGET KF6::Parts)
  find_path(KPARTS_INCLUDE_DIR kparts/readonlypart.h
    PATHS ${CMAKE_SOURCE_DIR}/.deps/usr/include/KF6/KParts NO_DEFAULT_PATH)
  find_library(KPARTS_LIBRARY NAMES libKF6Parts.so.6 KF6Parts)
  if(NOT KPARTS_INCLUDE_DIR OR NOT KPARTS_LIBRARY)
    message(FATAL_ERROR "KParts headers not found: install libkf6parts-dev or run scripts/fetch-kparts-headers.sh")
  endif()
  add_library(KF6::Parts UNKNOWN IMPORTED)
  set_target_properties(KF6::Parts PROPERTIES
    IMPORTED_LOCATION ${KPARTS_LIBRARY}
    INTERFACE_INCLUDE_DIRECTORIES ${KPARTS_INCLUDE_DIR}
    INTERFACE_LINK_LIBRARIES "KF6::CoreAddons;KF6::XmlGui")
endif()

add_library(agterm-core STATIC src/core/store.cpp src/core/control.cpp src/core/launcher.cpp)
target_include_directories(agterm-core PUBLIC src/core)
target_link_libraries(agterm-core PUBLIC Qt6::Core)

find_package(KF6Config REQUIRED)
add_library(agterm-ui STATIC src/app/mainwindow.cpp src/app/sidebar.cpp src/app/palette.cpp resources/resources.qrc)
target_include_directories(agterm-ui PUBLIC src/app)
target_link_libraries(agterm-ui PUBLIC agterm-core Qt6::Widgets Qt6::DBus Qt6::Svg KF6::Parts)
add_executable(agterm-qt src/app/main.cpp)
target_link_libraries(agterm-qt PRIVATE agterm-ui Qt6::Network KF6::ConfigCore)

add_executable(agtermctl src/ctl/agtermctl.cpp)
target_link_libraries(agtermctl PRIVATE agterm-core Qt6::Network)

enable_testing()
add_executable(test_core tests/test_core.cpp)
target_link_libraries(test_core PRIVATE agterm-core Qt6::Test)
add_test(NAME core COMMAND test_core)
add_executable(test_ui tests/test_ui.cpp)
target_link_libraries(test_ui PRIVATE agterm-ui Qt6::Test)
add_test(NAME ui COMMAND test_ui)
set_tests_properties(ui PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;AGTERM_STATE_DIR=/tmp/agterm-qt-test-ui")

target_sources(agterm-core PRIVATE src/core/filetree.cpp src/core/fileicons.cpp)
target_sources(agterm-ui PRIVATE src/app/filepanel.cpp src/app/fileviewer.cpp resources/fileicons.qrc)
add_executable(test_filepanel tests/test_filepanel.cpp)
target_link_libraries(test_filepanel PRIVATE agterm-ui Qt6::Test)
add_test(NAME filepanel COMMAND test_filepanel)
set_tests_properties(filepanel PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

include(GNUInstallDirs)
install(TARGETS agterm-qt agtermctl RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES packaging/agterm-qt.desktop DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
install(PROGRAMS share/agent-status/agterm-agent-status.sh share/agent-status/agterm-claude-status.sh
  DESTINATION ${CMAKE_INSTALL_DATADIR}/agterm-qt/agent-status)
