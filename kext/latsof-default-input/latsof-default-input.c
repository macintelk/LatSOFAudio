/*
 * latsof-default-input.c
 *
 * Set the LatSOF input device as the system default input. Nothing else.
 *
 *
 * Modes:
 *   default (no args) : wait (up to BOOT_WAIT_SECS) for the LatSOF input
 *                       device, set it as default, exit. Suitable for a
 *                       boot-time one-shot (RunAtLoad LaunchAgent).
 *   --watch           : keep polling every WATCH_INTERVAL seconds and
 *                       re-assert. Debug/foreground use; the shipped
 *                       LaunchAgent no longer runs this mode.
 *   --once            : same as default (explicit form).
 *   --dry-run         : find the device but don't change anything; print
 *                       what would happen. Useful for verifying install.
 *
 * Exit codes:
 *   0  set (or would set, in dry-run) successfully
 *   1  no LatSOF input device found (one-shot mode only; watch keeps trying)
 *   2  AudioObjectSetPropertyData failed
 *
 * Build:
 *   clang -O2 -Wall -arch x86_64 -arch arm64 \
 *       -framework CoreAudio -framework CoreFoundation \
 *       -o latsof-default-input latsof-default-input.c
 *
 * License: BSD-3-Clause, compatible with the LatSOF-Audio project.
 */

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

#define WATCH_INTERVAL 10          /* seconds between re-asserts in --watch */
#define BOOT_WAIT_SECS 30          /* one-shot: give up after this long */
#define BOOT_POLL_SECS  1          /* one-shot: poll interval while waiting */

static volatile sig_atomic_t gStop = 0;
static void onSignal(int sig) { (void)sig; gStop = 1; }

/* ------------------------------------------------------------------ */
/* CFString helpers                                                    */
/* ------------------------------------------------------------------ */

static Boolean cfContains(CFStringRef hay, const char *needle) {
    if (!hay) return false;
    CFStringRef n = CFStringCreateWithCString(kCFAllocatorDefault, needle,
                                              kCFStringEncodingUTF8);
    if (!n) return false;
    CFRange found = CFStringFind(hay, n, kCFCompareCaseInsensitive);
    CFRelease(n);
    return found.location != kCFNotFound;
}

static CFStringRef copyStringProp(AudioObjectID obj,
                                  AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress pa = {
        .mSelector = sel,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMaster
    };
    CFStringRef s = NULL;
    UInt32 sz = sizeof(s);
    OSStatus r = AudioObjectGetPropertyData(obj, &pa, 0, NULL, &sz, &s);
    if (r != noErr) return NULL;
    return s;
}

/* ------------------------------------------------------------------ */
/* Device discovery                                                    */
/* ------------------------------------------------------------------ */

static Boolean hasInputStreams(AudioDeviceID dev) {
    AudioObjectPropertyAddress pa = {
        .mSelector = kAudioDevicePropertyStreams,
        .mScope    = kAudioDevicePropertyScopeInput,
        .mElement  = kAudioObjectPropertyElementMaster
    };
    UInt32 sz = 0;
    OSStatus r = AudioObjectGetPropertyDataSize(dev, &pa, 0, NULL, &sz);
    if (r != noErr) return false;
    return sz > 0;
}

static AudioDeviceID findLatSOFInput(void) {
    AudioObjectPropertyAddress pa = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMaster
    };
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
                                       &pa, 0, NULL, &sz) != noErr) {
        return kAudioObjectUnknown;
    }
    UInt32 count = sz / sizeof(AudioDeviceID);
    if (count == 0) return kAudioObjectUnknown;
    AudioDeviceID *devs = (AudioDeviceID *)malloc(sz);
    if (!devs) return kAudioObjectUnknown;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                   &pa, 0, NULL, &sz, devs) != noErr) {
        free(devs);
        return kAudioObjectUnknown;
    }

    AudioDeviceID found = kAudioObjectUnknown;
    for (UInt32 i = 0; i < count; i++) {
        if (!hasInputStreams(devs[i])) continue;
        CFStringRef name = copyStringProp(devs[i], kAudioObjectPropertyName);
        CFStringRef uid  = copyStringProp(devs[i], kAudioDevicePropertyDeviceUID);
        Boolean match = (name && cfContains(name, "LatSOF")) ||
                        (uid  && cfContains(uid,  "LatSOF"));
        if (name) CFRelease(name);
        if (uid)  CFRelease(uid);
        if (match) { found = devs[i]; break; }
    }
    free(devs);
    return found;
}

/* ------------------------------------------------------------------ */
/* Default-input get/set                                               */
/* ------------------------------------------------------------------ */

static AudioDeviceID currentDefaultInput(void) {
    AudioObjectPropertyAddress pa = {
        .mSelector = kAudioHardwarePropertyDefaultInputDevice,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMaster
    };
    AudioDeviceID id = kAudioObjectUnknown;
    UInt32 sz = sizeof(id);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                   &pa, 0, NULL, &sz, &id) != noErr) {
        return kAudioObjectUnknown;
    }
    return id;
}

static int setDefaultInput(AudioDeviceID id) {
    AudioObjectPropertyAddress pa = {
        .mSelector = kAudioHardwarePropertyDefaultInputDevice,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMaster
    };
    OSStatus r = AudioObjectSetPropertyData(kAudioObjectSystemObject,
                                            &pa, 0, NULL,
                                            sizeof(id), &id);
    return (r == noErr) ? 0 : 2;
}

/* ------------------------------------------------------------------ */
/* Pretty-print                                                        */
/* ------------------------------------------------------------------ */

static void printDevice(const char *label, AudioDeviceID id) {
    if (id == kAudioObjectUnknown) {
        printf("%s: <none>\n", label);
        return;
    }
    CFStringRef name = copyStringProp(id, kAudioObjectPropertyName);
    CFStringRef uid  = copyStringProp(id, kAudioDevicePropertyDeviceUID);
    char nameBuf[256] = "?";
    char uidBuf[256]  = "?";
    if (name) CFStringGetCString(name, nameBuf, sizeof(nameBuf),
                                 kCFStringEncodingUTF8);
    if (uid)  CFStringGetCString(uid,  uidBuf,  sizeof(uidBuf),
                                 kCFStringEncodingUTF8);
    printf("%s: id=%u name=\"%s\" uid=\"%s\"\n",
           label, (unsigned)id, nameBuf, uidBuf);
    if (name) CFRelease(name);
    if (uid)  CFRelease(uid);
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [options]\n"
        "  --watch        poll every %d s and re-assert (debug only)\n"
        "  --once         wait up to %d s for the device, set it, exit\n"
        "                 (default; boot-time one-shot)\n"
        "  --dry-run      find device, print, don't change anything\n"
        "\n"
        "  Note: mic VOLUME lives in the kext now (nvram latsof.micvol);\n"
        "  this tool only fixes the default-input selection.\n",
        prog, WATCH_INTERVAL, BOOT_WAIT_SECS);
}

int main(int argc, char *argv[]) {
    int watch = 0, dry = 0;
    int waited = 0;                 /* seconds already waited in one-shot */
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--watch"))        watch = 1;
        else if (!strcmp(argv[i], "--once"))    watch = 0;
        else if (!strcmp(argv[i], "--dry-run")) dry = 1;
        else { usage(argv[0]); return 1; }
    }

    signal(SIGTERM, onSignal);
    signal(SIGINT,  onSignal);

    do {
        AudioDeviceID latsof = findLatSOFInput();
        if (latsof == kAudioObjectUnknown) {
            /* LatSOF publishes its engine ~1.5 s after kext start (deferred
             * initDSP), so the device legitimately may not exist yet. */
            if (watch) {
                if (gStop) break;
                sleep(WATCH_INTERVAL);
                continue;
            }
            /* One-shot (boot) mode: LatSOF publishes its engine ~1.5 s after
             * kext start because initDSP defers off the matching thread, and
             * a RunAtLoad agent can fire before that. Wait up to
             * BOOT_WAIT_SECS instead of dying in the race window. dry-run
             * skips the wait: it is an install check, not a boot race. */
            if (!dry && waited < BOOT_WAIT_SECS && !gStop) {
                if (waited == 0) {
                    fprintf(stderr,
                            "latsof-default-input: no LatSOF input device yet, "
                            "waiting up to %d s\n", BOOT_WAIT_SECS);
                }
                sleep(BOOT_POLL_SECS);
                waited += BOOT_POLL_SECS;
                continue;
            }
            fprintf(stderr, "latsof-default-input: no LatSOF input device found\n");
            return 1;
        }

        AudioDeviceID cur = currentDefaultInput();
        if (cur == latsof) {
            if (!watch) {
                printDevice("default input (already)", cur);
                return 0;
            }
        } else {
            printDevice("current default", cur);
            printDevice("LatSOF input   ", latsof);
            if (dry) {
                printf("dry-run: would set LatSOF as default input\n");
            } else {
                int rc = setDefaultInput(latsof);
                if (rc != 0) {
                    fprintf(stderr,
                            "latsof-default-input: setDefaultInput failed\n");
                    if (!watch) return rc;
                } else {
                    printf("latsof-default-input: OK (set id=%u as default input)\n",
                           (unsigned)latsof);
                }
            }
        }

        if (!watch) break;
        if (gStop)  break;
        sleep(WATCH_INTERVAL);
    } while (watch && !gStop);

    return 0;
}
