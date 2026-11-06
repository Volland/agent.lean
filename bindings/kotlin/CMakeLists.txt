# libagentlean_jni: the JNI glue (jni/agent_jni.c) linked against the agent.lean static library.
#
# The static library comes from the generated source bundle (bundle/out), added as a subdirectory,
# or, for quick desktop builds, from an already-built libagentlean.a (AGENTLEAN_PREBUILT_LIB).
#
#   cmake -S bindings/kotlin -B build/jni-host                                   # desktop JVM
#   cmake -S bindings/kotlin -B build/jni-arm64 \
#     -DCMAKE_TOOLCHAIN_FILE=$ANDROID_HOME/ndk/<ver>/build/cmake/android.toolchain.cmake \
#     -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_static  # Android
cmake_minimum_required(VERSION 3.20)
project(agentlean_jni C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(AGENTLEAN_BUNDLE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../bundle/out" CACHE PATH
  "agent.lean source bundle (output of scripts/bundle.py)")
set(AGENTLEAN_PREBUILT_LIB "" CACHE FILEPATH
  "Optional prebuilt libagentlean.a for this target; when set the bundle is not compiled")
get_filename_component(AGENTLEAN_BUNDLE_DIR "${AGENTLEAN_BUNDLE_DIR}" ABSOLUTE)
if(NOT EXISTS "${AGENTLEAN_BUNDLE_DIR}/extra/agent.h")
  message(FATAL_ERROR "AGENTLEAN_BUNDLE_DIR=${AGENTLEAN_BUNDLE_DIR} has no extra/agent.h; run scripts/bundle.py")
endif()

if(AGENTLEAN_PREBUILT_LIB)
  find_package(Threads REQUIRED)
  add_library(agentlean STATIC IMPORTED)
  set_target_properties(agentlean PROPERTIES
    IMPORTED_LOCATION "${AGENTLEAN_PREBUILT_LIB}"
    INTERFACE_INCLUDE_DIRECTORIES "${AGENTLEAN_BUNDLE_DIR}/extra"
    INTERFACE_LINK_LIBRARIES Threads::Threads)
  if(ANDROID)
    set_property(TARGET agentlean APPEND PROPERTY INTERFACE_LINK_LIBRARIES log)
  endif()
else()
  # EXCLUDE_FROM_ALL: build only the library, not the bundle's example programs.
  add_subdirectory("${AGENTLEAN_BUNDLE_DIR}" agentlean_bundle EXCLUDE_FROM_ALL)
endif()

add_library(agentlean_jni SHARED jni/agent_jni.c)
target_link_libraries(agentlean_jni PRIVATE agentlean)
target_include_directories(agentlean_jni PRIVATE "${AGENTLEAN_BUNDLE_DIR}/extra")
# The Lean runtime inside libagentlean.a is C++: link with the C++ driver so libc++ comes along
# (on Android, ANDROID_STL=c++_static links it statically into this .so).
set_target_properties(agentlean_jni PROPERTIES
  LINKER_LANGUAGE CXX
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden)

if(ANDROID)
  # jni.h comes from the NDK sysroot. Keep only the JNI entry points exported, drop unused
  # sections, and align segments to 16 KB pages (required for Android 15+ devices).
  target_link_options(agentlean_jni PRIVATE
    -Wl,--gc-sections -Wl,--exclude-libs,ALL -Wl,-z,max-page-size=16384)
else()
  set(AGENTLEAN_JNI_INCLUDE "" CACHE PATH "Directory holding jni.h (default: $JAVA_HOME/include)")
  if(NOT AGENTLEAN_JNI_INCLUDE)
    find_path(AGENTLEAN_JNI_INCLUDE jni.h
      HINTS "$ENV{JAVA_HOME}/include" "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home/include"
      REQUIRED)
  endif()
  if(APPLE)
    set(_md darwin)
  elseif(WIN32)
    set(_md win32)
  else()
    set(_md linux)
  endif()
  target_include_directories(agentlean_jni PRIVATE "${AGENTLEAN_JNI_INCLUDE}" "${AGENTLEAN_JNI_INCLUDE}/${_md}")
  if(APPLE)
    target_link_options(agentlean_jni PRIVATE -Wl,-dead_strip)
  else()
    target_link_options(agentlean_jni PRIVATE -Wl,--gc-sections -Wl,--exclude-libs,ALL)
  endif()
endif()
