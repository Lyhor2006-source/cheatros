cmake_minimum_required(VERSION 3.20)
project(RosModV2UI LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# Standalone iOS Metal + Dear ImGui UI overlay dylib (`RosModV2UI.dylib`):
#   - UIKit screen-capture container (`CaptureContainerView`)
#   - Metal + ImGui 1.85 WIP HUD overlay & dylib auto-attach (`RyomenXOverlayView`)
#   - Six-tab ImGui menu, Dynamic Island pill, floating HUD, & ESP drawer (`IosUI`)
#
# Building requires an Apple iOS ARM64 SDK (Xcode / Clang targeting iphoneos)
# plus Dear ImGui 1.85 (`IMGUI_DIR`, including `backends/imgui_impl_metal.mm`).
# Define ROSMODV2_DISABLE_AUTO_ATTACH if you attach `RyomenXOverlayView` manually.

if(NOT APPLE)
    message(WARNING "Target OS is not Apple/iOS. Source files require iOS UIKit, Metal, MetalKit, QuartzCore, and CoreGraphics frameworks to compile.")
endif()

set(IMGUI_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/imgui" CACHE PATH "Path to Dear ImGui 1.85 source tree")

set(ROSMODV2_UI_SOURCES
    src/AntiCheatBypass.mm
    src/BrandAssetsData.cpp
    src/CaptureContainerView.mm
    src/RyomenXOverlayView.mm
    src/IosUI.mm
    src/MachMemory.cpp
    src/MemoryCheats.cpp
    src/IosPythonRuntime.mm
    src/RosPayloadData.cpp
    src/IosGameBridge.mm
)

set(ROSMODV2_IMGUI_SOURCES
    "${IMGUI_DIR}/imgui.cpp"
    "${IMGUI_DIR}/imgui_draw.cpp"
    "${IMGUI_DIR}/imgui_tables.cpp"
    "${IMGUI_DIR}/imgui_widgets.cpp"
    "${IMGUI_DIR}/backends/imgui_impl_metal.mm"
)

if(EXISTS "${IMGUI_DIR}/imgui.cpp")
    list(APPEND ROSMODV2_UI_SOURCES ${ROSMODV2_IMGUI_SOURCES})
else()
    message(WARNING "IMGUI_DIR ('${IMGUI_DIR}') does not contain imgui.cpp yet; pass -DIMGUI_DIR=/path/to/imgui when building RosModV2UI.dylib on macOS/iOS.")
endif()

add_library(RosModV2UI SHARED
    ${ROSMODV2_UI_SOURCES}
)

set_target_properties(RosModV2UI PROPERTIES
    PREFIX ""
    SUFFIX ".dylib"
    OUTPUT_NAME "RosModV2UI"
    MACOSX_RPATH ON
    INSTALL_NAME_DIR "@rpath"
)

target_include_directories(RosModV2UI
    PUBLIC
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
        "${IMGUI_DIR}"
        "${IMGUI_DIR}/backends"
)

target_compile_options(RosModV2UI PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
)

if(APPLE)
    target_link_libraries(RosModV2UI PRIVATE
        "-framework Foundation"
        "-framework UIKit"
        "-framework Metal"
        "-framework MetalKit"
        "-framework QuartzCore"
        "-framework CoreGraphics"
    )
endif()
