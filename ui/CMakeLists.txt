cmake_minimum_required(VERSION 3.28)

set(APP_ID org.waywallen.waywallen)
set(APP_NAME "waywallen-ui")
set(APP_VERSION "0.2.1")
set(APP_SUMMARY "Wallpaper Manager for Linux")
set(APP_AUTHOR "hypengw")

project(waywallen-ui LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(BUILD_SHARED_LIBS OFF)

# WAYWALLEN_QML_FILESYSTEM: load QML files from disk at runtime instead of
# embedding them into the binary as Qt resources.
#
# OFF (default): QML is compiled into the binary via qrc — correct for AppImage.
# ON:  QML files are NOT embedded. The binary reads them from the build tree
#      (or wherever QML_IMPORT_PATH / QML2_IMPORT_PATH points).
#      Changes to .qml files take effect on the NEXT UI restart — no C++ rebuild.
#      Only meaningful for local dev; never use this for release/AppImage builds.
option(WAYWALLEN_QML_FILESYSTEM
    "Load QML from disk at runtime (dev hot-reload). Do not use for AppImage builds." OFF)

find_package(Qt6 REQUIRED COMPONENTS Quick DBus Protobuf ProtobufQuick ProtobufWellKnownTypes QuickPrivate)

option(WAYWALLEN_ENABLE_WEBENGINE "Enable the embedded Workshop browser when QtWebEngineQuick is available" ON)
option(WAYWALLEN_REQUIRE_WEBENGINE "Require QtWebEngineQuick for the embedded Workshop browser" OFF)
# Optional outside full/AppImage builds.  Lite AppImage builds pass
# WAYWALLEN_ENABLE_WEBENGINE=OFF to keep QtWebEngine out even if it exists in
# the build environment.
if(WAYWALLEN_ENABLE_WEBENGINE)
  find_package(Qt6 COMPONENTS WebEngineQuick QUIET)
endif()
if(WAYWALLEN_REQUIRE_WEBENGINE AND NOT TARGET Qt6::WebEngineQuick)
  message(FATAL_ERROR "WAYWALLEN_REQUIRE_WEBENGINE=ON, but Qt6::WebEngineQuick was not found")
endif()
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/SplitMocFiles.cmake)

if(QT_KNOWN_POLICY_QTP0004)
  qt_policy(SET QTP0003 NEW)
  qt_policy(SET QTP0004 NEW)
endif()
set(QT_QML_GENERATE_QMLLS_INI ON)

set(QT_QML_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/qml_modules")
set(QML_IMPORT_PATH
    "${CMAKE_CURRENT_BINARY_DIR}/qml_modules"
    CACHE STRING "QML import paths for IDE and tooling" FORCE
)
list(APPEND QML_DIRS "${QT_QML_OUTPUT_DIRECTORY}")
if("${QT_INSTALL_QML}" STREQUAL "")
  set(QT_INSTALL_QML "${CMAKE_INSTALL_LIBDIR}/qt6/qml")
endif()

set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)
include(${CMAKE_SOURCE_DIR}/cmake/FetchDeps.cmake)
fetchdeps(${CMAKE_SOURCE_DIR}/deps.json)

qt_standard_project_setup()

# ---------------------------------------------------------------------------
# Control-plane protobuf (shared schema with the Rust backend).
# Generates C++/QML types from ../proto/control.proto and ../proto/filter.proto
# via qt_add_protobuf.
# ---------------------------------------------------------------------------
set(WAYWALLEN_PROTO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../proto")
qt_add_protobuf(waywallen-control
    QML
    QML_URI waywallen.control
    PROTO_FILES
        "${WAYWALLEN_PROTO_DIR}/control.proto"
        "${WAYWALLEN_PROTO_DIR}/filter.proto"
    PROTO_INCLUDES
        "${WAYWALLEN_PROTO_DIR}"
)

set(SOURCES_NO_MOC
  src/action.cpp
  src/util.cpp
  src/backend.cpp
  src/app.cpp
  src/daemon_dbus.cpp
  src/objmodel/display.cpp
  src/objmodel/gpu.cpp
  src/objmodel/library.cpp
  src/notify.cpp
  src/objmodel/renderer.cpp
  src/msg/store.cpp
  src/model/store_item.cpp
  src/model/list_models.cpp
  src/model/wallpaper_select_storage.cpp
  src/model/remote_model.cpp
  src/model/filter_rule_model.cpp
  src/model/user_property_model.cpp
  src/query/wallpaper_query.cpp
  src/query/renderer_query.cpp
  src/query/source_query.cpp
  src/query/plugin_query.cpp
  src/query/tag_query.cpp
  src/query/health_query.cpp
  src/query/display_query.cpp
  src/query/gpu_query.cpp
  src/query/library_query.cpp
  src/query/settings_query.cpp
  src/query/remote_query.cpp
  src/query/playlist_query.cpp
  src/thumb/service.cpp
)

set(SOURCES
  src/qml_register.cpp
)

set(MOC_SOURCE_FILES
  src/action.cppm
  src/util.cppm
  src/app.cppm
  src/backend.cppm
  src/daemon_dbus.cppm
  src/objmodel/display.cppm
  src/objmodel/gpu.cppm
  src/objmodel/library.cppm
  src/notify.cppm
  src/objmodel/renderer.cppm
  src/msg/store.cppm
  src/model/store_item.cppm
  src/model/list_models.cppm
  src/model/wallpaper_select_storage.cppm
  src/model/remote_model.cppm
  src/model/filter_rule_model.cppm
  src/model/user_property_model.cppm
  src/query/wallpaper_query.cppm
  src/query/renderer_query.cppm
  src/query/source_query.cppm
  src/query/plugin_query.cppm
  src/query/tag_query.cppm
  src/query/health_query.cppm
  src/query/display_query.cppm
  src/query/gpu_query.cppm
  src/query/library_query.cppm
  src/query/settings_query.cppm
  src/query/remote_query.cppm
  src/query/playlist_query.cppm
  src/thumb/service.cppm
)
set(MODULES
    src/mod.cppm
    src/proto.cppm
    src/model/share_store.cppm
    src/msg/backend_msg.cppm
    src/query/query.cppm
    src/query/mod.cppm
)

set(QML_FILES
  qml/Window.qml
  qml/Global.qml
  qml/component/StatusDot.qml
  qml/component/PagePopup.qml
  qml/component/Tag.qml
  qml/component/GpuTag.qml
  qml/component/KdeDisplaysHelp.qml
  qml/component/ThumbnailImage.qml
  qml/component/SearchChip.qml
  qml/component/filter/StringFilter.qml
  qml/component/filter/IntFilter.qml
  qml/component/filter/WpTypeFilter.qml
  qml/component/filter/TagFilter.qml
  qml/component/filter/TagPickerDialog.qml
  qml/component/filter/ContentRatingFilter.qml
  qml/component/filter/EmptyFilter.qml
  qml/component/filter/WallpaperFilter.qml
  qml/component/settings/SettingField.qml
  qml/dialog/DaemonNotRunDialog.qml
  qml/dialog/WallpaperFilterDialog.qml
  qml/dialog/RemoteFilterDialog.qml
  qml/page/WallpaperPage.qml
  qml/page/PlaylistDetailPanel.qml
  qml/page/WallpaperDetailPanel.qml
  qml/page/WallpaperInfoPage.qml
  qml/page/WallpaperCard.qml
  qml/page/wallpaper/SelectSheet.qml
  qml/page/wallpaper/TweakSheet.qml
  qml/page/wallpaper/TweakState.qml
  qml/page/wallpaper/NewPlaylistSheetContent.qml
  qml/page/wallpaper/AddToPlaylistSheetContent.qml
  qml/page/wallpaper/SelectSheetContentState.qml
  qml/page/wallpaper/PlaylistListSheet.qml
  qml/page/wallpaper/PlaylistListSheetState.qml
  qml/page/DiscoverPage.qml
  qml/page/RemoteCard.qml
  qml/page/StatusPage.qml
  qml/page/PluginManagePage.qml
  qml/page/SettingsPage.qml
  qml/page/DisplaysPage.qml
  qml/page/SourceManagePage.qml
  qml/page/AddLibraryPage.qml
  qml/page/AboutPage.qml
  qml/page/PluginSettingsPage.qml
  qml/page/WorkshopPage.qml
  qml/page/HotkeysSettingsPage.qml
  qml/component/HotkeyActionCatalog.qml
  qml/component/HotkeyActionRow.qml
  qml/component/BindingChip.qml
)

if(TARGET Qt6::WebEngineQuick)
  list(APPEND QML_FILES qml/component/EmbeddedWorkshop.qml)
endif()

set(RESOURCES
  assets/waywallen-ui.svg
)

set_source_files_properties(qml/Global.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

set(QML_REG_INCLUDE_DIRS
    "${CMAKE_CURRENT_SOURCE_DIR}/include/waywallen/register"
    "${CMAKE_CURRENT_SOURCE_DIR}/include/waywallen/query"
)

set(APP_INFO_MACROS
    APP_ID="${APP_ID}" APP_VERSION="${APP_VERSION}" APP_AUTHOR="${APP_AUTHOR}"
    APP_NAME="${APP_NAME}" APP_SUMMARY="${APP_SUMMARY}")

if(WAYWALLEN_QML_FILESYSTEM)
  message(STATUS "waywallen: WAYWALLEN_QML_FILESYSTEM=ON — QML loaded from disk (dev mode)")
  # Module stays STATIC (no linker issues with MODULE_LIBRARY).
  # NO_CACHEGEN: skip .qmlc so Qt reads raw .qml source at runtime.
  # The running binary finds QML via QML_IMPORT_PATH pointing at the
  # build-tree qml_modules/ directory (set by app.cpp / dev_watch.sh).
  set(_QML_MODULE_TYPE STATIC)
  set(_QML_EXTRA_FLAGS NO_CACHEGEN)
else()
  set(_QML_MODULE_TYPE STATIC)
  set(_QML_EXTRA_FLAGS "")
endif()
set(_QML_PLUGIN_TARGET waywallen-qml)

qt_add_qml_module(
  waywallen-qml
  URI
  waywallen.ui
  ${_QML_MODULE_TYPE}
  ${_QML_EXTRA_FLAGS}
  PLUGIN_TARGET
  ${_QML_PLUGIN_TARGET}
  DEPENDENCIES
  QtCore
  QtQuick
  QtQuick.Shapes
  QtQml.Models
  Qcm.Material
  waywallen.control
  OUTPUT_TARGETS
  waywallen_ui_targets
  RESOURCE_PREFIX
  /
  VERSION
  ${APP_VERSION}
  QML_FILES
  ${QML_FILES}
  SOURCES
  ${SOURCES}
  RESOURCES
  ${RESOURCES}
  NO_PLUGIN_OPTIONAL)

if(WAYWALLEN_QML_FILESYSTEM)
  # Expose the source QML directory to the binary at compile time so
  # app.cpp can add it as an import path without hard-coding a path.
  target_compile_definitions(waywallen-qml PUBLIC
    WAYWALLEN_QML_SRC_DIR="${CMAKE_CURRENT_SOURCE_DIR}/qml"
    WAYWALLEN_QML_BUILD_DIR="${CMAKE_BINARY_DIR}/qml_modules"
  )
endif()

target_sources(waywallen-qml PUBLIC FILE_SET CXX_MODULES FILES ${MODULES} ${MOC_SOURCE_FILES})
target_sources(waywallen-qml PRIVATE ${SOURCES_NO_MOC})

set_source_files_properties(
  "${CMAKE_CURRENT_BINARY_DIR}/waywallen-qml_qmltyperegistrations.cpp" TARGET_DIRECTORY
  waywallen-qml PROPERTIES INCLUDE_DIRECTORIES "${QML_REG_INCLUDE_DIRS}")
set_source_files_properties(${SOURCES_NO_MOC} PROPERTIES SKIP_AUTOMOC ON)
#set_source_files_properties( PROPERTIES COMPILE_DEFINITIONS "${APP_INFO_MACROS}")

set_target_properties(waywallen-qml PROPERTIES CXX_SCAN_FOR_MODULES ON)

split_moc_files(
  TARGET
  waywallen-qml
  BASE_DIR
  src
  PREFIX
  waywallen
  MOC_SOURCE_FILES
  ${MOC_SOURCE_FILES})

#target_compile_definitions(
#  waywallen.ui
#  PUBLIC APP_ID="${APP_ID}" APP_VERSION="${APP_VERSION}"
#         APP_AUTHOR="${APP_AUTHOR}" APP_NAME="${APP_NAME}"
#         APP_SUMMARY="${APP_SUMMARY}")

target_include_directories(
  waywallen-qml
  PUBLIC include
  PRIVATE . # src/
)
target_compile_features(waywallen-qml PUBLIC cxx_std_20)
target_link_libraries(waywallen-qml
  PUBLIC
    Qt6::DBus
    Qt6::Protobuf
    Qt6::ProtobufQuick
    Qt6::ProtobufWellKnownTypes
    waywallen-control
    qml_material::qml_material
    ncrequest
    qextra
    wavsen::decode
)

# Link QtWebEngine only for builds that provide it.  Without this target the
# Workshop page falls back to Steam/system browser and no QtWebEngine QML is
# imported into the resource module.
if(TARGET Qt6::WebEngineQuick)
  target_link_libraries(waywallen-qml PUBLIC Qt6::WebEngineQuick)
  target_compile_definitions(waywallen-qml PUBLIC
    WAYWALLEN_HAS_WEBENGINE=1
    WAYWALLEN_FLAVOR="full"
  )
else()
  target_compile_definitions(waywallen-qml PUBLIC
    WAYWALLEN_FLAVOR="lite"
  )
endif()

qt_add_executable(${PROJECT_NAME} MANUAL_FINALIZATION src/main.cpp)
set_target_properties(${PROJECT_NAME} PROPERTIES
  CXX_SCAN_FOR_MODULES ON
  INSTALL_RPATH "${WAYWALLEN_BIN_RPATH}"
)
target_compile_definitions(${PROJECT_NAME} PRIVATE "${APP_INFO_MACROS}")
target_link_libraries(${PROJECT_NAME} PRIVATE waywallen-qml)

set(APP_DESKTOP assets/waywallen-ui.desktop)
set(APP_METAINFO assets/waywallen-ui.metainfo.xml)
set(APP_SVG assets/waywallen-ui.svg)
file(READ assets/waywallen-ui.releases.xml APP_RELEASES)
configure_file(${APP_DESKTOP}.in ${APP_DESKTOP} @ONLY)
configure_file(${APP_METAINFO}.in ${APP_METAINFO} @ONLY)

install(
  TARGETS ${PROJECT_NAME}
  BUNDLE DESTINATION .
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})

install(
  FILES "${CMAKE_CURRENT_BINARY_DIR}/${APP_DESKTOP}"
  RENAME ${APP_ID}.desktop
  DESTINATION share/applications)
install(
  FILES "${CMAKE_CURRENT_BINARY_DIR}/${APP_METAINFO}"
  RENAME ${APP_ID}.metainfo.xml
  DESTINATION share/metainfo)
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${APP_SVG}")
  install(
    FILES ${APP_SVG}
    RENAME ${APP_ID}.svg
    DESTINATION share/icons/hicolor/scalable/apps)
endif()

qt_finalize_target(${PROJECT_NAME})
