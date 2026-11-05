/*
 * SANE backend "plustek_scanapi": drives Plustek scanners through Plustek's own macOS engine
 * (ScanApi.framework, shipped with the vendor software) instead of a reimplemented USB protocol.
 *
 * The engine interface is reconstructed in ../scanapi/scanapi.h. Behaviour this backend relies on,
 * all observed on an ePhoto Z300 (07b3:131c):
 *   - source 4 is the sheet feeder (the only non-null entry of the device's source capabilities);
 *   - apiStartScan returns -97 while the feeder is empty, and succeeds once the paper sensor fires;
 *   - STARTSCAN.flag bit 16 ends the scan at the paper's end, apiRead then returns 6 ("PaperOut");
 *   - apiRead takes a byte count and reports whole lines;
 *   - apiRegister returns -90 while another process (ePhoto) holds the scanner.
 *
 * A photo is scanned completely in sane_start, cropped to its edges against the scanner's black backing,
 * and then served from memory, so sane_get_parameters reports the exact size once a scan has started.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <dlfcn.h>
#include <glob.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sane/sane.h>
#include <sane/saneopts.h>

#include "../scanapi/scanapi.h"

#define BACKEND_NAME "plustek_scanapi"
#define BUILD 1
#define DEFAULT_ENGINE_GLOB "/Applications/Plustek/*/ScanApi.framework/ScanApi"
#define SHEETFED_SOURCE 4
#define RET_NO_PAPER (-97)
#define RET_BUSY (-90)
#define RET_PAPER_OUT 6
#define FLAG_STOP_AT_PAPER_END (1u << 16)
#define MM_PER_INCH 25.4

/* The Z300 Scan app holds the scanner between scans; it lets go when asked and takes it back on resume. */
#define BRIDGE_RELEASE "z300bridge.release"
#define BRIDGE_RESUME "z300bridge.resume"
#define TAKE_ATTEMPTS 32         /* x 250 ms: time for the app to let go and the scanner to re-enumerate */

/* ---- logging ------------------------------------------------------------------------------------- */

static int debug_level;

static void dbg(int level, const char *fmt, ...) {
    if (level > debug_level) return;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[" BACKEND_NAME "] ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

/* ---- configuration --------------------------------------------------------------------------------- */

static char engine_paths[8][PATH_MAX];
static int n_engine_paths;
static int first_page_wait_s = 60;    /* how long sane_start waits for a photo at the start of a batch */
static int next_page_wait_s = 10;     /* ... and for each further photo of the same batch */
/* Raw scans come out oversaturated and dark; these match the Z300 Scan app's defaults (see adjust()). */
static double saturation = 0.85;
static double gamma_value = 1.6;

static void read_config(void) {
    const char *dirs = getenv("SANE_CONFIG_DIR");
    char path[PATH_MAX];
    FILE *f = NULL;
    if (dirs) {
        char copy[PATH_MAX];
        snprintf(copy, sizeof copy, "%s", dirs);
        for (char *d = strtok(copy, ":"); d && !f; d = strtok(NULL, ":")) {
            snprintf(path, sizeof path, "%s/" BACKEND_NAME ".conf", d);
            f = fopen(path, "r");
        }
    }
    if (!f) return;
    char line[PATH_MAX + 32];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        char *v;
        if (line[0] == '#' || !line[0]) continue;
        if (!strncmp(line, "engine ", 7) && n_engine_paths < 8) {
            for (v = line + 7; *v == ' '; v++) {}
            snprintf(engine_paths[n_engine_paths++], PATH_MAX, "%s", v);
        } else if (!strncmp(line, "first-page-wait ", 16)) {
            first_page_wait_s = atoi(line + 16);
        } else if (!strncmp(line, "next-page-wait ", 15)) {
            next_page_wait_s = atoi(line + 15);
        } else if (!strncmp(line, "saturation ", 11)) {
            saturation = atof(line + 11);
        } else if (!strncmp(line, "gamma ", 6)) {
            gamma_value = atof(line + 6);
        }
    }
    fclose(f);
}

/* ---- engines and devices --------------------------------------------------------------------------- */

typedef struct {
    char engine[PATH_MAX];
    char name[64];       /* SANE device name */
    char model[64];
    int vid, pids[2];
} Engine;

static Engine engines[8];
static int n_engines;
static SANE_Device sane_devices[8];
static const SANE_Device *device_list[9];

/* Reads VendorID / ProudctID / ProudctID2 / ProductString from the engine's Prereference.plist
 * (the keys are misspelled in Plustek's file). */
static int load_engine_info(const char *engine_path, Engine *e) {
    char plist[PATH_MAX];
    snprintf(plist, sizeof plist, "%s", engine_path);
    char *slash = strrchr(plist, '/');
    if (!slash) return -1;
    snprintf(slash, sizeof plist - (size_t)(slash - plist), "/Resources/Prereference.plist");

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)plist, (CFIndex)strlen(plist), false);
    CFReadStreamRef s = CFReadStreamCreateWithFile(NULL, url);
    CFRelease(url);
    if (!s || !CFReadStreamOpen(s)) { if (s) CFRelease(s); return -1; }
    CFPropertyListRef root = CFPropertyListCreateWithStream(NULL, s, 0, kCFPropertyListImmutable, NULL, NULL);
    CFReadStreamClose(s);
    CFRelease(s);
    if (!root) return -1;

    int ok = -1;
    CFDictionaryRef id = CFGetTypeID(root) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(root, CFSTR("ScannerID")) : NULL;
    if (id && CFGetTypeID(id) == CFDictionaryGetTypeID()) {
        CFNumberRef n;
        CFStringRef str;
        memset(e, 0, sizeof *e);
        snprintf(e->engine, sizeof e->engine, "%s", engine_path);
        if ((n = CFDictionaryGetValue(id, CFSTR("VendorID")))) CFNumberGetValue(n, kCFNumberIntType, &e->vid);
        if ((n = CFDictionaryGetValue(id, CFSTR("ProudctID")))) CFNumberGetValue(n, kCFNumberIntType, &e->pids[0]);
        if ((n = CFDictionaryGetValue(id, CFSTR("ProudctID2")))) CFNumberGetValue(n, kCFNumberIntType, &e->pids[1]);
        if ((str = CFDictionaryGetValue(id, CFSTR("ProductString"))))
            CFStringGetCString(str, e->model, sizeof e->model, kCFStringEncodingUTF8);
        char *suffix = strstr(e->model, "_Scanner");
        if (suffix) *suffix = 0;
        snprintf(e->name, sizeof e->name, "%04x:%04x", e->vid, e->pids[0]);   /* dll prefixes the backend name */
        ok = e->vid ? 0 : -1;
    }
    CFRelease(root);
    return ok;
}

static int usb_device_present(int vid, int pid) {
    if (!vid || !pid) return 0;
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid), p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), p);
    CFRelease(v);
    CFRelease(p);
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) != KERN_SUCCESS) return 0;
    io_object_t dev = IOIteratorNext(it);
    int present = dev != 0;
    if (dev) IOObjectRelease(dev);
    IOObjectRelease(it);
    return present;
}

static int engine_connected(const Engine *e) {
    return usb_device_present(e->vid, e->pids[0]) || usb_device_present(e->vid, e->pids[1]);
}

static void find_engines(void) {
    n_engines = 0;
    if (n_engine_paths) {
        for (int i = 0; i < n_engine_paths && n_engines < 8; i++)
            if (!load_engine_info(engine_paths[i], &engines[n_engines])) n_engines++;
        return;
    }
    glob_t g;
    if (glob(DEFAULT_ENGINE_GLOB, 0, NULL, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc && n_engines < 8; i++)
            if (!load_engine_info(g.gl_pathv[i], &engines[n_engines])) n_engines++;
        globfree(&g);
    }
}

/* ---- options ---------------------------------------------------------------------------------------- */

enum {
    OPT_NUM_OPTS, OPT_STANDARD_GROUP, OPT_MODE, OPT_RESOLUTION, OPT_SOURCE,
    OPT_GEOMETRY_GROUP, OPT_TL_X, OPT_TL_Y, OPT_BR_X, OPT_BR_Y,
    OPT_ENHANCEMENT_GROUP, OPT_AUTO_CROP, NUM_OPTIONS
};

static SANE_String_Const mode_list[] = { SANE_VALUE_SCAN_MODE_COLOR, SANE_VALUE_SCAN_MODE_GRAY, NULL };
static SANE_String_Const source_list[] = { "Automatic Document Feeder", NULL };
/* The engine's gray mode and resolutions below 300 dpi break the Z300's feed (the motor's resolution is logged as
 * 0, it jolts and the sheet does not advance). The scanner always scans in colour at 300 or 600 dpi; gray and
 * 150 dpi are made from that. */
static const SANE_Word resolution_list[] = { 3, 150, 300, 600 };
static const SANE_Range x_range = { 0, SANE_FIX(215.9), 0 };     /* 8.5 in */
static const SANE_Range y_range = { 0, SANE_FIX(914.4), 0 };     /* 36 in, MaxPaperLength in the engine config */

typedef struct {
    Engine *engine;
    void *lib;
    SCANAPI_FUNCTION_TABLE *t;
    SANE_Option_Descriptor opt[NUM_OPTIONS];
    char mode[16];
    SANE_Word resolution, tl_x, tl_y, br_x, br_y;
    SANE_Bool auto_crop;
    int registered;            /* the engine holds the scanner (apiRegister succeeded) */
    int batch_pages;           /* photos scanned since open or the last cancel */
    uint8_t *image;            /* finished scan, tightly packed */
    size_t image_size, served;
    SANE_Parameters params;
    int have_image;
} Scanner;

static volatile int paper_inserted;

static void init_options(Scanner *s) {
    SANE_Option_Descriptor *o = s->opt;
    memset(o, 0, sizeof s->opt);

    o[OPT_NUM_OPTS] = (SANE_Option_Descriptor){ SANE_NAME_NUM_OPTIONS, SANE_TITLE_NUM_OPTIONS, SANE_DESC_NUM_OPTIONS,
        SANE_TYPE_INT, SANE_UNIT_NONE, sizeof(SANE_Word), SANE_CAP_SOFT_DETECT, SANE_CONSTRAINT_NONE, { NULL } };
    o[OPT_STANDARD_GROUP] = (SANE_Option_Descriptor){ "", "Scan Mode", "", SANE_TYPE_GROUP, SANE_UNIT_NONE, 0, 0,
        SANE_CONSTRAINT_NONE, { NULL } };
    o[OPT_MODE] = (SANE_Option_Descriptor){ SANE_NAME_SCAN_MODE, SANE_TITLE_SCAN_MODE, SANE_DESC_SCAN_MODE,
        SANE_TYPE_STRING, SANE_UNIT_NONE, 16, SANE_CAP_SOFT_SELECT | SANE_CAP_SOFT_DETECT,
        SANE_CONSTRAINT_STRING_LIST, { .string_list = mode_list } };
    o[OPT_RESOLUTION] = (SANE_Option_Descriptor){ SANE_NAME_SCAN_RESOLUTION, SANE_TITLE_SCAN_RESOLUTION,
        SANE_DESC_SCAN_RESOLUTION, SANE_TYPE_INT, SANE_UNIT_DPI, sizeof(SANE_Word),
        SANE_CAP_SOFT_SELECT | SANE_CAP_SOFT_DETECT, SANE_CONSTRAINT_WORD_LIST, { .word_list = resolution_list } };
    o[OPT_SOURCE] = (SANE_Option_Descriptor){ SANE_NAME_SCAN_SOURCE, SANE_TITLE_SCAN_SOURCE, SANE_DESC_SCAN_SOURCE,
        SANE_TYPE_STRING, SANE_UNIT_NONE, 32, SANE_CAP_SOFT_SELECT | SANE_CAP_SOFT_DETECT,
        SANE_CONSTRAINT_STRING_LIST, { .string_list = source_list } };
    o[OPT_GEOMETRY_GROUP] = (SANE_Option_Descriptor){ "", "Geometry", "", SANE_TYPE_GROUP, SANE_UNIT_NONE, 0, 0,
        SANE_CONSTRAINT_NONE, { NULL } };
    const SANE_Int geo = SANE_CAP_SOFT_SELECT | SANE_CAP_SOFT_DETECT;
    o[OPT_TL_X] = (SANE_Option_Descriptor){ SANE_NAME_SCAN_TL_X, SANE_TITLE_SCAN_TL_X, SANE_DESC_SCAN_TL_X,
        SANE_TYPE_FIXED, SANE_UNIT_MM, sizeof(SANE_Word), geo, SANE_CONSTRAINT_RANGE, { .range = &x_range } };
    o[OPT_TL_Y] = (SANE_Option_Descriptor){ SANE_NAME_SCAN_TL_Y, SANE_TITLE_SCAN_TL_Y, SANE_DESC_SCAN_TL_Y,
        SANE_TYPE_FIXED, SANE_UNIT_MM, sizeof(SANE_Word), geo, SANE_CONSTRAINT_RANGE, { .range = &y_range } };
    o[OPT_BR_X] = (SANE_Option_Descriptor){ SANE_NAME_SCAN_BR_X, SANE_TITLE_SCAN_BR_X, SANE_DESC_SCAN_BR_X,
        SANE_TYPE_FIXED, SANE_UNIT_MM, sizeof(SANE_Word), geo, SANE_CONSTRAINT_RANGE, { .range = &x_range } };
    o[OPT_BR_Y] = (SANE_Option_Descriptor){ SANE_NAME_SCAN_BR_Y, SANE_TITLE_SCAN_BR_Y, SANE_DESC_SCAN_BR_Y,
        SANE_TYPE_FIXED, SANE_UNIT_MM, sizeof(SANE_Word), geo, SANE_CONSTRAINT_RANGE, { .range = &y_range } };
    o[OPT_ENHANCEMENT_GROUP] = (SANE_Option_Descriptor){ "", "Enhancement", "", SANE_TYPE_GROUP, SANE_UNIT_NONE, 0,
        0, SANE_CONSTRAINT_NONE, { NULL } };
    o[OPT_AUTO_CROP] = (SANE_Option_Descriptor){ "auto-crop", "Crop to photo",
        "Trim the scanner's black backing around the photo.", SANE_TYPE_BOOL, SANE_UNIT_NONE, sizeof(SANE_Word),
        SANE_CAP_SOFT_SELECT | SANE_CAP_SOFT_DETECT, SANE_CONSTRAINT_NONE, { NULL } };

    snprintf(s->mode, sizeof s->mode, "%s", SANE_VALUE_SCAN_MODE_COLOR);
    s->resolution = 300;
    s->tl_x = s->tl_y = 0;
    s->br_x = x_range.max;
    s->br_y = SANE_FIX(279.4);     /* US Letter length; the scan still ends at the photo's end */
    s->auto_crop = SANE_TRUE;
}

static int is_color(const Scanner *s) { return !strcmp(s->mode, SANE_VALUE_SCAN_MODE_COLOR); }

/* Parameters for the requested area, before a scan knows the photo's real size. */
static void estimate_params(Scanner *s, SANE_Parameters *p) {
    double w_in = SANE_UNFIX(s->br_x - s->tl_x) / MM_PER_INCH, h_in = SANE_UNFIX(s->br_y - s->tl_y) / MM_PER_INCH;
    p->format = is_color(s) ? SANE_FRAME_RGB : SANE_FRAME_GRAY;
    p->last_frame = SANE_TRUE;
    p->depth = 8;
    p->pixels_per_line = (SANE_Int)(w_in * s->resolution);
    p->lines = (SANE_Int)(h_in * s->resolution);
    p->bytes_per_line = p->pixels_per_line * (is_color(s) ? 3 : 1);
}

/* ---- engine callbacks ------------------------------------------------------------------------------- */

static SCANAPI_RET on_progress(SCANAPI_CALLBACK_CODE code, uint32_t value) {
    dbg(3, "progress code=%u value=%u", code, value);
    return 0;
}

/* Device events. apiStartScan does not proceed while an event is pending without a handler. */
typedef int32_t (*EVENT_HANDLER)(uint32_t event, int32_t value, void *ctx);
static int32_t on_event(uint32_t event, int32_t value, void *ctx) {
    dbg(2, "event id=%u value=%d", event, value);
    if (event == 2 && value == 1) paper_inserted = 1;   /* button 1 is the paper sensor */
    return 0;
}

/* ---- cropping --------------------------------------------------------------------------------------- */

/* Finds the photo against the black backing: rows and columns with enough pixels brighter than the
 * backing. Leaves the image alone when nothing photo-sized stands out. */
static void auto_crop(Scanner *s, uint8_t *img, int width, int height, int bpp) {
    const int threshold = 48, min_size = s->resolution / 2;     /* half an inch */
    int top = -1, bottom = -1, left = width, right = -1;
    int *col_hits = calloc((size_t)width, sizeof(int));
    for (int y = 0; y < height; y++) {
        const uint8_t *row = img + (size_t)y * width * bpp;
        int hits = 0;
        for (int x = 0; x < width; x++) {
            const uint8_t *px = row + x * bpp;
            int lum = bpp == 3 ? (px[0] * 3 + px[1] * 6 + px[2]) / 10 : px[0];
            if (lum > threshold) { hits++; col_hits[x]++; }
        }
        if (hits > width / 50) { if (top < 0) top = y; bottom = y; }
    }
    int rows = bottom - top + 1;
    for (int x = 0; x < width; x++)
        if (rows > 0 && col_hits[x] > rows / 50) { if (x < left) left = x; right = x; }
    free(col_hits);
    if (top < 0 || right - left + 1 < min_size || rows < min_size) {
        dbg(1, "auto-crop: no photo edges found, keeping the full scan");
        return;
    }
    int w = right - left + 1, h = rows;
    for (int y = 0; y < h; y++)
        memmove(img + (size_t)y * w * bpp, img + ((size_t)(top + y) * width + left) * bpp, (size_t)w * bpp);
    dbg(1, "auto-crop: %dx%d -> %dx%d at (%d,%d)", width, height, w, h, left, top);
    s->params.pixels_per_line = w;
    s->params.bytes_per_line = w * bpp;
    s->params.lines = h;
    s->image_size = (size_t)w * h * bpp;
}

/* Averages each factor x factor block into one pixel, in place. */
static void downscale(uint8_t *img, int *width, size_t *lines, int bpp, int factor) {
    const int w = *width / factor, n = factor * factor;
    const size_t h = *lines / (size_t)factor;
    for (size_t y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            for (int c = 0; c < bpp; c++) {
                int sum = 0;
                for (int dy = 0; dy < factor; dy++) {
                    const uint8_t *row = img + ((y * factor + dy) * (size_t)*width) * bpp;
                    for (int dx = 0; dx < factor; dx++) sum += row[(x * factor + dx) * bpp + c];
                }
                img[(y * w + x) * bpp + c] = (uint8_t)((sum + n / 2) / n);   /* never overtakes the rows it reads */
            }
    *width = w;
    *lines = h;
}

/* Scales each pixel's colour around its luma by `saturation`, then lifts midtones with `gamma`
 * (black and white stay put). Same as Imaging.adjust in the app. */
static void adjust(uint8_t *img, size_t size, int bpp) {
    if (saturation == 1 && gamma_value == 1) return;
    uint8_t lut[256];
    for (int i = 0; i < 256; i++) lut[i] = (uint8_t)fmin(255, round(255 * pow(i / 255.0, 1 / gamma_value)));
    if (bpp == 1) {
        for (size_t i = 0; i < size; i++) img[i] = lut[img[i]];
        return;
    }
    const float s = (float)saturation;
    for (size_t i = 0; i + 2 < size; i += 3) {
        float r = img[i], g = img[i + 1], b = img[i + 2], y = 0.299f * r + 0.587f * g + 0.114f * b;
        img[i] = lut[(int)fminf(255, fmaxf(0, roundf(y + s * (r - y))))];
        img[i + 1] = lut[(int)fminf(255, fmaxf(0, roundf(y + s * (g - y))))];
        img[i + 2] = lut[(int)fminf(255, fmaxf(0, roundf(y + s * (b - y))))];
    }
}

/* ---- SANE entry points ------------------------------------------------------------------------------ */

SANE_Status sane_plustek_scanapi_init(SANE_Int *version_code, SANE_Auth_Callback authorize) {
    const char *d = getenv("SANE_DEBUG_PLUSTEK_SCANAPI");
    debug_level = d ? atoi(d) : 0;
    if (version_code) *version_code = SANE_VERSION_CODE(SANE_CURRENT_MAJOR, SANE_CURRENT_MINOR, BUILD);
    read_config();
    find_engines();
    dbg(1, "init: %d engine(s)", n_engines);
    return SANE_STATUS_GOOD;
}

void sane_plustek_scanapi_exit(void) {}

SANE_Status sane_plustek_scanapi_get_devices(const SANE_Device ***list, SANE_Bool local_only) {
    int n = 0;
    /* Every installed engine is listed, connected or not: frontends that enumerate once (AirSane without
     * hotplug) then still offer the scanner after it is plugged in. */
    for (int i = 0; i < n_engines; i++) {
        Engine *e = &engines[i];
        dbg(1, "get_devices: %s %s", e->model, engine_connected(e) ? "connected" : "not connected");
        sane_devices[n] = (SANE_Device){ e->name, "Plustek", e->model, "sheetfed scanner" };
        device_list[n] = &sane_devices[n];
        n++;
    }
    device_list[n] = NULL;
    *list = device_list;
    dbg(1, "get_devices: %d", n);
    return SANE_STATUS_GOOD;
}

SANE_Status sane_plustek_scanapi_open(SANE_String_Const name, SANE_Handle *handle) {
    Engine *e = NULL;
    for (int i = 0; i < n_engines && !e; i++)
        if (!name || !*name || !strcmp(name, engines[i].name)) e = &engines[i];
    if (!e) return SANE_STATUS_INVAL;

    void *lib = dlopen(e->engine, RTLD_NOW | RTLD_LOCAL);
    if (!lib) { dbg(1, "dlopen %s: %s", e->engine, dlerror()); return SANE_STATUS_IO_ERROR; }
    SCANAPI_FUNCTION_TABLE *(*get_table)(void) = (SCANAPI_FUNCTION_TABLE * (*)(void)) dlsym(lib, "SCANAPI_GetFunctionTable");
    if (!get_table) return SANE_STATUS_IO_ERROR;

    Scanner *s = calloc(1, sizeof *s);
    s->engine = e;
    s->lib = lib;
    s->t = get_table();
    init_options(s);
    *handle = s;
    dbg(1, "open %s", e->name);
    return SANE_STATUS_GOOD;
}

static void post_bridge(const char *name) {
    CFStringRef n = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(), n, NULL, NULL, true);
    CFRelease(n);
}

/* The engine takes the scanner on apiRegister, and makes it re-enumerate on USB on apiUnregister. So it is
 * only taken when a scan starts, and released when the frontend closes the handle. */
static SANE_Status take_scanner(Scanner *s) {
    if (s->registered) return SANE_STATUS_GOOD;
    if (!engine_connected(s->engine)) { dbg(1, "scanner not connected"); return SANE_STATUS_IO_ERROR; }
    post_bridge(BRIDGE_RELEASE);
    SCANAPI_VERSION_INFO v = { 0 };
    SCANAPI_RET r = RET_BUSY;
    for (int i = 0; i < TAKE_ATTEMPTS && (r = s->t->Register(&v)) == RET_BUSY; i++) usleep(250000);
    dbg(1, "Register -> %d", r);
    if (r != 0) {
        post_bridge(BRIDGE_RESUME);
        return r == RET_BUSY ? SANE_STATUS_DEVICE_BUSY : SANE_STATUS_IO_ERROR;
    }
    ((SCANAPI_RET(*)(EVENT_HANDLER, void *, bool))s->t->ScannerEventCallback)(on_event, NULL, true);
    void *caps = NULL;
    s->t->GetDeviceCapability(&caps);
    s->registered = 1;
    return SANE_STATUS_GOOD;
}

static void drop_image(Scanner *s) {
    free(s->image);
    s->image = NULL;
    s->image_size = s->served = 0;
    s->have_image = 0;
}

void sane_plustek_scanapi_close(SANE_Handle h) {
    Scanner *s = h;
    drop_image(s);
    if (s->registered) {
        s->t->Unregister();
        post_bridge(BRIDGE_RESUME);
    }
    dbg(1, "close");
    free(s);   /* the engine stays loaded: it may still own threads */
}

const SANE_Option_Descriptor *sane_plustek_scanapi_get_option_descriptor(SANE_Handle h, SANE_Int n) {
    Scanner *s = h;
    return n >= 0 && n < NUM_OPTIONS ? &s->opt[n] : NULL;
}

static SANE_Word *word_option(Scanner *s, SANE_Int n) {
    switch (n) {
    case OPT_RESOLUTION: return &s->resolution;
    case OPT_TL_X: return &s->tl_x;
    case OPT_TL_Y: return &s->tl_y;
    case OPT_BR_X: return &s->br_x;
    case OPT_BR_Y: return &s->br_y;
    case OPT_AUTO_CROP: return &s->auto_crop;
    default: return NULL;
    }
}

SANE_Status sane_plustek_scanapi_control_option(SANE_Handle h, SANE_Int n, SANE_Action action, void *value,
                                                SANE_Int *info) {
    Scanner *s = h;
    if (info) *info = 0;
    if (n < 0 || n >= NUM_OPTIONS || s->opt[n].type == SANE_TYPE_GROUP) return SANE_STATUS_INVAL;

    if (action == SANE_ACTION_GET_VALUE) {
        if (n == OPT_NUM_OPTS) *(SANE_Word *)value = NUM_OPTIONS;
        else if (n == OPT_MODE) strcpy(value, s->mode);
        else if (n == OPT_SOURCE) strcpy(value, source_list[0]);
        else *(SANE_Word *)value = *word_option(s, n);
        return SANE_STATUS_GOOD;
    }
    if (action != SANE_ACTION_SET_VALUE || n == OPT_NUM_OPTS) return SANE_STATUS_INVAL;

    SANE_Int reload = SANE_INFO_RELOAD_PARAMS;
    if (n == OPT_MODE || n == OPT_SOURCE) {
        const SANE_String_Const *list = n == OPT_MODE ? mode_list : source_list;
        int i = 0;
        while (list[i] && strcmp(list[i], value)) i++;
        if (!list[i]) return SANE_STATUS_INVAL;
        if (n == OPT_MODE) snprintf(s->mode, sizeof s->mode, "%s", list[i]);
    } else if (n == OPT_RESOLUTION) {
        SANE_Word want = *(SANE_Word *)value, best = resolution_list[1];
        for (int i = 1; i <= resolution_list[0]; i++)
            if (abs(resolution_list[i] - want) < abs(best - want)) best = resolution_list[i];
        if (best != want) reload |= SANE_INFO_INEXACT;
        s->resolution = best;
    } else if (n == OPT_AUTO_CROP) {
        s->auto_crop = *(SANE_Word *)value ? SANE_TRUE : SANE_FALSE;
    } else {
        const SANE_Range *r = s->opt[n].constraint.range;
        SANE_Word v = *(SANE_Word *)value;
        if (v < r->min || v > r->max) { v = v < r->min ? r->min : r->max; reload |= SANE_INFO_INEXACT; }
        *word_option(s, n) = v;
    }
    if (info) *info = reload;
    return SANE_STATUS_GOOD;
}

SANE_Status sane_plustek_scanapi_get_parameters(SANE_Handle h, SANE_Parameters *p) {
    Scanner *s = h;
    if (s->have_image) *p = s->params;
    else estimate_params(s, p);
    return SANE_STATUS_GOOD;
}

SANE_Status sane_plustek_scanapi_start(SANE_Handle h) {
    Scanner *s = h;
    drop_image(s);
    SANE_Status taken = take_scanner(s);
    if (taken != SANE_STATUS_GOOD) return taken;

    SCANAPI_SCAN_PROPERTY prop;
    memset(&prop, 0, sizeof prop);
    prop.source.source = SHEETFED_SOURCE;
    prop.mode = 2;   /* always colour, see resolution_list */
    prop.wBitDepth = 8;
    const int scan_dpi = s->resolution > 300 ? 600 : 300, factor = scan_dpi / s->resolution;
    prop.dwDpiX = prop.dwDpiY = (uint32_t)scan_dpi;
    prop.scan_area.xyOrigin.x = SANE_UNFIX(s->tl_x) / MM_PER_INCH;
    prop.scan_area.xyOrigin.y = SANE_UNFIX(s->tl_y) / MM_PER_INCH;
    prop.scan_area.xySize.x = SANE_UNFIX(s->br_x - s->tl_x) / MM_PER_INCH;
    prop.scan_area.xySize.y = SANE_UNFIX(s->br_y - s->tl_y) / MM_PER_INCH;
    prop.scan_area.unit = SCANAPI_UNIT_INCH;

    SCANAPI_IMAGE_INFO layout;
    memset(&layout, 0, sizeof layout);
    SCANAPI_RET r = s->t->GetImageLayout(&prop, &layout);
    dbg(1, "start: %s %d dpi (scanned at %d), layout -> %d: %u px, %u bytes/line, %u lines", s->mode, s->resolution,
        scan_dpi, r, layout.dwPixel, layout.dwByte, layout.dwLine);
    if (r != 0 || !layout.dwPixel || !layout.dwLine) return SANE_STATUS_INVAL;

    static uint8_t startscan[0x800];   /* apiStartScan copies SCANAPI_STARTSCAN_COPY bytes */
    memset(startscan, 0, sizeof startscan);
    SCANAPI_STARTSCAN *ss = (SCANAPI_STARTSCAN *)startscan;
    ss->pscan_property = &prop;
    ss->pfnCallback = on_progress;
    ss->ScanCount = 1;
    ss->flag = FLAG_STOP_AT_PAPER_END;

    int wait_s = s->batch_pages ? next_page_wait_s : first_page_wait_s;
    int waited_ds = 0;
    while ((r = s->t->StartScan(ss)) == RET_NO_PAPER && waited_ds < wait_s * 10) {
        if (!waited_ds) dbg(1, "start: feeder empty, waiting up to %d s for a photo", wait_s);
        paper_inserted = 0;
        for (int i = 0; i < 5 && !paper_inserted; i++, waited_ds++) usleep(100000);
    }
    dbg(1, "start: StartScan -> %d", r);
    if (r == RET_NO_PAPER) return SANE_STATUS_NO_DOCS;
    if (r != 0) return SANE_STATUS_IO_ERROR;

    const size_t stride = layout.dwByte, packed = (size_t)layout.dwPixel * 3, chunk_lines = 300;
    uint8_t *raw = malloc(stride * (layout.dwLine + chunk_lines));
    size_t lines = 0;
    SANE_Status status = SANE_STATUS_GOOD;
    while (lines < layout.dwLine) {
        uint32_t got = 0;
        r = s->t->Read(raw + lines * stride, (uint32_t)(stride * chunk_lines), &got);
        lines += got;
        if (r == RET_PAPER_OUT || r == 2 || got == 0) break;     /* 2: no more data */
        if (r != 0) { dbg(1, "read -> %d", r); status = SANE_STATUS_IO_ERROR; break; }
    }
    s->t->StopScan();
    s->t->EndScan(true);
    if (lines > layout.dwLine) lines = layout.dwLine;
    dbg(1, "start: read %zu lines (last Read -> %d)", lines, r);
    if (status != SANE_STATUS_GOOD || !lines) { free(raw); return status != SANE_STATUS_GOOD ? status : SANE_STATUS_IO_ERROR; }

    if (stride != packed)
        for (size_t y = 1; y < lines; y++) memmove(raw + y * packed, raw + y * stride, packed);
    int width = (int)layout.dwPixel;
    const int bpp = is_color(s) ? 3 : 1;
    if (bpp == 1)
        for (size_t i = 0; i < (size_t)width * lines; i++)   /* luma, Rec. 601 weights; overwrites only read bytes */
            raw[i] = (uint8_t)((299 * raw[3 * i] + 587 * raw[3 * i + 1] + 114 * raw[3 * i + 2] + 500) / 1000);
    if (factor > 1) {
        downscale(raw, &width, &lines, bpp, factor);
        dbg(1, "start: averaged down to %d x %zu", width, lines);
    }
    s->image = raw;
    s->image_size = (size_t)width * bpp * lines;
    s->params = (SANE_Parameters){ bpp == 3 ? SANE_FRAME_RGB : SANE_FRAME_GRAY, SANE_TRUE, width * bpp, width,
                                   (SANE_Int)lines, 8 };
    if (s->auto_crop) auto_crop(s, s->image, width, (int)lines, bpp);
    adjust(s->image, s->image_size, bpp);
    s->have_image = 1;
    s->batch_pages++;
    return SANE_STATUS_GOOD;
}

SANE_Status sane_plustek_scanapi_read(SANE_Handle h, SANE_Byte *buf, SANE_Int max_len, SANE_Int *len) {
    Scanner *s = h;
    *len = 0;
    if (!s->have_image) return SANE_STATUS_INVAL;
    if (s->served >= s->image_size) return SANE_STATUS_EOF;
    size_t n = s->image_size - s->served;
    if (n > (size_t)max_len) n = (size_t)max_len;
    memcpy(buf, s->image + s->served, n);
    s->served += n;
    *len = (SANE_Int)n;
    return SANE_STATUS_GOOD;
}

void sane_plustek_scanapi_cancel(SANE_Handle h) {
    Scanner *s = h;
    drop_image(s);
    s->batch_pages = 0;
}

SANE_Status sane_plustek_scanapi_set_io_mode(SANE_Handle h, SANE_Bool non_blocking) {
    return non_blocking ? SANE_STATUS_UNSUPPORTED : SANE_STATUS_GOOD;
}

SANE_Status sane_plustek_scanapi_get_select_fd(SANE_Handle h, SANE_Int *fd) {
    return SANE_STATUS_UNSUPPORTED;
}
