#include "MemoryScanner.hpp"
#include <iostream>
#include <sstream>
#include <algorithm>
#include <cstring>
#include <mach/mach.h>
#include <mach/vm_region.h>

// Safe memory reading helpers
template<typename T>
static bool readMemorySafe(uintptr_t address, T& outValue) {
    vm_size_t read_size = sizeof(T);
    vm_offset_t data;
    mach_msg_type_number_t data_size;
    kern_return_t kr = vm_read(mach_task_self(), address, read_size, &data, &data_size);
    if (kr == KERN_SUCCESS && data_size == read_size) {
        std::memcpy(&outValue, reinterpret_cast<void*>(data), read_size);
        vm_deallocate(mach_task_self(), data, data_size);
        return true;
    }
    return false;
}

// Safe memory writing helpers
template<typename T>
static bool writeMemorySafe(uintptr_t address, T value) {
    kern_return_t kr = vm_write(mach_task_self(), address, reinterpret_cast<vm_offset_t>(&value), sizeof(T));
    if (kr == KERN_SUCCESS) {
        return true;
    }
    // If it failed (e.g. read-only page), temporarily change protection and try again
    vm_prot_t prot = VM_PROT_READ | VM_PROT_WRITE;
    uintptr_t page_addr = address & ~static_cast<uintptr_t>(PAGE_MASK);
    uintptr_t page_size = PAGE_SIZE;
    vm_protect(mach_task_self(), page_addr, page_size, false, prot);
    
    kr = vm_write(mach_task_self(), address, reinterpret_cast<vm_offset_t>(&value), sizeof(T));
    return (kr == KERN_SUCCESS);
}

std::vector<MemoryRegion> MemoryScanner::getWritableRegions() {
    std::vector<MemoryRegion> regions;
    vm_address_t address = 0;
    vm_size_t size = 0;
    uint32_t depth = 0;
    
    while (true) {
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(mach_task_self(), &address, &size, &depth, reinterpret_cast<vm_region_recurse_info_t>(&info), &count);
        if (kr != KERN_SUCCESS) {
            break;
        }
        
        if (info.is_submap) {
            depth++;
            continue;
        }
        
        // Match readable and writable regions (exclude execute regions to avoid code segment scanning)
        if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE) && !(info.protection & VM_PROT_EXECUTE)) {
            MemoryRegion region;
            region.start = address;
            region.end = address + size;
            region.size = size;
            region.protection = info.protection;
            regions.push_back(region);
        }
        
        address += size;
    }
    return regions;
}

template<typename T>
static void scanRegionBuffer(const uint8_t* buffer, size_t bufferSize, uintptr_t startAddr, T targetValue, ValueType type, std::vector<ScanResult>& outResults) {
    if (bufferSize < sizeof(T)) return;
    
    // Scan with 1-byte alignment to catch unaligned game values (extremely thorough)
    for (size_t offset = 0; offset <= bufferSize - sizeof(T); offset++) {
        T val;
        std::memcpy(&val, buffer + offset, sizeof(T));
        if (val == targetValue) {
            ScanResult res;
            res.address = startAddr + offset;
            res.type = type;
            outResults.push_back(res);
            
            // Limit results to prevent memory exhaustion (cap at 100,000 matches)
            if (outResults.size() >= 100000) {
                break;
            }
        }
    }
}

bool MemoryScanner::firstScan(ValueType type, const std::string& valueStr) {
    results.clear();
    currentType = type;
    isFirstScan = false;
    
    std::vector<MemoryRegion> regions = getWritableRegions();
    
    // Parse value based on type
    std::stringstream ss(valueStr);
    
    if (type == Type_i32) {
        int32_t val;
        if (!(ss >> val)) return false;
        
        for (std::vector<MemoryRegion>::const_iterator it = regions.begin(); it != regions.end(); ++it) {
            const MemoryRegion& region = *it;
            vm_offset_t data;
            mach_msg_type_number_t data_size;
            kern_return_t kr = vm_read(mach_task_self(), region.start, region.size, &data, &data_size);
            if (kr == KERN_SUCCESS) {
                scanRegionBuffer<int32_t>(reinterpret_cast<const uint8_t*>(data), data_size, region.start, val, type, results);
                vm_deallocate(mach_task_self(), data, data_size);
            }
            if (results.size() >= 100000) break;
        }
    } else if (type == Type_i64) {
        int64_t val;
        if (!(ss >> val)) return false;
        
        for (std::vector<MemoryRegion>::const_iterator it = regions.begin(); it != regions.end(); ++it) {
            const MemoryRegion& region = *it;
            vm_offset_t data;
            mach_msg_type_number_t data_size;
            kern_return_t kr = vm_read(mach_task_self(), region.start, region.size, &data, &data_size);
            if (kr == KERN_SUCCESS) {
                scanRegionBuffer<int64_t>(reinterpret_cast<const uint8_t*>(data), data_size, region.start, val, type, results);
                vm_deallocate(mach_task_self(), data, data_size);
            }
            if (results.size() >= 100000) break;
        }
    } else if (type == Type_Float) {
        float val;
        if (!(ss >> val)) return false;
        
        for (std::vector<MemoryRegion>::const_iterator it = regions.begin(); it != regions.end(); ++it) {
            const MemoryRegion& region = *it;
            vm_offset_t data;
            mach_msg_type_number_t data_size;
            kern_return_t kr = vm_read(mach_task_self(), region.start, region.size, &data, &data_size);
            if (kr == KERN_SUCCESS) {
                scanRegionBuffer<float>(reinterpret_cast<const uint8_t*>(data), data_size, region.start, val, type, results);
                vm_deallocate(mach_task_self(), data, data_size);
            }
            if (results.size() >= 100000) break;
        }
    } else if (type == Type_Double) {
        double val;
        if (!(ss >> val)) return false;
        
        for (std::vector<MemoryRegion>::const_iterator it = regions.begin(); it != regions.end(); ++it) {
            const MemoryRegion& region = *it;
            vm_offset_t data;
            mach_msg_type_number_t data_size;
            kern_return_t kr = vm_read(mach_task_self(), region.start, region.size, &data, &data_size);
            if (kr == KERN_SUCCESS) {
                scanRegionBuffer<double>(reinterpret_cast<const uint8_t*>(data), data_size, region.start, val, type, results);
                vm_deallocate(mach_task_self(), data, data_size);
            }
            if (results.size() >= 100000) break;
        }
    }
    
    return true;
}

bool MemoryScanner::nextScan(const std::string& valueStr) {
    if (results.empty()) return false;
    
    std::vector<ScanResult> newResults;
    std::stringstream ss(valueStr);
    
    if (currentType == Type_i32) {
        int32_t targetVal;
        if (!(ss >> targetVal)) return false;
        
        for (std::vector<ScanResult>::const_iterator it = results.begin(); it != results.end(); ++it) {
            const ScanResult& res = *it;
            int32_t currentVal;
            if (readMemorySafe<int32_t>(res.address, currentVal)) {
                if (currentVal == targetVal) {
                    newResults.push_back(res);
                }
            }
        }
    } else if (currentType == Type_i64) {
        int64_t targetVal;
        if (!(ss >> targetVal)) return false;
        
        for (std::vector<ScanResult>::const_iterator it = results.begin(); it != results.end(); ++it) {
            const ScanResult& res = *it;
            int64_t currentVal;
            if (readMemorySafe<int64_t>(res.address, currentVal)) {
                if (currentVal == targetVal) {
                    newResults.push_back(res);
                }
            }
        }
    } else if (currentType == Type_Float) {
        float targetVal;
        if (!(ss >> targetVal)) return false;
        
        for (std::vector<ScanResult>::const_iterator it = results.begin(); it != results.end(); ++it) {
            const ScanResult& res = *it;
            float currentVal;
            if (readMemorySafe<float>(res.address, currentVal)) {
                if (currentVal == targetVal) {
                    newResults.push_back(res);
                }
            }
        }
    } else if (currentType == Type_Double) {
        double targetVal;
        if (!(ss >> targetVal)) return false;
        
        for (std::vector<ScanResult>::const_iterator it = results.begin(); it != results.end(); ++it) {
            const ScanResult& res = *it;
            double currentVal;
            if (readMemorySafe<double>(res.address, currentVal)) {
                if (currentVal == targetVal) {
                    newResults.push_back(res);
                }
            }
        }
    }
    
    results = std::move(newResults);
    return true;
}

bool MemoryScanner::modifyValue(uintptr_t address, ValueType type, const std::string& valueStr) {
    std::stringstream ss(valueStr);
    
    if (type == Type_i32) {
        int32_t val;
        if (ss >> val) {
            return writeMemorySafe<int32_t>(address, val);
        }
    } else if (type == Type_i64) {
        int64_t val;
        if (ss >> val) {
            return writeMemorySafe<int64_t>(address, val);
        }
    } else if (type == Type_Float) {
        float val;
        if (ss >> val) {
            return writeMemorySafe<float>(address, val);
        }
    } else if (type == Type_Double) {
        double val;
        if (ss >> val) {
            return writeMemorySafe<double>(address, val);
        }
    }
    return false;
}

void MemoryScanner::lockValue(uintptr_t address, ValueType type, const std::string& valueStr) {
    for (std::vector<LockedValue>::iterator it = lockedValues.begin(); it != lockedValues.end(); ++it) {
        LockedValue& lv = *it;
        if (lv.address == address) {
            lv.value = valueStr;
            return;
        }
    }
    LockedValue lv;
    lv.address = address;
    lv.type = type;
    lv.value = valueStr;
    lockedValues.push_back(lv);
}

void MemoryScanner::unlockValue(uintptr_t address) {
    for (std::vector<LockedValue>::iterator it = lockedValues.begin(); it != lockedValues.end(); ) {
        if (it->address == address) {
            it = lockedValues.erase(it);
        } else {
            ++it;
        }
    }
}

void MemoryScanner::updateLockedValues() {
    for (std::vector<LockedValue>::const_iterator it = lockedValues.begin(); it != lockedValues.end(); ++it) {
        const LockedValue& lv = *it;
        modifyValue(lv.address, lv.type, lv.value);
    }
}

void MemoryScanner::clear() {
    results.clear();
    lockedValues.clear();
    isFirstScan = true;
}

// ---------------------------------------------------------------
// Point-scan / pin implementation
// ---------------------------------------------------------------

void MemoryScanner::pinAddress(mach_vm_address_t address, ValueType type) {
    if (address == 0) return;
    // Idempotent: don't double-pin the same address.
    for (std::vector<PinnedAddress>::const_iterator it = pinnedAddresses.begin(); it != pinnedAddresses.end(); ++it) {
        if (it->address == address) return;
    }

    // Read the current value at the address and cache it.  We use
    // the same safe-read helpers used by firstScan, so we can read
    // both i32/i64 and float/double.
    int size = (type == Type_i32) ? 4 :
               (type == Type_i64) ? 8 :
               (type == Type_Float) ? 4 : 8;

    PinnedAddress p;
    p.address = address;
    p.type = type;
    p.value = "?";

    std::stringstream ss_val;
    if (type == Type_i32) {
        int32_t v;
        if (readMemorySafe<int32_t>(address, v)) {
            ss_val << v;
            p.value = ss_val.str();
        }
    } else if (type == Type_i64) {
        int64_t v;
        if (readMemorySafe<int64_t>(address, v)) {
            ss_val << v;
            p.value = ss_val.str();
        }
    } else if (type == Type_Float) {
        float v;
        if (readMemorySafe<float>(address, v)) {
            ss_val << v;
            p.value = ss_val.str();
        }
    } else if (type == Type_Double) {
        double v;
        if (readMemorySafe<double>(address, v)) {
            ss_val << v;
            p.value = ss_val.str();
        }
    }
    (void)size;  // for future use if we add more types

    pinnedAddresses.push_back(p);
}

void MemoryScanner::unpinAddress(mach_vm_address_t address) {
    for (std::vector<PinnedAddress>::iterator it = pinnedAddresses.begin(); it != pinnedAddresses.end(); ) {
        if (it->address == address) {
            it = pinnedAddresses.erase(it);
        } else {
            ++it;
        }
    }
}

bool MemoryScanner::isPinned(mach_vm_address_t address) const {
    for (std::vector<PinnedAddress>::const_iterator it = pinnedAddresses.begin(); it != pinnedAddresses.end(); ++it) {
        if (it->address == address) return true;
    }
    return false;
}

void MemoryScanner::refreshPinned() {
    for (std::vector<PinnedAddress>::iterator it = pinnedAddresses.begin(); it != pinnedAddresses.end(); ++it) {
        PinnedAddress& p = *it;
        std::stringstream ss_val;
        if (p.type == Type_i32) {
            int32_t v;
            if (readMemorySafe<int32_t>(p.address, v)) {
                ss_val << v;
                p.value = ss_val.str();
            }
        } else if (p.type == Type_i64) {
            int64_t v;
            if (readMemorySafe<int64_t>(p.address, v)) {
                ss_val << v;
                p.value = ss_val.str();
            }
        } else if (p.type == Type_Float) {
            float v;
            if (readMemorySafe<float>(p.address, v)) {
                ss_val << v;
                p.value = ss_val.str();
            }
        } else if (p.type == Type_Double) {
            double v;
            if (readMemorySafe<double>(p.address, v)) {
                ss_val << v;
                p.value = ss_val.str();
            }
        }
    }
}

std::vector<PinnedAddress> MemoryScanner::copyPinnedAddresses() const {
    return pinnedAddresses;  // std::vector copy-ctor already does the right thing
}