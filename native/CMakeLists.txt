cmake_minimum_required(VERSION 3.13)
project(mirrorcore C)

# The AirPlay core is built as a SHARED library, not linked into the app.
# Everything copyleft (UxPlay's lib/, playfair, libplist) lives here behind the
# small C ABI in include/mirror_bridge.h, so this component can be rebuilt from
# source and swapped without rebuilding the app. See licenses/NOTICE.md.
set(NO_MARCH_NATIVE ON)
add_definitions(-DUXPLAY_HAVE_APPLE_P2P)

# Required: the static sub-libraries get linked into a shared object.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(UXPLAY ${CMAKE_CURRENT_SOURCE_DIR}/../vendor/UxPlay)

add_subdirectory(${UXPLAY}/lib/dns_sd dns_sd)
add_subdirectory(${UXPLAY}/lib/llhttp llhttp)
add_subdirectory(${UXPLAY}/lib/playfair playfair)
add_subdirectory(${UXPLAY}/lib airplay)

add_library(mirrorcore SHARED mirror_bridge.c)
target_include_directories(mirrorcore PRIVATE
    ${UXPLAY}/lib
    ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(mirrorcore PRIVATE airplay)

# Only the mb_* bridge API is exported, keeping the boundary between this
# library and the application explicit.
set_target_properties(mirrorcore PROPERTIES
    OUTPUT_NAME MirrorCore
    MACOSX_RPATH ON
    INSTALL_NAME_DIR "@rpath"
    LINK_FLAGS "-Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/exported_symbols.txt")
