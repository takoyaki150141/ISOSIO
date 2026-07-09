#pragma once
#include <vector>
#include <string>
#include <cstdint>
#include <mach/mach.h>

enum ValueType {
    Type_i32,
    Type_i64,
    Type_Float,
    Type_Double
};

struct MemoryRegion {
    vm_address_t start;
    vm_address_t end;
    vm_size_t size;
    vm_prot_t protection;
};

struct ScanResult {
    uintptr_t address;
    ValueType type;
};

struct LockedValue {
    uintptr_t address;
    ValueType type;
    std::string value;
};

class MemoryScanner {
public:
    static MemoryScanner& getInstance() {
        static MemoryScanner instance;
        return instance;
    }

    std::vector<MemoryRegion> getWritableRegions();
    bool firstScan(ValueType type, const std::string& valueStr);
    bool nextScan(const std::string& valueStr);
    bool modifyValue(uintptr_t address, ValueType type, const std::string& valueStr);
    void lockValue(uintptr_t address, ValueType type, const std::string& valueStr);
    void unlockValue(uintptr_t address);
    void updateLockedValues();
    void clear();

    std::vector<ScanResult>& getResults() { return results; }

private:
    MemoryScanner() : currentType(Type_i32) {}
    ~MemoryScanner() {}
    MemoryScanner(const MemoryScanner&);
    MemoryScanner& operator=(const MemoryScanner&);

    std::vector<ScanResult> results;
    std::vector<LockedValue> lockedValues;
    ValueType currentType;
};