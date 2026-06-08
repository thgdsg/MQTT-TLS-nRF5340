cmake_minimum_required(VERSION 3.20.0)

set(BOARD_FLASH_RUNNER nrfutil CACHE STRING "Use nrfutil for west flash" FORCE)

set(WOLFSSL_MODULE "${CMAKE_CURRENT_SOURCE_DIR}/../modules/wolfssl" CACHE PATH "wolfSSL module path")
set(WOLFMQTT_MODULE "${CMAKE_CURRENT_SOURCE_DIR}/../modules/wolfmqtt" CACHE PATH "wolfMQTT module path")

set(WOLFSSL_MLKEM "yes" CACHE STRING "Enable wolfSSL ML-KEM for TLS 1.3 PQC key exchange")
set(WOLFSSL_PQC_HYBRIDS "no" CACHE STRING "Disable classical/PQC hybrid TLS groups")
set(WOLFSSL_TLS_NO_MLKEM_STANDALONE "no" CACHE STRING "Allow standalone ML-KEM TLS groups")

if(EXISTS "${WOLFSSL_MODULE}/zephyr/module.yml")
  list(APPEND ZEPHYR_EXTRA_MODULES "${WOLFSSL_MODULE}")
endif()

if(EXISTS "${WOLFMQTT_MODULE}/zephyr/module.yml")
  list(APPEND ZEPHYR_EXTRA_MODULES "${WOLFMQTT_MODULE}")
endif()

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(ipsp_mqtt_tls_wolf)

target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
