cmake_minimum_required(VERSION 3.24)

project(PathOfBuildingMacOSHost LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "Build Apple Silicon runtime")

find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL3 REQUIRED sdl3>=3.4.0)
pkg_check_modules(LUAJIT REQUIRED luajit)
pkg_check_modules(ZSTD REQUIRED libzstd)

find_package(CURL REQUIRED)
find_package(ZLIB REQUIRED)

# Bundle identifier. Development builds append "-dev" so a dev run and an
# installed release register as separate apps with macOS (distinct preferences,
# saved window state, LaunchServices entry) instead of fighting over one
# identity. tools/macos/build_app.sh enables MACOS_DEV_BUILD; package_app.sh
# builds the release identity (MACOS_DEV_BUILD OFF).
set(MACOS_BUNDLE_ID "community.pathofbuilding.poebuild2"
    CACHE STRING "Base macOS bundle identifier (release)")
option(MACOS_DEV_BUILD "Append -dev to the bundle id for side-by-side dev installs" OFF)
set(_macos_bundle_id "${MACOS_BUNDLE_ID}")
if(MACOS_DEV_BUILD)
    set(_macos_bundle_id "${_macos_bundle_id}-dev")
endif()

set(APP_ICON "${CMAKE_CURRENT_SOURCE_DIR}/AppIcon.icns")
set_source_files_properties("${APP_ICON}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")

add_executable(PathOfBuilding-PoE2
    src/main.mm
    src/Host.mm
    src/GpuImages.mm
    src/DdsDecode.mm
    src/TgaImage.mm
    src/FontRenderer.mm
    src/SubScript.mm
    "${APP_ICON}"
)

option(POB_BUILD_TESTS "Build native engine regression tests" OFF)
set(host_targets PathOfBuilding-PoE2)
if(POB_BUILD_TESTS)
    enable_testing()
    add_executable(EngineRegressionTests
        tests/EngineRegressionTests.mm
        src/DdsDecode.mm
        src/GpuImages.mm
        src/TgaImage.mm
        src/FontRenderer.mm
    )
    # The regression translation unit includes Host and SubScript so it can
    # exercise their Lua entry points and worker synchronization without a GUI.
    target_compile_options(EngineRegressionTests PRIVATE -UNDEBUG)
    list(APPEND host_targets EngineRegressionTests)
    add_test(NAME engine-regressions COMMAND EngineRegressionTests
        "${CMAKE_CURRENT_SOURCE_DIR}/../PathOfBuilding-PoE2/runtime/SimpleGraphic/Fonts")
    set_tests_properties(engine-regressions PROPERTIES TIMEOUT 15)
    add_test(NAME gpu-image-regressions COMMAND EngineRegressionTests
        "${CMAKE_CURRENT_SOURCE_DIR}/../PathOfBuilding-PoE2/runtime/SimpleGraphic/Fonts" --gpu)
    set_tests_properties(gpu-image-regressions PROPERTIES TIMEOUT 60)
endif()

foreach(host_target IN LISTS host_targets)
    target_include_directories(${host_target} PRIVATE
        ${SDL3_INCLUDE_DIRS}
        ${LUAJIT_INCLUDE_DIRS}
        ${ZSTD_INCLUDE_DIRS}
        src
    )

    target_link_directories(${host_target} PRIVATE
        ${SDL3_LIBRARY_DIRS}
        ${LUAJIT_LIBRARY_DIRS}
        ${ZSTD_LIBRARY_DIRS}
    )

    target_link_libraries(${host_target} PRIVATE
        ${SDL3_LIBRARIES}
        ${LUAJIT_LIBRARIES}
        ${ZSTD_LIBRARIES}
        CURL::libcurl
        ZLIB::ZLIB
        "-framework Cocoa"
    )

    target_compile_options(${host_target} PRIVATE
        ${SDL3_CFLAGS_OTHER}
        ${LUAJIT_CFLAGS_OTHER}
        ${ZSTD_CFLAGS_OTHER}
    )

endforeach()

set_target_properties(PathOfBuilding-PoE2 PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_BUNDLE_NAME "Path of Building (PoE2)"
    MACOSX_BUNDLE_GUI_IDENTIFIER "${_macos_bundle_id}"
    MACOSX_BUNDLE_ICON_FILE "AppIcon"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
)
