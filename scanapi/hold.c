// Registers with the engine, holds the scanner for N seconds, then unregisters. Prints USB registry IDs
// around each step to show when the engine makes the scanner re-enumerate.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include "scanapi.h"

static uint64_t scanner_id(void) {
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostDevice");
    int vid = 0x07b3, pid = 0x131c;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid), p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v); CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m);
    uint64_t id = 0;
    if (s) { IORegistryEntryGetRegistryEntryID(s, &id); IOObjectRelease(s); }
    return id;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int secs = argc > 1 ? atoi(argv[1]) : 5;
    void *lib = dlopen("/Applications/Plustek/ePhoto Z300/ScanApi.framework/ScanApi", RTLD_NOW | RTLD_LOCAL);
    SCANAPI_FUNCTION_TABLE *t = ((SCANAPI_FUNCTION_TABLE *(*)(void))dlsym(lib, "SCANAPI_GetFunctionTable"))();
    printf("before Register:  %llx\n", scanner_id());
    SCANAPI_VERSION_INFO v = {0};
    printf("Register -> %d\n", t->Register(&v));
    for (int i = 0; i < secs; i++) { sleep(1); printf("  +%ds: %llx\n", i + 1, scanner_id()); }
    printf("Unregister -> %d\n", t->Unregister());
    for (int i = 0; i < 3; i++) { sleep(1); printf("  +%ds after: %llx\n", i + 1, scanner_id()); }
    return 0;
}
