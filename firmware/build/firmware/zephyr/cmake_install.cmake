# Install script for directory: /home/thiago/ncs/v2.6.0/zephyr

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "/usr/local")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "TRUE")
endif()

# Set default install directory permissions.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "/home/thiago/ncs/toolchains/2be090971e/opt/zephyr-sdk/arm-zephyr-eabi/bin/arm-zephyr-eabi-objdump")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/zephyr/arch/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/zephyr/lib/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/zephyr/soc/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/zephyr/boards/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/zephyr/subsys/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/zephyr/drivers/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/nrf/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/mcuboot/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/mbedtls/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/trusted-firmware-m/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/cjson/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/azure-sdk-for-c/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/cirrus-logic/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/openthread/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/memfault-firmware-sdk/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/canopennode/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/chre/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/lz4/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/nanopb/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/zscilib/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/cmsis/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/cmsis-dsp/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/cmsis-nn/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/fatfs/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/hal_nordic/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/st/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/hal_wurthelektronik/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/libmetal/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/liblc3/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/littlefs/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/loramac-node/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/lvgl/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/mipi-sys-t/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/nrf_hw_models/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/open-amp/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/picolibc/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/segger/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/tinycrypt/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/uoscore-uedhoc/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/zcbor/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/wolfssl/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/wolfmqtt/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/nrfxlib/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/modules/connectedhomeip/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/zephyr/kernel/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/zephyr/cmake/flash/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/zephyr/cmake/usage/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build/firmware/zephyr/cmake/reports/cmake_install.cmake")
endif()

