#import <GameController/GameController.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fire_gate.h"

// The game reads R2 inside its GameController value-changed handler, using
// -isPressed for the fire button and -value for the analog amount. While R2
// has a weapon effect, both reads report "released" until the trigger passes
// the effect's break point, so shots fire on the click, not in the resistance.

static void *_Atomic gatedTrigger;
static _Atomic float gateThreshold;  // 0 = pass through
static _Atomic bool gateOpen;
static float (*originalValue)(id, SEL);
static BOOL (*originalPressed)(id, SEL);
static bool tracing;

// Releasing slightly after the click shouldn't stop automatic fire.
static const float releaseMargin = 0.06f;

static bool gatePasses(id button) {
    if ((__bridge void *)button != atomic_load(&gatedTrigger)) {
        return true;
    }
    float threshold = atomic_load(&gateThreshold);
    if (threshold <= 0) {
        return true;
    }
    float raw = originalValue(button, @selector(value));
    bool open = atomic_load(&gateOpen);
    bool next = open ? raw >= threshold - releaseMargin : raw >= threshold;
    if (next != open) {
        atomic_store(&gateOpen, next);
        if (tracing) {
            fprintf(stderr, "[fire] R2 %s at %.2f (break point %.2f)\n",
                    next ? "fires" : "held", raw, threshold);
        }
    }
    return next;
}

static float gatedValue(id button, SEL selector) {
    float value = originalValue(button, selector);
    return gatePasses(button) ? value : 0;
}

static BOOL gatedPressed(id button, SEL selector) {
    return gatePasses(button) && originalPressed(button, selector);
}

static bool installGate(GCControllerButtonInput *trigger) {
    static bool installed;
    if (installed) {
        return true;
    }
    Class buttonClass = object_getClass(trigger);
    Method value = class_getInstanceMethod(buttonClass, @selector(value));
    Method pressed = class_getInstanceMethod(buttonClass, @selector(isPressed));
    if (!value || !pressed) {
        fprintf(stderr, "RE4 DualSense: couldn't install the R2 fire gate.\n");
        return false;
    }
    originalValue = (float (*)(id, SEL))method_setImplementation(value, (IMP)gatedValue);
    originalPressed = (BOOL (*)(id, SEL))method_setImplementation(pressed, (IMP)gatedPressed);
    tracing = getenv("RE4_DUALSENSE_TRACE") != NULL;
    installed = true;
    return true;
}

void fireGateSet(GCControllerButtonInput *trigger, float breakPoint) {
    static int setting = -1;
    if (setting < 0) {
        const char *value = getenv("RE4_DUALSENSE_FIRE_GATE");
        setting = !(value && strcmp(value, "0") == 0);
    }
    if (!setting || !trigger || breakPoint <= 0 || !installGate(trigger)) {
        atomic_store(&gateThreshold, 0.0f);
        return;
    }
    if (atomic_load(&gatedTrigger) != (__bridge void *)trigger) {
        atomic_store(&gateOpen, false);
        atomic_store(&gatedTrigger, (__bridge void *)trigger);
    }
    atomic_store(&gateThreshold, breakPoint);
}

float fireGateRawValue(GCControllerButtonInput *trigger) {
    return originalValue ? originalValue(trigger, @selector(value)) : trigger.value;
}
