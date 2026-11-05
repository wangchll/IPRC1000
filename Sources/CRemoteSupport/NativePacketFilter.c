#include "NativePacketFilter.h"
#include <string.h>

static uint16_t le16(const uint8_t *p) { return (uint16_t)p[0] | (uint16_t)p[1] << 8; }
static uint32_t word32(const uint8_t *p, int little) {
    uint32_t value = 0;
    for (unsigned i = 0; i < 4; i++) value |= (uint32_t)p[i] << (8 * (little ? i : 3 - i));
    return value;
}
static void clear_voice(IPRCNativeFilter *f) {
    memset(f->voice_pdu, 0, sizeof(f->voice_pdu));
    f->voice_used = 0;
}
static void clear_link(IPRCNativeFilter *f) {
    f->handle = UINT16_MAX;
    f->interrupt_cid = 0;
    memset(f->requests, 0, sizeof(f->requests));
    clear_voice(f);
}
void iprc_native_filter_init(IPRCNativeFilter *f, const uint8_t address[6]) {
    memset(f, 0, sizeof(*f));
    memcpy(f->address, address, 6);
    clear_link(f);
}
static void signal_commands(IPRCNativeFilter *f, const uint8_t *p, size_t n, unsigned received) {
    while (n >= 4) {
        unsigned code = p[0], id = p[1];
        size_t length = le16(p + 2);
        if (length > n - 4) return;
        const uint8_t *body = p + 4;
        if (code == 2 && length == 4) {
            IPRCChannelRequest *q = &f->requests[received][id];
            q->source = le16(body + 2);
            q->valid = le16(body) == 0x13 && q->source >= 0x40;
        } else if (code == 3 && length == 8) {
            IPRCChannelRequest *q = &f->requests[!received][id];
            uint16_t destination = le16(body), source = le16(body + 2);
            uint16_t result = le16(body + 4), status = le16(body + 6);
            if (q->valid && q->source == source && result == 0 && status == 0 && destination >= 0x40) {
                f->interrupt_cid = received ? source : destination;
                q->valid = 0;
            } else if (result != 1) q->valid = 0;
        } else if (code == 6 && length == 4) {
            if (le16(body) == f->interrupt_cid || le16(body + 2) == f->interrupt_cid) {
                f->interrupt_cid = 0;
            }
        }
        p += 4 + length;
        n -= 4 + length;
    }
}
const uint8_t *iprc_native_filter_feed(IPRCNativeFilter *f, const uint8_t *data, size_t length) {
    if (!f || !data || length < 13 || length > 65539) return NULL;
    int little = word32(data, 1) == length - 4 && word32(data + 8, 1) < 1000000;
    int big = word32(data, 0) == length - 4 && word32(data + 8, 0) < 1000000;
    if (!little && !big) return NULL;
    unsigned type = data[12];
    const uint8_t *p = data + 13;
    size_t n = length - 13;
    if (type == 1) {
        if (n == 13 && p[0] == 3 && p[1] == 11 && p[2] == 0 && p[11] == 1) {
            uint16_t handle = le16(p + 3) & 0xfff;
            int target = 1;
            for (unsigned i = 0; i < 6; i++) if (p[5 + i] != f->address[5 - i]) target = 0;
            if (target || handle == f->handle) {
                clear_link(f);
                if (target) f->handle = handle;
            }
        } else if (n == 6 && p[0] == 5 && p[1] == 4 && p[2] == 0 && (le16(p + 3) & 0xfff) == f->handle) {
            clear_link(f);
        }
        return NULL;
    }
    if ((type != 2 && type != 3) || n < 4 || f->handle == UINT16_MAX) return NULL;
    uint16_t flags = le16(p);
    unsigned boundary = (flags >> 12) & 3;
    if ((flags & 0xfff) != f->handle) return NULL;
    if ((flags & 0xc000) || boundary == 3 || le16(p + 2) != n - 4) {
        if (type == 3) clear_voice(f);
        return NULL;
    }
    if (boundary == 1) {
        if (type != 3 || !f->voice_used) return NULL;
        if (n == 4 || n - 4 > sizeof(f->voice_pdu) - f->voice_used) {
            clear_voice(f);
            return NULL;
        }
        memcpy(f->voice_pdu + f->voice_used, p + 4, n - 4);
        f->voice_used += n - 4;
    } else {
        if (type == 3) clear_voice(f);
        if (n < 8) return NULL;
        uint16_t cid = le16(p + 6);
        if (cid == 1) {
            if (le16(p + 4) != n - 8) return NULL;
            uint16_t oldCID = f->interrupt_cid;
            signal_commands(f, p + 8, n - 8, type == 3);
            if (oldCID != f->interrupt_cid) clear_voice(f);
            return NULL;
        }
        if (type != 3 || !f->interrupt_cid || cid != f->interrupt_cid
            || le16(p + 4) != 653 || n - 4 > sizeof(f->voice_pdu)) return NULL;
        memcpy(f->voice_pdu, p + 4, n - 4);
        f->voice_used = n - 4;
    }
    if (f->voice_used != sizeof(f->voice_pdu)) return NULL;
    f->voice_used = 0;
    const uint8_t *voice = f->voice_pdu + 4;
    if (voice[0] != 0xa1 || voice[1] != 0xf7 || voice[2] != 1 || le16(voice + 11) != 320) {
        clear_voice(f);
        return NULL;
    }
    return voice + 1;
}
