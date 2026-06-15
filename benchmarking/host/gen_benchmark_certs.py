#!/usr/bin/env python3
"""Generate per-case TLS certificates and a firmware CA header."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = ROOT / "benchmarking"


ALG_MAP = {
    "ML-DSA-44": {"openssl": "ML-DSA-44", "digest": None},
    "ML-DSA-65": {"openssl": "ML-DSA-65", "digest": None},
    "ML-DSA-87": {"openssl": "ML-DSA-87", "digest": None},
    "SLH-DSA-SHAKE-128s": {"openssl": "SLH-DSA-SHAKE-128s", "digest": None},
    "SLH-DSA-SHAKE-192s": {"openssl": "SLH-DSA-SHAKE-192s", "digest": None},
    "SLH-DSA-SHAKE-256s": {"openssl": "SLH-DSA-SHAKE-256s", "digest": None},
    "ECDSA-P-256": {"openssl": "EC", "curve": "prime256v1", "digest": "-sha256"},
    "ECDSA-P-384": {"openssl": "EC", "curve": "secp384r1", "digest": "-sha384"},
    "ECDSA-P-521": {"openssl": "EC", "curve": "secp521r1", "digest": "-sha512"},
    "RSA-PSS-3072": {"openssl": "RSA", "bits": "3072", "digest": "-sha384"},
    "RSA-PSS-7680": {"openssl": "RSA", "bits": "7680", "digest": "-sha384"},
    "RSA-PSS-15360": {"openssl": "RSA", "bits": "15360", "digest": "-sha512"},
}


SLH_ENTITY_SIG = {
    "SLH-DSA-SHAKE-128s": "ML-DSA-44",
    "SLH-DSA-SHAKE-192s": "ML-DSA-65",
    "SLH-DSA-SHAKE-256s": "ML-DSA-87",
}


def run(cmd: list[str], cwd: Path | None = None) -> None:
    subprocess.run(cmd, cwd=cwd, check=True)


def gen_key(algorithm: str, output: Path) -> None:
    spec = ALG_MAP[algorithm]
    cmd = ["openssl", "genpkey", "-algorithm", str(spec["openssl"])]
    if spec["openssl"] == "RSA":
        cmd.extend(["-pkeyopt", f"rsa_keygen_bits:{spec['bits']}"])
    elif spec["openssl"] == "EC":
        cmd.extend(["-pkeyopt", f"ec_paramgen_curve:{spec['curve']}"])
    cmd.extend(["-out", str(output)])
    run(cmd)


def req_or_x509_digest_args(algorithm: str) -> list[str]:
    digest = ALG_MAP[algorithm].get("digest")
    return [str(digest)] if digest else []


def server_key_algorithm(cert_sig: str) -> str:
    return SLH_ENTITY_SIG.get(cert_sig, cert_sig)


def write_ca_ext(path: Path) -> None:
    path.write_text(
        "\n".join(
            [
                "[v3_ca]",
                "basicConstraints=critical,CA:TRUE,pathlen:0",
                "keyUsage=critical,keyCertSign,cRLSign",
                "subjectKeyIdentifier=hash",
                "",
            ]
        )
    )


def write_server_ext(path: Path, host_ip: str, host_dns: str) -> None:
    path.write_text(
        "\n".join(
            [
                "authorityKeyIdentifier=keyid,issuer",
                "basicConstraints=CA:FALSE",
                "keyUsage=digitalSignature,keyEncipherment",
                "extendedKeyUsage=serverAuth",
                f"subjectAltName=DNS:{host_dns},IP:{host_ip}",
                "",
            ]
        )
    )


def write_header(ca_crt: Path, header: Path) -> None:
    pem_lines = ca_crt.read_text().splitlines()
    header.parent.mkdir(parents=True, exist_ok=True)
    with header.open("w") as fp:
        fp.write("#ifndef APP_BENCHMARK_CERT_H\n")
        fp.write("#define APP_BENCHMARK_CERT_H\n\n")
        fp.write("static const char ca_cert_pem[] =\n")
        for line in pem_lines:
            fp.write(f"\"{line}\\n\"\n")
        fp.write(";\n\n#endif\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case-id", required=True)
    parser.add_argument("--cert-sig", required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--host-ip", default="2001:db8::2")
    parser.add_argument("--host-dns", default="localhost")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.cert_sig not in ALG_MAP:
        raise SystemExit(f"Unsupported certificate algorithm: {args.cert_sig}")

    cert_dir = args.out_dir / "certs"
    generated_dir = args.out_dir / "generated"
    cert_dir.mkdir(parents=True, exist_ok=True)

    ca_key = cert_dir / "ca.key"
    ca_csr = cert_dir / "ca.csr"
    ca_crt = cert_dir / "ca.crt"
    server_key = cert_dir / "server.key"
    server_csr = cert_dir / "server.csr"
    server_crt = cert_dir / "server.crt"
    ca_ext = cert_dir / "ca.ext"
    server_ext = cert_dir / "server.ext"

    server_sig = server_key_algorithm(args.cert_sig)
    gen_key(args.cert_sig, ca_key)
    gen_key(server_sig, server_key)

    write_ca_ext(ca_ext)
    run(
        [
            "openssl",
            "req",
            "-new",
            "-key",
            str(ca_key),
            "-subj",
            f"/CN=bench-ca-{args.case_id}",
            "-out",
            str(ca_csr),
        ]
    )

    run(
        [
            "openssl",
            "x509",
            "-req",
            "-in",
            str(ca_csr),
            "-signkey",
            str(ca_key),
            *req_or_x509_digest_args(args.cert_sig),
            "-days",
            "3650",
            "-extensions",
            "v3_ca",
            "-extfile",
            str(ca_ext),
            "-out",
            str(ca_crt),
        ]
    )

    run(
        [
            "openssl",
            "req",
            "-new",
            "-key",
            str(server_key),
            "-subj",
            f"/CN={args.host_dns}",
            "-out",
            str(server_csr),
        ]
    )

    write_server_ext(server_ext, args.host_ip, args.host_dns)
    run(
        [
            "openssl",
            "x509",
            "-req",
            "-in",
            str(server_csr),
            "-CA",
            str(ca_crt),
            "-CAkey",
            str(ca_key),
            "-CAcreateserial",
            "-out",
            str(server_crt),
            "-days",
            "825",
            *req_or_x509_digest_args(args.cert_sig),
            "-extfile",
            str(server_ext),
        ]
    )

    ca_csr.unlink(missing_ok=True)
    server_csr.unlink(missing_ok=True)
    ca_ext.unlink(missing_ok=True)
    server_ext.unlink(missing_ok=True)
    write_header(ca_crt, generated_dir / "benchmark_cert.h")

    print(f"cert_dir={cert_dir}")
    print(f"generated_dir={generated_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
