#include "RemoteSupport.h"
#include <Security/Security.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

static const char *tool = "/Applications/PacketLogger.app/Contents/Resources/packetlogger";

int iprc_hci_tool_status(void) {
    if (access(tool, F_OK) != 0) return -1001;
    if (access(tool, X_OK) != 0) return -1004;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL,
        (const UInt8 *)tool, strlen(tool), false);
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    OSStatus result = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
    if (result == errSecSuccess)
        result = SecRequirementCreateWithString(CFSTR("anchor apple"), kSecCSDefaultFlags, &requirement);
    if (result == errSecSuccess)
        result = SecStaticCodeCheckValidity(code, kSecCSCheckAllArchitectures, requirement);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    CFRelease(url);
    return result == errSecSuccess ? 0 : -1003;
}

int iprc_hci_open(const char *executable, const char *address, int *descriptor) {
    *descriptor = -1;
    AuthorizationRef authorization = NULL;
    OSStatus result = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
        kAuthorizationFlagDefaults, &authorization);
    if (result != errAuthorizationSuccess) return result;
    char *arguments[] = { "--hci-capture-helper", (char *)address, NULL };
    FILE *communication = NULL;
    // A temporary child, with no installed helper, daemon, or stored authorization.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    result = AuthorizationExecuteWithPrivileges(authorization, executable,
        kAuthorizationFlagDefaults, arguments, &communication);
#pragma clang diagnostic pop
    AuthorizationFree(authorization, kAuthorizationFlagDefaults);
    if (result == errAuthorizationSuccess) {
        if (!communication) return -1002;
        *descriptor = dup(fileno(communication));
        fclose(communication);
        if (*descriptor < 0) return -1002;
        fcntl(*descriptor, F_SETFD, FD_CLOEXEC);
    }
    return result;
}
