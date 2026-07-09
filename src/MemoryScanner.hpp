#ifndef MEMORY_SCANNER_HPP
#define MEMORY_SCANNER_HPP

#include <vector>
#include <string>
#include <cstdint>
#include <mach/mach.h>

enum class ValueType {
    Type_i32,
    Type_i64,
    Type_Float,
    Type_Double
};

struct MemoryRegion {
    uintptr_t start;
    uintptr_t end;
    size_t size;
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

    // Scan operations
    bool firstScan(ValueType type, const std::string& valueStr);
    bool nextScan(const std::string& valueStr);
    bool modifyValue(uintptr_t address, ValueType type, const std::string& valueStr);
    
    // Value locking
    void lockValue(uintptr_t address, ValueType type, const std::string& valueStr);
    void unlockValue(uintptr_t address);
    void updateLockedValues(); // Call periodically to freeze values

    // Getters
    const std::vector<ScanResult>& getResults() const { return results; }
    const std::vector<LockedValue>& getLockedValues() const { return lockedValues; }
    void clear();

private:
    MemoryScanner() = default;
    ~MemoryScanner() = default;
    MemoryScanner(const MemoryScanner&) = delete;
    MemoryScanner& operator=(const MemoryScanner&) = delete;

    std::vector<MemoryRegion> getWritableRegions();
    
    std::vector<ScanResult> results;
    std::vector<LockedValue> lockedValues;
    ValueType currentType = ValueType::Type_i32;
};

#endif // MEMORY_SCANNER_HPP
