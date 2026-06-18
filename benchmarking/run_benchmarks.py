#!/usr/bin/env python3
"""Run nRF5340 IPSP MQTT/TLS benchmark cases."""

from __future__ import annotations

import argparse
import csv
import os
import random
import queue
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BENCH_ROOT = ROOT / "benchmarking"
COMPOSE_FILE = BENCH_ROOT / "docker-compose.benchmark.yml"
WORK_DIR = BENCH_ROOT / "work"
RESULTS_DIR = BENCH_ROOT / "results"
CONTAINER_ROOT = Path("/workspace/ipsp_mqtt_tls_wolf")
IPSP_CONNECT_SCRIPT = ROOT / "host" / "ipsp_connect.sh"

INPUT_FIELDS = [
    "case_id",
    "enabled",
    "kex_group",
    "kex_nist_level",
    "cert_sig_alg",
    "sig_nist_level",
    "iterations",
    "warmup_iterations",
    "expected_support",
    "notes",
]

ATTEMPT_FIELDS = [
    "attempt_index",
    "warmup",
    "status",
    "tcp_connect_ms",
    "tls_handshake_ms",
    "mqtt_connect_ms",
    "full_connect_ms",
    "error_code",
    "message",
]

SUMMARY_FIELDS = [
    "case_id",
    "kex_group",
    "cert_sig_alg",
    "status",
    "success_count",
    "fail_count",
    "timeout_count",
    "mean_handshake_ms",
    "median_handshake_ms",
    "p95_handshake_ms",
    "min_handshake_ms",
    "max_handshake_ms",
    "stddev_handshake_ms",
    "handshake_throughput_hps",
    "mean_full_connect_ms",
    "connections_per_second",
    "notes",
]


@dataclass
class CasePaths:
    root: Path
    certs: Path
    generated: Path
    attempts_csv: Path
    board_log: Path
    broker_log: Path
    build_log: Path
    flash_log: Path
    docker_log: Path


@dataclass
class BrokerHandle:
    proc: subprocess.Popen[str]
    container_name: str


class SerialCapture:
    def __init__(self, proc: subprocess.Popen[str], paths: CasePaths):
        self.proc = proc
        self.paths = paths
        self.attempts: list[dict[str, object]] = []
        self.lines: queue.Queue[str] = queue.Queue()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="serial-capture", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def _run(self) -> None:
        with self.paths.board_log.open("a") as log:
            while not self._stop.is_set():
                if not self.proc.stdout:
                    return
                line = self.proc.stdout.readline()
                if not line:
                    if self.proc.poll() is not None:
                        return
                    time.sleep(0.05)
                    continue
                log.write(line)
                log.flush()
                self.lines.put(line)
                parsed = parse_attempt_line(line)
                if parsed:
                    self.attempts.append(parsed)

    def wait_for_text(self, text: str, timeout_sec: float) -> bool:
        deadline = time.time() + timeout_sec
        while time.time() < deadline:
            try:
                line = self.lines.get(timeout=max(0.1, min(0.5, deadline - time.time())))
            except queue.Empty:
                continue
            if text in line:
                return True
            # The board serial can drop one byte around resets; initial_delay_ms
            # is unique to the BENCH_READY line, so use it as the stable token.
            if text == "BENCH_READY" and line.startswith("B") and "initial_delay_ms" in line:
                return True
        return False

    def wait_for_attempts(self, expected_attempts: int, timeout_sec: float) -> list[dict[str, object]]:
        deadline = time.time() + timeout_sec
        while time.time() < deadline:
            if len(self.attempts) >= expected_attempts:
                break
            time.sleep(0.1)
        return list(self.attempts)

    def stop(self) -> None:
        self._stop.set()
        stop_serial(self.proc)
        self._thread.join(timeout=2)


def compose_cmd() -> list[str]:
    if subprocess.run(["docker", "compose", "version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        return ["docker", "compose"]
    if shutil.which("docker-compose"):
        return ["docker-compose"]
    raise RuntimeError("Docker Compose not found")


def run_logged(
    cmd: list[str],
    log_path: Path,
    *,
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
    check: bool = True,
    timeout: float | None = None,
) -> subprocess.CompletedProcess[str]:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a") as log:
        log.write(f"$ {' '.join(cmd)}\n")
        log.flush()
        try:
            proc = subprocess.run(
                cmd,
                cwd=cwd,
                env=env,
                text=True,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            log.write(f"[timeout] command exceeded {timeout}s\n")
            raise
        log.write(f"[exit] {proc.returncode}\n")
    if check and proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd)
    return proc


def sudo_noninteractive_hint(script: Path) -> str:
    return (
        "sudo -n cannot run the IPSP connect script without a password. "
        "Either run without --sudo-noninteractive and type your password, "
        "run sudo -v immediately before the benchmark, or add a narrow sudoers rule:\n"
        "  sudo visudo -f /etc/sudoers.d/ipsp-benchmark\n"
        f"  thiago ALL=(root) NOPASSWD: {script}\n"
        "Then validate with:\n"
        f"  sudo -n {script} F9:79:AE:2A:9A:1E 2\n"
        f"  sudo -n {script} --cleanup bt0"
    )


def check_sudo_noninteractive(args: argparse.Namespace) -> None:
    if os.geteuid() == 0 or not args.sudo_noninteractive:
        return

    proc = subprocess.run(
        ["sudo", "-n", "-l", str(IPSP_CONNECT_SCRIPT)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if proc.returncode != 0:
        raise PermissionError(sudo_noninteractive_hint(IPSP_CONNECT_SCRIPT))


def docker_run(
    args: list[str],
    log_path: Path,
    *,
    check: bool = True,
    timeout: float | None = None,
) -> subprocess.CompletedProcess[str]:
    cmd = [*compose_cmd(), "-f", str(COMPOSE_FILE), "run", "--rm", "ipsp-benchmark", *args]
    return run_logged(cmd, log_path, check=check, timeout=timeout)


def docker_rm_force(name: str, log_path: Path) -> None:
    try:
        run_logged(["docker", "rm", "-f", name], log_path, check=False, timeout=20)
    except subprocess.TimeoutExpired:
        with log_path.open("a") as log:
            log.write(f"[docker] timed out removing {name}; continuing cleanup\n")


def cleanup_host_ipsp_link(paths: CasePaths, args: argparse.Namespace) -> None:
    if os.geteuid() != 0 and not args.sudo_noninteractive:
        with paths.docker_log.open("a") as log:
            log.write("[cleanup] skipping bt0 cleanup without --sudo-noninteractive\n")
        return

    cmd = [str(IPSP_CONNECT_SCRIPT), "--cleanup", args.ipsp_interface]
    if os.geteuid() != 0:
        cmd = ["sudo", "-n", *cmd]
    run_logged(cmd, paths.docker_log, check=False)


def cleanup_stale_benchmark_containers(log_path: Path) -> None:
    ids: list[str] = []
    for name_filter in ("benchmarking-ipsp-benchmark-run", "ipsp-benchmark-broker"):
        proc = subprocess.run(
            ["docker", "ps", "-aq", "--filter", f"name={name_filter}"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        ids.extend(line.strip() for line in proc.stdout.splitlines() if line.strip())
    ids = sorted(set(ids))
    if ids:
        run_logged(["docker", "rm", "-f", *ids], log_path, check=False)


def container_path(path: Path) -> Path:
    resolved = path.resolve()
    try:
        return CONTAINER_ROOT / resolved.relative_to(ROOT)
    except ValueError as exc:
        raise ValueError(f"Path is outside the repository and cannot be mounted into Docker: {path}") from exc


def read_cases(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as fp:
        rows = list(csv.DictReader(fp))
    missing = [field for field in INPUT_FIELDS if field not in (rows[0].keys() if rows else [])]
    if missing:
        raise ValueError(f"Input CSV missing fields: {', '.join(missing)}")
    return [row for row in rows if row.get("enabled", "1") == "1"]


def write_csv(path: Path, fields: list[str], rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(f"Refusing to overwrite {path}")
    with path.open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def append_summary(path: Path, row: dict[str, object]) -> None:
    exists = path.exists()
    with path.open("a", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=SUMMARY_FIELDS)
        if not exists:
            writer.writeheader()
        writer.writerow(row)


def case_paths(run_dir: Path, sequence: int, case_id: str) -> CasePaths:
    root = run_dir / "cases" / f"{sequence:03d}_{case_id}"
    return CasePaths(
        root=root,
        certs=root / "certs",
        generated=root / "generated",
        attempts_csv=root / "attempts.csv",
        board_log=root / "board.log",
        broker_log=root / "broker.log",
        build_log=root / "build.log",
        flash_log=root / "flash.log",
        docker_log=root / "docker.log",
    )


def unsupported_attempt(message: str) -> list[dict[str, object]]:
    return [
        {
            "attempt_index": 0,
            "warmup": 0,
            "status": "unsupported",
            "tcp_connect_ms": "",
            "tls_handshake_ms": "",
            "mqtt_connect_ms": "",
            "full_connect_ms": "",
            "error_code": "",
            "message": message,
        }
    ]


def summarize(case: dict[str, str], attempts: list[dict[str, object]], notes: str = "") -> dict[str, object]:
    measured = [a for a in attempts if str(a.get("warmup")) != "1"]
    successes = [a for a in measured if a.get("status") == "success"]
    timeouts = [a for a in measured if a.get("status") == "timeout"]
    unsupported = [a for a in measured if a.get("status") == "unsupported"]
    failures = [a for a in measured if a.get("status") not in ("success", "timeout", "unsupported")]

    handshake = [float(a["tls_handshake_ms"]) for a in successes if str(a.get("tls_handshake_ms", "")) != ""]
    full = [float(a["full_connect_ms"]) for a in successes if str(a.get("full_connect_ms", "")) != ""]

    def p95(values: list[float]) -> str:
        if not values:
            return ""
        ordered = sorted(values)
        idx = int((len(ordered) - 1) * 0.95)
        return f"{ordered[idx]:.3f}"

    status = "success" if successes and not failures and not timeouts else "partial" if successes else "failed"
    if unsupported and not successes:
        status = "unsupported"

    mean_handshake = statistics.mean(handshake) if handshake else None
    mean_full = statistics.mean(full) if full else None

    return {
        "case_id": case["case_id"],
        "kex_group": case["kex_group"],
        "cert_sig_alg": case["cert_sig_alg"],
        "status": status,
        "success_count": len(successes),
        "fail_count": len(failures),
        "timeout_count": len(timeouts),
        "mean_handshake_ms": f"{mean_handshake:.3f}" if mean_handshake is not None else "",
        "median_handshake_ms": f"{statistics.median(handshake):.3f}" if handshake else "",
        "p95_handshake_ms": p95(handshake),
        "min_handshake_ms": f"{min(handshake):.3f}" if handshake else "",
        "max_handshake_ms": f"{max(handshake):.3f}" if handshake else "",
        "stddev_handshake_ms": f"{statistics.stdev(handshake):.3f}" if len(handshake) > 1 else "",
        "handshake_throughput_hps": f"{1000.0 / mean_handshake:.6f}" if mean_handshake else "",
        "mean_full_connect_ms": f"{mean_full:.3f}" if mean_full is not None else "",
        "connections_per_second": f"{1000.0 / mean_full:.6f}" if mean_full else "",
        "notes": notes or case.get("notes", ""),
    }


def parse_attempt_line(line: str) -> dict[str, object] | None:
    # Recover the exact one-byte-loss variants seen on the benchmark UART.
    markers = (
        "BENCH_ATTEMPT,",
        "BENCHATTEMPT,",
        "BENCH_ATTEPT,",
    )
    marker = next((candidate for candidate in markers if candidate in line), None)
    if marker is not None:
        payload = line.split(marker, 1)[1].strip()
    else:
        match = re.search(r"B[A-Z_]*ATT[A-Z_]*,", line)
        if not match:
            return None
        payload = line[match.end():].strip()
    parts = payload.split(",", 8)
    if len(parts) != 9:
        return None
    if parts[2] not in ("success", "error", "timeout", "unsupported"):
        return None
    return {
        "attempt_index": parts[0],
        "warmup": parts[1],
        "status": parts[2],
        "tcp_connect_ms": parts[3],
        "tls_handshake_ms": parts[4],
        "mqtt_connect_ms": parts[5],
        "full_connect_ms": parts[6],
        "error_code": parts[7],
        "message": parts[8],
    }


def generate_certs(case: dict[str, str], paths: CasePaths) -> bool:
    proc = docker_run(
        [
            "gen-certs",
            "--case-id",
            case["case_id"],
            "--cert-sig",
            case["cert_sig_alg"],
            "--out-dir",
            str(container_path(paths.root)),
        ],
        paths.docker_log,
        check=False,
    )
    return proc.returncode == 0


def case_artifact_cache(case: dict[str, str]) -> Path:
    return WORK_DIR / "case-artifacts" / case["case_id"]


def restore_cached_case_artifacts(case: dict[str, str], paths: CasePaths) -> bool:
    cache = case_artifact_cache(case)
    if not (cache / "certs" / "server.crt").exists():
        return False
    if not (cache / "certs" / "server.key").exists():
        return False
    if not (cache / "generated" / "benchmark_cert.h").exists():
        return False

    shutil.copytree(cache / "certs", paths.certs, dirs_exist_ok=True)
    shutil.copytree(cache / "generated", paths.generated, dirs_exist_ok=True)
    return True


def cache_case_artifacts(case: dict[str, str], paths: CasePaths) -> None:
    cache = case_artifact_cache(case)
    if cache.exists():
        shutil.rmtree(cache)
    shutil.copytree(paths.certs, cache / "certs")
    shutil.copytree(paths.generated, cache / "generated")


def build_broker(case: dict[str, str], paths: CasePaths) -> str:
    docker_run(
        [
            "build-broker",
            "--tls-group",
            case["kex_group"],
            "--cert-sig",
            case["cert_sig_alg"],
        ],
        paths.build_log,
    )
    for line in paths.build_log.read_text(errors="ignore").splitlines():
        if line.startswith("broker="):
            return line.split("=", 1)[1]
    raise RuntimeError("Broker type was not reported by build_benchmark_broker.sh")


def build_firmware(
    case: dict[str, str],
    paths: CasePaths,
    args: argparse.Namespace,
    *,
    iterations: int | None = None,
    warmup_iterations: int | None = None,
) -> Path:
    build_dir = WORK_DIR / "firmware-build" / case["case_id"]
    overlay = paths.generated / "bench_overlay.conf"
    default_generated = WORK_DIR / "generated" / "default"
    default_generated.mkdir(parents=True, exist_ok=True)
    if not (paths.generated / "benchmark_cert.h").exists():
        raise FileNotFoundError(
            f"Generated certificate header is missing: {paths.generated / 'benchmark_cert.h'}; "
            f"check {paths.docker_log}"
        )
    shutil.copy2(paths.generated / "benchmark_cert.h", default_generated / "benchmark_cert.h")

    group_configs = {
        "MLKEM512": "CONFIG_APP_BENCH_TLS_GROUP_MLKEM512=y",
        "MLKEM768": "CONFIG_APP_BENCH_TLS_GROUP_MLKEM768=y",
        "MLKEM1024": "CONFIG_APP_BENCH_TLS_GROUP_MLKEM1024=y",
        "ECDHE-P-256": "CONFIG_APP_BENCH_TLS_GROUP_ECDHE_P256=y",
        "ECDHE-P-384": "CONFIG_APP_BENCH_TLS_GROUP_ECDHE_P384=y",
        "ECDHE-P-521": "CONFIG_APP_BENCH_TLS_GROUP_ECDHE_P521=y",
    }
    if case["kex_group"] not in group_configs:
        raise ValueError(f"Unsupported firmware TLS group: {case['kex_group']}")

    overlay.parent.mkdir(parents=True, exist_ok=True)
    overlay.write_text(
        "\n".join(
            [
                f"CONFIG_APP_BENCH_ITERATIONS={iterations if iterations is not None else case['iterations']}",
                f"CONFIG_APP_BENCH_WARMUP_ITERATIONS={warmup_iterations if warmup_iterations is not None else case['warmup_iterations']}",
                f"CONFIG_APP_BENCH_INITIAL_DELAY_MS={int(args.initial_delay_sec * 1000)}",
                f"CONFIG_APP_MQTT_CMD_TIMEOUT_MS={int(args.mqtt_cmd_timeout_sec * 1000)}",
                f"CONFIG_APP_TLS_HANDSHAKE_TIMEOUT_MS={int(args.tls_handshake_timeout_sec * 1000)}",
                f"CONFIG_APP_TLS_IO_TIMEOUT_MS={int(args.tls_io_timeout_sec * 1000)}",
                f"CONFIG_APP_MQTT_KEEPALIVE_SEC={args.mqtt_keepalive_sec}",
                f"CONFIG_APP_BENCH_CONNECT_RETRIES={args.connect_retries}",
                f"CONFIG_APP_BENCH_CONNECT_RETRY_DELAY_MS={int(args.connect_retry_delay_sec * 1000)}",
                f"CONFIG_APP_BENCH_REBOOT_AFTER_ATTEMPT={'y' if args.firmware_reboot_after_attempt and args.session_attempt_limit == 1 else 'n'}",
                group_configs[case["kex_group"]],
                "",
            ]
        )
    )

    cmd = [
        args.nrfutil,
        "sdk-manager",
        "toolchain",
        "launch",
        "--ncs-version",
        args.ncs_version,
        "--chdir",
        args.ncs_chdir,
        "--",
        "west",
        "build",
        "-d",
        str(build_dir),
        "-b",
        args.board,
        "-p",
        "always",
        str(BENCH_ROOT / "firmware"),
        "--",
        f"-DEXTRA_CONF_FILE={overlay}",
    ]
    if args.sysbuild:
        cmd.insert(cmd.index("-p"), "--sysbuild")
    env = os.environ.copy()
    env["SHELL"] = "/bin/bash"
    run_logged(cmd, paths.build_log, env=env)
    return build_dir


def resolve_serial_number(args: argparse.Namespace, log_path: Path) -> str:
    if args.serial_number != "auto":
        return args.serial_number

    proc = run_logged([args.nrfutil, "device", "list"], log_path, check=False)
    text = log_path.read_text(errors="ignore")
    serials = sorted(set(re.findall(r"(?m)^([0-9]{6,})$", text)))
    if proc.returncode != 0:
        raise RuntimeError(f"nrfutil device list failed; see {log_path}")
    if len(serials) != 1:
        raise RuntimeError(
            f"--serial-number auto expected exactly one connected nRF device, found {len(serials)}: {serials}"
        )
    return serials[0]


def find_firmware_hex(build_dir: Path) -> Path:
    candidates = [
        build_dir / "merged.hex",
        build_dir / "zephyr" / "merged.hex",
        build_dir / "zephyr" / "zephyr.hex",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    searched = ", ".join(str(path.relative_to(build_dir)) for path in candidates)
    raise FileNotFoundError(f"Expected firmware HEX not found in {build_dir}; searched: {searched}")


def flash_firmware(build_dir: Path, paths: CasePaths, args: argparse.Namespace, *, reset: bool = True) -> None:
    app_hex = find_firmware_hex(build_dir)
    net_hex = build_dir / "merged_CPUNET.hex"
    serial_number = resolve_serial_number(args, paths.flash_log)

    common = [
        args.nrfutil,
        "device",
        "program",
        "--serial-number",
        serial_number,
        "--family",
        args.nrf_family,
        "--swd-clock-frequency",
        args.swd_clock_frequency,
    ]
    if not net_hex.exists():
        run_logged(
            [
                *common,
                "--firmware",
                str(app_hex),
                "--options",
                "chip_erase_mode=ERASE_ALL,verify=VERIFY_READ,reset=RESET_NONE",
            ],
            paths.flash_log,
        )
        if reset:
            reset_device(paths, args)
        return

    run_logged(
        [
            *common,
            "--core",
            "application",
            "--firmware",
            str(app_hex),
            "--options",
            "chip_erase_mode=ERASE_ALL,verify=VERIFY_READ,reset=RESET_NONE",
        ],
        paths.flash_log,
    )
    run_logged(
        [
            *common,
            "--core",
            "network",
            "--firmware",
            str(net_hex),
            "--options",
            "chip_erase_mode=ERASE_ALL,verify=VERIFY_READ,reset=RESET_NONE",
        ],
        paths.flash_log,
    )
    if reset:
        reset_device(paths, args)


def reset_device(paths: CasePaths, args: argparse.Namespace) -> None:
    serial_number = resolve_serial_number(args, paths.flash_log)
    run_logged([args.nrfutil, "device", "reset", "--serial-number", serial_number, "--family", args.nrf_family], paths.flash_log)


def connect_ipsp(paths: CasePaths, args: argparse.Namespace) -> None:
    cmd = [str(IPSP_CONNECT_SCRIPT), args.ipsp_addr, args.ipsp_addr_type]
    if os.geteuid() != 0:
        cmd.insert(0, "sudo")
        if args.sudo_noninteractive:
            # Avoid a password prompt in the middle of a benchmark run. Use a
            # sudoers NOPASSWD rule for host/ipsp_connect.sh, or pre-cache sudo.
            cmd.insert(1, "-n")
    try:
        run_logged(cmd, paths.docker_log)
    except subprocess.CalledProcessError as exc:
        if args.sudo_noninteractive and os.geteuid() != 0:
            raise PermissionError(sudo_noninteractive_hint(IPSP_CONNECT_SCRIPT)) from exc
        raise


def wait_for_ipsp_ready(paths: CasePaths, args: argparse.Namespace) -> None:
    deadline = time.time() + args.ipsp_ready_timeout_sec
    with paths.docker_log.open("a") as log:
        log.write(f"[wait] bt0 IPv6 ready timeout={args.ipsp_ready_timeout_sec}s\n")
        while time.time() < deadline:
            proc = subprocess.run(
                ["ip", "-6", "address", "show", "dev", "bt0"],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            log.write(proc.stdout)
            host_lines = [line for line in proc.stdout.splitlines() if "2001:db8::2/64" in line]
            if host_lines and all("tentative" not in line for line in host_lines):
                log.write("[wait] bt0 IPv6 address is ready\n")
                return
            log.flush()
            time.sleep(0.5)
        raise TimeoutError("bt0 IPv6 address did not leave tentative state")


def ping_board(paths: CasePaths, args: argparse.Namespace) -> bool:
    cmd = [
        "ping",
        "-6",
        "-I",
        args.ipsp_interface,
        "-c",
        str(args.ipsp_ping_count),
        "-W",
        str(args.ipsp_ping_timeout_sec),
        args.board_ipv6,
    ]
    proc = run_logged(cmd, paths.docker_log, check=False)
    return proc.returncode == 0


def require_board_ping(paths: CasePaths, args: argparse.Namespace) -> None:
    if args.skip_ipsp_ping_check:
        return

    for attempt in range(1, args.ipsp_ping_retries + 1):
        with paths.docker_log.open("a") as log:
            log.write(f"[ipsp] ping attempt {attempt}/{args.ipsp_ping_retries}\n")
        if ping_board(paths, args):
            return
        if attempt < args.ipsp_ping_retries:
            time.sleep(args.ipsp_ping_retry_delay_sec)

    log_ipsp_diagnostics(paths, args)
    raise TimeoutError(f"ping -6 -I {args.ipsp_interface} {args.board_ipv6} failed")


def log_ipsp_diagnostics(paths: CasePaths, args: argparse.Namespace) -> None:
    commands = [
        ["ip", "-6", "address", "show", "dev", args.ipsp_interface],
        ["ip", "-6", "route", "show", "dev", args.ipsp_interface],
        ["ip", "-6", "neigh", "show", "dev", args.ipsp_interface],
        ["ip", "-s", "link", "show", "dev", args.ipsp_interface],
        ["bluetoothctl", "info", args.ipsp_addr],
        ["sudo", "-n", "dmesg", "--ctime", "--level=err,warn"],
    ]
    with paths.docker_log.open("a") as log:
        log.write("[diag] IPSP diagnostics after failed ping\n")
    for cmd in commands:
        run_logged(cmd, paths.docker_log, check=False)


def ensure_ipsp_connected(paths: CasePaths, args: argparse.Namespace) -> None:
    last_error = "unknown IPSP connection failure"

    for attempt in range(1, args.ipsp_connect_retries + 1):
        with paths.docker_log.open("a") as log:
            log.write(f"[ipsp] connect attempt {attempt}/{args.ipsp_connect_retries}\n")
        try:
            connect_ipsp(paths, args)
            wait_for_ipsp_ready(paths, args)
            return
        except Exception as exc:
            last_error = str(exc)

        if attempt < args.ipsp_connect_retries:
            time.sleep(args.ipsp_reconnect_delay_sec)

    raise TimeoutError(f"IPSP link could not be created after {args.ipsp_connect_retries} attempts: {last_error}")


def broker_container_name(paths: CasePaths) -> str:
    safe = "".join(ch if ch.isalnum() else "-" for ch in paths.root.name.lower())
    return f"ipsp-benchmark-broker-{safe}"


def start_broker(broker: str, paths: CasePaths, case: dict[str, str], args: argparse.Namespace) -> BrokerHandle:
    name = broker_container_name(paths)
    docker_rm_force(name, paths.docker_log)
    cmd = [
        *compose_cmd(),
        "-f",
        str(COMPOSE_FILE),
        "run",
        "--rm",
        "--name",
        name,
        "ipsp-benchmark",
        "broker",
        "--broker",
        str(broker),
        "--cert",
        str(container_path(paths.certs / "server.crt")),
        "--key",
        str(container_path(paths.certs / "server.key")),
        "--tls-group",
        case["kex_group"],
        "--port",
        str(args.port),
    ]
    paths.broker_log.parent.mkdir(parents=True, exist_ok=True)
    log = paths.broker_log.open("a")
    log.write(f"$ {' '.join(cmd)}\n")
    log.flush()
    return BrokerHandle(
        proc=subprocess.Popen(cmd, cwd=ROOT, text=True, stdout=log, stderr=subprocess.STDOUT),
        container_name=name,
    )


def wait_for_broker_ready(handle: BrokerHandle, paths: CasePaths, args: argparse.Namespace) -> None:
    deadline = time.time() + args.broker_ready_timeout_sec
    while time.time() < deadline:
        if paths.broker_log.exists():
            text = paths.broker_log.read_text(errors="ignore")
            if (
                "broker: listening on port" in text
                or "Opening ipv6 listen socket on port" in text
                or "Opening ipv4 listen socket on port" in text
                or "mosquitto version" in text and "running" in text
            ):
                return
            if "bind failed" in text or "listen (TLS) failed" in text or "Address already in use" in text:
                raise RuntimeError(f"broker failed to listen; see {paths.broker_log}")
        if handle.proc.poll() is not None:
            raise RuntimeError(f"broker exited before listening; see {paths.broker_log}")
        time.sleep(0.25)
    raise TimeoutError(f"broker did not start listening within {args.broker_ready_timeout_sec}s")


def start_serial(paths: CasePaths, args: argparse.Namespace) -> subprocess.Popen[str]:
    if args.serial_reader == "tio":
        cmd = ["tio", args.serial_device, "-b", str(args.serial_baud)]
    else:
        subprocess.run(["stty", "-F", args.serial_device, str(args.serial_baud), "raw", "-echo"], check=False)
        cmd = ["stdbuf", "-oL", "cat", args.serial_device]
    paths.board_log.parent.mkdir(parents=True, exist_ok=True)
    return subprocess.Popen(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def stop_serial(proc: subprocess.Popen[str]) -> None:
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()


def attempt_batches(warmups: int, iterations: int, limit: int) -> list[tuple[int, int]]:
    total = warmups + iterations
    if limit <= 0 or total <= limit:
        return [(warmups, iterations)]

    batches: list[tuple[int, int]] = []
    consumed = 0
    while consumed < total:
        size = min(limit, total - consumed)
        batch_warmups = max(0, min(warmups - consumed, size))
        batch_iterations = size - batch_warmups
        batches.append((batch_warmups, batch_iterations))
        consumed += size
    return batches


def renumber_attempts(
    attempts: list[dict[str, object]],
    *,
    start_index: int,
    total_warmups: int,
) -> list[dict[str, object]]:
    renumbered: list[dict[str, object]] = []
    for offset, attempt in enumerate(attempts, start=0):
        global_index = start_index + offset
        renumbered.append(
            {
                **attempt,
                "attempt_index": global_index,
                "warmup": 1 if global_index <= total_warmups else 0,
            }
        )
    return renumbered


def stop_broker(handle: BrokerHandle, paths: CasePaths) -> None:
    handle.proc.terminate()
    try:
        handle.proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        handle.proc.kill()
        try:
            handle.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    docker_rm_force(handle.container_name, paths.docker_log)


def cleanup_case_session(paths: CasePaths, args: argparse.Namespace) -> None:
    cleanup_stale_benchmark_containers(paths.docker_log)
    try:
        docker_run(["clean-port"], paths.docker_log, check=False, timeout=20)
    except subprocess.TimeoutExpired:
        with paths.docker_log.open("a") as log:
            log.write("[cleanup] clean-port timed out; continuing with host IPSP cleanup\n")
    cleanup_host_ipsp_link(paths, args)


def run_case_session(
    sequence: int,
    session_count: int,
    session_warmups: int,
    session_iterations: int,
    broker: str,
    paths: CasePaths,
    case: dict[str, str],
    args: argparse.Namespace,
    *,
    build_dir: Path | None,
    flash_session: bool,
) -> list[dict[str, object]]:
    expected_attempts = session_warmups + session_iterations
    with paths.docker_log.open("a") as log:
        log.write(
            f"[session] {sequence}/{session_count} "
            f"warmups={session_warmups} iterations={session_iterations}\n"
        )

    cleanup_case_session(paths, args)

    broker_handle = start_broker(broker, paths, case, args)
    serial_capture: SerialCapture | None = None
    try:
        wait_for_broker_ready(broker_handle, paths, args)
        if args.skip_flash or not flash_session:
            serial_capture = SerialCapture(start_serial(paths, args), paths)
            serial_capture.start()
            reset_device(paths, args)
        else:
            if build_dir is None:
                raise RuntimeError("firmware build_dir is required when --skip-flash is not used")
            flash_firmware(build_dir, paths, args, reset=False)
            serial_capture = SerialCapture(start_serial(paths, args), paths)
            serial_capture.start()
            reset_device(paths, args)

        if not serial_capture.wait_for_text("BENCH_START", args.board_boot_timeout_sec):
            raise TimeoutError(
                f"board did not print BENCH_START within {args.board_boot_timeout_sec}s; see {paths.board_log}"
            )
        ensure_ipsp_connected(paths, args)
        if not serial_capture.wait_for_text("BENCH_READY", args.board_ready_timeout_sec):
            raise TimeoutError(
                f"board did not print BENCH_READY within {args.board_ready_timeout_sec}s after IPSP connect; "
                f"see {paths.board_log}"
            )
        require_board_ping(paths, args)
        return serial_capture.wait_for_attempts(expected_attempts, args.session_timeout_sec)
    finally:
        if serial_capture:
            serial_capture.stop()
        stop_broker(broker_handle, paths)
        cleanup_case_session(paths, args)
        if args.reset_after_case:
            reset_device(paths, args)


def run_case(sequence: int, case: dict[str, str], run_dir: Path, args: argparse.Namespace) -> dict[str, object]:
    paths = case_paths(run_dir, sequence, case["case_id"])
    paths.root.mkdir(parents=True, exist_ok=False)

    if case.get("expected_support") == "known_unsupported":
        attempts = unsupported_attempt(case.get("notes", "known unsupported"))
        write_csv(paths.attempts_csv, ATTEMPT_FIELDS, attempts)
        return summarize(case, attempts)

    if args.dry_run:
        attempts = unsupported_attempt("dry-run: not executed")
        write_csv(paths.attempts_csv, ATTEMPT_FIELDS, attempts)
        return summarize(case, attempts, "dry-run")

    if args.skip_flash:
        if not restore_cached_case_artifacts(case, paths):
            raise FileNotFoundError(
                f"--skip-flash requires cached certs for {case['case_id']} under "
                f"{case_artifact_cache(case)}. Run this case once without --skip-flash first."
            )
    else:
        if not generate_certs(case, paths):
            attempts = unsupported_attempt("certificate generation unsupported")
            write_csv(paths.attempts_csv, ATTEMPT_FIELDS, attempts)
            return summarize(case, attempts, "certificate generation unsupported")
        cache_case_artifacts(case, paths)

    broker = build_broker(case, paths)

    total_warmups = int(case["warmup_iterations"])
    total_iterations = int(case["iterations"])
    batches = attempt_batches(total_warmups, total_iterations, args.session_attempt_limit)
    build_dir = None
    if not args.skip_flash:
        build_dir = build_firmware(case, paths, args)

    attempts: list[dict[str, object]] = []
    next_attempt_index = 1
    for session_index, (session_warmups, session_iterations) in enumerate(batches, start=1):
        print(
            f"  session {session_index}/{len(batches)} "
            f"warmups={session_warmups} iterations={session_iterations}",
            flush=True,
        )
        session_attempts = run_case_session(
            session_index,
            len(batches),
            session_warmups,
            session_iterations,
            broker,
            paths,
            case,
            args,
            build_dir=build_dir,
            flash_session=session_index == 1 and not args.skip_flash,
        )
        if not session_attempts:
            session_attempts = [
                {
                    "attempt_index": 1,
                    "warmup": 1 if session_warmups > 0 else 0,
                    "status": "timeout",
                    "tcp_connect_ms": "",
                    "tls_handshake_ms": "",
                    "mqtt_connect_ms": "",
                    "full_connect_ms": "",
                    "error_code": "",
                    "message": f"session {session_index} produced no BENCH_ATTEMPT within {args.session_timeout_sec}s",
                }
            ]
        attempts.extend(
            renumber_attempts(
                session_attempts,
                start_index=next_attempt_index,
                total_warmups=total_warmups,
            )
        )
        next_attempt_index += len(session_attempts)

    if not attempts:
        attempts = [
            {
                "attempt_index": 0,
                "warmup": 0,
                "status": "timeout",
                "tcp_connect_ms": "",
                "tls_handshake_ms": "",
                "mqtt_connect_ms": "",
                "full_connect_ms": "",
                "error_code": "",
                "message": "no BENCH_ATTEMPT lines captured",
            }
        ]
    write_csv(paths.attempts_csv, ATTEMPT_FIELDS, attempts)
    return summarize(case, attempts)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=Path, required=True, help="input CSV generated by generate_cases.py")
    parser.add_argument("--seed", type=int, default=None, help="shuffle seed")
    parser.add_argument("--run-id", default=None, help="result directory name")
    parser.add_argument("--limit", type=int, default=None, help="run only the first N shuffled cases")
    parser.add_argument("--only-case", action="append", default=[], help="run only the selected case_id")
    parser.add_argument("--dry-run", action="store_true", help="create manifests/results without touching hardware")
    parser.add_argument("--serial-device", default="/dev/ttyACM0")
    parser.add_argument("--serial-baud", type=int, default=115200)
    parser.add_argument("--serial-reader", choices=("cat", "tio"), default="cat")
    parser.add_argument("--case-timeout-sec", type=int, default=900)
    parser.add_argument("--session-timeout-sec", type=int, default=360,
                        help="maximum time to wait for one split benchmark session to emit BENCH_ATTEMPT lines")
    parser.add_argument("--board-boot-timeout-sec", type=int, default=30)
    parser.add_argument("--board-ready-timeout-sec", type=int, default=30)
    parser.add_argument("--broker-ready-timeout-sec", type=int, default=20)
    parser.add_argument("--ipsp-ready-timeout-sec", type=int, default=20)
    parser.add_argument("--ipsp-connect-retries", type=int, default=3)
    parser.add_argument("--ipsp-reconnect-delay-sec", type=float, default=3.0)
    parser.add_argument("--ipsp-ping-count", type=int, default=1)
    parser.add_argument("--ipsp-ping-timeout-sec", type=int, default=5)
    parser.add_argument("--ipsp-ping-retries", type=int, default=3)
    parser.add_argument("--ipsp-ping-retry-delay-sec", type=float, default=1.0)
    parser.add_argument("--skip-ipsp-ping-check", action="store_true")
    parser.add_argument("--ipsp-interface", default="bt0")
    parser.add_argument("--board-ipv6", default="2001:db8::1")
    parser.add_argument("--ipsp-addr", default="F9:79:AE:2A:9A:1E")
    parser.add_argument("--ipsp-addr-type", default="2")
    parser.add_argument("--sudo-noninteractive", action="store_true",
                        help="run IPSP sudo command with sudo -n so benchmarks never stop for a password prompt")
    parser.add_argument("--skip-flash", action="store_true",
                        help="reuse already flashed firmware/certs for the case and only reset the board")
    parser.add_argument("--reset-after-case", action=argparse.BooleanOptionalAction, default=True,
                        help="reset the board after each case to clear firmware/network state")
    parser.add_argument("--session-attempt-limit", type=int, default=1,
                        help="max warmup+measured attempts per IPSP session; 0 disables session splitting")
    parser.add_argument("--connect-retries", type=int, default=3,
                        help="firmware connection tries per BENCH_ATTEMPT")
    parser.add_argument("--connect-retry-delay-sec", type=float, default=2.0,
                        help="delay between firmware connection retries")
    parser.add_argument("--initial-delay-sec", type=float, default=8.0,
                        help="firmware delay before the first BENCH_ATTEMPT; keep the default to let IPSP/IPv6 settle before measuring TCP")
    parser.add_argument("--mqtt-cmd-timeout-sec", type=float, default=60.0,
                        help="firmware wolfMQTT command timeout")
    parser.add_argument("--tls-handshake-timeout-sec", type=float, default=300.0,
                        help="firmware TLS handshake deadline; heavy PQC/RSA handshakes over IPSP can exceed a minute")
    parser.add_argument("--tls-io-timeout-sec", type=float, default=60.0,
                        help="per-call firmware TLS socket I/O timeout")
    parser.add_argument("--mqtt-keepalive-sec", type=int, default=120,
                        help="firmware MQTT keepalive; keep high for slow IPSP links")
    parser.add_argument("--firmware-reboot-after-attempt", action=argparse.BooleanOptionalAction, default=True,
                        help="when running one attempt per session, reboot firmware after each BENCH_ATTEMPT line")
    parser.add_argument("--port", type=int, default=8883)
    parser.add_argument("--nrfutil", default="/home/thiago/.local/bin/nrfutil")
    parser.add_argument("--ncs-version", default="v2.6.0")
    parser.add_argument("--ncs-chdir", default="/home/thiago/ncs/v2.6.0/nrf")
    parser.add_argument("--board", default="nrf52840dk_nrf52840")
    parser.add_argument("--sysbuild", action="store_true",
                        help="build with Zephyr sysbuild; needed for nRF5340 DK, not for nRF52840 DK")
    parser.add_argument("--nrf-family", default="nrf52",
                        help="nrfutil family value, for example nrf52 or nrf53")
    parser.add_argument("--serial-number", default="auto",
                        help="J-Link serial number, or auto when exactly one nRF device is connected")
    parser.add_argument("--swd-clock-frequency", default="1000")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.dry_run:
        check_sudo_noninteractive(args)

    rows = read_cases(args.cases)
    if args.only_case:
        selected = set(args.only_case)
        rows = [row for row in rows if row["case_id"] in selected]
    seed = args.seed if args.seed is not None else random.SystemRandom().randint(1, 2**31 - 1)
    rng = random.Random(seed)
    rng.shuffle(rows)
    if args.limit is not None:
        rows = rows[: args.limit]

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    run_id = args.run_id or f"{timestamp}_{seed}"
    run_dir = RESULTS_DIR / run_id
    if run_dir.exists():
        raise FileExistsError(f"Refusing to overwrite existing run directory: {run_dir}")
    run_dir.mkdir(parents=True)

    (run_dir / "seed.txt").write_text(f"{seed}\n")
    shutil.copy2(args.cases, run_dir / "input_cases.csv")

    manifest_rows = []
    for sequence, case in enumerate(rows, start=1):
        manifest_rows.append({**case, "sequence": sequence, "seed": seed, "run_id": run_id})
    write_csv(run_dir / "run_manifest.csv", ["sequence", *INPUT_FIELDS, "seed", "run_id"], manifest_rows)

    if not args.dry_run:
        docker_run(["setup-openssl-conf"], run_dir / "docker.log")
        docker_run(["oqs-check"], run_dir / "docker.log")

    for sequence, case in enumerate(rows, start=1):
        print(f"[{sequence}/{len(rows)}] {case['case_id']}")
        try:
            summary = run_case(sequence, case, run_dir, args)
        except Exception as exc:  # keep the full run alive and record the failed case
            paths = case_paths(run_dir, sequence, case["case_id"])
            paths.root.mkdir(parents=True, exist_ok=True)
            attempts = [
                {
                    "attempt_index": 0,
                    "warmup": 0,
                    "status": "error",
                    "tcp_connect_ms": "",
                    "tls_handshake_ms": "",
                    "mqtt_connect_ms": "",
                    "full_connect_ms": "",
                    "error_code": "",
                    "message": str(exc),
                }
            ]
            if not paths.attempts_csv.exists():
                write_csv(paths.attempts_csv, ATTEMPT_FIELDS, attempts)
            summary = summarize(case, attempts, str(exc))
            print(f"  error: {exc}", file=sys.stderr)
        append_summary(run_dir / "summary.csv", summary)

    print(f"results={run_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
