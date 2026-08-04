#ifndef FM_MOUNT_BACKEND_PROTOCOL_H
#define FM_MOUNT_BACKEND_PROTOCOL_H

// Process exit protocol shared by the isolated backend and its fixed-command
// executor. Encoded POSIX errno values occupy 81...143.
enum {
    FMMountBackendProcessExitUsage = 64,
    FMMountBackendProcessExitUnavailable = 69,
    FMMountBackendProcessExitCredentialBorrow = 70,
    FMMountBackendProcessExitCredentialRestore = 71,
    FMMountBackendProcessExitNotMounted = 72,
    FMMountBackendProcessExitPermission = 77,
    FMMountBackendProcessExitUnsafeState = 78,
    FMMountBackendProcessExitUnknownSyscall = 79,
    FMMountBackendProcessExitErrnoBase = 80,
    FMMountBackendProcessMaximumEncodedErrno = 63,
};

#endif
