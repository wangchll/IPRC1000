#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <signal.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/IOKitLib.h>

static volatile sig_atomic_t interrupted = 0;
static void stopSignal(int signum) { interrupted = signum; }

typedef enum { PacketRejected, PacketKeyboard, PacketAudio } PacketKind;
static PacketKind classifyPacket(const uint8_t *b, size_t length, uint16_t psm, BOOL target) {
    if (!target || psm != 0x13 || !b) return PacketRejected;
    if (length == 10 && b[0] == 0xa1 && b[1] == 1) return PacketKeyboard;
    if (length == 653 && b[0] == 0xa1 && b[1] == 0xf7 && b[2] == 1 &&
        b[11] == 0x40 && b[12] == 1) return PacketAudio;
    return PacketRejected;
}
static BOOL systemHasTargetHID(IOBluetoothDevice *device) {
    // Query only matching model metadata, then require the exact paired address.
    NSMutableDictionary *match = CFBridgingRelease(IOServiceMatching("IOHIDDevice"));
    match[@"VendorID"] = @0x0a5c; match[@"ProductID"] = @0x8502;
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, (__bridge_retained CFDictionaryRef)match, &iterator) != KERN_SUCCESS) return YES;
    BOOL found = NO;
    io_service_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        NSString *serial = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR(kIOHIDSerialNumberKey), NULL, 0));
        NSString *(^normalize)(NSString *) = ^NSString *(NSString *v) {
            return [[[v uppercaseString] componentsSeparatedByCharactersInSet:
                [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet]] componentsJoinedByString:@""];
        };
        if ([serial isKindOfClass:NSString.class] && [normalize(serial) isEqualToString:normalize(device.addressString)]) found = YES;
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    return found;
}
static int selfTest(void) {
    uint8_t audio[653] = {0xa1, 0xf7, 1}; audio[11] = 0x40; audio[12] = 1;
    uint8_t keyboard[10] = {0xa1, 1};
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d\n", __LINE__); return 1; } } while(0)
    CHECK(classifyPacket(audio,653,0x13,YES)==PacketAudio);
    CHECK(classifyPacket(keyboard,10,0x13,YES)==PacketKeyboard);
    CHECK(classifyPacket(audio,653,0x13,NO)==PacketRejected);
    CHECK(classifyPacket(audio,653,0x11,YES)==PacketRejected);
    CHECK(classifyPacket(NULL,653,0x13,YES)==PacketRejected);
    for(size_t n=0;n<653;n++) CHECK(classifyPacket(audio,n,0x13,YES)==PacketRejected);
    const size_t offsets[]={0,1,2,11,12};
    for(size_t i=0;i<5;i++) { size_t n=offsets[i]; uint8_t saved=audio[n]; audio[n]=0; CHECK(classifyPacket(audio,653,0x13,YES)==PacketRejected); audio[n]=saved; }
    audio[9]=1; CHECK(classifyPacket(audio,653,0x13,YES)==PacketAudio);
    puts("TARGET TRANSPORT SELF-TEST PASS: identity gate, PSM, framing, truncation and reserved field");
    return 0;
#undef CHECK
}

// A bounded development probe. No global packet/input listener, no private
// report requests, and no changes to pairing or other devices.
@interface TargetProbe : NSObject <IOBluetoothL2CAPChannelDelegate>
@property IOBluetoothDevice *device;
@property IOBluetoothL2CAPChannel *control;
@property IOBluetoothL2CAPChannel *interrupt;
@property BOOL ignored;
@property BOOL listenOnly;
@property BOOL existingOnly;
@property BOOL modernInterrupt;
@property BOOL opened;
@property NSTimeInterval openingDeadline;
@property IOBluetoothUserNotification *controlNotification;
@property IOBluetoothUserNotification *interruptNotification;
@property BOOL done;
@property BOOL failed;
@property NSUInteger keyboardReports;
@property NSUInteger audioReports;
- (void)start;
- (void)stop;
@end
@implementation TargetProbe
- (void)start {
    if (self.existingOnly) {
        if (!self.device.isConnected) { puts("target not connected; waiting without changing HID handling"); fflush(stdout); return; }
        [self attachExisting];
        return;
    }
    if (self.device.isConnected) {
        puts("REFUSED: target already connected; existing system channels are not taken over");
        self.failed = YES; self.done = YES; return;
    }
    self.controlNotification = [IOBluetoothL2CAPChannel registerForChannelOpenNotifications:self
        selector:@selector(channelOpened:channel:) withPSM:0x11 direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
    self.interruptNotification = [IOBluetoothL2CAPChannel registerForChannelOpenNotifications:self
        selector:@selector(channelOpened:channel:) withPSM:0x13 direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
    if (!self.controlNotification || !self.interruptNotification) {
        puts("target channel notification registration failed"); self.failed = YES; self.done = YES; return;
    }
    IOBluetoothIgnoreHIDDevice((__bridge IOBluetoothDeviceRef)self.device);
    self.ignored = YES;
    puts("target ignore hint submitted; effectiveness is NOT yet verified"); fflush(stdout);
    if (self.listenOnly) return;
    IOBluetoothL2CAPChannel *channel = nil;
    IOReturn result = [self.device openL2CAPChannelAsync:&channel withPSM:0x11 delegate:self];
    self.control = channel;
    printf("control open request=0x%08x\n", result); fflush(stdout);
    if (result != kIOReturnSuccess) { self.failed = YES; self.done = YES; }
}
- (void)attachExisting {
    if (self.interrupt || !self.device.isConnected) return;
    IOBluetoothL2CAPChannel *channel = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    IOReturn result = self.modernInterrupt
        ? [self.device openL2CAPChannelAsync:&channel withPSM:0x13 delegate:self]
        : [self.device openL2CAPChannel:0x13 findExisting:YES newChannel:&channel];
#pragma clang diagnostic pop
    printf("target %s interrupt request=0x%08x channel=%s (not yet ready)\n", self.modernInterrupt ? "async" : "find-existing", result, channel ? "present" : "none"); fflush(stdout);
    if (result != kIOReturnSuccess || !channel) { self.failed = YES; self.done = YES; return; }
    if (![channel.device.addressString isEqualToString:self.device.addressString] || channel.PSM != 0x13 || (channel.delegate != nil && channel.delegate != self)) {
        puts("REFUSED: existing channel identity/PSM/delegate check failed"); self.failed = YES; self.done = YES; return;
    }
    self.interrupt = channel;
    self.openingDeadline = NSProcessInfo.processInfo.systemUptime + 10;
    result = [channel setDelegate:self];
    printf("target interrupt delegate registration=0x%08x (not channel readiness)\n",result); fflush(stdout);
    if (result != kIOReturnSuccess) { self.failed = YES; self.done = YES; }
}
- (void)channelOpened:(IOBluetoothUserNotification *)notification channel:(IOBluetoothL2CAPChannel *)channel {
    // These notifications contain channel metadata only. Never subscribe to a
    // different device's payload, and never replace an existing delegate.
    if (!self.ignored || ![channel.device.addressString isEqualToString:self.device.addressString]) return;
    if (channel.PSM != 0x11 && channel.PSM != 0x13) return;
    if (!self.existingOnly && systemHasTargetHID(self.device)) {
        puts("REFUSED: system still exposes target HID; ignore hint did not isolate the target");
        self.failed = YES; self.done = YES; return;
    }
    if (channel.delegate != nil && channel.delegate != self) {
        puts("REFUSED: target channel already has a delegate"); self.failed = YES; self.done = YES; return;
    }
    if ((channel.PSM == 0x11 && self.control && self.control != channel) ||
        (channel.PSM == 0x13 && self.interrupt && self.interrupt != channel)) return;
    if (channel.PSM == 0x11) self.control = channel; else self.interrupt = channel;
    IOReturn result = [channel setDelegate:self];
    printf("target incoming psm=0x%04x attach=0x%08x\n", channel.PSM, result); fflush(stdout);
    if (result != kIOReturnSuccess) { self.failed = YES; self.done = YES; }
}
- (void)l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)channel status:(IOReturn)error {
    // An async implementation may invoke completion before returning its
    // out-parameter. Validate the actual target before binding that channel.
    if (self.modernInterrupt && !self.interrupt && channel.PSM == 0x13 &&
        [channel.device.addressString isEqualToString:self.device.addressString]) self.interrupt = channel;
    if (channel != self.control && channel != self.interrupt) return;
    self.opened = error == kIOReturnSuccess;
    printf("target channel open psm=0x%04x status=0x%08x\n", channel.PSM, error); fflush(stdout);
    if (error != kIOReturnSuccess) { self.failed = YES; self.done = YES; return; }
    if (!self.existingOnly && systemHasTargetHID(self.device)) {
        puts("REFUSED: target HID remains exposed after channel open"); self.failed = YES; self.done = YES; return;
    }
    if (channel == self.control && !self.listenOnly && !self.interrupt) {
        IOBluetoothL2CAPChannel *next = nil;
        IOReturn result = [self.device openL2CAPChannelAsync:&next withPSM:0x13 delegate:self];
        self.interrupt = next;
        printf("interrupt open request=0x%08x\n", result); fflush(stdout);
        if (result != kIOReturnSuccess) { self.failed = YES; self.done = YES; }
    }
}
- (void)l2capChannelData:(IOBluetoothL2CAPChannel *)channel data:(void *)data length:(size_t)length {
    if (channel != self.interrupt || ![channel.device.addressString isEqualToString:self.device.addressString]) return;
    if (!self.existingOnly && systemHasTargetHID(self.device)) {
        puts("REFUSED: target HID isolation was lost"); self.failed = YES; self.done = YES; return;
    }
    self.opened = YES;
    printf("target data callback length=%zu\n", length); fflush(stdout);
    PacketKind kind = classifyPacket(data, length, channel.PSM, YES);
    if (kind == PacketRejected) return;
    if (kind == PacketKeyboard) self.keyboardReports++;
    if (kind == PacketAudio) self.audioReports++;
    // Report metadata only. Never print or save microphone samples.
    printf("target report length=%zu keyboard=%lu audio=%lu\n", length,
           (unsigned long)self.keyboardReports, (unsigned long)self.audioReports); fflush(stdout);
}
- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel *)channel {
    if (channel == self.control || channel == self.interrupt) self.done = YES;
}
- (void)stop {
    [self.controlNotification unregister]; [self.interruptNotification unregister];
    self.controlNotification = nil; self.interruptNotification = nil;
    [self.interrupt setDelegate:nil]; [self.control setDelegate:nil];
    // Never close a channel obtained through findExisting; it belongs to the system.
    if (!self.existingOnly) { [self.interrupt closeChannel]; [self.control closeChannel]; }
    self.interrupt = nil; self.control = nil;
    if (self.ignored) {
        IOBluetoothRemoveIgnoredHIDDevice((__bridge IOBluetoothDeviceRef)self.device);
        self.ignored = NO;
        puts("target ignore hint removed"); fflush(stdout);
    }
}
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return selfTest();
        BOOL modern = argc == 2 && strcmp(argv[1], "--interrupt") == 0;
        BOOL existing = modern || (argc == 2 && strcmp(argv[1], "--existing") == 0);
        BOOL run = argc == 2 && strcmp(argv[1], "--run") == 0;
        BOOL listen = argc == 2 && strcmp(argv[1], "--listen") == 0;
        BOOL inspect = argc == 2 && strcmp(argv[1], "--inspect") == 0;
        BOOL restore = argc == 2 && strcmp(argv[1], "--restore") == 0;
        if (!run && !listen && !existing && !inspect && !restore) { puts("Usage: target-probe --inspect | --run | --listen | --restore | --existing | --interrupt"); return 64; }
        NSArray *targets = [[IOBluetoothDevice pairedDevices] filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(IOBluetoothDevice *d, NSDictionary *bindings __unused) {
                return [d.name isEqualToString:@"IPRC1000"];
            }]];
        if (targets.count != 1) { printf("unique paired target required; count=%lu\n", (unsigned long)targets.count); return 2; }
        IOBluetoothDevice *device = targets.firstObject;
        // Cross-check cached PnP service, not just its editable product name.
        IOBluetoothSDPUUID *uuid = [IOBluetoothSDPUUID uuid16:0x1200];
        IOBluetoothSDPServiceRecord *pnp = [device getServiceRecordForUUID:uuid];
        NSNumber *vendor = [[pnp getAttributeDataElement:0x0201] getNumberValue];
        NSNumber *product = [[pnp getAttributeDataElement:0x0202] getNumberValue];
        printf("paired target connected=%d vendor=%u product=%u\n", device.isConnected, vendor.unsignedIntValue, product.unsignedIntValue);
        if (vendor.unsignedIntValue != 0x0a5c || product.unsignedIntValue != 0x8502) { puts("cached target identity not validated"); return 3; }
        if (inspect) return 0;
        if (restore) {
            IOBluetoothRemoveIgnoredHIDDevice((__bridge IOBluetoothDeviceRef)device);
            puts("target ignore hint recovery submitted"); return 0;
        }
        signal(SIGINT, stopSignal); signal(SIGTERM, stopSignal);
        TargetProbe *probe = [TargetProbe new]; probe.device = device; probe.listenOnly = listen; probe.existingOnly = existing; probe.modernInterrupt = modern;
        @try {
            [probe start];
            NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + ((listen || existing) ? 180 : 25);
            NSTimeInterval nextIsolationCheck = 0;
            while (!probe.done && !interrupted && NSProcessInfo.processInfo.systemUptime < deadline) {
                [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
                if (now >= nextIsolationCheck) {
                    nextIsolationCheck = now + 0.25;
                    if (existing) { [probe attachExisting]; }
                    if (probe.modernInterrupt && probe.interrupt && !probe.opened && now >= probe.openingDeadline) {
                        puts("FAILED: request accepted but no channel-open completion or data within 10 seconds");
                        probe.failed = YES; probe.done = YES;
                    }
                    if (!existing && device.isConnected && systemHasTargetHID(device)) {
                        puts("REFUSED: target connected with system HID active; ignore hint ineffective");
                        probe.failed = YES; probe.done = YES;
                    }
                }
            }
        } @finally { [probe stop]; }
        printf("probe ended keyboard=%lu audio=%lu\n", (unsigned long)probe.keyboardReports, (unsigned long)probe.audioReports);
        return probe.failed ? 4 : (probe.audioReports ? 0 : 5);
    }
}
