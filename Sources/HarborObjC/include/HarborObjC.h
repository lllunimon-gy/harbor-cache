#include <stdint.h>
/// Nonblocking exclusive advisory lock; -1 means unavailable. Caller owns the descriptor.
int32_t HBLockDirectory(const char *lockPath);
void HBUnlockDirectory(int32_t descriptor);
