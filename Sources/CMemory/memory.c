#include "CMemory.h"
#include <mach/mach.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <stdlib.h>
#include <unistd.h>

ml_system_memory ml_read_system(void) {
    ml_system_memory result = {0};
    size_t size = sizeof(result.total);
    if (sysctlbyname("hw.memsize", &result.total, &size, NULL, 0) != 0) return result;
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t status = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (status != KERN_SUCCESS) return result;
    uint64_t page = (uint64_t)getpagesize();
    // Exclude purgeable pages, which macOS can reclaim without swapping.
    uint64_t active = vm.active_count > vm.purgeable_count ? vm.active_count - vm.purgeable_count : 0;
    result.used = (active + vm.wire_count + vm.compressor_page_count) * page;
    if (result.used > result.total) result.used = result.total;
    result.compressed = (uint64_t)vm.compressor_page_count * page;
    struct xsw_usage swap = {0};
    size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0) result.swap = swap.xsu_used;
    size = sizeof(result.pressure);
    sysctlbyname("kern.memorystatus_vm_pressure_level", &result.pressure, &size, NULL, 0);
    result.valid = 1;
    return result;
}

ml_process *ml_read_processes(size_t *count) {
    *count = 0;
    int capacity = proc_listallpids(NULL, 0) + 128;
    if (capacity <= 128) return NULL;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    ml_process *result = calloc((size_t)capacity, sizeof(ml_process));
    if (!pids || !result) { free(pids); free(result); return NULL; }
    int length = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    if (length > capacity) length = capacity;
    for (int i = 0; i < length; i++) {
        struct proc_bsdinfo bsd = {0};
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) continue;
        if (bsd.pbi_uid != getuid()) continue;
        ml_process *entry = &result[(*count)++];
        entry->pid = pids[i];
        entry->parent = (int32_t)bsd.pbi_ppid;
        proc_pidpath(pids[i], entry->path, sizeof(entry->path));
        struct rusage_info_v4 usage = {0};
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0) {
            entry->footprint = usage.ri_phys_footprint;
            entry->readable = 1;
        }
    }
    free(pids);
    return result;
}
void ml_free_processes(ml_process *processes) { free(processes); }
void ml_throttle_io(void) { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE); }
