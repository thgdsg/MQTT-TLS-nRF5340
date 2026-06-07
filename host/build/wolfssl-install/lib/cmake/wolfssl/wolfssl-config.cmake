
# Autoconf-generated configs won't define PACKAGE_PREFIX_DIR; fall back to the
# configured install prefix for non-relocatable packages.
if (NOT DEFINED PACKAGE_PREFIX_DIR)
  set(PACKAGE_PREFIX_DIR "/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/host/build/wolfssl-install")
endif()

include(CMakeFindDependencyMacro)
if (1)
  find_dependency(Threads)
endif()


include ( "${CMAKE_CURRENT_LIST_DIR}/wolfssl-targets.cmake" )
