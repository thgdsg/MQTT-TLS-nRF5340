# IPSP MQTT/TLS wolfSSL/wolfMQTT

Projeto experimental para comunicar um `nRF5340 DK` com um host Linux usando
MQTT sobre TLS por Bluetooth LE IPSP / IPv6-over-BLE.

O firmware roda como cliente MQTT/TLS usando wolfSSL + wolfMQTT. O computador
roda o broker TLS wolfMQTT e cria a interface Linux `bt0` via IPSP.

## Arquitetura

```text
nRF5340 DK
  BLE IPSP
  IPv6: 2001:db8::1
  wolfMQTT client + wolfSSL TLS 1.3
        |
        | BLE 6LoWPAN / IPSP
        v
Linux bt0
  IPv6: 2001:db8::2
  wolfMQTT broker + wolfSSL TLS 1.3
  TCP port: 8883
```

Topicos MQTT:

- `nrf5340/command`: comandos enviados para a placa.
- `nrf5340/telemetry`: telemetria publicada pela placa.

Comandos aceitos pela placa:

- `led:on`
- `led:off`
- `led:toggle`

## Requisitos

- CachyOS/Arch Linux com Bluetooth funcional.
- nRF Connect SDK `v2.6.0`. Esta versao ainda possui suporte IPSP no Zephyr.
- `nrfutil` com o comando `sdk-manager`.
- `openssl`, `mosquitto`, `bluez`, `iproute2`.
- A placa `nRF5340 DK` conectada pela porta USB do debugger/J-Link.

No Arch/CachyOS:

```sh
sudo pacman -S openssl mosquitto bluez bluez-utils iproute2
```

## 1. Baixar wolfSSL e wolfMQTT

Os modulos wolf nao sao versionados no repositorio. Baixe-os localmente:

```sh
cd /home/[USER]/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf
./scripts/fetch_wolf_modules.sh
```

Isso cria:

- `modules/wolfssl`
- `modules/wolfmqtt`

Essas pastas ficam ignoradas pelo Git.

## 2. Aplicar patch IPSP do Zephyr

O Zephyr do NCS `v2.6.0` pode emitir logs como:

```text
Ignoring invalid L2CAP TX metadata 0x20005202
```

No fluxo IPSP com MQTT/TLS, isso acontece porque o L2CAP guarda metadados em
`net_buf_user_data()`, mas a camada `bt_conn_send_cb()` tambem reutiliza esse
campo durante TX. Em transmissao segmentada, o callback pode receber um ponteiro
de metadado sobrescrito.

Este repositorio inclui o patch:

```text
patches/zephyr-v2.6.0-l2cap-tx-metadata.patch
```

Aplique no Zephyr do NCS `v2.6.0`:

```sh
cd /home/[USER]/ncs/v2.6.0/zephyr
git apply /home/[USER]/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/patches/zephyr-v2.6.0-l2cap-tx-metadata.patch
```

Se o patch ja estiver aplicado, o `git apply` pode falhar dizendo que os hunks
nao aplicam. Nesse caso, confira com:

```sh
git diff -- subsys/bluetooth/host/l2cap.c
```

## 3. Gerar certificados TLS

```sh
cd /home/[USER]/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf
./host/gen_tls_certs.sh 2001:db8::2 localhost
```

A CA gerada em `host/certs/ca.crt` esta embutida em
`firmware/src/main.c`. Se voce gerar novos certificados, atualize a string
`ca_cert_pem` no firmware antes de compilar.

## 4. Build e flash do firmware

Build:

```sh
cd /home/[USER]/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf
env SHELL=/bin/bash /home/[USER]/.local/bin/nrfutil sdk-manager toolchain launch \
  --ncs-version v2.6.0 \
  --chdir /home/[USER]/ncs/v2.6.0/nrf \
  -- west build \
     -d /home/[USER]/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware/build \
     -b nrf5340dk_nrf5340_cpuapp \
     --sysbuild \
     -p always \
     /home/[USER]/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/firmware
```

Flash:

```sh
cd /home/[USER]/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf
./scripts/flash_firmware.sh
```

O script `flash_firmware.sh` programa os HEX gerados pelo sysbuild usando
`nrfutil device program`, evitando incompatibilidades entre o runner antigo do
Zephyr/NCS `v2.6.0` e o `nrfutil` mais novo.

Para acompanhar logs da placa, use a segunda porta serial do J-Link:

```sh
tio /dev/ttyACM1 -b 115200
```

## 5. Conectar IPSP no Linux

Com a placa ligada e anunciando `nRF5340 IPSP MQTT TLS`, conecte o host:

```sh
cd /home/[USER]/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf
sudo ./host/ipsp_connect.sh F8:69:5E:1E:CE:2F 2
```

Troque `F8:69:5E:1E:CE:2F` pelo endereco BLE anunciado pela sua placa. O tipo
`2` indica endereco LE random, que e o caso comum neste firmware.

O script:

- monta `debugfs` se necessario;
- carrega `bluetooth_6lowpan`;
- habilita `/sys/kernel/debug/bluetooth/6lowpan_enable`;
- pede ao kernel para conectar o peer IPSP;
- espera a interface `bt0`;
- configura `2001:db8::2/64` no host.

Teste IPv6:

```sh
ping -6 -c 3 -I bt0 2001:db8::1
```

## 6. Rodar o broker TLS no host

```sh
cd /home/[USER]/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf
./host/build_wolf_broker.sh
./host/run_wolf_broker.sh
```

O broker escuta em TLS na porta `8883`. O build do host compila uma wolfSSL
local em `host/build/wolfssl-install` e gera o executavel
`host/build/wolfmqtt-broker`.

## 7. Testar MQTT

Assinar telemetria:

```sh
cd /home/[USER]/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf
mosquitto_sub -h 127.0.0.1 -p 8883 \
  --cafile host/certs/ca.crt \
  --insecure \
  -t nrf5340/telemetry
```

Ligar/desligar/toggle do LED:

```sh
mosquitto_pub -h 127.0.0.1 -p 8883 --cafile host/certs/ca.crt --insecure \
  -t nrf5340/command -m 'led:on'

mosquitto_pub -h 127.0.0.1 -p 8883 --cafile host/certs/ca.crt --insecure \
  -t nrf5340/command -m 'led:off'

mosquitto_pub -h 127.0.0.1 -p 8883 --cafile host/certs/ca.crt --insecure \
  -t nrf5340/command -m 'led:toggle'
```

No console da placa, voce deve ver mensagens como:

```text
MQTT/TLS connected and subscribed to nrf5340/command
MQTT ping ok
MQTT TX nrf5340/telemetry: counter:N
MQTT command: led:on
```

## Notas de implementacao

- O firmware usa TLS 1.3 classico com wolfSSL. PQC/ML-KEM ficou desabilitado no
  firmware para estabilizar primeiro o transporte IPSP + MQTT/TLS.
- O keepalive MQTT e mantido explicitamente: quando `MqttClient_WaitMessage()`
  retorna timeout, o firmware envia `MqttClient_Ping()`.
- O broker foi usado em modo TLS-only na porta `8883`.
- `firmware/build/`, `host/build/`, `modules/` e `tools/` sao gerados localmente
  e nao devem ser commitados.

## Limpeza antes de commit

Os diretorios de build sao artefatos locais. Para remover caso sejam recriados:

```sh
rm -rf firmware/build host/build
git status --short
```

## Licenca

wolfSSL/wolfMQTT sao GPLv3 nos repositorios publicos, salvo licenca comercial.
