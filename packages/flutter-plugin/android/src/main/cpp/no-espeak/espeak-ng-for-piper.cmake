# GPL-free stand-in for sherpa-onnx's cmake/espeak-ng-for-piper.cmake — see README.md.
set(espeak_ng_SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR})
if(NOT TARGET espeak-ng)
  add_library(espeak-ng STATIC ${CMAKE_CURRENT_LIST_DIR}/no_espeak.cc)
  target_include_directories(espeak-ng PUBLIC ${CMAKE_CURRENT_LIST_DIR}/include)
  set_target_properties(espeak-ng PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()
message(STATUS "espeak-ng: NOT built (GPL-free stand-in from ${CMAKE_CURRENT_LIST_DIR})")
