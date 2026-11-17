cmake_minimum_required(VERSION 3.21)
project(hangar VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Widgets Network DBus Svg Sql Test)
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

add_library(hangar-core STATIC src/core/store.cpp src/core/control.cpp src/core/launcher.cpp src/core/keymap.cpp src/core/hooks.cpp src/core/restore.cpp src/core/commands.cpp src/core/installers.cpp src/core/livehost.cpp)
target_include_directories(hangar-core PUBLIC src/core)
target_link_libraries(hangar-core PUBLIC Qt6::Core PRIVATE Qt6::Sql)

find_package(KF6Config REQUIRED)
find_package(KF6WidgetsAddons REQUIRED)
add_library(hangar-ui STATIC src/app/mainwindow.cpp src/app/config.cpp src/app/settingsdialog.cpp src/app/sidebar.cpp src/app/palette.cpp src/app/overlay.cpp src/app/dashboard.cpp src/app/library.cpp src/app/attention.cpp src/app/konsoleprivate.cpp src/app/controlui.cpp src/app/help.cpp src/app/smoothwheel.cpp src/app/phone.cpp src/ctl/qrcodegen/qrcodegen.cpp
  resources/resources.qrc)
target_include_directories(hangar-ui PUBLIC src/app)
find_package(KF6Notifications REQUIRED)
find_package(KF6SyntaxHighlighting REQUIRED)
find_package(KF6WindowSystem REQUIRED)
target_link_libraries(hangar-ui PUBLIC hangar-core Qt6::Widgets Qt6::DBus Qt6::Svg KF6::Parts KF6::Notifications KF6::SyntaxHighlighting KF6::WindowSystem KF6::ConfigCore KF6::WidgetsAddons ${CMAKE_DL_LIBS})
add_executable(hangar src/app/main.cpp)
target_link_libraries(hangar PRIVATE hangar-ui Qt6::Network KF6::ConfigCore)

add_executable(hangar-session-host src/host/sessionhost.cpp) # plain POSIX: it outlives the app, so no Qt
target_link_libraries(hangar-session-host PRIVATE util)
add_dependencies(hangar hangar-session-host) # spawned from the app's own directory

add_executable(hangarctl src/ctl/hangarctl.cpp src/ctl/mobile.cpp src/ctl/qrcodegen/qrcodegen.cpp)
target_link_libraries(hangarctl PRIVATE hangar-core Qt6::Network)

enable_testing()
add_executable(test_core tests/test_core.cpp)
target_link_libraries(test_core PRIVATE hangar-core Qt6::Sql Qt6::Test)
target_compile_definitions(test_core PRIVATE HANGAR_SOURCE_SHARE="${CMAKE_SOURCE_DIR}/share" HANGAR_SESSION_HOST="$<TARGET_FILE:hangar-session-host>")
add_dependencies(test_core hangar-session-host)
add_test(NAME core COMMAND test_core)
add_executable(test_ui tests/test_ui.cpp)
target_link_libraries(test_ui PRIVATE hangar-ui Qt6::Test)
add_test(NAME ui COMMAND test_ui)
set_tests_properties(ui PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;HANGAR_STATE_DIR=/tmp/hangar-test-ui")

target_sources(hangar-core PRIVATE src/core/filetree.cpp src/core/fileicons.cpp)
target_sources(hangar-ui PRIVATE src/app/filepanel.cpp src/app/fileviewer.cpp resources/fileicons.qrc)
add_executable(test_filepanel tests/test_filepanel.cpp)
target_link_libraries(test_filepanel PRIVATE hangar-ui Qt6::Test)
add_test(NAME filepanel COMMAND test_filepanel)
set_tests_properties(filepanel PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

include(GNUInstallDirs)
install(TARGETS hangar hangarctl hangar-session-host RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
configure_file(packaging/hangar.desktop.in hangar.desktop @ONLY) # Exec is absolute: the Plasma menu does not see ~/.local/bin
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/hangar.desktop DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
install(DIRECTORY resources/icons/ DESTINATION ${CMAKE_INSTALL_DATADIR}/icons)
install(DIRECTORY share/agent-status share/skill USE_SOURCE_PERMISSIONS DESTINATION ${CMAKE_INSTALL_DATADIR}/hangar)
# a build-tree run finds the shipped agent-status package and skill in the source tree
target_compile_definitions(hangar-ui PRIVATE HANGAR_SOURCE_SHARE="${CMAKE_SOURCE_DIR}/share")
