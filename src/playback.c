#include "playback.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/utils/result.h>

struct cadence_playback {
	struct pw_thread_loop *loop;
	struct pw_stream *stream;
	struct spa_hook listener;

	char *name;
	uint32_t rate;
	uint32_t channels;

	/* spsc ring of interleaved frames. the caller is the only writer, the
	 * process callback on the data thread the only reader */
	float *ring;
	uint32_t frames; /* capacity in frames, a power of two */
	uint32_t mask;
	_Atomic uint64_t head; /* write, in frames */
	_Atomic uint64_t tail; /* read, in frames */

	/* a seek cannot move head backwards - the writer would then be behind
	 * the reader and the ring would read as almost full rather than empty.
	 * so a flush publishes the point to skip to and the data thread, which
	 * is the only owner of tail, moves it. anything written after the flush
	 * sits past that point and survives */
	_Atomic uint64_t drop_to;
	uint64_t dropped_seen;

	_Atomic int paused;
	_Atomic int running;
	_Atomic uint64_t underruns;

	char err[256];
};

static void on_process(void *userdata)
{
	cadence_playback *p = userdata;

	struct pw_buffer *b = pw_stream_dequeue_buffer(p->stream);
	if (b == NULL)
		return;

	struct spa_data *d = &b->buffer->datas[0];
	float *dst = d->data;
	if (dst == NULL) {
		pw_stream_queue_buffer(p->stream, b);
		return;
	}

	const uint32_t stride = sizeof(float) * p->channels;
	uint32_t want = d->maxsize / stride;
	if (b->requested != 0 && b->requested < want)
		want = (uint32_t)b->requested;

	uint64_t tail = atomic_load_explicit(&p->tail, memory_order_relaxed);

	/* a flush asked for everything up to this point to be skipped. tail is
	 * ours, so this is the only place it can happen */
	uint64_t drop_to = atomic_load_explicit(&p->drop_to, memory_order_acquire);
	if (drop_to != p->dropped_seen) {
		p->dropped_seen = drop_to;
		if (tail < drop_to)
			tail = drop_to;
	}

	uint32_t filled = 0;
	if (!atomic_load_explicit(&p->paused, memory_order_relaxed)) {
		uint64_t head = atomic_load_explicit(&p->head, memory_order_acquire);
		uint64_t avail = head > tail ? head - tail : 0;
		uint32_t n = avail < want ? (uint32_t)avail : want;

		for (uint32_t i = 0; i < n; i++) {
			const float *src = &p->ring[((tail + i) & p->mask) * p->channels];
			for (uint32_t c = 0; c < p->channels; c++)
				dst[i * p->channels + c] = src[c];
		}
		filled = n;

		if (n > 0)
			atomic_store_explicit(&p->tail, tail + n, memory_order_release);
		/* head being 0 means nothing has ever been written, and the sink
		 * pulling before the first write is not the writer being late */
		if (n < want && head > 0)
			atomic_fetch_add_explicit(&p->underruns, want - n,
						  memory_order_relaxed);
	}

	/* the sink gets a full buffer either way. handing it a short one is a
	 * different sound to handing it silence, and paused should be silence */
	if (filled < want)
		memset(&dst[filled * p->channels], 0, (want - filled) * stride);

	d->chunk->offset = 0;
	d->chunk->stride = (int32_t)stride;
	d->chunk->size = want * stride;

	pw_stream_queue_buffer(p->stream, b);
}

static void on_state_changed(void *userdata, enum pw_stream_state old,
			     enum pw_stream_state state, const char *error)
{
	cadence_playback *p = userdata;
	(void)old;

	if (state == PW_STREAM_STATE_ERROR) {
		snprintf(p->err, sizeof(p->err), "stream error: %s",
			 error ? error : "unknown");
		atomic_store(&p->running, 0);
	} else if (state == PW_STREAM_STATE_UNCONNECTED) {
		atomic_store(&p->running, 0);
	}
}

static const struct pw_stream_events stream_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = on_state_changed,
	.process = on_process,
};

cadence_playback *cadence_play_open(const char *name, uint32_t rate,
				    uint32_t channels, uint32_t ring_frames)
{
	if (ring_frames == 0 || (ring_frames & (ring_frames - 1)) != 0)
		return NULL;
	if (channels == 0 || channels > SPA_AUDIO_MAX_CHANNELS)
		return NULL;

	cadence_playback *p = calloc(1, sizeof(*p));
	if (p == NULL)
		return NULL;

	p->rate = rate;
	p->channels = channels;
	p->frames = ring_frames;
	p->mask = ring_frames - 1;
	p->ring = calloc((size_t)ring_frames * channels, sizeof(float));
	p->name = strdup(name != NULL && name[0] != '\0' ? name : "cadence");
	if (p->ring == NULL || p->name == NULL) {
		free(p->ring);
		free(p->name);
		free(p);
		return NULL;
	}

	atomic_store(&p->running, 1);
	return p;
}

int cadence_play_start(cadence_playback *p)
{
	pw_init(NULL, NULL);

	p->loop = pw_thread_loop_new(p->name, NULL);
	if (p->loop == NULL) {
		snprintf(p->err, sizeof(p->err), "pw_thread_loop_new failed");
		return -1;
	}

	struct pw_properties *props = pw_properties_new(
		PW_KEY_MEDIA_TYPE, "Audio",
		PW_KEY_MEDIA_CATEGORY, "Playback",
		PW_KEY_MEDIA_ROLE, "Music",
		PW_KEY_NODE_NAME, p->name,
		NULL);
	if (props == NULL) {
		snprintf(p->err, sizeof(p->err), "out of memory");
		return -1;
	}
	/* the same small quantum capture asks for. it is also how closely the
	 * position can be known, which is what the playhead is drawn from */
	pw_properties_setf(props, PW_KEY_NODE_LATENCY, "256/%u", p->rate);

	pw_thread_loop_lock(p->loop);

	p->stream = pw_stream_new_simple(pw_thread_loop_get_loop(p->loop),
					 p->name, props, &stream_events, p);
	if (p->stream == NULL) {
		pw_thread_loop_unlock(p->loop);
		snprintf(p->err, sizeof(p->err), "pw_stream_new_simple failed");
		return -1;
	}

	uint8_t pod_buf[1024];
	struct spa_pod_builder bld = SPA_POD_BUILDER_INIT(pod_buf, sizeof(pod_buf));
	struct spa_audio_info_raw info = {
		.format = SPA_AUDIO_FORMAT_F32,
		.rate = p->rate,
		.channels = p->channels,
	};
	if (p->channels == 1) {
		info.position[0] = SPA_AUDIO_CHANNEL_MONO;
	} else if (p->channels == 2) {
		info.position[0] = SPA_AUDIO_CHANNEL_FL;
		info.position[1] = SPA_AUDIO_CHANNEL_FR;
	}
	const struct spa_pod *params[1] = {
		spa_format_audio_raw_build(&bld, SPA_PARAM_EnumFormat, &info),
	};

	int res = pw_stream_connect(p->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
				    PW_STREAM_FLAG_AUTOCONNECT |
					    PW_STREAM_FLAG_MAP_BUFFERS |
					    PW_STREAM_FLAG_RT_PROCESS,
				    params, 1);

	pw_thread_loop_unlock(p->loop);

	if (res < 0) {
		snprintf(p->err, sizeof(p->err), "connect failed: %s", spa_strerror(res));
		return -1;
	}
	if (pw_thread_loop_start(p->loop) != 0) {
		snprintf(p->err, sizeof(p->err), "pw_thread_loop_start failed");
		return -1;
	}
	return 0;
}

uint32_t cadence_play_space(const cadence_playback *p)
{
	uint64_t head = atomic_load_explicit(&p->head, memory_order_relaxed);
	uint64_t tail = atomic_load_explicit(&p->tail, memory_order_acquire);
	return p->frames - (uint32_t)(head - tail);
}

uint32_t cadence_play_write(cadence_playback *p, const float *src, uint32_t frames)
{
	uint32_t space = cadence_play_space(p);
	uint32_t n = frames < space ? frames : space;
	if (n == 0)
		return 0;

	uint64_t head = atomic_load_explicit(&p->head, memory_order_relaxed);
	for (uint32_t i = 0; i < n; i++) {
		float *dst = &p->ring[((head + i) & p->mask) * p->channels];
		for (uint32_t c = 0; c < p->channels; c++)
			dst[c] = src[i * p->channels + c];
	}
	atomic_store_explicit(&p->head, head + n, memory_order_release);
	return n;
}

uint64_t cadence_play_pos(const cadence_playback *p)
{
	uint64_t tail = atomic_load_explicit(&p->tail, memory_order_relaxed);
	uint64_t drop_to = atomic_load_explicit(&p->drop_to, memory_order_relaxed);
	/* a flush the data thread has not woken up for yet has still happened,
	 * as far as anyone asking where we are is concerned */
	return tail > drop_to ? tail : drop_to;
}

void cadence_play_pause(cadence_playback *p, int paused)
{
	atomic_store_explicit(&p->paused, paused ? 1 : 0, memory_order_relaxed);
}

int cadence_play_paused(const cadence_playback *p)
{
	return atomic_load_explicit(&p->paused, memory_order_relaxed);
}

uint64_t cadence_play_flush(cadence_playback *p)
{
	uint64_t head = atomic_load_explicit(&p->head, memory_order_relaxed);
	atomic_store_explicit(&p->drop_to, head, memory_order_release);
	return head;
}

void cadence_play_stop(cadence_playback *p)
{
	atomic_store(&p->running, 0);
	if (p->loop != NULL)
		pw_thread_loop_stop(p->loop);
}

void cadence_play_close(cadence_playback *p)
{
	if (p == NULL)
		return;
	if (p->loop != NULL) {
		pw_thread_loop_stop(p->loop);
		if (p->stream != NULL)
			pw_stream_destroy(p->stream);
		pw_thread_loop_destroy(p->loop);
		pw_deinit();
	}
	free(p->ring);
	free(p->name);
	free(p);
}

const char *cadence_play_error(const cadence_playback *p)
{
	return p->err;
}

uint64_t cadence_play_underruns(const cadence_playback *p)
{
	return atomic_load_explicit(&p->underruns, memory_order_relaxed);
}
