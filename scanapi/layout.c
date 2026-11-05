// Asks the engine for image layouts under different enum values (no scanning) to learn what they mean.
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include "scanapi.h"

#define SCANAPI_PATH "/Applications/Plustek/ePhoto Z300/ScanApi.framework/ScanApi"

static SCANAPI_FUNCTION_TABLE *t;

static void layout(uint32_t source, uint32_t mode, uint16_t bits, uint32_t dpi, uint32_t unit, double w, double h) {
    SCANAPI_SCAN_PROPERTY p; memset(&p, 0, sizeof p);
    p.source.source = source; p.mode = mode; p.wBitDepth = bits; p.dwDpiX = p.dwDpiY = dpi;
    p.scan_area.xySize.x = w; p.scan_area.xySize.y = h; p.scan_area.unit = unit;
    SCANAPI_IMAGE_INFO i; memset(&i, 0, sizeof i);
    SCANAPI_RET r = t->GetImageLayout(&p, &i);
    printf("src=%-2u mode=%u bits=%-2u dpi=%-4u unit=%u %.1fx%.1f -> ret=%-4d pixel=%-5u byte=%-5u line=%-5u off=%u,%u\n",
           source, mode, bits, dpi, unit, w, h, r, i.dwPixel, i.dwByte, i.dwLine, i.dwOffsetX, i.dwOffsetY);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    void *lib = dlopen(SCANAPI_PATH, RTLD_NOW | RTLD_LOCAL);
    t = ((SCANAPI_FUNCTION_TABLE *(*)(void))dlsym(lib, "SCANAPI_GetFunctionTable"))();
    SCANAPI_VERSION_INFO v = {0};
    SCANAPI_RET rr = t->Register(&v);
    printf("Register -> %d\n", rr);
    if (rr != 0) return 2;

    void *caps = NULL;
    printf("GetDeviceCapability -> %d caps=%p\n", t->GetDeviceCapability(&caps), caps);
    if (caps) {
        void **src = (void **)caps;  /* pSourceCaps[5] */
        for (int k = 0; k < 5; k++) printf("  pSourceCaps[%d] = %p\n", k, src[k]);
    }
    puts("-- source");
    for (uint32_t s = 0; s <= 16; s++) layout(s, 2, 24, 300, 0, 8.5, 11);
    puts("-- mode (source 8)");
    for (uint32_t m = 0; m <= 6; m++) { layout(8, m, 24, 300, 0, 8.5, 11); layout(8, m, 8, 300, 0, 8.5, 11); }
    puts("-- unit (source 8)");
    for (uint32_t u = 0; u <= 3; u++) layout(8, 2, 24, 300, u, 4, 6);
    printf("Unregister -> %d\n", t->Unregister());
    return 0;
}
