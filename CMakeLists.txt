cmake_minimum_required(VERSION 3.16)
project(netmon VERSION 1.0 LANGUAGES C OBJC)

set(CMAKE_C_STANDARD 11)
set(CMAKE_OBJC_FLAGS "-fobjc-arc")
set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)

add_executable(netmon_client MACOSX_BUNDLE
    tools/netmon_cocoa.m)

set_target_properties(netmon_client PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER    "com.haglard.netmon"
    MACOSX_BUNDLE_BUNDLE_NAME       "Vibe NetMon"
    MACOSX_BUNDLE_BUNDLE_VERSION    "1.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0"
    OUTPUT_NAME "Vibe NetMon")

target_compile_options(netmon_client PRIVATE -Wall -Wno-deprecated-declarations)
target_link_libraries(netmon_client PRIVATE
    "-framework AppKit"
    "-framework Foundation")
