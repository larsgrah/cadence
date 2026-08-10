#include "capture.h"

#include <errno.h>
#include <semaphore.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/utils/result.h>

struct cadence_capture {
	struct pw_thread_loop *loop;
	struct pw_stream *stream;
	struct spa_hook listener;

	char *target;
	uint32_t rate;

	/* spsc ring. the process callback is the only writer and runs on the
	 * data thread, the reader is whoever called cadence_read */
	float *ring;
	uint32_t mask;
	_Atomic uint32_t head; /* write */
	_Atomic uint32_t tail; /* read */
	_Atomic uint64_t dropped;

	sem_t sem;
	_Atomic int running;
	_Atomic int posted;

	char err[256];
};

static void on_process(void *userdata)
{
	cadence_capture *c = userdata;

	struct pw_buffer *b = pw_stream_dequeue_buffer(c->stream);
	if (b == NULL)
		return;

	struct spa_data *d = &b->buffer->datas[0];
	const float *src = d->data;
	if (src != NULL && d->chunk->size > 0) {
		uint32_t n = d->chunk->size / sizeof(float);
		uint32_t head = atomic_load_explicit(&c->head, memory_order_relaxed);
		uint32_t tail = atomic_load_explicit(&c->tail, memory_order_acquire);
		uint32_t space = (c->mask + 1) - (head - tail);

		/* a reader that fell behind gets the newest samples, not the
		 * oldest. a visualiser that catches up by replaying history is
		 * worse than one that skips */
		if (n > space) {
			atomic_fetch_add_explicit(&c->dropped, n - space, memory_order_relaxed);
			src += n - space;
			n = space;
		}
		for (uint32_t i = 0; i < n; i++)
			c->ring[(head + i) & c->mask] = src[i];

		atomic_store_explicit(&c->head, head + n, memory_order_release);

		/* one post per wakeup, not one per buffer. the reader drains
		 * everything it finds, so a backlog of posts just spins it */
		if (atomic_exchange_explicit(&c->posted, 1, memory_order_acq_rel) == 0)
			sem_post(&c->sem);
	}

	pw_stream_queue_buffer(c->stream, b);
}

static void on_state_changed(void *userdata, enum pw_stream_state old,
			     enum pw_stream_state state, const char *error)
{
	cadence_capture *c = userdata;
	(void)old;

	if (state == PW_STREAM_STATE_ERROR) {
		snprintf(c->err, sizeof(c->err), "stream error: %s",
			 error ? error : "unknown");
		cadence_stop(c);
	} else if (state == PW_STREAM_STATE_UNCONNECTED) {
		cadence_stop(c);
	}
}

static const struct pw_stream_events stream_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = on_state_changed,
	.process = on_process,
};

cadence_capture *cadence_open(const char *target, uint32_t rate, uint32_t ring_frames)
{
	if (ring_frames == 0 || (ring_frames & (ring_frames - 1)) != 0)
		return NULL;

	cadence_capture *c = calloc(1, sizeof(*c));
	if (c == NULL)
		return NULL;

	c->rate = rate;
	c->mask = ring_frames - 1;
	c->ring = calloc(ring_frames, sizeof(float));
	if (c->ring == NULL) {
		free(c);
		return NULL;
	}
	if (sem_init(&c->sem, 0, 0) != 0) {
		free(c->ring);
		free(c);
		return NULL;
	}

	if (target != NULL && target[0] != '\0') {
		size_t len = strlen(target);
		const char *suffix = ".monitor";
		size_t slen = strlen(suffix);
		if (len > slen && strcmp(target + len - slen, suffix) == 0)
			len -= slen;
		c->target = strndup(target, len);
	}

	atomic_store(&c->running, 1);
	return c;
}

int cadence_start(cadence_capture *c)
{
	pw_init(NULL, NULL);

	c->loop = pw_thread_loop_new("cadence", NULL);
	if (c->loop == NULL) {
		snprintf(c->err, sizeof(c->err), "pw_thread_loop_new failed");
		return -1;
	}

	struct pw_properties *props = pw_properties_new(
		PW_KEY_MEDIA_TYPE, "Audio",
		PW_KEY_MEDIA_CATEGORY, "Capture",
		PW_KEY_MEDIA_ROLE, "Music",
		/* the whole point: attach to a sink and read what it plays,
		 * rather than naming its .monitor node by hand */
		PW_KEY_STREAM_CAPTURE_SINK, "true",
		PW_KEY_NODE_NAME, "cadence",
		NULL);
	if (props == NULL) {
		snprintf(c->err, sizeof(c->err), "out of memory");
		return -1;
	}
	if (c->target != NULL)
		pw_properties_set(props, PW_KEY_TARGET_OBJECT, c->target);

	/* small quantum, since the point of owning the client is that the
	 * buffer stops being someone else's decision */
	pw_properties_setf(props, PW_KEY_NODE_LATENCY, "256/%u", c->rate);

	pw_thread_loop_lock(c->loop);

	c->stream = pw_stream_new_simple(pw_thread_loop_get_loop(c->loop),
					 "cadence", props, &stream_events, c);
	if (c->stream == NULL) {
		pw_thread_loop_unlock(c->loop);
		snprintf(c->err, sizeof(c->err), "pw_stream_new_simple failed");
		return -1;
	}

	uint8_t pod_buf[1024];
	struct spa_pod_builder bld = SPA_POD_BUILDER_INIT(pod_buf, sizeof(pod_buf));
	struct spa_audio_info_raw info = {
		.format = SPA_AUDIO_FORMAT_F32,
		.rate = c->rate,
		.channels = 1,
		.position = { SPA_AUDIO_CHANNEL_MONO },
	};
	/* asking for mono f32 at a fixed rate puts audioconvert in the graph,
	 * so the downmix and any resample are pipewire's problem, not ours */
	const struct spa_pod *params[1] = {
		spa_format_audio_raw_build(&bld, SPA_PARAM_EnumFormat, &info),
	};

	int res = pw_stream_connect(c->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
				    PW_STREAM_FLAG_AUTOCONNECT |
					    PW_STREAM_FLAG_MAP_BUFFERS |
					    PW_STREAM_FLAG_RT_PROCESS,
				    params, 1);
	pw_thread_loop_unlock(c->loop);

	if (res < 0) {
		snprintf(c->err, sizeof(c->err), "connect failed: %s", spa_strerror(res));
		return -1;
	}
	if (pw_thread_loop_start(c->loop) != 0) {
		snprintf(c->err, sizeof(c->err), "pw_thread_loop_start failed");
		return -1;
	}
	return 0;
}

uint32_t cadence_read(cadence_capture *c, float *dst, uint32_t max)
{
	for (;;) {
		if (!atomic_load_explicit(&c->running, memory_order_acquire))
			return 0;

		uint32_t tail = atomic_load_explicit(&c->tail, memory_order_relaxed);
		uint32_t head = atomic_load_explicit(&c->head, memory_order_acquire);
		uint32_t avail = head - tail;

		if (avail > 0) {
			uint32_t n = avail < max ? avail : max;
			for (uint32_t i = 0; i < n; i++)
				dst[i] = c->ring[(tail + i) & c->mask];
			atomic_store_explicit(&c->tail, tail + n, memory_order_release);
			return n;
		}

		atomic_store_explicit(&c->posted, 0, memory_order_release);
		/* recheck after clearing the flag, or a buffer that landed in
		 * the gap sleeps until the next one arrives */
		if (atomic_load_explicit(&c->head, memory_order_acquire) != tail)
			continue;

		while (sem_wait(&c->sem) != 0 && errno == EINTR)
			;
	}
}

void cadence_stop(cadence_capture *c)
{
	if (atomic_exchange(&c->running, 0) == 0)
		return;
	sem_post(&c->sem);
}

void cadence_close(cadence_capture *c)
{
	if (c == NULL)
		return;
	if (c->loop != NULL) {
		pw_thread_loop_stop(c->loop);
		if (c->stream != NULL)
			pw_stream_destroy(c->stream);
		pw_thread_loop_destroy(c->loop);
		pw_deinit();
	}
	sem_destroy(&c->sem);
	free(c->target);
	free(c->ring);
	free(c);
}

const char *cadence_error(const cadence_capture *c)
{
	return c->err;
}

uint64_t cadence_dropped(const cadence_capture *c)
{
	return atomic_load_explicit(&c->dropped, memory_order_relaxed);
}
