// Direct FIPS 180-4 implementation of the existing Swift compression loop.
// Byte loads are alignment-independent; unsigned arithmetic wraps modulo 2^32.
#include "CRecklessNetworkHash.h"
#include <string.h>

static const uint32_t constants[64] = {
0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};
static uint32_t rotate_right(uint32_t x, unsigned n) {
    return (x >> n) | (x << (32 - n));
}
static void compress(rk_network_hash_context *context, const uint8_t *block) {
    uint32_t w[64];
    for (size_t i = 0; i < 16; ++i) {
        const uint8_t *p = block + i * 4;
        w[i] = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
             | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
    }
    for (size_t i = 16; i < 64; ++i) {
        uint32_t s0 = rotate_right(w[i-15], 7) ^ rotate_right(w[i-15], 18) ^ (w[i-15] >> 3);
        uint32_t s1 = rotate_right(w[i-2], 17) ^ rotate_right(w[i-2], 19) ^ (w[i-2] >> 10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    uint32_t a=context->state[0], b=context->state[1], c=context->state[2], d=context->state[3];
    uint32_t e=context->state[4], f=context->state[5], g=context->state[6], h=context->state[7];
    for (size_t i = 0; i < 64; ++i) {
        uint32_t sum1 = rotate_right(e,6) ^ rotate_right(e,11) ^ rotate_right(e,25);
        uint32_t choice = (e & f) ^ (~e & g);
        uint32_t t1 = h + sum1 + choice + constants[i] + w[i];
        uint32_t sum0 = rotate_right(a,2) ^ rotate_right(a,13) ^ rotate_right(a,22);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = sum0 + majority;
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    context->state[0]+=a; context->state[1]+=b; context->state[2]+=c; context->state[3]+=d;
    context->state[4]+=e; context->state[5]+=f; context->state[6]+=g; context->state[7]+=h;
}
void rk_network_hash_init(rk_network_hash_context *context) {
    static const uint32_t initial[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    };
    memset(context, 0, sizeof(*context));
    memcpy(context->state, initial, sizeof(initial));
}
void rk_network_hash_update(rk_network_hash_context *context, const uint8_t *bytes, size_t count) {
    if (count == 0) return;
    context->total_bytes += count;
    if (context->buffer_count != 0) {
        size_t needed = 64 - context->buffer_count;
        size_t take = count < needed ? count : needed;
        memcpy(context->buffer + context->buffer_count, bytes, take);
        context->buffer_count += take; bytes += take; count -= take;
        if (context->buffer_count == 64) {
            compress(context, context->buffer);
            context->buffer_count = 0;
        }
    }
    while (count >= 64) {
        compress(context, bytes); bytes += 64; count -= 64;
    }
    if (count != 0) {
        memcpy(context->buffer, bytes, count);
        context->buffer_count = count;
    }
}
void rk_network_hash_finalize(rk_network_hash_context *context, uint8_t digest[32]) {
    uint64_t bits = context->total_bytes * UINT64_C(8);
    context->buffer[context->buffer_count++] = 0x80;
    if (context->buffer_count > 56) {
        memset(context->buffer + context->buffer_count, 0, 64 - context->buffer_count);
        compress(context, context->buffer); context->buffer_count = 0;
    }
    memset(context->buffer + context->buffer_count, 0, 56 - context->buffer_count);
    for (size_t i = 0; i < 8; ++i) context->buffer[56+i] = (uint8_t)(bits >> (56 - i*8));
    compress(context, context->buffer); context->buffer_count = 0;
    for (size_t i = 0; i < 8; ++i) {
        for (size_t j = 0; j < 4; ++j) digest[i*4+j] = (uint8_t)(context->state[i] >> (24-j*8));
    }
}
