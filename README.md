# IPSP MQTT/TLS wolfSSL/wolfMQTT

Projeto experimental para `nRF5340 DK` usando:

- Bluetooth LE IPSP / IPv6-over-BLE no NCS `v2.6.0`
- wolfSSL + wolfMQTT no firmware cliente
- wolfSSL + wolfMQTT broker no host
- MQTT/TLS sobre TCP/IPv6 via interface Linux `bt0`

## Arquitetura

```text
nRF5340 DK
  BLE IPSP
  IPv6: 2001:db8::1
  TCP/TLS
  wolfMQTT client
        |
        | BLE 6LoWPAN / IPSP
        v
Linux bt0
  IPv6: 2001:db8::2
  wolfMQTT broker TLS :8883
```

## 1. Buscar wolfSSL/wolfMQTT

O NCS `v2.6.0` nao vem com os modulos wolf. Baixe-os para este projeto:

```sh
cd /home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf
./scripts/fetch_wolf_modules.sh
```

## 2. Gerar certificados

```sh
cd /home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf
./host/gen_tls_certs.sh 2001:db8::2 localhost
```

Este projeto ja foi deixado com a CA gerada em `host/certs/ca.crt` embutida em
`firmware/src/main.c`. Se voce rodar o script novamente, substitua `ca_cert_pem`
pela nova CA antes de compilar e gravar o firmware.

## 3. Build e flash do firmware

```sh
cd /home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware

nrfutil sdk-manager toolchain launch --ncs-version v2.6.0 -- \
  west build -b nrf5340dk_nrf5340_cpuapp --sysbuild -p always .

nrfutil sdk-manager toolchain launch --ncs-version v2.6.0 -- \
  west flash -d build
```

O projeto força `BOARD_FLASH_RUNNER=nrfutil` em `firmware/sysbuild.cmake` e
`firmware/CMakeLists.txt`. Como o sysbuild tambem gera um dominio `hci_ipc`
separado para o network core, ha uma etapa CMake em
`firmware/cmake/force_nrfutil_runner.cmake` que troca qualquer
`flash-runner: nrfjprog` restante para `flash-runner: nrfutil` depois do build.
Tambem ha um atalho equivalente:

```sh
cd /home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf
./scripts/flash_firmware.sh
```

Esse script nao usa `west flash`; ele programa diretamente `firmware/build/merged.hex`
no application core e `firmware/build/merged_CPUNET.hex` no network core usando
`nrfutil device program`. Isso evita a incompatibilidade entre o runner antigo do
Zephyr/NCS `v2.6.0` e o `nrfutil` novo.

Se ainda quiser testar o runner do Zephyr, use:

```sh
./scripts/west_flash_firmware.sh
```

Esse segundo script coloca `tools/nrfutil` no inicio do `PATH`. O wrapper traduz
o subcomando antigo `device execute-batch`, usado pelo runner do Zephyr/NCS
`v2.6.0`, para `device x-execute-batch`, aceito pelo `nrfutil` mais novo.

## 4. Conectar Linux ao IPSP

Carregue o modulo 6LoWPAN e conecte no endereco BLE anunciado pela placa:

```sh
sudo modprobe bluetooth_6lowpan
sudo sh -c 'echo 1 > /sys/kernel/debug/bluetooth/6lowpan_enable'

sudo hcitool lescan
sudo sh -c 'echo "AA:BB:CC:DD:EE:FF 2" > /sys/kernel/debug/bluetooth/6lowpan_control'
sudo ip address add 2001:db8::2/64 dev bt0
ping6 2001:db8::1
```

Troque `AA:BB:CC:DD:EE:FF` pelo endereco BLE da placa. O tipo `2` significa
endereco random, que e o caso comum do sample IPSP.

## 5. Rodar broker wolfMQTT/wolfSSL no host

```sh
cd /home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf
./host/build_wolf_broker.sh
./host/run_wolf_broker.sh
```

O build do host compila uma wolfSSL local em `host/build/wolfssl-install`, com
TLS 1.3, ML-KEM e grupos hibridos PQC habilitados. Isso evita depender do
pacote `wolfssl` do Arch/CachyOS.

## 6. Testar

Com o broker rodando, o firmware publica:

```text
nrf5340/telemetry -> counter:N
```

E assina:

```text
nrf5340/command
```

Comandos aceitos:

```text
led:on
led:off
led:toggle
```

## Observacoes

IPSP no Zephyr antigo e experimental. Primeiro prove `ping6 2001:db8::1`;
so depois investigue TLS/MQTT.

wolfSSL/wolfMQTT sao GPLv3 nos repositórios publicos, salvo licenca comercial.
