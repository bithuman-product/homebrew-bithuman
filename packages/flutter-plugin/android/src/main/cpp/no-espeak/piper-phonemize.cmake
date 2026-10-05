# GPL-free stand-in for sherpa-onnx's cmake/piper-phonemize.cmake — see README.md.
if(NOT TARGET piper_phonemize)
  add_library(piper_phonemize STATIC ${CMAKE_CURRENT_LIST_DIR}/no_piper.cc)
  target_include_directories(piper_phonemize PUBLIC ${CMAKE_CURRENT_LIST_DIR}/include)
  target_link_libraries(piper_phonemize PUBLIC espeak-ng)
  set_target_properties(piper_phonemize PROPERTIES POSITION_INDEPENDENT_CODE ON)
  install(TARGETS piper_phonemize espeak-ng DESTINATION lib)
endif()
message(STATUS "piper-phonemize: NOT built (GPL-free stand-in)")
