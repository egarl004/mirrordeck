cmake_minimum_required(VERSION 3.13)
project(mirrorcore C)

set(NO_MARCH_NATIVE ON)
add_definitions(-DUXPLAY_HAVE_APPLE_P2P)

set(UXPLAY ${CMAKE_CURRENT_SOURCE_DIR}/../vendor/UxPlay)

add_subdirectory(${UXPLAY}/lib/dns_sd dns_sd)
add_subdirectory(${UXPLAY}/lib/llhttp llhttp)
add_subdirectory(${UXPLAY}/lib/playfair playfair)
add_subdirectory(${UXPLAY}/lib airplay)

add_library(mirrorbridge STATIC mirror_bridge.c)
target_include_directories(mirrorbridge PRIVATE
    ${UXPLAY}/lib
    ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(mirrorbridge airplay)
