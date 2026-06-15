# nRF5340 IPSP MQTT/TLS Benchmarking

This directory is an isolated benchmark environment. It does not overwrite the
existing `firmware/`, `host/`, `scripts/`, `docker/`, `docker-compose.server.yml`,
or `modules/` flow.

## What It Measures

The benchmark uses the real nRF5340 DK over IPSP / IPv6-over-BLE and measures
TLS/MQTT connection cycles against a benchmark-only wolfMQTT broker.

Initial metrics:

- TLS handshake time and derived handshake throughput.
- Full TCP + TLS + MQTT connect time.
- Connections per second.
- Success, failure, timeout, and unsupported counts.

ML-KEM is tested as the TLS 1.3 key exchange group. ML-DSA, SLH-DSA, RSA-PSS,
and DSA are treated as server certificate/signature variants. Unsupported
combinations are recorded as `unsupported`; the runner does not silently fall
back to a different algorithm.

## Layout

```text
benchmarking/
  generate_cases.py
  run_benchmarks.py
  schemas.md
  docker/
  firmware/
  host/
  patches/
  cases/
  results/
  work/
```

`work/`, generated CSV case files, and `results/` are ignored by Git.

## Generate Cases

```bash
python benchmarking/generate_cases.py --seed 123 --iterations 10 --warmup-iterations 2
```

The command prints the output CSV path. Reusing the same seed gives the same
case order.

## Build The Benchmark Docker Image

```bash
docker compose -f benchmarking/docker-compose.benchmark.yml build
docker compose -f benchmarking/docker-compose.benchmark.yml run --rm ipsp-benchmark oqs-check
```

The OQS check must list `MLKEM512`, `MLKEM768`, and `MLKEM1024`.

## Dry Run

A dry run creates manifests and result CSVs without building, flashing, or using
the board:

```bash
python benchmarking/run_benchmarks.py \
  --cases benchmarking/cases/<generated>_benchmark_cases.csv \
  --seed 123 \
  --limit 3 \
  --dry-run
```

## Hardware Run

Power the nRF5340 DK, make sure `nrfutil device list` sees the board, and keep
the IPSP prerequisites from the main project working.

Then run a short smoke test:

```bash
python benchmarking/run_benchmarks.py \
  --cases benchmarking/cases/<generated>_benchmark_cases.csv \
  --seed 123 \
  --only-case mlkem768__rsa_pss_3072 \
  --case-timeout-sec 180
```

The runner will:

1. Generate per-case certificates under `benchmarking/results/<run_id>/cases/...`.
2. Build the benchmark broker in `benchmarking/work/build/`.
3. Build the benchmark firmware in `benchmarking/work/firmware-build/`.
4. Flash the board with `nrfutil`.
5. Reconnect IPSP using the existing `host/ipsp_connect.sh`.
6. Start the benchmark broker in Docker.
7. Parse serial `BENCH_ATTEMPT` lines and write CSV output.

Run `sudo -v` before the benchmark if your IPSP connect path requires sudo.
For long runs, prefer a narrow passwordless sudo rule for the IPSP connect
script so the benchmark never stops waiting for a password:

```bash
sudo visudo -f /etc/sudoers.d/ipsp-benchmark
```

Add this line:

```text
thiago ALL=(root) NOPASSWD: /home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/host/ipsp_connect.sh
```

Then validate it:

```bash
sudo chmod 0440 /etc/sudoers.d/ipsp-benchmark
sudo -n /home/thiago/Documents/canada/pesquisa/ipsp_mqtt_tls_wolf/host/ipsp_connect.sh F8:69:5E:1E:CE:2F 2
```

After that, run benchmarks with `--sudo-noninteractive`:

```bash
python benchmarking/run_benchmarks.py \
  --cases benchmarking/cases/<generated>_benchmark_cases.csv \
  --seed 123 \
  --limit 1 \
  --sudo-noninteractive
```

Useful hardware-run options:

- `--skip-flash`: do not program the board again; the runner only resets it.
  This requires cached cert artifacts for the same `case_id`, created by a
  previous run without `--skip-flash`.
- `--connect-retries 5`: firmware connection tries per measured attempt.
- `--connect-retry-delay-sec 5`: wait time between failed connection tries.
- `--initial-delay-sec 45`: firmware wait before the first measured attempt,
  giving the host time to create and validate `bt0`.
- `--case-timeout-sec 900`: max serial collection time for a case.
- `--board-boot-timeout-sec 30`: max wait for `BENCH_START` after reset.
- `--broker-ready-timeout-sec 20`: max wait for the Docker broker to listen.
- `--ipsp-ready-timeout-sec 20`: max wait for host `bt0` IPv6 readiness.
- `--ipsp-connect-retries 3`: host IPSP reconnect attempts before failing.
- `--ipsp-ping-count 3`: ICMP packets per board reachability check.
- `--ipsp-ping-timeout-sec 5`: per-packet ping timeout for the BLE/IPSP link.
- `--ipsp-ping-retries 3`: ping rounds before declaring IPSP unusable.
- `--skip-ipsp-ping-check`: skip the host `ping -6 -I bt0 2001:db8::1`
  preflight. This is useful only when ICMP is blocked but TCP is known to work.

## Results

Each run creates:

```text
benchmarking/results/<run_id>/
  seed.txt
  input_cases.csv
  run_manifest.csv
  summary.csv
  cases/<sequence>_<case_id>/attempts.csv
  cases/<sequence>_<case_id>/*.log
```

See `schemas.md` for exact columns.

## Notes

- Firmware build and flash are intentionally host-native, because your NCS and
  `nrfutil` flow already works on CachyOS.
- Docker is used for server-side benchmark dependencies only.
- The benchmark runner refuses to overwrite an existing `results/<run_id>`.
- The current project implementation remains available through the original
  scripts and Docker files.
