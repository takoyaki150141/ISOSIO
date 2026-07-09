#include "MemoryScanner.hpp"
#include <iostream>
#include <sstream>
#include <algorithm>
#include <cstring>
#include <mach/mach_vm.h>

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
        kern_return_t kr = vm_region_recurse_64(mach_task_self(), &address, &size, &depth, reinterpret_cast<vm_info_t>(&info), &count);
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
    
    std::vector<MemoryRegion> regions = getWritableRegions();
    
    // Parse value based on type
    std::stringstream ss(valueStr);
    
    if (type == ValueType::Type_i32) {
        int32_t val;
        if (!(ss >> val)) return false;
        
        for (const auto& region : regions) {
            vm_offset_t data;
            mach_msg_type_number_t data_size;
            kern_return_t kr = vm_read(mach_task_self(), region.start, region.size, &data, &data_size);
            if (kr == KERN_SUCCESS) {
                scanRegionBuffer<int32_t>(reinterpret_cast<const uint8_t*>(data), data_size, region.start, val, type, results);
                vm_deallocate(mach_task_self(), data, data_size);
            }
            if (results.size() >= 100000) break;
        }
    } else if (type == ValueType::Type_i64) {
        int64_t val;
        if (!(ss >> val)) return false;
        
        for (const auto& region : regions) {
            vm_offset_t data;
            mach_msg_type_number_t data_size;
            kern_return_t kr = vm_read(mach_task_self(), region.start, region.size, &data, &data_size);
            if (kr == KERN_SUCCESS) {
                scanRegionBuffer<int64_t>(reinterpret_cast<const uint8_t*>(data), data_size, region.start, val, type, results);
                vm_deallocate(mach_task_self(), data, data_size);
            }
            if (results.size() >= 100000) break;
        }
    } else if (type == ValueType::Type_Float) {
        float val;
        if (!(ss >> val)) return false;
        
        for (const auto& region : regions) {
            vm_offset_t data;
            mach_msg_type_number_t data_size;
            kern_return_t kr = vm_read(mach_task_self(), region.start, region.size, &data, &data_size);
            if (kr == KERN_SUCCESS) {
                scanRegionBuffer<float>(reinterpret_cast<const uint8_t*>(data), data_size, region.start, val, type, results);
                vm_deallocate(mach_task_self(), data, data_size);
            }
            if (results.size() >= 100000) break;
        }
    } else if (type == ValueType::Type_Double) {
        double val;
        if (!(ss >> val)) return false;
        
        for (const auto& region : regions) {
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
    
    if (currentType == ValueType::Type_i32) {
        int32_t targetVal;
        if (!(ss >> targetVal)) return false;
        
        for (const auto& res : results) {
            int32_t currentVal;
            if (readMemorySafe<int32_t>(res.address, currentVal)) {
                if (currentVal == targetVal) {
                    newResults.push_back(res);
                }
            }
        }
    } else if (currentType == ValueType::Type_i64) {
        int64_t targetVal;
        if (!(ss >> targetVal)) return false;
        
        for (const auto& res : results) {
            int64_t currentVal;
            if (readMemorySafe<int64_t>(res.address, currentVal)) {
                if (currentVal == targetVal) {
                    newResults.push_back(res);
                }
            }
        }
    } else if (currentType == ValueType::Type_Float) {
        float targetVal;
        if (!(ss >> targetVal)) return false;
        
        for (const auto& res : results) {
            float currentVal;
            if (readMemorySafe<float>(res.address, currentVal)) {
                if (currentVal == targetVal) {
                    newResults.push_back(res);
                }
            }
        }
    } else if (currentType == ValueType::Type_Double) {
        double targetVal;
        if (!(ss >> targetVal)) return false;
        
        for (const auto& res : results) {
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
    
    if (type == ValueType::Type_i32) {
        int32_t val;
        if (ss >> val) {
            return writeMemorySafe<int32_t>(address, val);
        }
    } else if (type == ValueType::Type_i64) {
        int64_t val;
        if (ss >> val) {
            return writeMemorySafe<int64_t>(address, val);
        }
    } else if (type == ValueType::Type_Float) {
        float val;
        if (ss >> val) {
            return writeMemorySafe<float>(address, val);
        }
    } else if (type == ValueType::Type_Double) {
        double val;
        if (ss >> val) {
            return writeMemorySafe<double>(address, val);
        }
    }
    return false;
}

void MemoryScanner::lockValue(uintptr_t address, ValueType type, const std::string& valueStr) {
    for (auto& lv : lockedValues) {
        if (lv.address == address) {
            lv.value = valueStr;
            return;
        }
    }
    lockedValues.push_back({address, type, valueStr});
}

void MemoryScanner::unlockValue(uintptr_t address) {
    lockedValues.erase(std::remove_if(lockedValues.begin(), lockedValues.end(),
        [address](const LockedValue& lv) { return lv.address == address; }),
        lockedValues.end());
}

void MemoryScanner::updateLockedValues() {
    for (const auto& lv : lockedValues) {
        modifyValue(lv.address, lv.type, lv.value);
    }
}

void MemoryScanner::clear() {
    results.clear();
    lockedValues.clear();
}
