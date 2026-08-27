# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

set(CMAKE_CXX_STANDARD 17)

project(zip_flutter_library VERSION 0.0.1 LANGUAGES CXX)

add_link_options("-Wl,--build-id=none")
add_library(zip_flutter SHARED
        "zip.cc"
        "miniz.h"
        "zip.h"
)

set_target_properties(zip_flutter PROPERTIES
  PUBLIC_HEADER zip.h
  OUTPUT_NAME "zip_flutter"
)

target_compile_definitions(zip_flutter PUBLIC DART_SHARED_LIB)
