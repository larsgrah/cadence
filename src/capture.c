#include "capture.h"

#include <ctype.h>
#include <errno.h>
#include <semaphore.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/utils/result.h>

/* Capturing one application is not a target you can ask for.
 *
 * Setting PW_KEY_TARGET_OBJECT to an application's node is quietly ignored:
 * the session manager links capture streams to *sources*, and an application
 * playing audio is a Stream/Output/Audio, not a source. Verified by recording
 * with the target set and getting silence.
 *
 * So the links get made by hand. Watch the registry for a node whose name
 * matches, find its output ports, and create a link from each of them to our
 * own input port through the link factory. Several outputs into one input is
 * how pipewire mixes, so a stereo application arrives already summed. */
#define MAX_LINKS 16

struct port {
	uint32_t id;
	uint32_t node_id;
	int is_output;
};

struct cadence_capture {
	struct pw_thread_loop *loop;
	struct pw_stream *stream;
	struct spa_hook listener;

	struct pw_core *core;
	struct pw_registry *registry;
	struct spa_hook registry_listener;

	char *app;
	uint32_t target_node;
	uint32_t our_node;
	uint32_t our_input;

	struct port *ports;
	uint32_t port_count;
	uint32_t port_cap;

	struct pw_proxy *links[MAX_LINKS];
	uint32_t linked_from[MAX_LINKS];
	uint32_t link_count;

	char *target;
	uint32_t rate;

	/* spsc ring. the process callback is the only writer and runs on the
	 * data thread, the reader is whoever called cadence_read */
	float *ring;
	uint32_t mask;
	_Atomic uint32_t head; /* write */
	_Atomic uint32_t tail; /* read */
	_Atomic uint64_t dropped;

	/* reader side only, so no atomic. the last dropped count it acted on */
	uint64_t seen_dropped;

	sem_t sem;
	_Atomic int running;
	_Atomic int posted;

	char err[256];
};

static int contains_ci(const char *hay, const char *needle)
{
	if (hay == NULL || needle == NULL)
		return 0;
	size_t nl = strlen(needle);
	if (nl == 0)
		return 0;
	for (const char *p = hay; *p != '\0'; p++) {
		size_t i = 0;
		while (i < nl && p[i] != '\0' &&
		       tolower((unsigned char)p[i]) == tolower((unsigned char)needle[i]))
			i++;
		if (i == nl)
			return 1;
	}
	return 0;
}

/* The registry hands out every port in the graph, not just the ones we want,
 * and a desktop with a browser open has well over a hundred. This grows rather
 * than capping: a cap that fills before the target's ports arrive stops the
 * capture attaching at all, and looks exactly like the application not
 * playing. Returns 0 only if the allocation failed. */
static int port_push(cadence_capture *c, uint32_t id, uint32_t node_id, int is_output)
{
	if (c->port_count == c->port_cap) {
		uint32_t cap = c->port_cap ? c->port_cap * 2 : 64;
		struct port *p = realloc(c->ports, cap * sizeof(*p));
		if (p == NULL)
			return 0;
		c->ports = p;
		c->port_cap = cap;
	}
	c->ports[c->port_count++] = (struct port){
		.id = id, .node_id = node_id, .is_output = is_output
	};
	return 1;
}

/* Links every known output port of the target node to our input port. Safe to
 * call repeatedly - ports arrive one at a time and out of order, so this runs
 * again on each one rather than trying to find the moment they are all in. */
static void relink(cadence_capture *c)
{
	if (c->target_node == 0 || c->our_node == 0)
		return;

	/* our own input port is resolved here rather than when it arrives:
	 * the registry hands out ports before pw_stream_get_node_id() has an
	 * answer, so at insert time there is nothing to compare against */
	if (c->our_input == 0) {
		for (uint32_t i = 0; i < c->port_count; i++) {
			if (c->ports[i].node_id == c->our_node && !c->ports[i].is_output) {
				c->our_input = c->ports[i].id;
				break;
			}
		}
	}
	if (c->our_input == 0)
		return;

	for (uint32_t i = 0; i < c->port_count; i++) {
		struct port *p = &c->ports[i];
		if (p->node_id != c->target_node || !p->is_output)
			continue;

		int already = 0;
		for (uint32_t j = 0; j < c->link_count; j++)
			if (c->linked_from[j] == p->id)
				already = 1;
		if (already || c->link_count >= MAX_LINKS)
			continue;

		char out_s[16], in_s[16];
		snprintf(out_s, sizeof(out_s), "%u", p->id);
		snprintf(in_s, sizeof(in_s), "%u", c->our_input);

		struct pw_properties *props = pw_properties_new(
			PW_KEY_LINK_OUTPUT_PORT, out_s,
			PW_KEY_LINK_INPUT_PORT, in_s,
			/* the link must not outlive us */
			PW_KEY_OBJECT_LINGER, "false",
			NULL);
		if (props == NULL)
			continue;

		struct pw_proxy *link = pw_core_create_object(
			c->core, "link-factory", PW_TYPE_INTERFACE_Link,
			PW_VERSION_LINK, &props->dict, 0);
		pw_properties_free(props);

		if (link == NULL)
			continue;

		c->links[c->link_count] = link;
		c->linked_from[c->link_count] = p->id;
		c->link_count++;
	}
}

static void drop_links(cadence_capture *c)
{
	for (uint32_t i = 0; i < c->link_count; i++)
		if (c->links[i] != NULL)
			pw_proxy_destroy(c->links[i]);
	c->link_count = 0;
}

static void on_global(void *userdata, uint32_t id, uint32_t permissions,
		      const char *type, uint32_t version,
		      const struct spa_dict *props)
{
	cadence_capture *c = userdata;
	(void)permissions;
	(void)version;

	if (props == NULL)
		return;

	if (spa_streq(type, PW_TYPE_INTERFACE_Port)) {
		const char *node_s = spa_dict_lookup(props, PW_KEY_NODE_ID);
		const char *dir = spa_dict_lookup(props, PW_KEY_PORT_DIRECTION);
		if (node_s == NULL || dir == NULL)
			return;

		uint32_t node_id = (uint32_t)strtoul(node_s, NULL, 10);
		int is_output = spa_streq(dir, "out");

		if (port_push(c, id, node_id, is_output))
			relink(c);
		return;
	}

	if (!spa_streq(type, PW_TYPE_INTERFACE_Node) || c->app == NULL)
		return;
	if (c->target_node != 0)
		return;

	/* only nodes that are an application playing audio. without this the
	 * match also catches the sink named after the app, and devices */
	const char *class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
	if (!spa_streq(class, "Stream/Output/Audio"))
		return;

	const char *cands[] = {
		spa_dict_lookup(props, PW_KEY_APP_NAME),
		spa_dict_lookup(props, PW_KEY_NODE_NAME),
		spa_dict_lookup(props, PW_KEY_MEDIA_NAME),
	};
	for (size_t i = 0; i < SPA_N_ELEMENTS(cands); i++) {
		if (contains_ci(cands[i], c->app)) {
			c->target_node = id;
			relink(c);
			return;
		}
	}
}

static void on_global_remove(void *userdata, uint32_t id)
{
	cadence_capture *c = userdata;

	if (id == c->target_node) {
		/* the links die with the node, so only our side needs clearing */
		c->target_node = 0;
		drop_links(c);
	}

	for (uint32_t i = 0; i < c->port_count; i++) {
		if (c->ports[i].id != id)
			continue;
		c->ports[i] = c->ports[c->port_count - 1];
		c->port_count--;
		break;
	}

	for (uint32_t i = 0; i < c->link_count; i++) {
		if (c->linked_from[i] != id)
			continue;
		if (c->links[i] != NULL)
			pw_proxy_destroy(c->links[i]);
		c->links[i] = c->links[c->link_count - 1];
		c->linked_from[i] = c->linked_from[c->link_count - 1];
		c->link_count--;
		break;
	}
}

static const struct pw_registry_events registry_events = {
	PW_VERSION_REGISTRY_EVENTS,
	.global = on_global,
	.global_remove = on_global_remove,
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

		/* no room, so the whole buffer goes rather than the part of it
		 * that fits. the reader resyncs to live when it sees the dropped
		 * count move, so anything squeezed in here is only samples it is
		 * about to skip past anyway */
		if (n > space) {
			atomic_fetch_add_explicit(&c->dropped, n, memory_order_relaxed);
		} else {
			for (uint32_t i = 0; i < n; i++)
				c->ring[(head + i) & c->mask] = src[i];

			atomic_store_explicit(&c->head, head + n, memory_order_release);

			/* one post per wakeup, not one per buffer. the reader
			 * drains everything it finds, so a backlog of posts just
			 * spins it */
			if (atomic_exchange_explicit(&c->posted, 1, memory_order_acq_rel) == 0)
				sem_post(&c->sem);
		}
	}

	pw_stream_queue_buffer(c->stream, b);
}

static void on_state_changed(void *userdata, enum pw_stream_state old,
			     enum pw_stream_state state, const char *error)
{
	cadence_capture *c = userdata;
	(void)old;

	/* the node does not exist yet when connect() returns, so this is the
	 * first point at which we can know our own id */
	if (c->app != NULL && c->our_node == 0) {
		uint32_t id = pw_stream_get_node_id(c->stream);
		if (id != SPA_ID_INVALID) {
			c->our_node = id;
			relink(c);
		}
	}

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

cadence_capture *cadence_open(const char *target, const char *app, uint32_t rate,
			      uint32_t ring_frames)
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

	if (app != NULL && app[0] != '\0')
		c->app = strdup(app);

	if (c->app == NULL && target != NULL && target[0] != '\0') {
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
		PW_KEY_NODE_NAME, "cadence",
		NULL);
	if (props == NULL) {
		snprintf(c->err, sizeof(c->err), "out of memory");
		return -1;
	}
	if (c->app == NULL) {
		/* attach to a sink and read what it plays, rather than naming
		 * its .monitor node by hand */
		pw_properties_set(props, PW_KEY_STREAM_CAPTURE_SINK, "true");
		if (c->target != NULL)
			pw_properties_set(props, PW_KEY_TARGET_OBJECT, c->target);
	}

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

	/* in app mode there must be no autoconnect: the session manager would
	 * link us to a source, and then we would be listening to the
	 * microphone while waiting for the application to show up */
	enum pw_stream_flags flags = PW_STREAM_FLAG_MAP_BUFFERS |
				     PW_STREAM_FLAG_RT_PROCESS;
	if (c->app == NULL)
		flags |= PW_STREAM_FLAG_AUTOCONNECT;

	int res = pw_stream_connect(c->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
				    flags, params, 1);

	if (res >= 0 && c->app != NULL) {
		/* the stream already holds a connection, so the registry rides
		 * on that rather than opening a second one. it is only needed
		 * to build links by hand, so a sink capture never opens it */
		c->core = pw_stream_get_core(c->stream);
		if (c->core != NULL) {
			c->registry = pw_core_get_registry(c->core, PW_VERSION_REGISTRY, 0);
			if (c->registry != NULL)
				pw_registry_add_listener(c->registry,
							 &c->registry_listener,
							 &registry_events, c);
		}
		if (c->registry == NULL) {
			pw_thread_loop_unlock(c->loop);
			snprintf(c->err, sizeof(c->err), "could not open the registry");
			return -1;
		}
	}

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

		/* the writer threw a buffer away, so everything still sitting in
		 * the ring is older than what was lost. jump to live rather than
		 * working through a backlog that is stale before it is read. a
		 * visualiser that catches up by replaying history is worse than
		 * one that skips */
		uint64_t dropped = atomic_load_explicit(&c->dropped, memory_order_relaxed);
		if (dropped != c->seen_dropped) {
			c->seen_dropped = dropped;
			tail = head;
			atomic_store_explicit(&c->tail, tail, memory_order_release);
		}

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
		drop_links(c);
		if (c->registry != NULL)
			pw_proxy_destroy((struct pw_proxy *)c->registry);
		/* the core belongs to the stream, so it is not ours to
		 * disconnect */
		if (c->stream != NULL)
			pw_stream_destroy(c->stream);
		pw_thread_loop_destroy(c->loop);
		pw_deinit();
	}
	sem_destroy(&c->sem);
	free(c->app);
	free(c->target);
	free(c->ports);
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

int cadence_attached(const cadence_capture *c)
{
	if (c->app == NULL)
		return 1;
	return c->link_count > 0;
}
