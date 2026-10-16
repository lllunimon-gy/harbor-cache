#import "HarborObjC.h"
#import <Foundation/Foundation.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
int32_t HBLockDirectory(const char *lockPath) {
    int fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return -1; }
    return fd;
}
void HBUnlockDirectory(int32_t descriptor) {
    if (descriptor >= 0) { flock(descriptor, LOCK_UN); close(descriptor); }
}
