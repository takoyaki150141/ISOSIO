#include "SpeedHack.hpp"
#include "../fishhook/fishhook.h"
#include <iostream>

// Global C wrappers for fishhook to target
extern "C" {
    uint64_t my_mach_absolute_time(void) {
        return SpeedHack::getInstance().getHookedMachAbsoluteTime();
    }
    
    int my_gettimeofday(struct timeval *tv, struct timezone *tz) {
        return SpeedHack::getInstance().getHookedTimeOfDay(tv, tz);
    }
    
    int my_clock_gettime(clockid_t clock_id, struct timespec *tp) {
        return SpeedHack::getInstance().getHookedClockGetTime(clock_id, tp);
    }
}

void SpeedHack::setSpeed(double speed) {
    if (speed <= 0.0) {
        speed = 0.01; // Avoid negative/zero time progression
    }
    speedMultiplier = speed;
}

uint64_t SpeedHack::getHookedMachAbsoluteTime() {
    if (orig_mach_absolute_time == nullptr) {
        // Fallback in case fishhook rebind failed
        return 0;
    }
    
    uint64_t actual = orig_mach_absolute_time();
    if (!initialized) {
        lastActualMachTime = actual;
        lastSimulatedMachTime = actual;
        initialized = true;
        return actual;
    }
    
    uint64_t elapsed = actual - lastActualMachTime;
    uint64_t simulatedElapsed = static_cast<uint64_t>(elapsed * speedMultiplier);
    
    lastSimulatedMachTime += simulatedElapsed;
    lastActualMachTime = actual;
    
    return lastSimulatedMachTime;
}

int SpeedHack::getHookedTimeOfDay(struct timeval *tv, struct timezone *tz) {
    if (orig_gettimeofday == nullptr) {
        return -1;
    }
    
    if (tv == nullptr) {
        return orig_gettimeofday(tv, tz);
    }
    
    struct timeval actual;
    int ret = orig_gettimeofday(&actual, tz);
    if (ret != 0) return ret;
    
    if (lastActualTimeval.tv_sec == 0 && lastActualTimeval.tv_usec == 0) {
        lastActualTimeval = actual;
        lastSimulatedTimeval = actual;
        *tv = actual;
        return 0;
    }
    
    double elapsed = (actual.tv_sec - lastActualTimeval.tv_sec) + 
                     (actual.tv_usec - lastActualTimeval.tv_usec) / 1000000.0;
                     
    double simulatedElapsed = elapsed * speedMultiplier;
    
    double totalSimulatedSec = lastSimulatedTimeval.tv_sec + 
                               (lastSimulatedTimeval.tv_usec / 1000000.0) + 
                               simulatedElapsed;
                               
    lastSimulatedTimeval.tv_sec = static_cast<time_t>(totalSimulatedSec);
    lastSimulatedTimeval.tv_usec = static_cast<suseconds_t>((totalSimulatedSec - lastSimulatedTimeval.tv_sec) * 1000000.0);
    
    lastActualTimeval = actual;
    *tv = lastSimulatedTimeval;
    return 0;
}

int SpeedHack::getHookedClockGetTime(clockid_t clock_id, struct timespec *tp) {
    if (orig_clock_gettime == nullptr) {
        return -1;
    }
    
    if (tp == nullptr) {
        return orig_clock_gettime(clock_id, tp);
    }
    
    struct timespec actual;
    int ret = orig_clock_gettime(clock_id, &actual);
    if (ret != 0) return ret;
    
    if (lastActualTimespec.tv_sec == 0 && lastActualTimespec.tv_nsec == 0) {
        lastActualTimespec = actual;
        lastSimulatedTimespec = actual;
        *tp = actual;
        return 0;
    }
    
    double elapsed = (actual.tv_sec - lastActualTimespec.tv_sec) + 
                     (actual.tv_nsec - lastActualTimespec.tv_nsec) / 1000000000.0;
                     
    double simulatedElapsed = elapsed * speedMultiplier;
    
    double totalSimulatedSec = lastSimulatedTimespec.tv_sec + 
                               (lastSimulatedTimespec.tv_nsec / 1000000000.0) + 
                               simulatedElapsed;
                               
    lastSimulatedTimespec.tv_sec = static_cast<time_t>(totalSimulatedSec);
    lastSimulatedTimespec.tv_nsec = static_cast<long>((totalSimulatedSec - lastSimulatedTimespec.tv_sec) * 1000000000.0);
    
    lastActualTimespec = actual;
    *tp = lastSimulatedTimespec;
    return 0;
}

void SpeedHack::start() {
    struct rebinding rebs[3];
    
    rebs[0].name = "mach_absolute_time";
    rebs[0].replacement = reinterpret_cast<void*>(my_mach_absolute_time);
    rebs[0].replaced = reinterpret_cast<void**>(&orig_mach_absolute_time);
    
    rebs[1].name = "gettimeofday";
    rebs[1].replacement = reinterpret_cast<void*>(my_gettimeofday);
    rebs[1].replaced = reinterpret_cast<void**>(&orig_gettimeofday);
    
    rebs[2].name = "clock_gettime";
    rebs[2].replacement = reinterpret_cast<void*>(my_clock_gettime);
    rebs[2].replaced = reinterpret_cast<void**>(&orig_clock_gettime);
    
    rebind_symbols(rebs, 3);
}
