// Scans one sheet through Plustek's engine and writes it as PNG.
// Usage: scantest <out.png> [dpi] [mode 0=bw 1=gray 2=color] [source]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include "scanapi.h"

#define SCANAPI_PATH "/Applications/Plustek/ePhoto Z300/ScanApi.framework/ScanApi"

static SCANAPI_RET callback(SCANAPI_CALLBACK_CODE code, uint32_t value) {
    fprintf(stderr, "  callback code=%u value=%u\n", code, value);
    return 0;
}

/* apiScannerEventCallback(handler, context, enable): the engine delivers device events (paper inserted = button 1)
 * here, and apiStartScan does not proceed while an event is pending without a handler. */
typedef int32_t (*EVENT_HANDLER)(uint32_t event, int32_t value, void *ctx);
static volatile int paper_inserted;
static int32_t on_event(uint32_t event, int32_t value, void *ctx) {
    fprintf(stderr, "  event id=%u value=%d\n", event, value);
    if (event == 2 && value == 1) paper_inserted = 1;   /* button 1 = paper sensor */
    return 0;
}

static int write_png(const char *path, uint8_t *rgb, size_t w, size_t h, size_t stride, int gray) {
    CGColorSpaceRef cs = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, rgb, stride * h, NULL);
    CGImageRef img = CGImageCreate(w, h, 8, gray ? 8 : 24, stride, cs, kCGImageAlphaNone, dp, NULL, false, kCGRenderingIntentDefault);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(d, img, NULL);
    bool ok = CGImageDestinationFinalize(d);
    CFRelease(d); CFRelease(url); CGImageRelease(img); CGDataProviderRelease(dp); CGColorSpaceRelease(cs);
    return ok ? 0 : -1;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *out = argc > 1 ? argv[1] : "scan.png";
    uint32_t dpi = argc > 2 ? (uint32_t)atoi(argv[2]) : 300;
    uint32_t mode = argc > 3 ? (uint32_t)atoi(argv[3]) : 2;
    uint32_t source = argc > 4 ? (uint32_t)atoi(argv[4]) : 8;

    void *lib = dlopen(SCANAPI_PATH, RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    SCANAPI_FUNCTION_TABLE *t = ((SCANAPI_FUNCTION_TABLE *(*)(void))dlsym(lib, "SCANAPI_GetFunctionTable"))();
    SCANAPI_VERSION_INFO v = {0};
    SCANAPI_RET r = t->Register(&v);
    printf("Register -> %d\n", r);
    if (r != 0) return 2;

    SCANAPI_RET (*setEventHandler)(EVENT_HANDLER, void *, bool) = (SCANAPI_RET (*)(EVENT_HANDLER, void *, bool))t->ScannerEventCallback;
    printf("ScannerEventCallback -> %d\n", setEventHandler(on_event, NULL, true));
    void *caps = NULL;
    printf("GetDeviceCapability -> %d\n", t->GetDeviceCapability(&caps));

    SCANAPI_SCAN_PROPERTY p; memset(&p, 0, sizeof p);
    p.source.source = source; p.mode = mode; p.wBitDepth = 8; p.dwDpiX = p.dwDpiY = dpi;
    p.scan_area.xySize.x = 8.5; p.scan_area.xySize.y = 14; p.scan_area.unit = SCANAPI_UNIT_INCH;
    SCANAPI_IMAGE_INFO li; memset(&li, 0, sizeof li);
    r = t->GetImageLayout(&p, &li);
    printf("GetImageLayout -> %d: %u px, %u bytes/line, %u lines\n", r, li.dwPixel, li.dwByte, li.dwLine);
    if (r != 0) goto done;

    uint8_t *ss = calloc(1, 0x800);   /* engine copies SCANAPI_STARTSCAN_COPY bytes */
    SCANAPI_STARTSCAN *s = (SCANAPI_STARTSCAN *)ss;
    s->pscan_property = &p;
    s->pfnCallback = callback;
    s->ScanCount = 1;
    s->flag = 1u << 16;   /* end the scan at the paper's end: Read then returns 6 ("PaperOut") */
    /* -97: no paper in the feeder. Wait for the paper sensor's event, then try again. */
    for (int waited = 0; (r = t->StartScan(s)) == -97 && waited < 600; waited++) {
        if (waited == 0) printf("waiting for a photo...\n");
        paper_inserted = 0;
        for (int i = 0; i < 10 && !paper_inserted; i++) usleep(100000);
    }
    printf("StartScan -> %d\n", r);
    if (r != 0) goto done;

    /* Read takes a byte count and reports whole lines read. */
    size_t chunk = (size_t)li.dwByte * 300, cap = (size_t)li.dwByte * li.dwLine, lines = 0;
    uint8_t *img = malloc(cap + chunk);
    for (int i = 0; i < 10000; i++) {
        uint32_t got = 0;
        r = t->Read(img + lines * li.dwByte, (uint32_t)chunk, &got);
        lines += got;
        if (i < 2 || r != 0) printf("Read #%d -> %d, %u lines (total %zu)\n", i, r, got, lines);
        if (r != 0 || got == 0 || (lines + 300) * li.dwByte > cap + chunk) break;
    }
    printf("StopScan -> %d\n", t->StopScan());
    printf("EndScan -> %d\n", t->EndScan(true));
    printf("total %zu lines of %u bytes\n", lines, li.dwByte);
    if (lines && mode != 0) printf("png -> %d\n", write_png(out, img, li.dwPixel, lines, li.dwByte, mode == 1));
done:
    printf("Unregister -> %d\n", t->Unregister());
    return 0;
}
