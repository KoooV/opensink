cmake_minimum_required(VERSION 3.13)
project(app_linux LANGUAGES CXX)

set(BINARY_NAME "app")

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE STRING "Flutter build mode" FORCE)
endif()

function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
endfunction()

set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
if(EXISTS "${FLUTTER_MANAGED_DIR}")
  add_subdirectory(${FLUTTER_MANAGED_DIR})
endif()

add_subdirectory("runner")

add_dependencies(${BINARY_NAME} flutter_assemble)

set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "bin")
