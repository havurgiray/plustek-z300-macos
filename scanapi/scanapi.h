/*
 * Plustek ScanApi (macOS ScanApi.framework 1.4.27.13, shipped with ePhoto Z300 2.5.14): reconstructed interface,
 * written for interoperability from the engine's exported function table and symbol names, the interface types
 * visible in ePhoto's frameworks, and observing the engine while it runs. No Plustek code is included: programs
 * load the engine from the user's own ePhoto installation.
 *
 * The structures are packed (1-byte alignment).
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>

#pragma pack(push, 1)

typedef int32_t  SCANAPI_RET;            /* 0 = success (assumed) */
typedef uint32_t SCANAPI_SOURCE;         /* tagSCANAPI_SOURCE */
typedef uint32_t SCANAPI_MODE;           /* tagSCANAPI_MODE */
typedef uint32_t SCANAPI_UNIT;           /* tagSCANAPI_UNIT, from apiGetImageLayout's conversion table */
enum { SCANAPI_UNIT_300DPI = 0, SCANAPI_UNIT_INCH = 1, SCANAPI_UNIT_CM = 2, SCANAPI_UNIT_PIXEL = 3 };
typedef uint32_t SCANAPI_QUALITY;        /* tagSCANAPI_QUALITY */
typedef uint32_t SCANAPI_CHANNEL;        /* tagSCANAPI_CHANNEL */
typedef uint32_t SCANAPI_CALLBACK_CODE;  /* tagSCANAPI_CALLBACK_CODE */
typedef signed char OBJC_BOOL;           /* ObjCBool in the Swift view */

typedef struct { uint16_t wMajor, wMinor, wRelease, wBuilt; } SCANAPI_VERSION_INFO;
typedef struct { double x, y; } SCANAPI_XY;
typedef struct { SCANAPI_XY xyOrigin, xySize; SCANAPI_UNIT unit; } SCANAPI_SCAN_AREA;
typedef struct { SCANAPI_SOURCE source; uint32_t dwLens; } SCANAPI_INPUT_SOURCE;
typedef struct { uint32_t dwMin, dwDef, dwMax, dwPhy; } SCANAPI_DPI_DEF;

typedef struct {
    SCANAPI_INPUT_SOURCE source;
    SCANAPI_MODE mode;
    uint16_t wBitDepth;
    uint32_t dwDpiX, dwDpiY;
    SCANAPI_SCAN_AREA scan_area;
    uint8_t bBoundary;
    OBJC_BOOL fPreview;
} SCANAPI_SCAN_PROPERTY;

typedef struct { uint32_t dwPixel, dwByte, dwLine, dwOffsetX, dwOffsetY; } SCANAPI_IMAGE_INFO;

typedef SCANAPI_RET (*SCANAPI_CALLBACK)(SCANAPI_CALLBACK_CODE code, uint32_t value);

typedef struct {
    SCANAPI_SCAN_PROPERTY *pscan_property;
    uint32_t flag;                       /* C bitfield struct; members unknown */
    void *pCalibratedData;
    SCANAPI_CALLBACK pfnCallback;
    uint8_t *pMap;                       /* gamma map */
    SCANAPI_QUALITY quality;
    SCANAPI_CHANNEL GrayChannel;
    uint8_t a_bBackground[2];
    uint16_t ScanCount;
    uint8_t bMultiColorDropoutRGB[3];
    int32_t iSensitivity, iThreshold;
    uint16_t advance_flag;               /* C bitfield struct; members unknown */
    uint8_t bMultiExposureTimes, bIndexOfFrame;
    double dbLongPaperLength, dbShortPaperLength;
} SCANAPI_STARTSCAN;

typedef struct {
    uint16_t wVid, wPid;
    char szModule[10];
    char szManufacturer[128];
    char szProduct_Name[128];
    char szSerialNumber[128];
    char szCompany[64];
} SCANAPI_SCANNER_INFO;

/* Slots of the table returned by SCANAPI_GetFunctionTable. Unused slots are declared as void*. */
typedef struct {
    SCANAPI_RET (*Register)(SCANAPI_VERSION_INFO *);                                     /*  0 */
    SCANAPI_RET (*Unregister)(void);                                                     /*  1 */
    SCANAPI_RET (*Lock)(bool);                                                           /*  2 */
    SCANAPI_RET (*GetDeviceCapability)(void **);                                         /*  3 */
    SCANAPI_RET (*GetDeviceStatus)(SCANAPI_INPUT_SOURCE, void *);                        /*  4 */
    SCANAPI_RET (*GetImageLayout)(SCANAPI_SCAN_PROPERTY *, SCANAPI_IMAGE_INFO *);        /*  5 */
    SCANAPI_RET (*StartScan)(SCANAPI_STARTSCAN *);                                       /*  6 */
    SCANAPI_RET (*Read)(uint8_t *buf, uint32_t size, uint32_t *got);                     /*  7 */
    SCANAPI_RET (*StopScan)(void);                                                       /*  8 */
    SCANAPI_RET (*GetButtonStatus)(uint8_t *);                                           /*  9 */
    SCANAPI_RET (*TestUnitReady)(void);                                                  /* 10 */
    SCANAPI_RET (*Precalibration)(void **, SCANAPI_SCAN_PROPERTY *);                     /* 11 */
    void *LedControl, *AdfControl, *LampControl, *MotorControl, *ModuleControl,          /* 12-16 */
         *ReadCalibration, *ScannerOrigin, *WarmUpTime, *LampOffTime, *ReadOneImageLine; /* 17-21 */
    SCANAPI_RET (*Reset)(void);                                                          /* 22 */
    void *CISCalibration;                                                                /* 23 */
    SCANAPI_RET (*DoCalibration)(SCANAPI_SOURCE);                                        /* 24 */
    void *GetCalibrationInfo, *GetRegistryPath, *GetExtCapability,                       /* 25-27 */
         *SAAGetCaps, *SAAStartScan, *ScannerEventCallback, *UpgradeFirmware,            /* 28-31 */
         *GetDeviceSerialNumber, *ReadDuplex, *GetNewExtCapability, *EjectPaperControl;  /* 32-35 */
    SCANAPI_RET (*SetPaperSize)(SCANAPI_SCAN_AREA *);                                    /* 36 */
    void *GetCounterInfo, *CounterControl;                                               /* 37-38 */
    SCANAPI_RET (*EndScan)(bool);                                                        /* 39 */
    void *CalibratInterval, *RegisterWia, *UnregisterWia, *ShowColorDropoutUI,           /* 40-43 */
         *IsScaning;                                                                     /* 44 */
    SCANAPI_RET (*GetScannerInfo)(SCANAPI_SCANNER_INFO *);                               /* 45 */
    void *PaperSizeRatio;                                                                /* 46 */
} SCANAPI_FUNCTION_TABLE;

#pragma pack(pop)

/* apiStartScan copies SCANAPI_STARTSCAN_COPY bytes from the caller's pointer, more than the public struct,
 * so callers must hand it a buffer at least that large. */
#define SCANAPI_STARTSCAN_COPY 0x713

_Static_assert(sizeof(SCANAPI_SCAN_PROPERTY) == 0x3c, "SCAN_PROPERTY layout");
_Static_assert(sizeof(SCANAPI_STARTSCAN) == 0x4f, "STARTSCAN layout");
_Static_assert(sizeof(SCANAPI_FUNCTION_TABLE) == 47 * 8, "function table");
