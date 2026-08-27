cmake_minimum_required(VERSION 3.10)

set(CMAKE_CXX_STANDARD 17)

project(zip_flutter_library_test VERSION 0.0.1 LANGUAGES CXX)

add_executable(zip_flutter_test test.cpp ../zip.cc)

set_target_properties(zip_flutter_test
    PROPERTIES
    OUTPUT_NAME "main"
)