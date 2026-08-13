/* Narrow C surface over pipewire, the other way round.
 *
 * capture.h's twin: the same reason for existing - translate-c cannot parse
 * spa's macro-heavy headers, so pipewire stays in C and zig only sees floats.
 * Playback is the simpler half. There is no registry and there are no links to
 * make by hand, because a playback stream is exactly the thing the session
 * manager already knows how to connect. */
#ifndef CADENCE_PLAYBACK_H
#define CADENCE_PLAYBACK_H

#include <stdint.h>

typedef struct cadence_playback cadence_playback;

/* name is what shows up in a mixer. ring_frames must be a power of two, and
 * is how far ahead the writer is allowed to get - it sets the cost of a
 * flush, since everything queued behind the playhead has to be thrown away. */
cadence_playback *cadence_play_open(const char *name, uint32_t rate,
				    uint32_t channels, uint32_t ring_frames);

/* Connects and starts the loop on its own thread. 0 on success. */
int cadence_play_start(cadence_playback *p);

/* Frames of room in the ring. */
uint32_t cadence_play_space(const cadence_playback *p);

/* Writes interleaved frames, never blocking. Returns how many it took, which
 * is min(frames, space). */
uint32_t cadence_play_write(cadence_playback *p, const float *src, uint32_t frames);

/* Frames handed to the sink since open, counted in the writer's own stream:
 * the frame at index `cadence_play_pos()` is the one being heard. It does not
 * move while paused, and a flush jumps it forward to the flush point.
 *
 * Accurate to the quantum, which is 256 frames - about 5ms at 48k. What it
 * does not know about is any buffering past our own node. */
uint64_t cadence_play_pos(const cadence_playback *p);

/* Silence out, and the position holds where it is. */
void cadence_play_pause(cadence_playback *p, int paused);
int cadence_play_paused(const cadence_playback *p);

/* Throws away everything queued but not yet played, and returns the position
 * that will be reached once it has taken effect - which is what a seek needs
 * in order to say where the new audio starts. Anything written after this call
 * survives, so the sequence is: flush, then write from the new position. */
uint64_t cadence_play_flush(cadence_playback *p);

void cadence_play_stop(cadence_playback *p);
void cadence_play_close(cadence_playback *p);

const char *cadence_play_error(const cadence_playback *p);

/* Frames of silence the sink had to be given because the writer was late.
 * Should stay 0. */
uint64_t cadence_play_underruns(const cadence_playback *p);

#endif
