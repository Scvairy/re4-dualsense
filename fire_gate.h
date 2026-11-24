#ifndef RE4_DUALSENSE_FIRE_GATE_H
#define RE4_DUALSENSE_FIRE_GATE_H

@class GCControllerButtonInput;

// Holds back R2 presses until `breakPoint` (0–1 of trigger travel).
// Pass nil or 0 to let R2 through unchanged.
void fireGateSet(GCControllerButtonInput *trigger, float breakPoint);

// The trigger's physical value, ignoring the gate.
float fireGateRawValue(GCControllerButtonInput *trigger);

#endif
