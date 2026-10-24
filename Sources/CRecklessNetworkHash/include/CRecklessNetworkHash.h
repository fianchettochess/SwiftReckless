// Streaming SHA-256 for network artifact integrity, FIPS 180-4.
#ifndef CRecklessNetworkHash_H
#define CRecklessNetworkHash_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint32_t state[8];
    uint8_t buffer[64];
    uint64_t total_bytes;
    size_t buffer_count;
} rk_network_hash_context;
void rk_network_hash_init(rk_network_hash_context *context);
void rk_network_hash_update(rk_network_hash_context *context, const uint8_t *bytes, size_t count);
void rk_network_hash_finalize(rk_network_hash_context *context, uint8_t digest[32]);
#ifdef __cplusplus
}
#endif
#endif
