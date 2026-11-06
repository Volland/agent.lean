# agent_llama: in-process local inference as a byte transport (ADR 0004).
#
#   scripts/fetch_llama.sh                       # clone pinned llama.cpp, download the model, build the libs
#   cmake -S c/llama -B build/llama/build && cmake --build build/llama/build
#
# Builds llama.cpp (static: llama, ggml, llama-common) from LLAMA_CPP_DIR, the adapter library
# `agent_llama`, and -- when the agent.lean source bundle is present -- the test programs
# `llama_run`, `llama_constrained` and `llama_conformance`.
cmake_minimum_required(VERSION 3.20)
project(agent_llama C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

get_filename_component(AGENT_REPO ${CMAKE_CURRENT_SOURCE_DIR}/../.. ABSOLUTE)
set(LLAMA_CPP_DIR ${AGENT_REPO}/build/llama/llama.cpp CACHE PATH "llama.cpp checkout (scripts/fetch_llama.sh)")
set(AGENT_BUNDLE_DIR ${AGENT_REPO}/build/bundle-dev CACHE PATH "agent.lean CMake source bundle")
if(EXISTS ${AGENT_BUNDLE_DIR}/CMakeLists.txt)
  set(AGENT_LLAMA_TESTS_DEFAULT ON)
else()
  set(AGENT_LLAMA_TESTS_DEFAULT OFF)
endif()
option(AGENT_LLAMA_TESTS "Build llama_run / llama_constrained / llama_conformance" ${AGENT_LLAMA_TESTS_DEFAULT})

if(NOT EXISTS ${LLAMA_CPP_DIR}/CMakeLists.txt)
  message(FATAL_ERROR "llama.cpp not found at ${LLAMA_CPP_DIR}; run scripts/fetch_llama.sh")
endif()

# llama.cpp as static libraries: only the core, ggml and the common utils (chat templates, grammars).
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)
foreach(opt LLAMA_BUILD_TESTS LLAMA_BUILD_TOOLS LLAMA_BUILD_EXAMPLES LLAMA_BUILD_SERVER LLAMA_BUILD_APP
            LLAMA_BUILD_UI LLAMA_OPENSSL LLAMA_LLGUIDANCE LLAMA_ALL_WARNINGS)
  set(${opt} OFF CACHE BOOL "" FORCE)
endforeach()
if(APPLE)
  set(GGML_METAL ON CACHE BOOL "" FORCE)
  set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
else()
  set(GGML_METAL OFF CACHE BOOL "" FORCE)
endif()
add_subdirectory(${LLAMA_CPP_DIR} llama.cpp EXCLUDE_FROM_ALL)

# The adapter: request body bytes in, response body bytes out. It needs only the agent_buf_t type
# from agent.h, not the agent core.
add_library(agent_llama STATIC agent_llama.cpp agent_llama.h)
target_include_directories(agent_llama PUBLIC ${CMAKE_CURRENT_SOURCE_DIR} ${AGENT_REPO}/c)
target_link_libraries(agent_llama PUBLIC llama llama-common)

if(AGENT_LLAMA_TESTS)
  add_subdirectory(${AGENT_BUNDLE_DIR} agentlean_bundle EXCLUDE_FROM_ALL)

  add_executable(llama_run llama_run.cpp)
  target_link_libraries(llama_run PRIVATE agent_llama agentlean)

  add_executable(llama_constrained llama_constrained.cpp)
  target_link_libraries(llama_constrained PRIVATE agent_llama agentlean)

  # Replays a golden file through the C ABI (c/tests/conformance.c); named apart from the bundle's own
  # `conformance` example target.
  add_executable(llama_conformance ${AGENT_REPO}/c/tests/conformance.c)
  target_include_directories(llama_conformance PRIVATE ${AGENT_REPO}/c/tests)
  target_link_libraries(llama_conformance PRIVATE agentlean)
  set_target_properties(llama_conformance PROPERTIES LINKER_LANGUAGE CXX)
endif()
