#include "pqm4_mlkem_backend.h"

#include <stdint.h>
#include <string.h>

#include <zephyr/sys/util.h>

#include <wolfssl/options.h>
#include <wolfssl/ssl.h>
#include <wolfssl/wolfcrypt/cryptocb.h>
#include <wolfssl/wolfcrypt/error-crypt.h>
#include <wolfssl/wolfcrypt/random.h>
#include <wolfssl/wolfcrypt/wc_mlkem.h>

#define PQM4_MLKEM_DEV_ID 42040
#define MLKEM_KEYPAIR_RANDOM_BYTES 64
#define MLKEM_ENCAPS_RANDOM_BYTES 32

int PQCLEAN_MLKEM512_CLEAN_crypto_kem_keypair_derand(uint8_t *pk, uint8_t *sk,
						     const uint8_t *coins);
int PQCLEAN_MLKEM512_CLEAN_crypto_kem_enc_derand(uint8_t *ct, uint8_t *ss,
						 const uint8_t *pk,
						 const uint8_t *coins);
int PQCLEAN_MLKEM512_CLEAN_crypto_kem_dec(uint8_t *ss, const uint8_t *ct,
					  const uint8_t *sk);

int PQCLEAN_MLKEM768_CLEAN_crypto_kem_keypair_derand(uint8_t *pk, uint8_t *sk,
						     const uint8_t *coins);
int PQCLEAN_MLKEM768_CLEAN_crypto_kem_enc_derand(uint8_t *ct, uint8_t *ss,
						 const uint8_t *pk,
						 const uint8_t *coins);
int PQCLEAN_MLKEM768_CLEAN_crypto_kem_dec(uint8_t *ss, const uint8_t *ct,
					  const uint8_t *sk);

int PQCLEAN_MLKEM1024_CLEAN_crypto_kem_keypair_derand(uint8_t *pk, uint8_t *sk,
						      const uint8_t *coins);
int PQCLEAN_MLKEM1024_CLEAN_crypto_kem_enc_derand(uint8_t *ct, uint8_t *ss,
						  const uint8_t *pk,
						  const uint8_t *coins);
int PQCLEAN_MLKEM1024_CLEAN_crypto_kem_dec(uint8_t *ss, const uint8_t *ct,
					   const uint8_t *sk);

struct pqm4_mlkem_level {
	int wolf_type;
	word32 public_len;
	word32 private_len;
	word32 ciphertext_len;
	int (*keypair_derand)(uint8_t *pk, uint8_t *sk, const uint8_t *coins);
	int (*enc_derand)(uint8_t *ct, uint8_t *ss, const uint8_t *pk,
			  const uint8_t *coins);
	int (*dec)(uint8_t *ss, const uint8_t *ct, const uint8_t *sk);
};

static const struct pqm4_mlkem_level mlkem_levels[] = {
	{
		.wolf_type = WC_ML_KEM_512,
		.public_len = WC_ML_KEM_512_PUBLIC_KEY_SIZE,
		.private_len = WC_ML_KEM_512_PRIVATE_KEY_SIZE,
		.ciphertext_len = WC_ML_KEM_512_CIPHER_TEXT_SIZE,
		.keypair_derand = PQCLEAN_MLKEM512_CLEAN_crypto_kem_keypair_derand,
		.enc_derand = PQCLEAN_MLKEM512_CLEAN_crypto_kem_enc_derand,
		.dec = PQCLEAN_MLKEM512_CLEAN_crypto_kem_dec,
	},
	{
		.wolf_type = WC_ML_KEM_768,
		.public_len = WC_ML_KEM_768_PUBLIC_KEY_SIZE,
		.private_len = WC_ML_KEM_768_PRIVATE_KEY_SIZE,
		.ciphertext_len = WC_ML_KEM_768_CIPHER_TEXT_SIZE,
		.keypair_derand = PQCLEAN_MLKEM768_CLEAN_crypto_kem_keypair_derand,
		.enc_derand = PQCLEAN_MLKEM768_CLEAN_crypto_kem_enc_derand,
		.dec = PQCLEAN_MLKEM768_CLEAN_crypto_kem_dec,
	},
	{
		.wolf_type = WC_ML_KEM_1024,
		.public_len = WC_ML_KEM_1024_PUBLIC_KEY_SIZE,
		.private_len = WC_ML_KEM_1024_PRIVATE_KEY_SIZE,
		.ciphertext_len = WC_ML_KEM_1024_CIPHER_TEXT_SIZE,
		.keypair_derand = PQCLEAN_MLKEM1024_CLEAN_crypto_kem_keypair_derand,
		.enc_derand = PQCLEAN_MLKEM1024_CLEAN_crypto_kem_enc_derand,
		.dec = PQCLEAN_MLKEM1024_CLEAN_crypto_kem_dec,
	},
};

static const struct pqm4_mlkem_level *level_from_key(const MlKemKey *key)
{
	int type;

	if (!key) {
		return NULL;
	}

	type = key->type;
	if (type & MLKEM_KYBER) {
		type &= ~MLKEM_KYBER;
	}

	for (size_t i = 0; i < ARRAY_SIZE(mlkem_levels); i++) {
		if (mlkem_levels[i].wolf_type == type) {
			return &mlkem_levels[i];
		}
	}

	return NULL;
}

static int rng_bytes(WC_RNG *rng, uint8_t *out, word32 out_len)
{
	if (!rng || !out) {
		return BAD_FUNC_ARG;
	}

	return wc_RNG_GenerateBlock(rng, out, out_len);
}

static int pqm4_make_key(WC_RNG *rng, MlKemKey *key)
{
	const struct pqm4_mlkem_level *level = level_from_key(key);
	uint8_t coins[MLKEM_KEYPAIR_RANDOM_BYTES];
	uint8_t *pk;
	uint8_t *sk;
	int ret;

	if (!level) {
		return CRYPTOCB_UNAVAILABLE;
	}

	pk = XMALLOC(level->public_len, key->heap, DYNAMIC_TYPE_TMP_BUFFER);
	sk = XMALLOC(level->private_len, key->heap, DYNAMIC_TYPE_TMP_BUFFER);
	if (!pk || !sk) {
		ret = MEMORY_E;
		goto out;
	}

	ret = rng_bytes(rng, coins, sizeof(coins));
	if (ret == 0) {
		ret = level->keypair_derand(pk, sk, coins);
	}
	if (ret == 0) {
		ret = wc_MlKemKey_DecodePrivateKey(key, sk, level->private_len);
	}

out:
	if (pk) {
		XMEMSET(pk, 0, level ? level->public_len : 0);
		XFREE(pk, key ? key->heap : NULL, DYNAMIC_TYPE_TMP_BUFFER);
	}
	if (sk) {
		XMEMSET(sk, 0, level ? level->private_len : 0);
		XFREE(sk, key ? key->heap : NULL, DYNAMIC_TYPE_TMP_BUFFER);
	}
	XMEMSET(coins, 0, sizeof(coins));
	return ret;
}

static int pqm4_encapsulate(WC_RNG *rng, MlKemKey *key, uint8_t *ct,
			    word32 ct_len, uint8_t *ss, word32 ss_len)
{
	const struct pqm4_mlkem_level *level = level_from_key(key);
	uint8_t coins[MLKEM_ENCAPS_RANDOM_BYTES];
	uint8_t *pk;
	int ret;

	if (!level) {
		return CRYPTOCB_UNAVAILABLE;
	}
	if (!ct || !ss || ct_len != level->ciphertext_len ||
	    ss_len != WC_ML_KEM_SS_SZ) {
		return BUFFER_E;
	}

	pk = XMALLOC(level->public_len, key->heap, DYNAMIC_TYPE_TMP_BUFFER);
	if (!pk) {
		return MEMORY_E;
	}

	ret = wc_MlKemKey_EncodePublicKey(key, pk, level->public_len);
	if (ret == 0) {
		ret = rng_bytes(rng, coins, sizeof(coins));
	}
	if (ret == 0) {
		ret = level->enc_derand(ct, ss, pk, coins);
	}

	XMEMSET(pk, 0, level->public_len);
	XFREE(pk, key->heap, DYNAMIC_TYPE_TMP_BUFFER);
	XMEMSET(coins, 0, sizeof(coins));
	return ret;
}

static int pqm4_decapsulate(MlKemKey *key, const uint8_t *ct, word32 ct_len,
			    uint8_t *ss, word32 ss_len)
{
	const struct pqm4_mlkem_level *level = level_from_key(key);
	uint8_t *sk;
	int ret;

	if (!level) {
		return CRYPTOCB_UNAVAILABLE;
	}
	if (!ct || !ss || ct_len != level->ciphertext_len ||
	    ss_len != WC_ML_KEM_SS_SZ) {
		return BUFFER_E;
	}

	sk = XMALLOC(level->private_len, key->heap, DYNAMIC_TYPE_TMP_BUFFER);
	if (!sk) {
		return MEMORY_E;
	}

	ret = wc_MlKemKey_EncodePrivateKey(key, sk, level->private_len);
	if (ret == 0) {
		ret = level->dec(ss, ct, sk);
	}

	XMEMSET(sk, 0, level->private_len);
	XFREE(sk, key->heap, DYNAMIC_TYPE_TMP_BUFFER);
	return ret;
}

static int pqm4_mlkem_crypto_cb(int dev_id, wc_CryptoInfo *info, void *ctx)
{
	ARG_UNUSED(dev_id);
	ARG_UNUSED(ctx);

	if (!info || info->algo_type != WC_ALGO_TYPE_PK) {
		return CRYPTOCB_UNAVAILABLE;
	}

	switch (info->pk.type) {
	case WC_PK_TYPE_PQC_KEM_KEYGEN:
		if (info->pk.pqc_kem_kg.type != WC_PQC_KEM_TYPE_MLKEM) {
			return CRYPTOCB_UNAVAILABLE;
		}
		return pqm4_make_key(info->pk.pqc_kem_kg.rng,
				     (MlKemKey *)info->pk.pqc_kem_kg.key);
	case WC_PK_TYPE_PQC_KEM_ENCAPS:
		if (info->pk.pqc_encaps.type != WC_PQC_KEM_TYPE_MLKEM) {
			return CRYPTOCB_UNAVAILABLE;
		}
		return pqm4_encapsulate(info->pk.pqc_encaps.rng,
					(MlKemKey *)info->pk.pqc_encaps.key,
					info->pk.pqc_encaps.ciphertext,
					info->pk.pqc_encaps.ciphertextLen,
					info->pk.pqc_encaps.sharedSecret,
					info->pk.pqc_encaps.sharedSecretLen);
	case WC_PK_TYPE_PQC_KEM_DECAPS:
		if (info->pk.pqc_decaps.type != WC_PQC_KEM_TYPE_MLKEM) {
			return CRYPTOCB_UNAVAILABLE;
		}
		return pqm4_decapsulate((MlKemKey *)info->pk.pqc_decaps.key,
					info->pk.pqc_decaps.ciphertext,
					info->pk.pqc_decaps.ciphertextLen,
					info->pk.pqc_decaps.sharedSecret,
					info->pk.pqc_decaps.sharedSecretLen);
	default:
		return CRYPTOCB_UNAVAILABLE;
	}
}

int pqm4_mlkem_backend_init(void)
{
	int ret = wolfSSL_Init();

	if (ret != WOLFSSL_SUCCESS) {
		return ret;
	}

	wc_CryptoCb_UnRegisterDevice(PQM4_MLKEM_DEV_ID);
	ret = wc_CryptoCb_RegisterDevice(PQM4_MLKEM_DEV_ID,
					 pqm4_mlkem_crypto_cb, NULL);
	if (ret == BUFFER_E) {
		wolfSSL_Cleanup();
		ret = wolfSSL_Init();
		if (ret != WOLFSSL_SUCCESS) {
			return ret;
		}
		ret = wc_CryptoCb_RegisterDevice(PQM4_MLKEM_DEV_ID,
						 pqm4_mlkem_crypto_cb, NULL);
	}

	return ret;
}

int pqm4_mlkem_backend_dev_id(void)
{
	return PQM4_MLKEM_DEV_ID;
}
