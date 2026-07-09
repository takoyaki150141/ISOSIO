#ifndef SPEED_HACK_HPP
#define SPEED_HACK_HPP

#include <cstdint>
#include <sys/time.h>
#include <time.h>

class SpeedHack {
public:
    static SpeedHack& getInstance() {
        static SpeedHack instance;
        return instance;
    }

    void setSpeed(double speed);
    double getSpeed() const { return speedMultiplier; }
    void start();

    // Hook targets (must be public or friendly so global functions can access them)
    uint64_t getHookedMachAbsoluteTime();
    int getHookedTimeOfDay(struct timeval *tv, struct timezone *tz);
    int getHookedClockGetTime(clockid_t clock_id, struct timespec *tp);

    // Original function pointers
    uint64_t (*orig_mach_absolute_time)(void) = nullptr;
    int (*orig_gettimeofday)(struct timeval *, struct timezone *) = nullptr;
    int (*orig_clock_gettime)(clockid_t, struct timespec *) = nullptr;

private:
    SpeedHack() = default;
    ~SpeedHack() = default;
    SpeedHack(const SpeedHack&) = delete;
    SpeedHack& operator=(const SpeedHack&) = delete;

    double speedMultiplier = 1.0;
    
    // Baselines for mach_absolute_time
    uint64_t lastActualMachTime = 0;
    uint64_t lastSimulatedMachTime = 0;

    // Baselines for gettimeofday
    struct timeval lastActualTimeval = {0, 0};
    struct timeval lastSimulatedTimeval = {0, 0};

    // Baselines for clock_gettime (we support CLOCK_REALTIME, CLOCK_MONOTONIC, CLOCK_UPTIME_RAW etc.)
    struct timespec lastActualTimespec = {0, 0};
    struct timespec lastSimulatedTimespec = {0, 0};
    
    bool initialized = false;
};

#endif // SPEED_HACK_HPP
