#import <Foundation/Foundation.h>
#import <Security/Authorization.h>
#import <xpc/xpc.h>
#include "include/RemoteSupport.h"
#include "NativePacketFilter.h"
#include <ctype.h>

enum { FrameCapacity = 64, ReportLength = 652 };

/* Match a service diagnostic, never search arbitrary HCI/audio payloads. */
static BOOL profileRequired(const uint8_t *data, size_t length) {
    static const char message[] = "Bluetooth Profile Required";
    if (!data) return NO;
    if (length >= 13 && data[12] == 0xfc) {
        uint32_t big = 0, little = 0;
        for (unsigned i = 0; i < 4; i++) {
            big = (big << 8) | data[i];
            little |= (uint32_t)data[i] << (8 * i);
        }
        if (big != length - 4 && little != length - 4) return NO;
        data += 13;
        length -= 13;
    }
    return (length == sizeof(message) - 1 || (length == sizeof(message) && data[length - 1] == 0))
        && memcmp(data, message, sizeof(message) - 1) == 0;
}

@interface IPRCNativeSession : NSObject {
@public
    AuthorizationRef authorization;
    AuthorizationExternalForm external;
    IPRCNativeFilter filter;
    IPRCNativeCaptureStats stats;
    uint8_t reports[FrameCapacity][ReportLength];
    uint16_t handles[FrameCapacity];
    unsigned head, count;
    BOOL stopped;
}
@property(strong) dispatch_queue_t queue;
@property(strong) xpc_connection_t connection;
@end

@implementation IPRCNativeSession
- (void)dealloc {
    if (authorization) AuthorizationFree(authorization, kAuthorizationFlagDefaults);
}
@end

int iprc_native_capture_create(const char *address, IPRCNativeCaptureRef *capture) {
    if (!capture) return -2001;
    *capture = NULL;
    if (!address || strlen(address) != 12) return -2001;
    uint8_t bytes[6];
    for (unsigned i = 0; i < 6; i++) {
        if (!isxdigit((unsigned char)address[i * 2]) || !isxdigit((unsigned char)address[i * 2 + 1])) return -2001;
        char pair[3] = {address[i * 2], address[i * 2 + 1], 0};
        char *end;
        unsigned long value = strtoul(pair, &end, 16);
        if (end != pair + 2 || value > 255) return -2001;
        bytes[i] = (uint8_t)value;
    }
    IPRCNativeSession *session = [IPRCNativeSession new];
    OSStatus result = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
        kAuthorizationFlagDefaults, &session->authorization);
    AuthorizationItem item = {"com.apple.PacketLogger.HCI", 0, NULL, 0};
    AuthorizationRights rights = {1, &item};
    if (result == errAuthorizationSuccess)
        result = AuthorizationCopyRights(session->authorization, &rights,
            kAuthorizationEmptyEnvironment, kAuthorizationFlagExtendRights, NULL);
    if (result == errAuthorizationSuccess)
        result = AuthorizationMakeExternalForm(session->authorization, &session->external);
    if (result != errAuthorizationSuccess) return (int)result;

    iprc_native_filter_init(&session->filter, bytes);
    session->stats.handle = UINT16_MAX;
    session.queue = dispatch_queue_create("local.iprc1000.native-capture", DISPATCH_QUEUE_SERIAL);
    session.connection = xpc_connection_create_mach_service("com.apple.bluetooth.BTPacketLogger",
        session.queue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!session.connection) return -2002;
    __weak IPRCNativeSession *weakSession = session;
    void (^receive)(xpc_object_t) = ^(xpc_object_t message) {
        IPRCNativeSession *s = weakSession;
        if (!s || s->stopped) return;
        if (xpc_get_type(message) == XPC_TYPE_ERROR) {
            s->stats.error = message == XPC_ERROR_CONNECTION_INTERRUPTED ? -2003 : -2004;
            return;
        }
        if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
        if (xpc_dictionary_get_bool(message, "RequiresAuth") && !s->stats.authorization_submitted) {
            xpc_object_t auth = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_data(auth, "Authentication", &s->external, sizeof(s->external));
            xpc_connection_send_message(s.connection, auth);
            s->stats.authorization_submitted = 1;
        }
        xpc_object_t packet = xpc_dictionary_get_value(message, "packet");
        if (!packet || xpc_get_type(packet) != XPC_TYPE_DATA) return;
        s->stats.envelopes++;
        const uint8_t *bytes = xpc_data_get_bytes_ptr(packet);
        size_t length = xpc_data_get_length(packet);
        if (profileRequired(bytes, length)) {
            s->stats.error = IPRCNativeCaptureProfileRequired;
            s->stopped = YES;
            memset(s->reports, 0, sizeof(s->reports));
            s->head = s->count = 0;
            memset(s->filter.voice_pdu, 0, sizeof(s->filter.voice_pdu));
            s->filter.voice_used = 0;
            return;
        }
        uint16_t oldHandle = s->filter.handle, oldCID = s->filter.interrupt_cid;
        const uint8_t *report = iprc_native_filter_feed(&s->filter, bytes, length);
        if (oldHandle != s->filter.handle || (oldCID && !s->filter.interrupt_cid)) {
            memset(s->reports, 0, sizeof(s->reports));
            s->head = s->count = 0;
        }
        s->stats.handle = s->filter.handle;
        s->stats.interrupt_cid = s->filter.interrupt_cid;
        if (!report) return;
        s->stats.frames++;
        if (s->count == FrameCapacity) {
            s->head = (s->head + 1) % FrameCapacity;
            s->count--;
            s->stats.dropped++;
        }
        unsigned tail = (s->head + s->count) % FrameCapacity;
        memcpy(s->reports[tail], report, ReportLength);
        s->handles[tail] = s->filter.handle;
        s->count++;
    };
    xpc_connection_set_event_handler(session.connection, receive);
    xpc_connection_resume(session.connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_connection_send_message_with_reply(session.connection, request, session.queue, receive);
    *capture = (__bridge_retained void *)session;
    return 0;
}

void iprc_native_capture_destroy(IPRCNativeCaptureRef capture) {
    if (!capture) return;
    IPRCNativeSession *session = (__bridge_transfer IPRCNativeSession *)capture;
    dispatch_semaphore_t closed = dispatch_semaphore_create(0);
    dispatch_sync(session.queue, ^{
        session->stopped = YES;
        xpc_connection_set_event_handler(session.connection, ^(xpc_object_t message) {
            if (message == XPC_ERROR_CONNECTION_INVALID) dispatch_semaphore_signal(closed);
        });
        xpc_connection_cancel(session.connection);
        memset(session->reports, 0, sizeof(session->reports));
        memset(&session->filter, 0, sizeof(session->filter));
        session->count = 0;
    });
    // Cancellation is asynchronous. Drain its terminal event before the caller
    // restores HCI tracing, without blocking the callback queue or waiting forever.
    dispatch_semaphore_wait(closed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
}

int iprc_native_capture_read(IPRCNativeCaptureRef capture, uint8_t report[652], uint16_t *handle) {
    if (!capture || !report || !handle) return 0;
    IPRCNativeSession *session = (__bridge IPRCNativeSession *)capture;
    __block int available = 0;
    dispatch_sync(session.queue, ^{
        if (!session->count || session->stopped) return;
        memcpy(report, session->reports[session->head], ReportLength);
        *handle = session->handles[session->head];
        session->head = (session->head + 1) % FrameCapacity;
        session->count--;
        available = 1;
    });
    return available;
}

void iprc_native_capture_stats(IPRCNativeCaptureRef capture, IPRCNativeCaptureStats *stats) {
    if (!capture || !stats) return;
    IPRCNativeSession *session = (__bridge IPRCNativeSession *)capture;
    dispatch_sync(session.queue, ^{ *stats = session->stats; });
}
