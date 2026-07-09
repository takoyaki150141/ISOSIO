#include "SpeedHack.hpp"
#include <mach/mach_time.h>
#include <dlfcn.h>

// Static hook functions
static uint64_t hooked_mach_absolute_time() {
    return SpeedHack::getInstance().getHookedMachAbsoluteTime();
}

static int hooked_gettimeofday(struct timeval *tv, struct timezone *tz) {
    return SpeedHack::getInstance().getHookedTimeOfDay(tv, tz);
}

static int hooked_clock_gettime(clockid_t clock_id, struct timespec *tp) {
    return SpeedHack::getInstance().getHookedClockGetTime(clock_id, tp);
}

void SpeedHack::start() {
    if (initialized) return;

    orig_mach_absolute_time = (uint64_t (*)(void))dlsym(RTLD_DEFAULT, "mach_absolute_time");
    orig_gettimeofday = (int (*)(struct timeval *, struct timezone *))dlsym(RTLD_DEFAULT, "gettimeofday");
    orig_clock_gettime = (int (*)(clockid_t, struct timespec *))dlsym(RTLD_DEFAULT, "clock_gettime");

    initialized = true;
}

uint64_t SpeedHack::getHookedMachAbsoluteTime() {
    uint64_t actual = orig_mach_absolute_time ? orig_mach_absolute_time() : mach_absolute_time();
    
    if (lastActualMachTime == 0) {
        lastActualMachTime = actual;
        lastSimulatedMachTime = actual;
        return actual;
    }
    
    uint64_t elapsed = actual - lastActualMachTime;
    uint64_t simulatedElapsed = (uint64_t)(elapsed * speedMultiplier);
    lastSimulatedMachTime += simulatedElapsed;
    lastActualMachTime = actual;
    
    return lastSimulatedMachTime;
}

int SpeedHack::getHookedTimeOfDay(struct timeval *tv, struct timezone *tz) {
    if (!tv) return orig_gettimeofday ? orig_gettimeofday(tv, tz) : gettimeofday(tv, tz);
    
    struct timeval actual;
    int result = orig_gettimeofday ? orig_gettimeofday(&actual, tz) : gettimeofday(&actual, tz);
    if (result != 0) return result;
    
    if (lastActualTimeval.tv_sec == 0 && lastActualTimeval.tv_usec == 0) {
        lastActualTimeval = actual;
        lastSimulatedTimeval = actual;
        *tv = actual;
        return 0;
    }
    
    double elapsed = (actual.tv_sec - lastActualTimeval.tv_sec) +
                     (actual.tv_usec - lastActualTimeval.tv_usec) / 1000000.0;
    double simulatedElapsed = elapsed * speedMultiplier;
    
    lastSimulatedTimeval.tv_sec += (time_t)simulatedElapsed;
    lastSimulatedTimeval.tv_usec += (suseconds_t)((simulatedElapsed - (long)simulatedElapsed) * 1000000.0);
    if (lastSimulatedTimeval.tv_usec >= 1000000) {
        lastSimulatedTimeval.tv_sec++;
        lastSimulatedTimeval.tv_usec -= 1000000;
    }
    
    lastActualTimeval = actual;
    *tv = lastSimulatedTimeval;
    
    return 0;
}

int SpeedHack::getHookedClockGetTime(clockid_t clock_id, struct timespec *tp) {
    if (!tp) return orig_clock_gettime ? orig_clock_gettime(clock_id, tp) : clock_gettime(clock_id, tp);
    
    struct timespec actual;
    int result = orig_clock_gettime ? orig_clock_gettime(clock_id, &actual) : clock_gettime(clock_id, &actual);
    if (result != 0) return result;
    
    if (lastActualTimespec.tv_sec == 0 && lastActualTimespec.tv_nsec == 0) {
        lastActualTimespec = actual;
        lastSimulatedTimespec = actual;
        *tp = actual;
        return 0;
    }
    
    double elapsed = (actual.tv_sec - lastActualTimespec.tv_sec) +
                     (actual.tv_nsec - lastActualTimespec.tv_nsec) / 1000000000.0;
    double simulatedElapsed = elapsed * speedMultiplier;
    
    long sec = (long)simulatedElapsed;
    long nsec = (long)((simulatedElapsed - sec) * 1000000000.0);
    
    lastSimulatedTimespec.tv_sec += sec;
    lastSimulatedTimespec.tv_nsec += nsec;
    if (lastSimulatedTimespec.tv_nsec >= 1000000000) {
        lastSimulatedTimespec.tv_sec++;
        lastSimulatedTimespec.tv_nsec -= 1000000000;
    }
    
    lastActualTimespec = actual;
    *tp = lastSimulatedTimespec;
    
    return 0;
}