#ifndef MEMORYLINE_C_MEMORY_H
#define MEMORYLINE_C_MEMORY_H
#include <stdint.h>
#include <stddef.h>
typedef struct {
    uint64_t total, used, compressed, swap;
    int pressure; // kernel values: normal=1, warning=2, critical=4; unavailable=0
    int valid;
} ml_system_memory;
typedef struct {
    int32_t pid, parent;
    uint64_t footprint;
    int readable;
    char path[4096];
} ml_process;
ml_system_memory ml_read_system(void);
// Caller owns the array and must free it with ml_free_processes.
ml_process *ml_read_processes(size_t *count);
void ml_free_processes(ml_process *processes);
// Drops the calling thread to the lowest disk I/O priority so
// on-demand scans don't steal bandwidth from foreground work.
void ml_throttle_io(void);
#endif
