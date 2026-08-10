/* Narrow C surface over pipewire.
 *
 * Deliberately mentions no pipewire type. zig's translate-c cannot parse
 * spa/utils/json-core.h, and the parts it does parse badly are exactly the
 * macro-heavy ones - spa_zero, the pod builder, the _events version fields.
 * So all of that stays in C and zig only sees floats. */
#ifndef CADENCE_CAPTURE_H
#define CADENCE_CAPTURE_H

#include <stdint.h>

typedef struct cadence_capture cadence_capture;

/* target may be NULL for the default sink. A trailing ".monitor" is stripped:
 * capturing a sink is a property of the stream, not a different node name.
 * ring_frames must be a power of two. */
cadence_capture *cadence_open(const char *target, uint32_t rate, uint32_t ring_frames);

/* Connects and starts the loop on its own thread. 0 on success. */
int cadence_start(cadence_capture *c);

/* Blocks until at least one sample is available, then drains up to max of
 * them. Returns 0 only when the capture has stopped. */
uint32_t cadence_read(cadence_capture *c, float *dst, uint32_t max);

void cadence_stop(cadence_capture *c);
void cadence_close(cadence_capture *c);

const char *cadence_error(const cadence_capture *c);

/* Samples the reader was too slow to collect. Should stay 0. */
uint64_t cadence_dropped(const cadence_capture *c);

#endif
