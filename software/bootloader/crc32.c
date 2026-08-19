#include "crc32.h"

alt_u32 crc32_update(alt_u32 crc, const alt_u8 *data, alt_u32 length)
{
    alt_u32 i;
    alt_u32 bit;

    for (i = 0U; i < length; ++i) {
        crc ^= data[i];
        for (bit = 0U; bit < 8U; ++bit) {
            crc = (crc & 1U) ? ((crc >> 1) ^ 0xEDB88320U) : (crc >> 1);
        }
    }
    return crc;
}
