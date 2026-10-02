/* A stand-in for the native bridge, for test/run.lua: the same six liap_*
 * functions, but the "store" is a queue the test fills with fake_push, and
 * every call iap.lua makes is logged for fake_calls to read back. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *queue[256];
static int head, tail;
static char current[1024];
static char calls[8192];

static void logcall(const char *fmt, const char *a, int b)
{
	char line[512];
	snprintf(line, sizeof line, fmt, a ? a : "", b);
	strncat(calls, line, sizeof calls - strlen(calls) - 1);
	strncat(calls, "\n", sizeof calls - strlen(calls) - 1);
}

void fake_push(const char *line) { queue[tail++ % 256] = strdup(line); }
const char *fake_calls(void) { return calls; }
void fake_reset(void) { calls[0] = 0; }

int liap_start(const char *ids) { logcall("start %s", ids, 0); return 1; }
void liap_buy(const char *id) { logcall("buy %s", id, 0); }
void liap_finish(const char *token, int consume) { logcall("finish %s %d", token, consume); }
void liap_restore(void) { logcall("restore", NULL, 0); }
const char *liap_error(void) { return ""; }

const char *liap_poll(void)
{
	if (head == tail) return NULL;
	char *line = queue[head++ % 256];
	snprintf(current, sizeof current, "%s", line);
	free(line);
	return current;
}
