/* Exercises the production launcher without privileges, an actual helper, or PacketLogger. */
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <assert.h>

static int dependency_checks, launches, auth_creates;
static int missing_communication;
static OSStatus auth_result;
static int missing_tool(const char *path, int mode) {
    (void)path; (void)mode;
    dependency_checks++;
    errno = ENOENT;
    return -1;
}
static OSStatus fake_create(const AuthorizationRights *rights,
    const AuthorizationEnvironment *environment, AuthorizationFlags flags,
    AuthorizationRef *authorization) {
    (void)rights; (void)environment; (void)flags;
    auth_creates++;
    *authorization = (AuthorizationRef)(uintptr_t)1;
    return auth_result;
}
static OSStatus fake_free(AuthorizationRef authorization, AuthorizationFlags flags) {
    (void)authorization; (void)flags;
    return errAuthorizationSuccess;
}
static OSStatus fake_execute(AuthorizationRef authorization, const char *path,
    AuthorizationFlags flags, char *const *arguments, FILE **communication) {
    (void)authorization; (void)flags;
    assert(strcmp(path, "/not-executed/IPRC1000Adapter") == 0);
    assert(strcmp(arguments[0], "--hci-capture-helper") == 0);
    assert(strcmp(arguments[1], "AABBCCDDEEFF") == 0 && arguments[2] == NULL);
    launches++;
    *communication = missing_communication ? NULL : tmpfile();
    assert(missing_communication || *communication);
    return errAuthorizationSuccess;
}

#define access missing_tool
#define AuthorizationCreate fake_create
#define AuthorizationFree fake_free
#define AuthorizationExecuteWithPrivileges fake_execute
#include "../../Sources/CRemoteSupport/HCICapture.c"

int main(void) {
    assert(iprc_hci_tool_status() == -1001);
    dependency_checks = 0;
    int fd = -1;
    assert(iprc_hci_open("/not-executed/IPRC1000Adapter", "AABBCCDDEEFF", &fd) == 0);
    assert(dependency_checks == 0 && auth_creates == 1 && launches == 1 && fd >= 0);
    assert(fcntl(fd, F_GETFD) & FD_CLOEXEC);
    close(fd);
    auth_result = errAuthorizationCanceled;
    assert(iprc_hci_open("/not-executed/IPRC1000Adapter", "AABBCCDDEEFF", &fd) == errAuthorizationCanceled);
    assert(fd == -1 && launches == 1);
    auth_result = errAuthorizationSuccess;
    missing_communication = 1;
    assert(iprc_hci_open("/not-executed/IPRC1000Adapter", "AABBCCDDEEFF", &fd) == -1002);
    assert(fd == -1 && dependency_checks == 0);
    puts("CAPTURE STARTUP SELF-TEST PASS: missing PacketLogger does not block keyboard helper; cancellation and communication failures remain explicit");
    return 0;
}
