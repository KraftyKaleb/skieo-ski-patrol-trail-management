/* Code fingerprints of the four game routines that guard the CPU snow cache layout.
   Copied from skieomod's native/SkiEONativeTerrain/layout_profiles.h (BSD-3-Clause, Copyright (c) 2026, Ayane;
   see LICENSE-skieomod). Instruction bytes with address operands masked out are hashed (FNV-1a), so a
   game build whose routines changed does not match and the sampler stays off. */
static const uint8_t prefix_VALIDITY[] = {0x0f,0xb6,0x81,0xa5,0x01,0x00,0x00,0x41,0x88,0x00};
static const mask_t masks_VALIDITY[] = {{0,0}};
static const uint8_t prefix_LOOKUP[] = {0x49,0x63,0xc0,0x48,0x6b,0xd0,0x38,0x49,0x03,0xd2,0x48,0x8b,0x0a,0x41,0x3b,0xc9};
static const mask_t masks_LOOKUP[] = {{479,4},{507,4}};
static const uint8_t prefix_MAPPING[] = {0xf2,0x0f,0x10,0x89,0xf8,0x00,0x00,0x00,0x0f,0x57,0xd2,0xf2,0x0f,0x5c,0x89,0xe8,0x00,0x00,0x00};
static const mask_t masks_MAPPING[] = {{87,4},{158,4},{209,4},{236,4}};
static const uint8_t prefix_READY[] = {0x41,0x38,0x54,0x24,0x20,0x0f,0x84};
static const mask_t masks_READY[] = {{7,4},{15,4}};
static const layout_t layouts[4] = {
    {prefix_VALIDITY,10,11,masks_VALIDITY,0,UINT64_C(0x9162FE1838DDB349)},
    {prefix_LOOKUP,16,718,masks_LOOKUP,2,UINT64_C(0xF1C96B14F792ED4F)},
    {prefix_MAPPING,19,251,masks_MAPPING,4,UINT64_C(0x31E8DFD67F6DB5C6)},
    {prefix_READY,7,136,masks_READY,2,UINT64_C(0x19B77A5DC6051C2A)},
};
