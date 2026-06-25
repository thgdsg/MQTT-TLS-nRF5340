#ifndef APP_BENCH_WOLFSSL_USER_SETTINGS_H
#define APP_BENCH_WOLFSSL_USER_SETTINGS_H

#include <zephyr/net/socket.h>

#define WOLFSSL_TLS13
#define HAVE_TLS_EXTENSIONS
#define HAVE_SUPPORTED_CURVES
#define HAVE_ECC
#define HAVE_ECC384
#define HAVE_ECC521
#define HAVE_CURVE25519
#define HAVE_FFDHE_2048
#define WC_RSA_PSS
#define WOLFSSL_PSS_LONG_SALT
#define WOLFSSL_PSS_SALT_LEN_DISCOVER
#define WOLFSSL_RSA_VERIFY_INLINE
#define HAVE_AESGCM
#define HAVE_HKDF
#define HAVE_HASHDRBG
#define WOLFSSL_BASE64_ENCODE
#define WOLFSSL_SHA256
#define WOLFSSL_SHA384
#define WOLFSSL_SHA3
#define WOLFSSL_SHA512
#define WOLFSSL_SHAKE128
#define WOLFSSL_SHAKE256
#define HAVE_SERVER_INDICATION
#define WOLFSSL_DH_CONST
#define WOLFSSL_NO_SOCK
#define WOLFSSL_USER_IO
#define XMALLOC_USER
#define NO_INT128
#define NO_ASN_TIME_CHECK

#ifdef CONFIG_APP_BENCH_WOLFSSL_DEBUG
#define DEBUG_WOLFSSL
#endif

/*
 * RSA-PSS-15360 certificates need big-integer operations beyond the default
 * SP math limits. Heap math keeps those very large RSA verifies dynamic instead
 * of requiring a huge fixed FP_MAX_BITS buffer on the nRF52840.
 */
#define USE_INTEGER_HEAP_MATH
#define RSA_MAX_SIZE 16384

#ifdef CONFIG_WOLFSSL_MLKEM
#define WOLFSSL_HAVE_MLKEM
#define WOLFSSL_PQC_HYBRIDS
#endif

#ifdef CONFIG_APP_BENCH_MLKEM_BACKEND_PQM4_CLEAN
#define WOLF_CRYPTO_CB
#define WOLF_CRYPTO_CB_FIND
#define WOLF_CRYPTO_CB_ONLY_PQC
#define MAX_CRYPTO_DEVID_CALLBACKS 16
#endif

/*
 * Keep these enabled for benchmark builds so certificate signature variants
 * can be probed. Unsupported combinations are reported by the runner instead
 * of falling back to a different algorithm silently.
 */
#define WOLFSSL_HAVE_MLDSA
#define WOLFSSL_MLDSA_VERIFY_SMALL_MEM
#define WOLFSSL_HAVE_SLHDSA
#define WOLFSSL_WC_SLHDSA

#endif
