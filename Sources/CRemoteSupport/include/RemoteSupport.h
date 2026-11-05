#ifndef IPRC_REMOTE_SUPPORT_H
#define IPRC_REMOTE_SUPPORT_H

#include <stddef.h>
#include <stdint.h>

typedef void *IPRCSBCDecoderRef;

IPRCSBCDecoderRef iprc_sbc_decoder_create(void);
void iprc_sbc_decoder_destroy(IPRCSBCDecoderRef decoder);

/* Decodes one 57-byte mSBC frame. Returns mono PCM sample count, or < 0. */
int iprc_sbc_decode_msbc(IPRCSBCDecoderRef decoder,
                         const uint8_t *input,
                         size_t input_length,
                         int16_t *output,
                         size_t output_capacity);

int iprc_hci_tool_status(void);
int iprc_hci_open(const char *executable, const char *address, int *descriptor);

typedef void *IPRCNativeCaptureRef;
enum { IPRCNativeCaptureProfileRequired = -2005 };
typedef struct {
    uint64_t envelopes, frames, dropped;
    uint16_t handle, interrupt_cid;
    int error, authorization_submitted;
} IPRCNativeCaptureStats;

/* System XPC backend; no Apple executable/framework or raw packet persistence.
 * Calls are serialized internally. Caller must stop polling before destroying. */
int iprc_native_capture_create(const char *address, IPRCNativeCaptureRef *capture);
void iprc_native_capture_destroy(IPRCNativeCaptureRef capture);
int iprc_native_capture_read(IPRCNativeCaptureRef capture, uint8_t report[652], uint16_t *handle);
void iprc_native_capture_stats(IPRCNativeCaptureRef capture, IPRCNativeCaptureStats *stats);

#endif
