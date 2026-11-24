#ifndef RE4_DUALSENSE_NATIVE_PROFILES_H
#define RE4_DUALSENSE_NATIVE_PROFILES_H

#include <stdbool.h>
#include <stdint.h>

// A trigger effect after the game's own DualSense conversion rules.
// Positions and strengths are normalized to 0–1.
typedef enum {
    NativeTriggerOff,
    NativeTriggerFeedback,   // start, strength
    NativeTriggerWeapon,     // start, end, strength
    NativeTriggerVibration,  // start, amplitude, frequency
} NativeTriggerKind;

typedef struct {
    NativeTriggerKind kind;
    float values[3];
} NativeTriggerEffect;

// True once the game's weapon trigger profiles are hooked for this session.
bool nativeTriggersEnabled(void);

// Copies the latest L2 and R2 effects. Returns false when nothing changed
// since `generation`, which is updated on success.
bool nativeTriggersSnapshot(uint64_t *generation, NativeTriggerEffect effects[2]);

// Current physical L2 and R2 pull (0–1), used for the profile's vibration
// threshold. Call from the main thread whenever the controller is polled.
void nativeTriggersSetPull(float left, float right);

#endif
