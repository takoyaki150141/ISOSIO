#pragma once
#include <cstdint>
#include <sys/time.h>
#include <time.h>

#include "fishhook.h"
class SpeedHack {
public:
    static SpeedHack& getInstance() {
        static SpeedHack instance;
        return instance;
    }

    void start();
    void setSpeed(double speed) { speedMultiplier = speed; }
    double getSpeed() const { return speedMultiplier; }

    // Hooked functions
    uint64_t getHookedMachAbsoluteTime();
    int getHookedTimeOfDay(struct timeval *tv, struct timezone *tz);
    int getHookedClockGetTime(clockid_t clock_id, struct timespec *tp);

private:
    SpeedHack() : speedMultiplier(1.0), initialized(false),
                  lastActualMachTime(0), lastSimulatedMachTime(0) {
        lastActualTimeval.tv_sec = 0;
        lastActualTimeval.tv_usec = 0;
        lastSimulatedTimeval.tv_sec = 0;
        lastSimulatedTimeval.tv_usec = 0;
        lastActualTimespec.tv_sec = 0;
        lastActualTimespec.tv_nsec = 0;
        lastSimulatedTimespec.tv_sec = 0;
        lastSimulatedTimespec.tv_nsec = 0;
    }
    ~SpeedHack() {}
    SpeedHack(const SpeedHack&);
    SpeedHack& operator=(const SpeedHack&);

    uint64_t (*orig_mach_absolute_time)(void);
    int (*orig_gettimeofday)(struct timeval *, struct timezone *);
    int (*orig_clock_gettime)(clockid_t, struct timespec *);

    double speedMultiplier;
    bool initialized;
    uint64_t lastActualMachTime;
    uint64_t lastSimulatedMachTime;
    struct timeval lastActualTimeval;
    struct timeval lastSimulatedTimeval;
    struct timespec lastActualTimespec;
    struct timespec lastSimulatedTimespec;
};