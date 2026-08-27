cmake_minimum_required(VERSION 3.5.0)
project(venera_native)

add_library(venerasqlite3 SHARED sqlite/sqlite3.c)

target_include_directories(venerasqlite3 PRIVATE sqlite)

target_compile_options(venerasqlite3 PRIVATE
    -DSQLITE_ENABLE_FTS5
    -DSQLITE_ENABLE_RTREE
    -DSQLITE_ENABLE_JSON1
    -DSQLITE_ENABLE_DBSTAT_VTAB
    -DSQLITE_THREADSAFE=1
    -O2)

# --- flutter_qjs (QuickJS-NG via Dart FFI) ---
set(FLUTTER_QJS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ohos_plugins/flutter_qjs")
set(QUICKJS_NG "${FLUTTER_QJS_DIR}/cxx/quickjs-ng")

if(EXISTS "${QUICKJS_NG}/quickjs.c")
    file(STRINGS "${QUICKJS_NG}/VERSION" QUICKJS_VERSION)
    add_library(quickjs_core STATIC
        "${QUICKJS_NG}/cutils.c"
        "${QUICKJS_NG}/libregexp.c"
        "${QUICKJS_NG}/libunicode.c"
        "${QUICKJS_NG}/quickjs.c"
        "${QUICKJS_NG}/libbf.c"
    )
    set_target_properties(quickjs_core PROPERTIES POSITION_INDEPENDENT_CODE ON)
    target_include_directories(quickjs_core PRIVATE "${QUICKJS_NG}")
    target_compile_definitions(quickjs_core PRIVATE CONFIG_VERSION="${QUICKJS_VERSION}")

    add_library(qjs SHARED "${FLUTTER_QJS_DIR}/cxx/ffi.cpp")
    # Do NOT add ${QUICKJS_NG} to the include path of C++ targets: its
    # bare `VERSION` file shadows libc++'s <version> header on
    # case-insensitive filesystems.
    target_include_directories(qjs PRIVATE "${FLUTTER_QJS_DIR}/cxx")
    target_link_libraries(qjs PRIVATE quickjs_core)
endif()

# --- zip_flutter (kuba--/zip + miniz via Dart FFI) ---
set(ZIP_FLUTTER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ohos_plugins/zip_flutter")
if(EXISTS "${ZIP_FLUTTER_DIR}/src/zip.cc")
    add_library(zip_flutter SHARED
        "${ZIP_FLUTTER_DIR}/src/zip.cc"
    )
    set_target_properties(zip_flutter PROPERTIES OUTPUT_NAME "zip_flutter" CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
    target_include_directories(zip_flutter PRIVATE "${ZIP_FLUTTER_DIR}/src")
    target_compile_definitions(zip_flutter PRIVATE DART_SHARED_LIB)
endif()

# --- lodepng_flutter (single-file LodePNG via Dart FFI) ---
set(LODEPNG_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ohos_plugins/lodepng_flutter")
if(EXISTS "${LODEPNG_DIR}/src/lodepng.c")
    add_library(lodepng_flutter SHARED "${LODEPNG_DIR}/src/lodepng.c")
    set_target_properties(lodepng_flutter PROPERTIES OUTPUT_NAME "lodepng_flutter")
    target_include_directories(lodepng_flutter PRIVATE "${LODEPNG_DIR}/src")
    target_compile_definitions(lodepng_flutter PRIVATE DART_SHARED_LIB)
endif()

# --- flutter_7zip (LZMA SDK via Dart FFI) ---
set(SZ_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ohos_plugins/flutter_7zip")
if(EXISTS "${SZ_DIR}/src/flutter_7zip.cpp")
    set(SZ_BASE "${SZ_DIR}/src/7zip/C")
    add_library(flutter_7zip SHARED
        "${SZ_BASE}/7zAlloc.c"
        "${SZ_BASE}/7zArcIn.c"
        "${SZ_BASE}/7zBuf.c"
        "${SZ_BASE}/7zBuf2.c"
        "${SZ_BASE}/7zCrc.c"
        "${SZ_BASE}/7zCrcOpt.c"
        "${SZ_BASE}/7zDec.c"
        "${SZ_BASE}/7zFile.c"
        "${SZ_BASE}/7zStream.c"
        "${SZ_BASE}/Bcj2.c"
        "${SZ_BASE}/Bra.c"
        "${SZ_BASE}/Bra86.c"
        "${SZ_BASE}/Delta.c"
        "${SZ_BASE}/LzmaDec.c"
        "${SZ_BASE}/Lzma2Dec.c"
        "${SZ_BASE}/CpuArch.c"
        "${SZ_DIR}/src/flutter_7zip.cpp"
    )
    set_target_properties(flutter_7zip PROPERTIES OUTPUT_NAME "flutter_7zip" CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
    target_include_directories(flutter_7zip PRIVATE "${SZ_BASE}")
    target_compile_definitions(flutter_7zip PRIVATE DART_SHARED_LIB)
endif()
