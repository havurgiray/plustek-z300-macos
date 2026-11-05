// Loads Plustek's ScanApi.framework, registers, and prints what the engine reports about the scanner.
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include "scanapi.h"

#define SCANAPI_PATH "/Applications/Plustek/ePhoto Z300/ScanApi.framework/ScanApi"

int main(void) {
    void *lib = dlopen(SCANAPI_PATH, RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    SCANAPI_FUNCTION_TABLE *(*getTable)(void) = (SCANAPI_FUNCTION_TABLE *(*)(void))dlsym(lib, "SCANAPI_GetFunctionTable");
    const char *ver = dlsym(lib, "ScanApiVersionString");
    if (!getTable) { fprintf(stderr, "no SCANAPI_GetFunctionTable\n"); return 1; }
    SCANAPI_FUNCTION_TABLE *t = getTable();
    printf("engine version: %s\n", ver ? ver : "?");
    printf("table: Register=%p StartScan=%p Read=%p EndScan=%p GetScannerInfo=%p\n",
           (void *)t->Register, (void *)t->StartScan, (void *)t->Read, (void *)t->EndScan, (void *)t->GetScannerInfo);

    SCANAPI_VERSION_INFO v = {0};
    SCANAPI_RET r = t->Register(&v);
    printf("Register -> %d (version out: %u.%u.%u.%u)\n", r, v.wMajor, v.wMinor, v.wRelease, v.wBuilt);
    if (r != 0) return 2;

    SCANAPI_SCANNER_INFO info; memset(&info, 0, sizeof info);
    r = t->GetScannerInfo(&info);
    printf("GetScannerInfo -> %d: %04x:%04x module=%.10s maker=%s product=%s serial=%s company=%s\n", r,
           info.wVid, info.wPid, info.szModule, info.szManufacturer, info.szProduct_Name, info.szSerialNumber, info.szCompany);
    printf("TestUnitReady -> %d\n", t->TestUnitReady());
    printf("Unregister -> %d\n", t->Unregister());
    return 0;
}
