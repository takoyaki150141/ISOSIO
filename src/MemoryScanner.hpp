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

// Point-scan / pin: a snapshot-friendly view of a single
// address. Cached value is refreshed in-place by refreshPinned().
// Field name 'value' matches DLGMemor's search_result.value so
// the two repos stay byte-for-byte compatible on the wire.
struct PinnedAddress {
    mach_vm_address_t address;
    ValueType type;
    std::string value;  // textual representation
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

    // Point-scan / pin API
    // pinAddress reads the current value at the given address and
    // stores it in pinnedAddresses. Idempotent: pinning an already
    // pinned address is a no-op.
    void pinAddress(mach_vm_address_t address, ValueType type);
    // unpinAddress removes the address from the pin list. Safe to
    // call for non-pinned addresses.
    void unpinAddress(mach_vm_address_t address);
    // isPinned is a quick O(n) lookup; n is normally < 100.
    bool isPinned(mach_vm_address_t address) const;
    // refreshPinned re-reads every pinned address from memory in-
    // place. Cheap (n × sizeof(type)) and safe to call frequently.
    void refreshPinned();
    // copyPinnedAddresses returns a deep copy of the pin list.  The
    // caller owns the returned std::vector; it can be safely
    // iterated from a UI thread while refreshPinned() runs on
    // another.
    std::vector<PinnedAddress> copyPinnedAddresses() const;

    std::vector<ScanResult>& getResults() { return results; }

private:
    MemoryScanner() : currentType(Type_i32), isFirstScan(true) {}
    ~MemoryScanner() {}
    MemoryScanner(const MemoryScanner&);
    MemoryScanner& operator=(const MemoryScanner&);

    std::vector<ScanResult> results;
    std::vector<LockedValue> lockedValues;
    std::vector<PinnedAddress> pinnedAddresses;
    ValueType currentType;
    bool isFirstScan;

public:
    bool getIsFirstScan() const { return isFirstScan; }
    void setIsFirstScan(bool b) { isFirstScan = b; }
};