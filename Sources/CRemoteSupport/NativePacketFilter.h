#ifndef IPRC_NATIVE_PACKET_FILTER_H
#define IPRC_NATIVE_PACKET_FILTER_H
#include <stddef.h>
#include <stdint.h>

typedef struct { uint16_t source; uint8_t valid; } IPRCChannelRequest;
typedef struct {
    uint8_t address[6];
    uint16_t handle, interrupt_cid;
    IPRCChannelRequest requests[2][256];
    uint8_t voice_pdu[657];
    size_t voice_used;
} IPRCNativeFilter;
void iprc_native_filter_init(IPRCNativeFilter *filter, const uint8_t address[6]);
/* Complete PacketLogger record from the system XPC service. No payload is stored.
 * Returns the target's 652-byte F7 report only after successful PSM 0x13 negotiation.
 * The returned bytes must be consumed before the next feed call. */
const uint8_t *iprc_native_filter_feed(IPRCNativeFilter *filter, const uint8_t *data, size_t length);
#endif
